import Foundation
import AppKit

/// Owns the EQ profile library, drives the audio engine and spectrum analyzer,
/// and persists everything. One instance is shared by the menu-bar panel and
/// the Equalizer window.
@MainActor
final class EQModel: ObservableObject {
    @Published var profiles: [PEQProfile]
    @Published var profile: PEQProfile {
        didSet { profileChanged() }
    }
    @Published private(set) var isEnabled = false
    @Published private(set) var engineRunning = false
    @Published private(set) var currentSampleRate: Double?
    @Published private(set) var automaticHeadroomDB = 0.0
    @Published private(set) var clippingDetected = false
    @Published var statusMessage = ""

    let analyzer = SpectrumAnalyzer()
    private let engine = ProcessTapEngine()
    private var saveWork: DispatchWorkItem?
    private var engineApplyWork: DispatchWorkItem?
    private var clippingTimer: Timer?
    private var lastClippingEpoch: UInt64 = 0
    private var clippingVisibleUntil = Date.distantPast

    init() {
        let store = EQModel.load()
        profiles = store.profiles
        profile = store.profiles.first(where: { $0.id == store.selectedID }) ?? store.profiles[0]

        engine.onSampleRateChange = { [weak self] rate in
            Task { @MainActor in
                self?.currentSampleRate = rate
                self?.analyzer.sampleRate = rate
            }
        }
        engine.onHeadroomChange = { [weak self] attenuation in
            Task { @MainActor in self?.automaticHeadroomDB = attenuation }
        }
        engine.onRuntimeError = { [weak self] message in
            Task { @MainActor in
                guard let self else { return }
                self.engineRunning = false
                self.isEnabled = false
                self.currentSampleRate = nil
                self.automaticHeadroomDB = 0
                self.analyzer.stop()
                self.stopClippingMonitoring()
                self.statusMessage = message
            }
        }
    }

    // MARK: - Enable / engine

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled   // optimistic — the switch stays responsive

        let engine = self.engine
        let analyzer = self.analyzer

