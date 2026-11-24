import AVFAudio
import CoreAudio
import Foundation

/// Captures all system audio with a Core Audio process tap (macOS 14.2+) and emits
/// PCM s16le, 48 kHz, stereo, interleaved.
///
/// With `muteOutput`, the tapped audio is muted before it reaches the Mac's speakers. The output
/// device itself is not muted, so the volume keys keep working; `OutputVolumeMonitor` forwards them
/// to the TV. Never mute or change the user's output device to silence the Mac.
final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "app.beamly.tap", qos: .userInteractive)
    private var inFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    /// Output format of the wire protocol: PCM s16, 48 kHz, stereo, interleaved.
    private var outFormat: AVAudioFormat?

    func start(muteOutput: Bool, onPCM: @escaping (Data) -> Void) throws {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.name = "Beamly"
        desc.isPrivate = true
        desc.muteBehavior = muteOutput ? .muted : .unmuted
        var st = AudioHardwareCreateProcessTap(desc, &tapID)
        guard st == noErr else {
            throw BeamlyError("Cannot create the audio tap (\(st)); System Audio Recording permission is required")
        }

        do {
            guard let out = AudioDevices.defaultOutput(), let outUID = AudioDevices.uid(of: out) else {
                throw BeamlyError("No audio output device found")
            }
            let config: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Beamly",
                kAudioAggregateDeviceUIDKey: "app.beamly.tap.\(UUID().uuidString)",
                kAudioAggregateDeviceMainSubDeviceKey: outUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapDriftCompensationKey: true,
                        kAudioSubTapUIDKey: desc.uuid.uuidString,
                    ]
                ],
            ]
            st = AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregateID)
            guard st == noErr else { throw BeamlyError("Cannot create the aggregate audio device (\(st))") }

            var addr = AudioDevices.address(kAudioTapPropertyFormat)
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            st = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
            guard st == noErr, let fmt = AVAudioFormat(streamDescription: &asbd),
                let target = AVAudioFormat(
                    commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 2, interleaved: true),
                let conv = AVAudioConverter(from: fmt, to: target)
            else {
                throw BeamlyError("Unsupported audio tap format (\(st))")
            }
            outFormat = target
            inFormat = fmt
            converter = conv

            st = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
                self?.process(input, onPCM)
            }
            guard st == noErr else { throw BeamlyError("Cannot read from the audio tap (\(st))") }
            st = AudioDeviceStart(aggregateID, procID)
            guard st == noErr else { throw BeamlyError("Cannot start the audio tap (\(st))") }
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func process(_ input: UnsafePointer<AudioBufferList>, _ onPCM: (Data) -> Void) {
        guard let inFormat, let outFormat, let converter,
            let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, bufferListNoCopy: input, deallocator: nil),
            inBuf.frameLength > 0
        else { return }
        let capacity = AVAudioFrameCount(Double(inBuf.frameLength) * outFormat.sampleRate / inFormat.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return inBuf
        }
        guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData?[0] else { return }
        onPCM(Data(bytes: samples, count: Int(out.frameLength) * 4))
    }
}
