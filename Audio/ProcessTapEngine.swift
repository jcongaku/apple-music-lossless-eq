import Foundation
import AppKit
import CoreAudio
import OSLog

/// Inserts an EQ into Apple Music's audio without a driver or admin rights, using
/// the macOS 14.4+ Core Audio process-tap API.
///
/// Pipeline: a *muted* process tap on Music.app silences Music's normal output
/// and hands us its samples; a private aggregate device bundles that tap (as
/// input) with the real output device (as output); our IOProc copies tap →
/// (optional biquad EQ) → real device. Because Choritsu renders from a separate
/// process, there is no feedback loop.
///
/// Coefficient changes are crossfaded and bypass changes are ramped by the
/// processor. Output-device and sample-rate changes trigger a full path rebuild.
// Control methods are serialized on `controlQueue`; render runs on the audio
// thread. That manual discipline is what `@unchecked Sendable` asserts here.
final class ProcessTapEngine: @unchecked Sendable {
    private let log = Logger(subsystem: "com.garykong.choritsu", category: "EQEngine")
    private let musicBundleID = "com.apple.Music"
    private let aggregateUID = "com.garykong.choritsu.eq-aggregate"

    private let processor = BiquadProcessor()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private(set) var sampleRate: Double = 48000
    private var currentProfile: PEQProfile = .flat
    private var inputFormat = AudioStreamBasicDescription()
    private var outputFormat = AudioStreamBasicDescription()
    private var desiredActive = false
    private var spectrumScratch = [Float](repeating: 0, count: 8_192)

    /// Unretained because EQModel owns the analyzer for the whole engine lifetime.
    /// Updated only while audio IO is stopped, avoiding ARC on the render thread.
    private var sampleSinkPointer: UnsafeMutableRawPointer?
    /// Fired on the main queue when the output device's sample rate changes.
    var onSampleRateChange: ((Double) -> Void)?
    var onHeadroomChange: ((Double) -> Void)?
    var onRuntimeError: ((String) -> Void)?

    private var rateListenerDevice = AudioObjectID(kAudioObjectUnknown)
    private var rateListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var rebuildWork: DispatchWorkItem?

    /// Serializes all engine control (start/stop/apply) and the rate-change
    /// listener off the main thread, so toggling the EQ never blocks the UI on
    /// Core Audio device creation.
    let controlQueue = DispatchQueue(label: "com.garykong.choritsu.eq.control")

    private(set) var isRunning = false
    private(set) var lastError: String?

    // MARK: - Lifecycle

    /// Start tapping Music and rendering to the current default output device.
    /// Returns false (and sets `lastError`) on the first step that fails.
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        lastError = nil

        guard let processObject = musicProcessObject() else {
            return fail("Apple Music isn't running (no audio process to tap).")
        }
        guard let outputDevice = defaultOutputDeviceID() else {
            return fail("No default output device.")
        }
        guard let outputUID = deviceUID(outputDevice) else {
            return fail("Couldn't read the output device UID.")
        }
        sampleRate = nominalSampleRate(outputDevice) ?? 48000

        guard let tap = createTap(processObject: processObject) else {
            return fail("AudioHardwareCreateProcessTap failed.")
        }
        tapID = tap
        guard let tapUID = stringProperty(tap, selector: kAudioTapPropertyUID) else {
            stop()
            return fail("Couldn't read the tap UID.")
        }
        guard let aggregate = createAggregate(tapUID: tapUID, outputUID: outputUID) else {
            stop()
            return fail("AudioHardwareCreateAggregateDevice failed.")
        }
        aggregateID = aggregate

        guard let capturedInputFormat = streamFormat(device: aggregate,
                                                     scope: kAudioObjectPropertyScopeInput),
              let capturedOutputFormat = streamFormat(device: aggregate,
                                                       scope: kAudioObjectPropertyScopeOutput),
              validateFormats(input: capturedInputFormat, output: capturedOutputFormat) else {
            stop()
            return fail("Unsupported Core Audio stream format. Choritsu requires matching Float32 PCM streams.")
        }
        inputFormat = capturedInputFormat
        outputFormat = capturedOutputFormat
        sampleRate = capturedOutputFormat.mSampleRate