        if enabled {
            statusMessage = loc("Equalizer on — Apple Music is no longer bit-perfect.")
            let snapshot = profile
            engine.controlQueue.async { [weak self] in
                engine.setSampleSink(analyzer)
                engine.apply(profile: snapshot)
                engine.setActive(true)
                let started = engine.start()
                let rate = engine.sampleRate
                let error = engine.lastError
                DispatchQueue.main.async {
                    guard let self, self.isEnabled else { return }   // user may have toggled back off
                    if started {
                        self.engineRunning = true
                        self.currentSampleRate = rate
                        analyzer.sampleRate = rate
                        analyzer.start()
                        self.startClippingMonitoring()
                    } else {
                        engine.setSampleSink(nil)
                        self.isEnabled = false
                        self.statusMessage = error ?? self.loc("Couldn't start the EQ engine.")
                    }
                }
            }
        } else {
            engineRunning = false
            currentSampleRate = nil
            automaticHeadroomDB = 0
            analyzer.stop()
            stopClippingMonitoring()
            statusMessage = loc("Equalizer off — bit-perfect playback restored.")
            engine.controlQueue.async {
                engine.setActive(false)
                engine.stop()
                engine.setSampleSink(nil)
            }
        }
    }

    func toggleEnabled() { setEnabled(!isEnabled) }

    // MARK: - Profile library

    func selectProfile(_ id: PEQProfile.ID) {
        guard let match = profiles.first(where: { $0.id == id }) else { return }
        profile = match
    }

    func newProfile() {
        let new = PEQProfile(name: uniqueName(loc("New Profile")))
        profiles.append(new)
        profile = new
    }

    func duplicateProfile() {
        let copy = PEQProfile(name: uniqueName(profile.name + " " + loc("copy")),
                              preampDB: profile.preampDB,
                              bands: profile.bands)
        profiles.append(copy)
        profile = copy
    }

    func deleteProfile(_ id: PEQProfile.ID) {
        profiles.removeAll { $0.id == id }
        if profiles.isEmpty { profiles = [PEQProfile(name: "Flat")] }
        if !profiles.contains(where: { $0.id == profile.id }) {
            profile = profiles[0]
        }
        scheduleSave()
    }

    // MARK: - Band editing

    func addBand() {
        guard profile.bands.count < PEQConstraints.maximumBands else {
            statusMessage = String(format: loc("Maximum %1$ld EQ bands."),
                                   PEQConstraints.maximumBands)
            return
        }
        profile.bands.append(PEQBand(type: .peak, frequency: 1000, gainDB: 0, q: 1.0))
    }

    func removeBand(_ id: PEQBand.ID) {
        profile.bands.removeAll { $0.id == id }
    }

    func resetFlat() {
        profile = PEQProfile(id: profile.id, name: profile.name)
    }

    // MARK: - AutoEQ import (creates a new profile)

    func importAutoEQ(from url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            statusMessage = String(format: loc("Couldn't read %1$@."), url.lastPathComponent)
            return
        }
        let name = url.deletingPathExtension().lastPathComponent
        let result = AutoEQParser.parse(text)
        guard !result.bands.isEmpty else {
            statusMessage = String(format: loc("No filters found in %1$@."), url.lastPathComponent)
            return
        }
        let imported = PEQProfile(name: uniqueName(name),
                                  preampDB: result.preampDB,
                                  bands: result.bands).sanitized()
        profiles.append(imported)
        profile = imported

        let truncatedCount = max(0, result.bands.count - imported.bands.count)
        if result.skippedLines.isEmpty, truncatedCount == 0 {
            statusMessage = String(format: loc("Imported %1$ld bands from %2$@."),
                                   imported.bands.count, name)
        } else {
            statusMessage = String(format: loc("Imported %1$ld bands from %2$@ (%3$ld skipped or over limit)."),
                                   imported.bands.count,
                                   name,
                                   result.skippedLines.count + truncatedCount)
        }
    }

    // MARK: - Reactions / persistence

    private func profileChanged() {
        let validated = profile.sanitized()
        if validated != profile {
            profile = validated
            return
        }
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        }
        if isEnabled {
            let engine = self.engine
            let snapshot = profile
            engineApplyWork?.cancel()
            let work = DispatchWorkItem {
                engine.controlQueue.async { engine.apply(profile: snapshot) }
            }
            engineApplyWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: work)
        }
        scheduleSave()
    }

    private func startClippingMonitoring() {
        stopClippingMonitoring()
        lastClippingEpoch = engine.clippingEventCount()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollClippingState() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clippingTimer = timer
    }

    private func stopClippingMonitoring() {
        clippingTimer?.invalidate()
        clippingTimer = nil
        clippingDetected = false
    }

    private func pollClippingState() {
        let epoch = engine.clippingEventCount()
        if epoch != lastClippingEpoch {
            lastClippingEpoch = epoch
            clippingVisibleUntil = Date().addingTimeInterval(2)
            clippingDetected = true
        } else if Date() >= clippingVisibleUntil {
            clippingDetected = false
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = EQStore(profiles: profiles, selectedID: profile.id)
        let work = DispatchWorkItem { EQModel.save(snapshot) }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func uniqueName(_ base: String) -> String {
        var name = base
        var counter = 2
        while profiles.contains(where: { $0.name == name }) {
            name = "\(base) \(counter)"
            counter += 1
        }
        return name
    }

    private func loc(_ key: String) -> String { NSLocalizedString(key, comment: "") }

    private struct EQStore: Codable {
        var profiles: [PEQProfile]
        var selectedID: UUID
    }

    private static var storeURL: URL? {
        let manager = FileManager.default
        guard let base = manager.urls(for: .applicationSupportDirectory,
                                      in: .userDomainMask).first else { return nil }
        let folder = base.appendingPathComponent("Choritsu", isDirectory: true)
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("eq-profiles.json")
    }

    private static func load() -> EQStore {
        if let url = storeURL,
           let data = try? Data(contentsOf: url),
           var store = try? JSONDecoder().decode(EQStore.self, from: data),
           !store.profiles.isEmpty {
            store.profiles = store.profiles.map { $0.sanitized() }
            return store
        }
        let fallback = PEQProfile(name: "Flat")
        return EQStore(profiles: [fallback], selectedID: fallback.id)
    }

    private static func save(_ store: EQStore) {
        guard let url = storeURL, let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
