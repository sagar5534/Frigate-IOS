import AudioToolbox
import AVFoundation
import WebRTC

/// WebRTC's stock iOS device uses VoiceProcessingIO, which opens microphone input
/// even when every transceiver is receive-only. This device only creates a
/// RemoteIO output bus, so viewing a camera never touches the phone microphone.
final class PlaybackAudioDevice: NSObject, RTCAudioDevice {
    private let sampleRate = 48_000.0
    private let bufferDuration = 0.01
    private var delegate: (any RTCAudioDeviceDelegate)?
    private var audioUnit: AudioUnit?

    private(set) var isInitialized = false
    private(set) var isPlayoutInitialized = false
    private(set) var isPlaying = false
    let isRecordingInitialized = true
    let isRecording = false

    var deviceInputSampleRate: Double { sampleRate }
    var inputIOBufferDuration: TimeInterval { bufferDuration }
    var inputNumberOfChannels: Int { 1 }
    var inputLatency: TimeInterval { 0 }
    var deviceOutputSampleRate: Double { sampleRate }
    var outputIOBufferDuration: TimeInterval { bufferDuration }
    var outputNumberOfChannels: Int { 1 }
    var outputLatency: TimeInterval { AVAudioSession.sharedInstance().outputLatency }

    func initialize(with delegate: any RTCAudioDeviceDelegate) -> Bool {
        self.delegate = delegate
        isInitialized = true
        return true
    }

    func terminateDevice() -> Bool {
        _ = stopPlayout()
        if let audioUnit {
            AudioUnitUninitialize(audioUnit)
            AudioComponentInstanceDispose(audioUnit)
            self.audioUnit = nil
        }
        isPlayoutInitialized = false
        isInitialized = false
        delegate = nil
        return true
    }

    func initializePlayout() -> Bool {
        guard isInitialized else { return false }
        if isPlayoutInitialized { return true }

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_RemoteIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else { return false }
        var unit: AudioUnit?
        guard AudioComponentInstanceNew(component, &unit) == noErr, let unit else { return false }

        var disableInput: UInt32 = 0
        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var callback = AURenderCallbackStruct(
            inputProc: { refCon, flags, timestamp, bus, frames, output in
                guard let output else { return kAudio_ParamError }
                let device = Unmanaged<PlaybackAudioDevice>.fromOpaque(refCon).takeUnretainedValue()
                guard let delegate = device.delegate else { return kAudio_ParamError }
                return delegate.getPlayoutData(flags, timestamp, Int(bus), frames, output)
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        let configured = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
            &disableInput, UInt32(MemoryLayout<UInt32>.size)
        ) == noErr && AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
            &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ) == noErr && AudioUnitSetProperty(
            unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
            &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        ) == noErr && AudioUnitInitialize(unit) == noErr

        guard configured else {
            AudioComponentInstanceDispose(unit)
            return false
        }
        audioUnit = unit
        isPlayoutInitialized = true
        return true
    }

    func startPlayout() -> Bool {
        guard isPlayoutInitialized, let audioUnit else { return false }
        if isPlaying { return true }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch { return false }
        guard AudioOutputUnitStart(audioUnit) == noErr else { return false }
        isPlaying = true
        return true
    }

    func stopPlayout() -> Bool {
        guard isPlaying else { return true }
        if let audioUnit { AudioOutputUnitStop(audioUnit) }
        isPlaying = false
        return true
    }

    func initializeRecording() -> Bool { true }
    func startRecording() -> Bool { false }
    func stopRecording() -> Bool { true }
}
