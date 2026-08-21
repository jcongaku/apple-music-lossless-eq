import Foundation
import Synchronization

/// Real-time-safe stereo biquad cascade.
///
/// The control queue publishes scalar coefficient data through an atomic
/// sequence-locked mailbox. Only the audio thread owns the live coefficient
/// banks and delay lines, so it never races a writer, allocates, retains an
/// Array value, or takes a lock. Parameter changes crossfade two complete
/// cascades over 20 ms; rapid edits are coalesced to the newest mailbox value.
final class BiquadProcessor {
    static let maximumSections = PEQConstraints.maximumBands
    static let maximumChannels = 2

    private static let coefficientFieldCount = 5
    private static let mailboxValueCount = maximumSections * coefficientFieldCount

    // MARK: Control-thread -> audio-thread mailbox

    private let mailboxValues: UnsafeMutablePointer<Atomic<UInt64>>
    private let mailboxCount = Atomic<Int>(0)
    private let mailboxPreamp = Atomic<UInt64>(1.0.bitPattern)
    private let mailboxSampleRate = Atomic<UInt64>(48_000.0.bitPattern)
    private let mailboxEpoch = Atomic<UInt64>(0)
    private let requestedWet = Atomic<UInt64>(0)
    private let requestedResetEpoch = Atomic<UInt64>(0)
    private let clippingEpoch = Atomic<UInt64>(0)

    // MARK: Audio-thread-owned state

    private var coefficients: [BiquadCoefficients]
    private var sectionCounts = [Int](repeating: 0, count: 2)
    private var preampLinear = [Double](repeating: 1, count: 2)
    private var bankSampleRates = [Double](repeating: 48_000, count: 2)
    private var z1: [Double]
    private var z2: [Double]

    private var activeBank = 0
    private var transitionFromBank = 0
    private var transitionToBank = 1
    private var transitionPosition = 0
    private var transitionFrames = 0
    private var renderTransitionStart = 0
    private var hasConfiguration = false
    private var consumedMailboxEpoch: UInt64 = 0
    private var consumedResetEpoch: UInt64 = 0

    private var wetMix = 0.0
    private var wetRampStart = 0.0
    private var wetRampTarget = 0.0
    private var wetRampPosition = 0
    private var wetRampFrames = 1
    private var renderWetRampStart = 0
    private var renderClipped = false

    init() {
        mailboxValues = .allocate(capacity: Self.mailboxValueCount)
        for index in 0..<Self.mailboxValueCount {
            mailboxValues.advanced(by: index).initialize(to: Atomic(0))
        }

        coefficients = [BiquadCoefficients](repeating: .identity,
                                             count: 2 * Self.maximumSections)
        let stateCount = 2 * Self.maximumChannels * Self.maximumSections
        z1 = [Double](repeating: 0, count: stateCount)
        z2 = [Double](repeating: 0, count: stateCount)
    }

    deinit {
        for index in 0..<Self.mailboxValueCount {
            mailboxValues.advanced(by: index).deinitialize(count: 1)
        }
        mailboxValues.deallocate()
    }

    // MARK: Control queue

    func setSections(_ newCoefficients: [BiquadCoefficients],
                     preampDB: Double,
                     sampleRate: Double) {
        let count = min(newCoefficients.count, Self.maximumSections)
        let current = mailboxEpoch.load(ordering: .relaxed)
        let writingEpoch = current.isMultiple(of: 2) ? current &+ 1 : current &+ 2
        mailboxEpoch.store(writingEpoch, ordering: .releasing)

        for section in 0..<count {
            let coefficient = newCoefficients[section]
            let base = section * Self.coefficientFieldCount
            mailboxValues[base].store(coefficient.b0.bitPattern, ordering: .relaxed)
            mailboxValues[base + 1].store(coefficient.b1.bitPattern, ordering: .relaxed)
            mailboxValues[base + 2].store(coefficient.b2.bitPattern, ordering: .relaxed)
            mailboxValues[base + 3].store(coefficient.a1.bitPattern, ordering: .relaxed)
            mailboxValues[base + 4].store(coefficient.a2.bitPattern, ordering: .relaxed)
        }
        mailboxCount.store(count, ordering: .relaxed)
        mailboxPreamp.store(pow(10, preampDB / 20).bitPattern, ordering: .relaxed)
        mailboxSampleRate.store(sampleRate.bitPattern, ordering: .relaxed)
        mailboxEpoch.store(writingEpoch &+ 1, ordering: .releasing)
    }

    func setActive(_ active: Bool) {
        requestedWet.store(active ? 1 : 0, ordering: .releasing)
    }

    func requestReset() {
        let next = requestedResetEpoch.load(ordering: .relaxed) &+ 1
        requestedResetEpoch.store(next, ordering: .releasing)
    }

    func clippingEventCount() -> UInt64 {
        clippingEpoch.load(ordering: .acquiring)
    }

    // MARK: Audio render thread

    func beginRender(frameCount: Int) {
        renderClipped = false

        let resetEpoch = requestedResetEpoch.load(ordering: .acquiring)
        if resetEpoch != consumedResetEpoch {
            clearAllStates()
            consumedResetEpoch = resetEpoch
        }

        if transitionFrames == 0 {
            let destination = hasConfiguration ? 1 - activeBank : activeBank
            if loadPublishedConfiguration(into: destination) {
                clearStates(for: destination)
                if hasConfiguration {
                    transitionFromBank = activeBank
                    transitionToBank = destination
                    transitionPosition = 0
                    transitionFrames = max(64, Int(bankSampleRates[destination] * 0.020))
                } else {
                    activeBank = destination
                    hasConfiguration = true
                }
            }
        }
        renderTransitionStart = transitionPosition

        let newWetTarget = requestedWet.load(ordering: .acquiring) == 0 ? 0.0 : 1.0
        if newWetTarget != wetRampTarget {
            wetMix = currentWetMix()
            wetRampStart = wetMix
            wetRampTarget = newWetTarget
            wetRampPosition = 0
            let sampleRate = bankSampleRates[activeBank]
            wetRampFrames = max(32, Int(sampleRate * 0.005))
        }
        renderWetRampStart = wetRampPosition
    }

