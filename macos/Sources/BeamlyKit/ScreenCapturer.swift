import CoreMedia
import Foundation
import ScreenCaptureKit

/// Captures one display with ScreenCaptureKit, feeds frames to `VideoEncoder` and sends system audio.
final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var encoder: VideoEncoder?
    private let sender: Sender
    private let options: StreamOptions
    private let videoQueue = DispatchQueue(label: "app.beamly.capture", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "app.beamly.audio", qos: .userInteractive)
    private var frames = 0
    private var dropped = 0
    private var lastStats = Date()
    private var stopped = false
    private var tap: SystemAudioTap?
    private var volumeMonitor: OutputVolumeMonitor?

    var onFailure: ((String) -> Void)?
    var onStats: ((Double, Int) -> Void)?

    init(sender: Sender, options: StreamOptions) {
        self.sender = sender
        self.options = options
    }

    /// Starts capturing. Returns a human-readable description of the stream.
    func start() async throws -> String {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard options.display < content.displays.count else {
            throw BeamlyError("Display \(options.display) does not exist")
        }
        let display = content.displays[options.display]
        let width = options.width & ~1
        let height = Int((Double(width) * Double(display.height) / Double(display.width)).rounded()) & ~1

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.showsCursor = true
        configuration.queueDepth = 5

        let audioDescription = startAudio(configuration: configuration)

        encoder = try VideoEncoder(
            width: width, height: height, fps: options.fps, bitrate: options.bitrate, sender: sender)
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if configuration.capturesAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        try await stream.startCapture()
        self.stream = stream
        return "\(display.width)x\(display.height) → \(width)x\(height) @\(options.fps) fps, "
            + "\(options.bitrate / 1_000_000) Mbps, \(audioDescription)"
    }

    /// Chooses the audio path. With `muteMacOutput`, a muted process tap captures system audio and the
    /// Mac's volume is mirrored to the TV; otherwise (or if the tap fails) ScreenCaptureKit captures audio.
    private func startAudio(configuration: SCStreamConfiguration) -> String {
        guard options.audio else { return "no audio" }
        var note = "audio on"
        if options.muteMacOutput {
            do {
                let tap = SystemAudioTap()
                try tap.start(muteOutput: true) { [weak self] pcm in self?.sender.send(.audio, payload: pcm) }
                self.tap = tap
                let monitor = OutputVolumeMonitor()
                monitor.onChange = { [weak self] volume, gain, muted in
                    self?.sender.send(
                        .volume, payload: PacketCodec.volumePayload(volume: volume, gain: gain, muted: muted))
                }
                monitor.start()
                volumeMonitor = monitor
                return "audio on TV only (Mac volume keys control the TV)"
            } catch {
                note = "audio also on the Mac speakers: \(error.localizedDescription)"
            }
        }
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        return note
    }

    func stop() {
        volumeMonitor?.stop()
        volumeMonitor = nil
        tap?.stop()
        tap = nil
        // Must not be `videoQueue.sync`: stop() can run on the network queue while the video queue
        // is waiting on the network queue (Sender.congested), which would deadlock.
        videoQueue.async {
            self.stopped = true
            self.encoder?.invalidate()
            self.encoder = nil
        }
        let stream = self.stream
        self.stream = nil
        Task { try? await stream?.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            if sampleBuffer.isValid { sendAudio(sampleBuffer) }
            return
        }
        guard !stopped, type == .screen, sampleBuffer.isValid, let image = sampleBuffer.imageBuffer else { return }
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int,
            SCFrameStatus(rawValue: rawStatus) == .complete
        else { return }

        // Drop frames while the network is congested so latency does not build up.
        if sender.congested {
            dropped += 1
            return
        }
        encoder?.encode(image, presentationTime: sampleBuffer.presentationTimeStamp)
        frames += 1

        let elapsed = Date().timeIntervalSince(lastStats)
        if elapsed >= options.statsInterval {
            onStats?(Double(frames) / elapsed, dropped)
            frames = 0
            dropped = 0
            lastStats = Date()
        }
    }

    /// Converts ScreenCaptureKit's Float32 audio to PCM s16le stereo interleaved and sends it.
    private func sendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let format = sampleBuffer.formatDescription,
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
            asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            asbd.mBitsPerChannel == 32, Int(asbd.mSampleRate) == 48_000
        else { return }
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return }

        let bufferList = AudioBufferList.allocate(maximumBuffers: channels)
        defer { free(bufferList.unsafeMutablePointer) }
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: bufferList.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: channels), blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &block)
        guard status == noErr else { return }

        let pointers: [UnsafePointer<Float>] = bufferList.compactMap {
            $0.mData.map { UnsafePointer($0.assumingMemoryBound(to: Float.self)) }
        }
        guard !pointers.isEmpty else { return }
        func sample(channel: Int, frame: Int) -> Float {
            if nonInterleaved { return pointers[min(channel, pointers.count - 1)][frame] }
            return pointers[0][frame * channels + min(channel, channels - 1)]
        }
        var pcm = Data(count: frameCount * 4)
        pcm.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for frame in 0..<frameCount {
                for channel in 0..<2 {
                    let value = max(-1, min(1, sample(channel: channel, frame: frame)))
                    out[frame * 2 + channel] = Int16(value * 32767).littleEndian
                }
            }
        }
        let pts = UInt64(max(0, sampleBuffer.presentationTimeStamp.seconds * 1_000_000))
        sender.send(.audio, ptsMicros: pts, payload: pcm)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onFailure?("Screen capture stopped: \(error.localizedDescription)")
    }
}
