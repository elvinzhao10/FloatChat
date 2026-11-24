import Accelerate
import AVFoundation
import AudioToolbox
import CoreAudio
import os

@MainActor
protocol CombinedRecording: AnyObject {
    var isRunning: Bool { get }
    var heardSystemAudio: Bool { get }
    var includesSystemAudio: Bool { get }
    var usesBuiltInMicrophone: Bool { get }
    var audioLevel: Float { get }
    func stop()
}

/// A private HAL device puts the microphone and the system mix on one clock.
@available(macOS 14.2, *)
@MainActor
final class CombinedAudioCapture: CombinedRecording {
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var writer: MixedAudioWriter?
    let includesSystemAudio: Bool
    private(set) var sampleRate = 0.0
    private(set) var usesBuiltInMicrophone = false
    private var ownsAggregate = false

    private var finalSystemSignal = false

    var heardSystemAudio: Bool { writer?.heardSystemAudio ?? finalSystemSignal }
    var audioLevel: Float { writer?.audioLevel ?? 0 }

    var isRunning: Bool {
        guard ioProc != nil, writer?.failed == false else { return false }
        var running: UInt32 = 0
        return (try? Self.readProperty(kAudioDevicePropertyDeviceIsRunning, of: device, into: &running)) != nil
            && running != 0
    }

    init(url: URL? = nil, includesSystemAudio: Bool = true, stream: WebsiteAudioBuffer? = nil) throws {
        self.includesSystemAudio = includesSystemAudio
        do {
            let microphone = try configureDevice()
            let microphoneChannels = try Self.inputChannels(of: microphone)
            let combinedChannels = try Self.inputChannels(of: device)
            guard microphoneChannels > 0,
                  !includesSystemAudio || combinedChannels > microphoneChannels else {
                throw AudioCaptureError.unavailable
            }
            try Self.readProperty(kAudioDevicePropertyNominalSampleRate, of: device, into: &sampleRate)
            let writer = try MixedAudioWriter(url: url, sampleRate: sampleRate, microphoneChannels: microphoneChannels,
                                              stream: stream)
            self.writer = writer
            try Self.installIOProc(on: device, into: &ioProc, writer: writer)
            guard let ioProc else { throw AudioCaptureError.unavailable }
            try AudioCaptureError.check(AudioDeviceStart(device, ioProc))
        } catch {
            stop()
            throw error
        }
    }

    private nonisolated static func installIOProc(on device: AudioObjectID, into proc: inout AudioDeviceIOProcID?,
                                                  writer: MixedAudioWriter) throws {
        try AudioCaptureError.check(AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { _, input, _, _, _ in
            writer.write(input)
        })
    }

    private static func readProperty<Value>(_ selector: AudioObjectPropertySelector, of device: AudioObjectID,
                                            into value: inout Value) throws {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Value>.size)
        try withUnsafeMutablePointer(to: &value) {
            try AudioCaptureError.check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0))
        }
    }

    private static func inputChannels(of device: AudioObjectID) throws -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try AudioCaptureError.check(AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size))
        guard size >= MemoryLayout<AudioBufferList>.size else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        try AudioCaptureError.check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage))
        return UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
            .reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func defaultInput() throws -> AudioObjectID {
        var input = AudioObjectID(kAudioObjectUnknown)
        try readProperty(kAudioHardwarePropertyDefaultInputDevice, of: system, into: &input)
        guard input != kAudioObjectUnknown else { throw AudioCaptureError.unavailable }
        return input
    }

    static func needsHeadphoneSafeInput() throws -> Bool {
        var output = AudioObjectID(kAudioObjectUnknown)
        try readProperty(kAudioHardwarePropertyDefaultOutputDevice, of: system, into: &output)
        return try isBluetooth(defaultInput()) && isBluetooth(output)
    }

    private static func isBluetooth(_ device: AudioObjectID) throws -> Bool {
        var transport: UInt32 = 0
        try readProperty(kAudioDevicePropertyTransportType, of: device, into: &transport)
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func builtInMicrophone() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try AudioCaptureError.check(AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size))
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try devices.withUnsafeMutableBytes { storage in
            guard let pointer = storage.baseAddress else { throw AudioCaptureError.noSafeMicrophone }
            try AudioCaptureError.check(AudioObjectGetPropertyData(system, &address, 0, nil, &size, pointer))
        }
        for candidate in devices {
            var transport: UInt32 = 0
            try? readProperty(kAudioDevicePropertyTransportType, of: candidate, into: &transport)
            if transport == kAudioDeviceTransportTypeBuiltIn, (try? inputChannels(of: candidate)) ?? 0 > 0 {
                return candidate
            }
        }
        throw AudioCaptureError.noSafeMicrophone
    }

    private func configureDevice() throws -> AudioObjectID {
        usesBuiltInMicrophone = try Self.needsHeadphoneSafeInput()
        let microphone = try usesBuiltInMicrophone ? Self.builtInMicrophone() : Self.defaultInput()
        guard includesSystemAudio else {
            device = microphone
            return microphone
        }

        var microphoneUID: CFString = "" as CFString
        try Self.readProperty(kAudioDevicePropertyDeviceUID, of: microphone, into: &microphoneUID)
        // A global mix follows playback even if macOS changes endpoints. An
        // unmuted tap leaves ordinary headphone playback running.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "FloatChat System Audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try AudioCaptureError.check(AudioHardwareCreateProcessTap(description, &tap))
        var tapUID: CFString = "" as CFString
        try Self.readProperty(kAudioTapPropertyUID, of: tap, into: &tapUID)

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "FloatChat Audio Capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: microphoneUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: microphoneUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true
            ]]
        ]
        try AudioCaptureError.check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device))
        ownsAggregate = true
        return microphone
    }

    func stop() {
        if let ioProc {
            AudioDeviceStop(device, ioProc)
            AudioDeviceDestroyIOProcID(device, ioProc)
            self.ioProc = nil
        }
        if let writer {
            finalSystemSignal = writer.heardSystemAudio
            writer.close()
            self.writer = nil
        }
        if ownsAggregate && device != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(device)
            device = kAudioObjectUnknown
        }
        if tap != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tap)
            tap = kAudioObjectUnknown
        }
    }
}