        var procID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcID(aggregateID,
                                                     ioProc,
                                                     Unmanaged.passUnretained(self).toOpaque(),
                                                     &procID)
        guard createStatus == noErr, let procID else {
            stop()
            return fail("AudioDeviceCreateIOProcID failed (\(createStatus)).")
        }
        ioProcID = procID

        apply(profile: currentProfile)
        processor.requestReset()
        processor.setActive(desiredActive)

        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            stop()
            return fail("AudioDeviceStart failed (\(startStatus)).")
        }

        isRunning = true
        installLifecycleListeners(device: outputDevice)
        log.info("EQ engine started at \(self.sampleRate, privacy: .public) Hz")
        return true
    }

    func stop() {
        rebuildWork?.cancel()
        rebuildWork = nil
        removeLifecycleListeners()
        tearDownAudio()
        processor.setActive(false)
        processor.requestReset()
        isRunning = false
        log.info("EQ engine stopped")
    }

    private func tearDownAudio() {
        if let ioProcID {
            if aggregateID != kAudioObjectUnknown {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            self.ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    // MARK: - EQ control

    /// Turn DSP processing on or off. Coefficients are supplied separately via
    /// `apply(profile:)`; bypass = true is a true passthrough.
    func setActive(_ active: Bool) {
        desiredActive = active
        processor.setActive(active)
    }

    /// Recompute coefficients for a profile at the current sample rate.
    /// Coefficients are sample-rate dependent, so this also runs automatically
    /// when the device rate changes (see `handleRateChange`).
    func apply(profile: PEQProfile) {
        let validated = profile.sanitized()
        currentProfile = validated
        let coefficients = validated.bands
            .filter { $0.isEnabled }
            .map { BiquadCoefficients(band: $0, sampleRate: sampleRate) }
        let automaticHeadroom = PEQResponse.requiredAutomaticHeadroomDB(profile: validated,
                                                                         sampleRate: sampleRate)
        processor.setSections(coefficients,
                              preampDB: validated.preampDB - automaticHeadroom,
                              sampleRate: sampleRate)
        onHeadroomChange?(automaticHeadroom)
    }

    func clippingEventCount() -> UInt64 {
        processor.clippingEventCount()
    }

    func setSampleSink(_ sink: SpectrumAnalyzer?) {
        sampleSinkPointer = sink.map { Unmanaged.passUnretained($0).toOpaque() }
    }

    // MARK: - Render (audio thread)

    fileprivate func render(input: UnsafePointer<AudioBufferList>,
                            output: UnsafeMutablePointer<AudioBufferList>) {
        let inList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)
        let outputFrames = frameCapacity(of: outList, format: outputFormat)
        guard outputFrames > 0 else { return }
        let inputFrames = frameCapacity(of: inList, format: inputFormat)
        let inputChannels = Int(inputFormat.mChannelsPerFrame)
        let outputChannels = Int(outputFormat.mChannelsPerFrame)
        let capturedChannels = min(inputChannels, BiquadProcessor.maximumChannels)
        let renderedChannels = min(outputChannels, BiquadProcessor.maximumChannels)
        let spectrumFrames = min(outputFrames, spectrumScratch.count)

        processor.beginRender(frameCount: outputFrames)
        for frame in 0..<outputFrames {
            for channel in 0..<outputChannels {
                let inputSample: Float
                if frame >= inputFrames {
                    inputSample = 0
                } else if outputChannels == 1, capturedChannels >= 2 {
                    inputSample = (readSample(from: inList, format: inputFormat,
                                              frame: frame, channel: 0)
                                 + readSample(from: inList, format: inputFormat,
                                              frame: frame, channel: 1)) * 0.5
                } else if channel < capturedChannels {
                    inputSample = readSample(from: inList, format: inputFormat,
                                             frame: frame, channel: channel)
                } else {
                    inputSample = 0
                }

                let outputSample = channel < renderedChannels
                    ? processor.processSample(inputSample, channel: channel, frameOffset: frame)
                    : 0
                writeSample(outputSample, to: outList, format: outputFormat,
                            frame: frame, channel: channel)
                if channel == 0, frame < spectrumFrames {
                    spectrumScratch[frame] = outputSample
                }
            }
        }
        processor.endRender(frameCount: outputFrames)

        if spectrumFrames > 0, let sampleSinkPointer {
            let sampleSink = Unmanaged<SpectrumAnalyzer>
                .fromOpaque(sampleSinkPointer)
                .takeUnretainedValue()
            spectrumScratch.withUnsafeBufferPointer { buffer in
                if let baseAddress = buffer.baseAddress {
                    sampleSink.append(baseAddress, count: spectrumFrames)
                }
            }
        }
    }

    // MARK: - Core Audio setup

    private func createTap(processObject: AudioObjectID) -> AudioObjectID? {
        let description = CATapDescription(stereoMixdownOfProcesses: [processObject])
        description.name = "Choritsu EQ Tap"
        description.isPrivate = true
        description.muteBehavior = .muted   // silence Music's own output; we re-render
        var tap = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != kAudioObjectUnknown else {
            log.error("AudioHardwareCreateProcessTap failed: \(status)")
            return nil
        }
        return tap
    }

    private func createAggregate(tapUID: String, outputUID: String) -> AudioObjectID? {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Choritsu EQ",
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: outputUID],
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapDriftCompensationKey as String: true,
                    kAudioSubTapUIDKey as String: tapUID,
                ],
            ],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
        guard status == noErr, aggregate != kAudioObjectUnknown else {
            log.error("AudioHardwareCreateAggregateDevice failed: \(status)")
            return nil
        }
        return aggregate
    }

    // MARK: - Output-device / sample-rate following

    private func installLifecycleListeners(device: AudioObjectID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleRebuild()
        }
        let status = AudioObjectAddPropertyListenerBlock(device, &address, controlQueue, block)
        if status == noErr {
            rateListenerDevice = device
            rateListenerBlock = block
        }

        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleRebuild()
        }
        let defaultStatus = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddress,
            controlQueue,
            defaultBlock)
        if defaultStatus == noErr {
            defaultDeviceListenerBlock = defaultBlock
        }
    }

    private func removeLifecycleListeners() {
        if let block = rateListenerBlock, rateListenerDevice != kAudioObjectUnknown {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(rateListenerDevice, &address, controlQueue, block)
        }
        rateListenerBlock = nil
        rateListenerDevice = kAudioObjectUnknown

        if let block = defaultDeviceListenerBlock {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                   &address,
                                                   controlQueue,
                                                   block)
        }
        defaultDeviceListenerBlock = nil
    }

    private func scheduleRebuild() {
        guard isRunning else { return }
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuildAudioPath() }
        rebuildWork = work
        controlQueue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func rebuildAudioPath() {
        guard isRunning else { return }
        let shouldBeActive = desiredActive
        removeLifecycleListeners()
        tearDownAudio()
        isRunning = false
        processor.requestReset()

        desiredActive = shouldBeActive
        if start() {
            onSampleRateChange?(sampleRate)
            log.info("EQ audio path rebuilt at \(self.sampleRate, privacy: .public) Hz")
        } else {
            let message = lastError ?? "Couldn't rebuild the EQ audio path."
            onRuntimeError?(message)
        }
    }

    // MARK: - Stream format / buffer helpers

    private func streamFormat(device: AudioObjectID,
                              scope: AudioObjectPropertyScope) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &format)
        return status == noErr ? format : nil
    }

    private func validateFormats(input: AudioStreamBasicDescription,
                                 output: AudioStreamBasicDescription) -> Bool {
        guard isSupportedFloatPCM(input), isSupportedFloatPCM(output),
              input.mChannelsPerFrame > 0, output.mChannelsPerFrame > 0,
              input.mSampleRate > 0, output.mSampleRate > 0,
              abs(input.mSampleRate - output.mSampleRate) < 0.5 else {
            return false
        }
        return true
    }

    private func isSupportedFloatPCM(_ format: AudioStreamBasicDescription) -> Bool {
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsPacked != 0,
              format.mBitsPerChannel == 32,
              format.mFramesPerPacket == 1 else {
            return false
        }
        let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let expectedBytes = UInt32(MemoryLayout<Float>.size)
            * (nonInterleaved ? 1 : format.mChannelsPerFrame)
        return format.mBytesPerFrame == expectedBytes
            && format.mBytesPerPacket == expectedBytes
    }

    @inline(__always)
    private func frameCapacity(of list: UnsafeMutableAudioBufferListPointer,
                               format: AudioStreamBasicDescription) -> Int {
        let bytesPerFrame = Int(format.mBytesPerFrame)
        guard bytesPerFrame > 0, !list.isEmpty else { return 0 }
        let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        if nonInterleaved {
            let count = min(Int(format.mChannelsPerFrame), list.count)
            guard count > 0 else { return 0 }
            var result = Int.max
            for index in 0..<count {
                result = min(result, Int(list[index].mDataByteSize) / bytesPerFrame)
            }
            return result == Int.max ? 0 : result
        }
        return Int(list[0].mDataByteSize) / bytesPerFrame
    }

    @inline(__always)
    private func readSample(from list: UnsafeMutableAudioBufferListPointer,
                            format: AudioStreamBasicDescription,
                            frame: Int,
                            channel: Int) -> Float {
        let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let bufferIndex = nonInterleaved ? channel : 0
        guard bufferIndex < list.count, let data = list[bufferIndex].mData else { return 0 }
        let samples = data.assumingMemoryBound(to: Float.self)
        let index = nonInterleaved ? frame : frame * Int(format.mChannelsPerFrame) + channel
        return samples[index]
    }

    @inline(__always)
    private func writeSample(_ sample: Float,
                             to list: UnsafeMutableAudioBufferListPointer,
                             format: AudioStreamBasicDescription,
                             frame: Int,
                             channel: Int) {
        let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let bufferIndex = nonInterleaved ? channel : 0
        guard bufferIndex < list.count, let data = list[bufferIndex].mData else { return }
        let samples = data.assumingMemoryBound(to: Float.self)
        let index = nonInterleaved ? frame : frame * Int(format.mChannelsPerFrame) + channel
        samples[index] = sample
    }

    // MARK: - Property helpers

    private func musicProcessObject() -> AudioObjectID? {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: musicBundleID).first else {
            return nil
        }
        var pid = app.processIdentifier
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &size,
            &object)
        guard status == noErr, object != kAudioObjectUnknown else { return nil }
        return object
    }

    private func defaultOutputDeviceID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    private func deviceUID(_ device: AudioObjectID) -> String? {
        stringProperty(device, selector: kAudioDevicePropertyDeviceUID)
    }

    private func nominalSampleRate(_ device: AudioObjectID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate = Double(0)
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        guard status == noErr, rate > 0 else { return nil }
        return rate
    }

    private func stringProperty(_ object: AudioObjectID,
                                selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    @discardableResult
    private func fail(_ message: String) -> Bool {
        lastError = message
        log.error("\(message, privacy: .public)")
        return false
    }
}

// Top-level C-compatible IOProc; recovers the engine from the client-data pointer.
private func ioProc(_ device: AudioObjectID,
                    _ now: UnsafePointer<AudioTimeStamp>,
                    _ inputData: UnsafePointer<AudioBufferList>,
                    _ inputTime: UnsafePointer<AudioTimeStamp>,
                    _ outputData: UnsafeMutablePointer<AudioBufferList>,
                    _ outputTime: UnsafePointer<AudioTimeStamp>,
                    _ clientData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let clientData else { return noErr }
    let engine = Unmanaged<ProcessTapEngine>.fromOpaque(clientData).takeUnretainedValue()
    engine.render(input: inputData, output: outputData)
    return noErr
}
