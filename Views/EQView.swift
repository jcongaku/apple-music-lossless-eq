import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Palette (matches GlassPanelView's 和風 language)

private enum EQWashi {
    static let rikyu = Color(red: 0.45, green: 0.47, blue: 0.26)    // 利休 — wabi-sabi green-gold
    static let ai = Color(red: 0.31, green: 0.39, blue: 0.45)       // 藍鼠 — muted indigo-grey
}

// MARK: - Equalizer window

struct EQView: View {
    @ObservedObject var eq: EQModel
    @State private var selectedBand: PEQBand.ID?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            Divider()
            EQGraph(profile: $eq.profile,
                    analyzer: eq.analyzer,
                    selectedBand: $selectedBand,
                    sampleRate: eq.currentSampleRate ?? 48_000)
                .frame(height: 220)
                .padding(12)
            hint
            Divider()
            bandTable
                .frame(height: 160)
            statusBar
        }
        .frame(width: 470)
    }

    // MARK: Toolbar (two rows)

    private var toolbar: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PARAMETRIC EQ")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(2.5)
                    Text("パラメトリック・イコライザー")
                        .font(.system(size: 9))
                        .tracking(0.5)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Fixed-width slot so toggling the engine never reflows the row.
                Label(eq.currentSampleRate.map { sampleRateText($0) } ?? "—",
                      systemImage: "waveform.path")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .opacity(eq.currentSampleRate == nil ? 0 : 1)
                    .frame(width: 84, alignment: .trailing)

                Toggle("", isOn: Binding(get: { eq.isEnabled },
                                         set: { eq.setEnabled($0) }))
                    .toggleStyle(.switch)
                    .tint(EQWashi.rikyu)
                    .labelsHidden()
                    .accessibilityLabel("Equalizer")
            }

            HStack(spacing: 10) {
                profileMenu
                TextField("Profile name", text: $eq.profile.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 132)

                Spacer()

                Button { importAutoEQ() } label: {
                    Image(systemName: "square.and.arrow.down")
                        .frame(width: 42, height: 26)
                        .glassEffect(.regular, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Import AutoEQ…")
                .accessibilityLabel("Import AutoEQ…")
                Button { eq.addBand() } label: {
                    Image(systemName: "plus")
                        .frame(width: 42, height: 26)
                        .glassEffect(.regular, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(eq.profile.bands.count >= PEQConstraints.maximumBands)
                .help(eq.profile.bands.count >= PEQConstraints.maximumBands
                      ? "Maximum \(PEQConstraints.maximumBands) bands"
                      : "Add")
                .accessibilityLabel("Add")
                Button { eq.resetFlat() } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .frame(width: 42, height: 26)
                        .glassEffect(.regular, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Flat")
                .accessibilityLabel("Flat")
            }

            HStack(spacing: 10) {
                Text("Preamp").font(.system(size: 11)).foregroundStyle(.secondary)
                Slider(value: $eq.profile.preampDB, in: -24...12)
                    .tint(EQWashi.rikyu)
                Text(String(format: "%+.1f dB", eq.profile.preampDB))
                    .font(.system(size: 11).monospacedDigit())
                    .frame(width: 56, alignment: .trailing)
                if eq.automaticHeadroomDB > 0.05 {
                    Label(String(format: "Auto −%.1f", eq.automaticHeadroomDB),
                          systemImage: "shield.lefthalf.filled")
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(EQWashi.rikyu)
                        .help("Automatic headroom prevents output clipping")
                }
            }
        }
    }

    private var profileMenu: some View {
        Menu {
            ForEach(eq.profiles) { item in
                Button {
                    eq.selectProfile(item.id)
                } label: {
                    if item.id == eq.profile.id {
                        Label(item.name, systemImage: "checkmark")
                    } else {
                        Text(item.name)
                    }
                }
            }
            Divider()
            Button { eq.newProfile() } label: { Label("New Profile", systemImage: "plus") }
            Button { eq.duplicateProfile() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Button(role: .destructive) { eq.deleteProfile(eq.profile.id) } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(eq.profiles.count <= 1)
        } label: {
            Label(eq.profile.name, systemImage: "list.bullet")
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 124)
    }

    private var hint: some View {
        Text("Drag: frequency × gain · Hover point + scroll: Q · Shift: fine")
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .padding(.bottom, 2)
    }

    // MARK: Band table

    private var bandTable: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach($eq.profile.bands) { $band in
                    BandRow(band: $band,
                            isSelected: selectedBand == band.id,
                            onSelect: { selectedBand = band.id },
                            onDelete: { eq.removeBand(band.id) })
                    Divider().opacity(0.4)
                }
                if eq.profile.bands.isEmpty {
                    Text("No bands. Add one, or import an AutoEQ ParametricEQ.txt.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 24)
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private var statusBar: some View {
        HStack {
            Circle()
                .fill(eq.clippingDetected ? Color.orange
                      : (eq.isEnabled ? EQWashi.rikyu : Color.secondary.opacity(0.5)))
                .frame(width: 7, height: 7)
            Text(eq.clippingDetected
                 ? String(localized: "Output peak protected — lower boost or preamp")
                 : eq.statusMessage.isEmpty
                 ? (eq.isEnabled ? String(localized: "Equalizer active")
                                 : String(localized: "Bypassed — bit-perfect"))
                 : eq.statusMessage)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: Actions / helpers

    private func importAutoEQ() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText, .text]
        panel.message = String(localized: "Choose an AutoEQ ParametricEQ.txt file")

        // Choritsu runs as a menu-bar accessory app, so it's never the active
        // app — without this the open panel opens *behind* the frontmost app.
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            eq.importAutoEQ(from: url)
        }
    }

    private func sampleRateText(_ rate: Double) -> String {
        let khz = rate / 1000
        return khz == khz.rounded()
            ? String(format: "%.0f kHz", khz)
            : String(format: "%.1f kHz", khz)
    }
}

// MARK: - One editable band row

private struct BandRow: View {
    @Binding var band: PEQBand
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $band.isEnabled).labelsHidden().tint(EQWashi.rikyu)

            Picker("", selection: $band.type) {
                ForEach(PEQFilterType.allCases) { type in
                    Text(typeKey(type)).tag(type)
                }
            }
            .labelsHidden()
            .frame(width: 120)

            field("Freq", value: $band.frequency, unit: "Hz", width: 70)
            field("Gain", value: $band.gainDB, unit: "dB", width: 60)
            field("Q", value: $band.q, unit: "", width: 50)

            Spacer()

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(isSelected ? EQWashi.rikyu.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .opacity(band.isEnabled ? 1 : 0.45)
    }

    private func typeKey(_ type: PEQFilterType) -> LocalizedStringKey {
        switch type {
        case .peak: return "Peak"
        case .lowShelf: return "Low Shelf"
        case .highShelf: return "High Shelf"
        }
    }

    private func field(_ label: LocalizedStringKey, value: Binding<Double>,
                       unit: String, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 8)).foregroundStyle(.secondary)
            HStack(spacing: 2) {
                TextField("", value: value, format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: width)
                    .font(.system(size: 11).monospacedDigit())
                    .accessibilityLabel(label)
                if !unit.isEmpty {
                    Text(unit).font(.system(size: 8)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Interactive response graph + spectrum

private struct EQGraph: View {
    private struct BandDragState {
        let id: PEQBand.ID
        let band: PEQBand
        let controlFrequency: Double
        let controlDB: Double
    }

    @Binding var profile: PEQProfile
    /// Held, not observed: the spectrum repaints inside `SpectrumView` so its
    /// 24 fps updates don't drag the static grid + curve into every frame.
    let analyzer: SpectrumAnalyzer
    @Binding var selectedBand: PEQBand.ID?
    let sampleRate: Double
    @Environment(\.colorScheme) private var colorScheme
    @State private var dragState: BandDragState?

    private let dbRange: Double = 24
    private let fMin: Double = 20
    private let fMax: Double = 20_000
    private let space = "eqgraph"

    private var displaySampleRate: Double { max(sampleRate, 1) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Dynamic layer: the spectrum repaints ~24×/s, isolated in its
                // own analyzer-observing view.
                SpectrumView(analyzer: analyzer, colorScheme: colorScheme)

                // Static layer: grid + response curve, repainted only when the
                // profile or appearance changes — not on every spectrum frame.
                Canvas { context, size in
                    drawGrid(context, size)
                    drawCurve(context, size)
                }

                ForEach($profile.bands) { $band in
                    if band.isEnabled {
                        handle($band, size: geo.size)
                    }
                }
            }
            .coordinateSpace(name: space)
            .background(
                ScrollCatcher { deltaY, location, isPrecise, isFineAdjustment in
                    adjustQ(by: deltaY,
                            at: location,
                            size: geo.size,
                            isPrecise: isPrecise,
                            isFineAdjustment: isFineAdjustment)
                }
            )
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(colorScheme == .dark ? Color.black.opacity(0.25) : Color.white.opacity(0.4))
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: Drawing

    private var gridColor: Color { (colorScheme == .dark ? Color.white : Color.black).opacity(0.10) }

    private func drawGrid(_ context: GraphicsContext, _ size: CGSize) {
        for f in [20.0, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000] {
            let x = xPos(f, width: size.width)
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(path, with: .color(gridColor), lineWidth: 0.5)
        }
        for g in stride(from: -12.0, through: 12.0, by: 6.0) {
            let y = yPos(g, height: size.height)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: .color(g == 0 ? gridColor.opacity(2) : gridColor),
                           lineWidth: g == 0 ? 0.9 : 0.5)
        }
        for (f, label) in [(100.0, "100"), (1000.0, "1k"), (10000.0, "10k")] {
            context.draw(Text(label).font(.system(size: 8)).foregroundStyle(.secondary),
                         at: CGPoint(x: xPos(f, width: size.width), y: size.height - 8))
        }
    }

    private func drawCurve(_ context: GraphicsContext, _ size: CGSize) {
        let points = PEQResponse.curve(profile: profile, sampleRate: displaySampleRate,
                                       fMin: fMin, fMax: fMax, points: 480)
        guard points.count > 1 else { return }
        var line = Path()
        for (index, point) in points.enumerated() {
            let p = CGPoint(x: xPos(point.frequency, width: size.width),
                            y: yPos(point.db, height: size.height))
            if index == 0 { line.move(to: p) } else { line.addLine(to: p) }
        }
        context.stroke(line, with: .color(EQWashi.rikyu), lineWidth: 2)
    }

    // MARK: Handles

    private func handle(_ band: Binding<PEQBand>, size: CGSize) -> some View {
        let value = band.wrappedValue
        let id = value.id
        let isSelected = selectedBand == id
        let controlFrequency = PEQResponse.controlFrequency(for: value,
                                                            sampleRate: displaySampleRate,
                                                            fMin: fMin,
                                                            fMax: fMax)
        let controlDB = PEQResponse.magnitudeDB(profile: profile,
                                                frequency: controlFrequency,
                                                sampleRate: displaySampleRate)
        let position = CGPoint(x: xPos(controlFrequency, width: size.width),
                               y: yPos(controlDB, height: size.height))
        return ZStack {
            Circle()
                .fill(EQWashi.rikyu.opacity(isSelected ? 1 : 0.72))
                .overlay(Circle().stroke(.white.opacity(0.92), lineWidth: isSelected ? 2 : 1))
                .shadow(color: .black.opacity(isSelected ? 0.22 : 0.10), radius: isSelected ? 4 : 2, y: 1)
                .frame(width: isSelected ? 18 : 14, height: isSelected ? 18 : 14)

            if isSelected {
                Text(String(format: "Q %.2f", value.q))
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 6)
                    .frame(height: 19)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 0.5))
                    .offset(y: position.y < 34 ? 25 : -25)
                    .allowsHitTesting(false)
            }
        }
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
            .position(position)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                    .onChanged { value in
                        selectedBand = id
                        if dragState?.id != id {
                            dragState = BandDragState(id: id,
                                                      band: band.wrappedValue,
                                                      controlFrequency: controlFrequency,
                                                      controlDB: controlDB)
                        }
                        guard let dragState, dragState.id == id else { return }
                        updateBand(band,
                                   from: dragState,
                                   translation: value.translation,
                                   size: size)
                    }
                    .onEnded { _ in dragState = nil }
            )
            .help("Drag: frequency and gain · Scroll: Q")
            .accessibilityLabel("\(value.type.displayName) EQ band")
            .accessibilityValue("\(Int(value.frequency.rounded())) hertz, \(String(format: "%+.1f", value.gainDB)) decibels, Q \(String(format: "%.2f", value.q))")
    }

    private func updateBand(_ binding: Binding<PEQBand>,
                            from state: BandDragState,
                            translation: CGSize,
                            size: CGSize) {
        let startX = xPos(state.controlFrequency, width: size.width)
        let startY = yPos(state.controlDB, height: size.height)
        let targetFrequency = freqAt(startX + translation.width, width: size.width)
        let targetDB = min(max(dbAt(startY + translation.height, height: size.height),
                               -dbRange), dbRange)

        var candidate = state.band
        switch candidate.type {
        case .peak:
            candidate.frequency = clampFreq(targetFrequency)
            candidate.gainDB = solvedGain(for: candidate,
                                          at: candidate.frequency,
                                          targetTotalDB: targetDB)

        case .lowShelf, .highShelf:
            // Preserve the visual shoulder-to-centre ratio while moving, then
            // refine it after the gain solution so the handle tracks the cursor.
            let startRatio = state.controlFrequency / max(state.band.frequency, fMin)
            candidate.frequency = clampFreq(targetFrequency / max(startRatio, 0.0001))
            for _ in 0..<3 {
                candidate.gainDB = solvedGain(for: candidate,
                                              at: targetFrequency,
                                              targetTotalDB: targetDB)
                let actualControlFrequency = PEQResponse.controlFrequency(for: candidate,
                                                                          sampleRate: displaySampleRate,
                                                                          fMin: fMin,
                                                                          fMax: fMax)
                guard actualControlFrequency > 0 else { break }
                candidate.frequency = clampFreq(candidate.frequency * targetFrequency / actualControlFrequency)
            }
            candidate.gainDB = solvedGain(for: candidate,
                                          at: targetFrequency,
                                          targetTotalDB: targetDB)
        }

        candidate.gainDB = clampGain(candidate.gainDB)
        binding.wrappedValue = candidate
    }

    private func solvedGain(for band: PEQBand,
                            at frequency: Double,
                            targetTotalDB: Double) -> Double {
        let otherDB = PEQResponse.magnitudeDB(profile: profile,
                                              frequency: frequency,
                                              sampleRate: displaySampleRate,
                                              excluding: band.id)
        let targetBandDB = targetTotalDB - otherDB
        var lower = -dbRange
        var upper = dbRange

        // At a bell apex or shelf shoulder, response is monotonic in gain.
        // Solving instead of assigning gain directly keeps the dot under the
        // cursor when preamp and overlapping bands contribute to the curve.
        for _ in 0..<18 {
            let midpoint = (lower + upper) / 2
            var probe = band
            probe.gainDB = midpoint
            let coefficients = BiquadCoefficients(band: probe, sampleRate: displaySampleRate)
            let magnitude = coefficients.magnitude(atFrequency: frequency,
                                                   sampleRate: displaySampleRate)
            let responseDB = magnitude > 0 ? 20 * log10(magnitude) : -dbRange
            if responseDB < targetBandDB {
                lower = midpoint
            } else {
                upper = midpoint
            }
        }
        return (lower + upper) / 2
    }

    private func adjustQ(by deltaY: CGFloat,
                         at location: CGPoint,
                         size: CGSize,
                         isPrecise: Bool,
                         isFineAdjustment: Bool) {
        let hoveredID = profile.bands
            .filter(\.isEnabled)
            .map { band -> (PEQBand.ID, CGFloat) in
                let frequency = PEQResponse.controlFrequency(for: band,
                                                             sampleRate: displaySampleRate,
                                                             fMin: fMin,
                                                             fMax: fMax)
                let db = PEQResponse.magnitudeDB(profile: profile,
                                                 frequency: frequency,
                                                 sampleRate: displaySampleRate)
                let point = CGPoint(x: xPos(frequency, width: size.width),
                                    y: yPos(db, height: size.height))
                return (band.id, hypot(point.x - location.x, point.y - location.y))
            }
            .filter { $0.1 <= 30 }
            .min { $0.1 < $1.1 }?.0

        guard let id = hoveredID ?? selectedBand,
              let index = profile.bands.firstIndex(where: { $0.id == id }) else { return }
        selectedBand = id
        var effectiveDelta = Double(deltaY)
        if isPrecise { effectiveDelta *= 0.35 }
        if isFineAdjustment { effectiveDelta *= 0.2 }
        let factor = pow(1.04, effectiveDelta)
        let newQ = profile.bands[index].q * factor
        let range = PEQConstraints.qRange(for: profile.bands[index].type)
        profile.bands[index].q = (min(max(newQ, range.lowerBound), range.upperBound) * 100).rounded() / 100
    }

    // MARK: Coordinate mapping

    private func xPos(_ freq: Double, width: CGFloat) -> CGFloat {
        let t = (log10(max(freq, fMin)) - log10(fMin)) / (log10(fMax) - log10(fMin))
        return CGFloat(t) * width
    }

    private func freqAt(_ x: CGFloat, width: CGFloat) -> Double {
        let t = Double(max(0, min(1, width == 0 ? 0 : x / width)))
        return pow(10, log10(fMin) + t * (log10(fMax) - log10(fMin)))
    }

    private func yPos(_ db: Double, height: CGFloat) -> CGFloat {
        let clamped = max(-dbRange, min(dbRange, db))
        return height / 2 - CGFloat(clamped / dbRange) * (height / 2)
    }

    private func dbAt(_ y: CGFloat, height: CGFloat) -> Double {
        guard height > 0 else { return 0 }
        return Double((height / 2 - y) / (height / 2)) * dbRange
    }

    private func clampFreq(_ f: Double) -> Double {
        min(max(f, PEQConstraints.frequencyRange.lowerBound),
            PEQConstraints.frequencyRange.upperBound)
    }

    private func clampGain(_ g: Double) -> Double {
        let range = PEQConstraints.gainRange
        return (min(max(g, range.lowerBound), range.upperBound) * 10).rounded() / 10
    }
}

// MARK: - Spectrum layer

/// The live spectrum fill. Isolated in its own view that observes the analyzer,
/// so its ~24 fps repaints don't invalidate the static grid + curve `Canvas`
/// stacked above it.
private struct SpectrumView: View {
    @ObservedObject var analyzer: SpectrumAnalyzer
    let colorScheme: ColorScheme

    var body: some View {
        Canvas { context, size in
            let levels = analyzer.levels
            guard levels.count > 1 else { return }
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            for i in levels.indices {
                let x = CGFloat(i) / CGFloat(levels.count - 1) * size.width
                let y = size.height - CGFloat(levels[i]) * size.height
                path.addLine(to: CGPoint(x: x, y: y))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            context.fill(path, with: .color(EQWashi.ai.opacity(colorScheme == .dark ? 0.35 : 0.22)))
        }
    }
}

// MARK: - Scroll-wheel capture (for Q on the graph)

private struct ScrollCatcher: NSViewRepresentable {
    let onScroll: (CGFloat, CGPoint, Bool, Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = CatcherView()
        view.onScroll = onScroll
        view.installMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.onScroll = onScroll
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Void) {
        (nsView as? CatcherView)?.removeMonitor()
    }

    final class CatcherView: NSView {
        var onScroll: ((CGFloat, CGPoint, Bool, Bool) -> Void)?
        private var monitor: Any?

        override var isFlipped: Bool { true }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self,
                      event.window === self.window else {
                    return event
                }
                let location = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(location) else { return event }
                self.onScroll?(event.scrollingDeltaY,
                               location,
                               event.hasPreciseScrollingDeltas,
                               event.modifierFlags.contains(.shift))
                return event
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            removeMonitor()
        }
    }
}