enum AudioCaptureError: Error {
    case unavailable
    case noSafeMicrophone
    case audioToolbox(OSStatus)

    static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw AudioCaptureError.audioToolbox(status) }
    }
}

/// The HAL supplies one producer with native interleaved Float32 buffers.
/// The capture owner closes the writer after unregistering that producer.
final class MixedAudioWriter: @unchecked Sendable {
    private let file: ExtAudioFileRef?
    private let stream: WebsiteAudioBuffer?
    private let scratch: AVAudioPCMBuffer
    private let failure = OSAllocatedUnfairLock(initialState: false)

    private let systemSignal = OSAllocatedUnfairLock(initialState: false)
    private let meter = OSAllocatedUnfairLock(initialState: Float.zero)
    private let microphoneChannels: Int
    private var detectedSystemAudio = false  // Accessed only by the HAL producer.

    var failed: Bool { failure.withLock { $0 } }
    var heardSystemAudio: Bool { systemSignal.withLock { $0 } }
    var audioLevel: Float {
        meter.withLock { peak in
            defer { peak = 0 }
            return peak
        }
    }

    init(url: URL?, sampleRate: Double, microphoneChannels: Int, stream: WebsiteAudioBuffer? = nil) throws {
        self.microphoneChannels = microphoneChannels
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)
        else { throw AudioCaptureError.unavailable }
        self.scratch = scratch
        self.stream = stream
        guard let url else {
            guard stream != nil else { throw AudioCaptureError.unavailable }
            self.file = nil
            return
        }

        var output = AudioStreamBasicDescription()
        output.mSampleRate = 32_000
        output.mFormatID = kAudioFormatMPEG4AAC
        output.mChannelsPerFrame = 1
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try AudioCaptureError.check(AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &size, &output))
        var file: ExtAudioFileRef?
        try AudioCaptureError.check(ExtAudioFileCreateWithURL(url as CFURL, kAudioFileM4AType, &output, nil, 0, &file))
        guard let file else { throw AudioCaptureError.unavailable }
        do {
            try AudioCaptureError.check(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                                                               size, format.streamDescription))
            try AudioCaptureError.check(ExtAudioFileWriteAsync(file, 0, nil))
        } catch {
            ExtAudioFileDispose(file)
            throw error
        }
        self.file = file
    }

    func write(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let frames = buffers.reduce(Int.max) { count, buffer in
            guard buffer.mData != nil, buffer.mDataByteSize > 0, buffer.mNumberChannels > 0 else { return count }
            let available = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * Int(buffer.mNumberChannels))
            return min(count, available)
        }
        guard frames > 0, frames != Int.max, let output = scratch.floatChannelData?[0] else { return }
        var offset = 0
        while offset < frames {
            let count = min(Int(scratch.frameCapacity), frames - offset)
            scratch.frameLength = AVAudioFrameCount(count)
            mix(buffers, offset: offset, frames: count, into: output)
            var rms: Float = 0
            vDSP_rmsqv(output, 1, &rms, vDSP_Length(count))
            let level = rms
            _ = meter.withLockIfAvailable { $0 = max($0, level) }
            stream?.append(output, count: count)
            if let file, ExtAudioFileWriteAsync(file, scratch.frameLength, scratch.audioBufferList) != noErr {
                failure.withLock { $0 = true }
                return
            }
            offset += count
        }
    }

    private func mix(_ buffers: UnsafeMutableAudioBufferListPointer, offset: Int, frames: Int,
                     into output: UnsafeMutablePointer<Float>) {
        let size = vDSP_Length(frames)
        let totalChannels = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        var microphoneGain = 0.7 / Float(max(1, microphoneChannels))
        var playbackGain = 0.7 / Float(max(1, totalChannels - microphoneChannels))
        vDSP_vclr(output, 1, size)
        var firstChannel = 0
        for buffer in buffers {
            let channels = Int(buffer.mNumberChannels)
            defer { firstChannel += channels }
            guard buffer.mDataByteSize > 0, let audio = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for channel in 0..<channels {
                let samples = audio + offset * channels + channel
                let stride = vDSP_Stride(channels)
                let isPlayback = firstChannel + channel >= microphoneChannels
                if isPlayback {
                    if !detectedSystemAudio {
                        var peak: Float = 0
                        vDSP_maxmgv(samples, stride, &peak, size)
                        if peak > 0.001 {
                            detectedSystemAudio = true
                            systemSignal.withLock { $0 = true }
                        }
                    }
                    vDSP_vsma(samples, stride, &playbackGain, output, 1, output, 1, size)
                } else {
                    vDSP_vsma(samples, stride, &microphoneGain, output, 1, output, 1, size)
                }
            }
        }
        var minimum: Float = -1
        var maximum: Float = 1
        vDSP_vclip(output, 1, &minimum, &maximum, output, 1, size)
    }

    func close() { if let file { ExtAudioFileDispose(file) } }
}