    @inline(__always)
    func processSample(_ sample: Float, channel: Int, frameOffset: Int) -> Float {
        let dry = Double(sample)
        guard channel >= 0, channel < Self.maximumChannels else {
            return protectedFloat(dry)
        }

        let wet: Double
        if transitionFrames > 0 {
            let from = processBankSample(dry, bank: transitionFromBank, channel: channel)
            let to = processBankSample(dry, bank: transitionToBank, channel: channel)
            let progress = min(1, Double(renderTransitionStart + frameOffset + 1)
                                   / Double(transitionFrames))
            let mix = smoothstep(progress)
            wet = from * (1 - mix) + to * mix
        } else {
            wet = processBankSample(dry, bank: activeBank, channel: channel)
        }

        let mix = wetMix(at: renderWetRampStart + frameOffset)
        return protectedFloat(dry * (1 - mix) + wet * mix)
    }

    func endRender(frameCount: Int) {
        if transitionFrames > 0 {
            transitionPosition += frameCount
            if transitionPosition >= transitionFrames {
                activeBank = transitionToBank
                transitionPosition = 0
                transitionFrames = 0
            }
        }

        if wetRampPosition < wetRampFrames {
            wetRampPosition = min(wetRampFrames, wetRampPosition + frameCount)
            wetMix = currentWetMix()
        }

        if renderClipped {
            let next = clippingEpoch.load(ordering: .relaxed) &+ 1
            clippingEpoch.store(next, ordering: .releasing)
        }
    }

    // MARK: Mailbox receive

    private func loadPublishedConfiguration(into bank: Int) -> Bool {
        let before = mailboxEpoch.load(ordering: .acquiring)
        guard before.isMultiple(of: 2), before != consumedMailboxEpoch else { return false }

        let count = min(max(mailboxCount.load(ordering: .relaxed), 0), Self.maximumSections)
        let preamp = Double(bitPattern: mailboxPreamp.load(ordering: .relaxed))
        let sampleRate = Double(bitPattern: mailboxSampleRate.load(ordering: .relaxed))
        let bankBase = bank * Self.maximumSections

        for section in 0..<count {
            let base = section * Self.coefficientFieldCount
            coefficients[bankBase + section] = BiquadCoefficients(
                b0: Double(bitPattern: mailboxValues[base].load(ordering: .relaxed)),
                b1: Double(bitPattern: mailboxValues[base + 1].load(ordering: .relaxed)),
                b2: Double(bitPattern: mailboxValues[base + 2].load(ordering: .relaxed)),
                a1: Double(bitPattern: mailboxValues[base + 3].load(ordering: .relaxed)),
                a2: Double(bitPattern: mailboxValues[base + 4].load(ordering: .relaxed)))
        }

        let after = mailboxEpoch.load(ordering: .acquiring)
        guard before == after else { return false }
        sectionCounts[bank] = count
        preampLinear[bank] = preamp.isFinite ? preamp : 1
        bankSampleRates[bank] = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48_000
        consumedMailboxEpoch = after
        return true
    }

    // MARK: DSP helpers

    @inline(__always)
    private func processBankSample(_ input: Double, bank: Int, channel: Int) -> Double {
        var x = input * preampLinear[bank]
        let coefficientBase = bank * Self.maximumSections
        let stateBase = (bank * Self.maximumChannels + channel) * Self.maximumSections

        for section in 0..<sectionCounts[bank] {
            let coefficient = coefficients[coefficientBase + section]
            let state = stateBase + section
            let y = coefficient.b0 * x + z1[state]
            z1[state] = coefficient.b1 * x - coefficient.a1 * y + z2[state]
            z2[state] = coefficient.b2 * x - coefficient.a2 * y
            x = y
        }
        return x
    }

    @inline(__always)
    private func smoothstep(_ value: Double) -> Double {
        let t = min(max(value, 0), 1)
        return t * t * (3 - 2 * t)
    }

    @inline(__always)
    private func wetMix(at position: Int) -> Double {
        guard position < wetRampFrames else { return wetRampTarget }
        let progress = Double(position + 1) / Double(wetRampFrames)
        return wetRampStart + (wetRampTarget - wetRampStart) * smoothstep(progress)
    }

    private func currentWetMix() -> Double {
        wetMix(at: wetRampPosition)
    }

    @inline(__always)
    private func protectedFloat(_ value: Double) -> Float {
        guard value.isFinite else {
            renderClipped = true
            return 0
        }
        if value > 1 {
            renderClipped = true
            return 1
        }
        if value < -1 {
            renderClipped = true
            return -1
        }
        return Float(value)
    }

    private func clearStates(for bank: Int) {
        let start = bank * Self.maximumChannels * Self.maximumSections
        let end = start + Self.maximumChannels * Self.maximumSections
        for index in start..<end {
            z1[index] = 0
            z2[index] = 0
        }
    }

    private func clearAllStates() {
        for index in z1.indices {
            z1[index] = 0
            z2[index] = 0
        }
    }
}
