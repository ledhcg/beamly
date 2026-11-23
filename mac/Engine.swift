// Lõi mac2tv: chụp màn hình + âm thanh (ScreenCaptureKit), encode H.264 (VideoToolbox), gửi tới Android TV qua TCP.
// Dùng chung cho CLI (mac/cli) và app thanh menu (mac/app).
//
// Giao thức (big-endian), mỗi gói:  u32 len | u8 type | u64 ptsMicros | payload[len]
//   type 0 = config   payload: u16 width | u16 height | u16 spsLen | sps | u16 ppsLen | pps
//   type 1 = keyframe (Annex-B)
//   type 2 = frame    (Annex-B)
//   type 3 = audio    PCM s16le, 48 kHz, stereo, interleaved
//   type 4 = bye      (rỗng) Mac chủ động dừng
//   type 5 = ping     (rỗng) heartbeat mỗi giây; TV coi mất kết nối nếu 4s không nhận được gì
//   type 6 = hello    UTF-8 tên máy Mac, gửi ngay khi kết nối
//   type 7 = volume   f32 âm lượng macOS (0..1) | f32 hệ số khuếch đại (0..1) | u8 mute

import AppKit
import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import Network
import CoreAudio
import AVFAudio

// MARK: - Public types

struct StreamOptions {
    var fps = 60
    var bitrate = 12_000_000
    var width = 1920
    var display = 0          // chỉ số trong SCShareableContent.displays
    var audio = true
    /// Tạm tắt loa Mac trong lúc phát, để âm thanh chỉ phát ở TV.
    var muteMacOutput = false
    var statsInterval: TimeInterval = 2
}

enum StopReason {
    case user
    case permission
    case error(String)
}

enum StreamEvent {
    case connected(String)               // địa chỉ TV
    case streaming(String)               // mô tả luồng
    case stats(fps: Double, dropped: Int)
    case stopped(StopReason)
}

struct EngineError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct TV: Hashable {
    let name: String
    let endpoint: NWEndpoint
}

struct DisplayInfo {
    let index: Int
    let name: String
    let width: Int
    let height: Int
}

func isPermissionError(_ error: Error) -> Bool {
    let e = error as NSError
    return e.domain == SCStreamErrorDomain && e.code == SCStreamError.userDeclined.rawValue
}

func listDisplays() async throws -> [DisplayInfo] {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    var names: [CGDirectDisplayID: String] = [:]
    for s in NSScreen.screens {
        if let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            names[n.uint32Value] = s.localizedName
        }
    }
    return content.displays.enumerated().map { i, d in
        DisplayInfo(index: i, name: names[d.displayID] ?? "Màn hình \(i + 1)", width: d.width, height: d.height)
    }
}

// MARK: - Session

/// Một phiên phát tới một TV. Sự kiện được gửi về main queue.
final class StreamSession {
    private let sender: Sender
    private let capturer: Capturer
    private let emit: (StreamEvent) -> Void
    private let lock = NSLock()
    private var finished = false

    init(endpoint: NWEndpoint, options: StreamOptions, onEvent: @escaping (StreamEvent) -> Void) {
        emit = { e in DispatchQueue.main.async { onEvent(e) } }
        sender = Sender(endpoint: endpoint)
        capturer = Capturer(sender: sender, options: options)

        sender.onFailure = { [weak self] msg in self?.finish(.error(msg)) }
        capturer.onFailure = { [weak self] msg in self?.finish(.error(msg)) }
        capturer.onStats = { [weak self] fps, dropped in self?.emit(.stats(fps: fps, dropped: dropped)) }
        sender.onReady = { [weak self] in
            guard let self else { return }
            self.emit(.connected(self.sender.remoteDescription))
            Task {
                do {
                    let desc = try await self.capturer.start()
                    if self.isFinished { self.capturer.stop() } else { self.emit(.streaming(desc)) }
                } catch {
                    self.finish(isPermissionError(error) ? .permission : .error(error.localizedDescription))
                }
            }
        }
    }

    func start() { sender.start() }
    func stop() { finish(.user) }

    private var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }

    private func finish(_ reason: StopReason) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        lock.unlock()
        capturer.stop()
        if case .user = reason { sender.close() } else { sender.cancel() }
        emit(.stopped(reason))
    }
}

// MARK: - Discovery

/// Theo dõi liên tục các TV đang mở app Mac2TV (Bonjour _mac2tv._tcp). Callback chạy trên main queue.
final class TVBrowser {
    static let serviceType = "_mac2tv._tcp"
    private var browser: NWBrowser?
    private(set) var tvs: [TV] = []
    var onChange: (([TV]) -> Void)?
    var onError: ((String) -> Void)?

    func start() {
        let b = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: NWParameters())
        b.browseResultsChangedHandler = { [weak self] results, _ in
            var seen = Set<String>()
            let list = results.compactMap { r -> TV? in
                guard case let .service(name, _, _, _) = r.endpoint, seen.insert(name).inserted else { return nil }
                return TV(name: name, endpoint: r.endpoint)
            }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async {
                self?.tvs = list
                self?.onChange?(list)
            }
        }
        b.stateUpdateHandler = { [weak self] state in
            var msg: String?
            switch state {
            case .failed(let e): msg = "Không dò được TV: \(e.localizedDescription)"
            case .waiting(let e): msg = "Không dò được TV (cần quyền Mạng cục bộ?): \(e.localizedDescription)"
            default: break
            }
            if let msg { DispatchQueue.main.async { self?.onError?(msg) } }
        }
        b.start(queue: DispatchQueue(label: "mac2tv.browser"))
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}

// MARK: - Network

final class Sender {
    private let conn: NWConnection
    private let q = DispatchQueue(label: "mac2tv.net")
    private var pending = 0
    private let maxPending = 3 * 1024 * 1024
    private var ready = false
    private var closed = false
    private var heartbeat: DispatchSourceTimer?
    var onReady: (() -> Void)?
    var onFailure: ((String) -> Void)?

    init(endpoint: NWEndpoint) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        conn = NWConnection(to: endpoint, using: NWParameters(tls: nil, tcp: tcp))
    }

    var remoteDescription: String {
        if case let .hostPort(h, p)? = conn.currentPath?.remoteEndpoint { return "\(h):\(p)" }
        return "\(conn.endpoint)"
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.ready = true
                let t = DispatchSource.makeTimerSource(queue: self.q)
                t.schedule(deadline: .now() + 1, repeating: 1)
                t.setEventHandler { [weak self] in self?.send(type: 5, pts: 0, payload: Data()) }
                t.resume()
                self.heartbeat = t
                let name = Host.current().localizedName ?? "Mac"
                self.send(type: 6, pts: 0, payload: Data(name.utf8))
                self.onReady?()
            case .waiting(let e):
                // NWConnection tự thử lại mãi; sau 5s vẫn chưa được thì báo lỗi.
                self.q.asyncAfter(deadline: .now() + 5) {
                    if !self.ready { self.onFailure?("Không kết nối được tới TV (\(e.localizedDescription)). App trên TV đã mở chưa?") }
                }
            case .failed(let e):
                self.onFailure?("Mất kết nối: \(e.localizedDescription)")
            default: break
            }
        }
        conn.start(queue: q)
    }

    /// Ngắt ngay (khi đã lỗi).
    func cancel() {
        q.async {
            self.closed = true
            self.heartbeat?.cancel()
            self.conn.cancel()
        }
    }

    /// Dừng có báo cho TV: gửi gói bye + FIN rồi mới huỷ kết nối.
    func close() {
        q.async {
            guard !self.closed else { return }
            self.closed = true
            self.heartbeat?.cancel()
            guard self.ready else { self.conn.cancel(); return }
            self.conn.send(content: Self.packet(type: 4, pts: 0, payload: Data()), contentContext: .finalMessage,
                           isComplete: true, completion: .contentProcessed { [conn = self.conn] _ in conn.cancel() })
            // Phòng khi gửi không xong.
            self.q.asyncAfter(deadline: .now() + 1) { [conn = self.conn] in conn.cancel() }
        }
    }

    var congested: Bool { q.sync { pending > maxPending } }

    private static func packet(type: UInt8, pts: UInt64, payload: Data) -> Data {
        var pkt = Data(capacity: 13 + payload.count)
        var len = UInt32(payload.count).bigEndian
        var p = pts.bigEndian
        withUnsafeBytes(of: &len) { pkt.append(contentsOf: $0) }
        pkt.append(type)
        withUnsafeBytes(of: &p) { pkt.append(contentsOf: $0) }
        pkt.append(payload)
        return pkt
    }

    func send(type: UInt8, pts: UInt64, payload: Data) {
        let pkt = Self.packet(type: type, pts: pts, payload: payload)
        let size = pkt.count
        q.async { [self] in
            guard !self.closed else { return }
            self.pending += size
            self.conn.send(content: pkt, completion: .contentProcessed { [weak self] err in
                guard let self else { return }
                self.q.async { self.pending -= size }
                if let err, !self.closed { self.onFailure?("Lỗi gửi: \(err.localizedDescription)") }
            })
        }
    }
}

// MARK: - Encoder

final class Encoder {
    private var session: VTCompressionSession?
    private let sender: Sender
    private let width: Int, height: Int
    private var forceKey = true
    private let startCode: [UInt8] = [0, 0, 0, 1]

    init(width: Int, height: Int, fps: Int, bitrate: Int, sender: Sender) throws {
        self.width = width; self.height = height; self.sender = sender

        let lowLatency = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue] as CFDictionary
        var status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                                codecType: kCMVideoCodecType_H264, encoderSpecification: lowLatency,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        if status != noErr {
            status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                                codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        }
        guard status == noErr, let s = session else { throw EngineError(message: "Không tạo được encoder H.264 (\(status))") }

        func set(_ k: CFString, _ v: CFTypeRef) { _ = VTSessionSetProperty(s, key: k, value: v) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, (fps * 2) as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 2 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    func invalidate() {
        if let s = session { VTCompressionSessionInvalidate(s) }
        session = nil
    }

    func encode(_ image: CVImageBuffer, pts: CMTime) {
        guard let s = session else { return }
        var props: CFDictionary? = nil
        if forceKey {
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            forceKey = false
        }
        VTCompressionSessionEncodeFrame(s, imageBuffer: image, presentationTimeStamp: pts, duration: .invalid,
                                        frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sbuf in
            guard status == noErr, let sbuf, let self else { return }
            self.output(sbuf)
        }
    }

    private func output(_ sbuf: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sbuf) else { return }
        let atts = CMSampleBufferGetSampleAttachmentsArray(sbuf, createIfNecessary: false) as? [[CFString: Any]]
        let isKey = !((atts?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        let pts = UInt64(max(0, CMSampleBufferGetPresentationTimeStamp(sbuf).seconds * 1_000_000))

        if isKey, let fmt = CMSampleBufferGetFormatDescription(sbuf) { sendConfig(fmt) }

        // AVCC (độ dài 4 byte) -> Annex-B (start code)
        let total = CMBlockBufferGetDataLength(block)
        var avcc = Data(count: total)
        avcc.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: $0.baseAddress!) }
        var annexB = Data(capacity: total)
        var i = 0
        while i + 4 <= total {
            let n = Int(avcc[i]) << 24 | Int(avcc[i+1]) << 16 | Int(avcc[i+2]) << 8 | Int(avcc[i+3])
            i += 4
            guard n > 0, i + n <= total else { break }
            annexB.append(contentsOf: startCode)
            annexB.append(avcc[i..<i+n])
            i += n
        }
        sender.send(type: isKey ? 1 : 2, pts: pts, payload: annexB)
    }

    private func sendConfig(_ fmt: CMFormatDescription) {
        var sets: [Data] = []
        for idx in 0..<2 {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            let st = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: idx,
                parameterSetPointerOut: &ptr, parameterSetSizeOut: &size, parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil)
            guard st == noErr, let ptr else { return }
            sets.append(Data(bytes: ptr, count: size))
        }
        var cfg = Data()
        func u16(_ v: Int) { cfg.append(UInt8((v >> 8) & 0xff)); cfg.append(UInt8(v & 0xff)) }
        u16(width); u16(height)
        u16(sets[0].count); cfg.append(sets[0])
        u16(sets[1].count); cfg.append(sets[1])
        sender.send(type: 0, pts: 0, payload: cfg)
    }
}

// MARK: - Capture

final class Capturer: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var encoder: Encoder?
    private let sender: Sender
    private let options: StreamOptions
    private let q = DispatchQueue(label: "mac2tv.capture", qos: .userInteractive)
    private let audioQ = DispatchQueue(label: "mac2tv.audio", qos: .userInteractive)
    private var frames = 0, dropped = 0
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

    func start() async throws -> String {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard options.display < content.displays.count else { throw EngineError(message: "Không có màn hình số \(options.display)") }
        let display = content.displays[options.display]
        let w = options.width & ~1
        let h = Int((Double(w) * Double(display.height) / Double(display.width)).rounded()) & ~1

        let cfg = SCStreamConfiguration()
        cfg.width = w
        cfg.height = h
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.showsCursor = true
        cfg.queueDepth = 5

        // "Chỉ phát tiếng ở TV": thu bằng audio tap (chặn tiếng ra loa Mac) và đồng bộ âm lượng Mac sang TV.
        var useScreenCaptureAudio = options.audio
        var audioNote = ""
        if options.audio && options.muteMacOutput {
            do {
                let t = SystemAudioTap()
                try t.start(muteOutput: true) { [weak self] pcm in self?.sender.send(type: 3, pts: 0, payload: pcm) }
                tap = t
                useScreenCaptureAudio = false
                let monitor = OutputVolumeMonitor()
                monitor.onChange = { [weak self] volume, gain, muted in self?.sendVolume(volume, gain, muted) }
                monitor.start()
                volumeMonitor = monitor
                audioNote = ", loa Mac tắt (phím âm lượng Mac điều khiển TV)"
            } catch {
                audioNote = ", vẫn phát ở loa Mac: \(error.localizedDescription)"
            }
        }
        if useScreenCaptureAudio {
            cfg.capturesAudio = true
            cfg.sampleRate = 48_000
            cfg.channelCount = 2
            cfg.excludesCurrentProcessAudio = true
        }

        encoder = try Encoder(width: w, height: h, fps: options.fps, bitrate: options.bitrate, sender: sender)
        let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: q)
        if useScreenCaptureAudio { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQ) }
        try await s.startCapture()
        stream = s
        return "\(display.width)x\(display.height) → \(w)x\(h) @\(options.fps)fps, \(options.bitrate / 1_000_000) Mbps, "
            + (options.audio ? "có âm thanh" : "không âm thanh") + audioNote
    }

    private func sendVolume(_ volume: Float, _ gain: Float, _ muted: Bool) {
        var payload = Data()
        for f in [volume, gain] { withUnsafeBytes(of: f.bitPattern.bigEndian) { payload.append(contentsOf: $0) } }
        payload.append(muted ? 1 : 0)
        sender.send(type: 7, pts: 0, payload: payload)
    }

    func stop() {
        volumeMonitor?.stop()
        volumeMonitor = nil
        tap?.stop()
        tap = nil
        // Không dùng q.sync: stop() có thể được gọi từ hàng đợi mạng trong khi q đang chờ hàng đợi mạng.
        q.async {
            self.stopped = true
            self.encoder?.invalidate()
            self.encoder = nil
        }
        let s = stream
        stream = nil
        Task { try? await s?.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio { if sb.isValid { sendAudio(sb) }; return }
        guard !stopped, type == .screen, sb.isValid, let image = sb.imageBuffer else { return }
        guard let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = atts.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }

        if sender.congested { dropped += 1; return }   // mạng nghẽn: bỏ khung để không bị trễ dồn
        encoder?.encode(image, pts: sb.presentationTimeStamp)
        frames += 1

        let secs = Date().timeIntervalSince(lastStats)
        if secs >= options.statsInterval {
            onStats?(Double(frames) / secs, dropped)
            frames = 0; dropped = 0; lastStats = Date()
        }
    }

    /// Chuyển audio Float32 của ScreenCaptureKit -> PCM s16le stereo interleaved và gửi đi.
    private func sendAudio(_ sb: CMSampleBuffer) {
        guard let fmt = sb.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32, Int(asbd.mSampleRate) == 48_000 else { return }
        let ch = max(1, Int(asbd.mChannelsPerFrame))
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let frames = CMSampleBufferGetNumSamples(sb)
        guard frames > 0 else { return }

        let abl = AudioBufferList.allocate(maximumBuffers: ch)
        defer { free(abl.unsafeMutablePointer) }
        var block: CMBlockBuffer?
        let st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: nil,
            bufferListOut: abl.unsafeMutablePointer, bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: ch),
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block)
        guard st == noErr else { return }

        let ptrs: [UnsafePointer<Float>] = abl.compactMap { $0.mData.map { UnsafePointer($0.assumingMemoryBound(to: Float.self)) } }
        guard !ptrs.isEmpty else { return }
        @inline(__always) func sample(_ c: Int, _ i: Int) -> Float {
            if nonInterleaved { return ptrs[min(c, ptrs.count - 1)][i] }
            return ptrs[0][i * ch + min(c, ch - 1)]
        }
        var out = Data(count: frames * 4)
        out.withUnsafeMutableBytes { raw in
            let o = raw.bindMemory(to: Int16.self)
            for i in 0..<frames {
                for c in 0..<2 {
                    let v = max(-1, min(1, sample(c, i)))
                    o[i * 2 + c] = Int16(v * 32767).littleEndian
                }
            }
        }
        let pts = UInt64(max(0, sb.presentationTimeStamp.seconds * 1_000_000))
        sender.send(type: 3, pts: pts, payload: out)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onFailure?("Dừng chụp màn hình: \(error.localizedDescription)")
    }
}

// MARK: - Âm thanh hệ thống: tap + đồng bộ âm lượng

/// Tiện ích CoreAudio.
enum AudioDevices {
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func defaultOutput() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return st == noErr && id != 0 ? id : nil
    }

    static func uid(of dev: AudioDeviceID) -> String? {
        var addr = address(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    static func device(forUID uid: String) -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID = uid as CFString
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let st = withUnsafeMutablePointer(to: &cfUID) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
        }
        return st == noErr && id != kAudioObjectUnknown ? id : nil
    }

    static func getFloat(_ dev: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Float32? {
        var a = addr
        guard AudioObjectHasProperty(dev, &a) else { return nil }
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    static func setFloat(_ dev: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ value: Float32) -> Bool {
        var a = addr
        var v = value
        return AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
    }

    static func getUInt32(_ dev: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> UInt32? {
        var a = addr
        guard AudioObjectHasProperty(dev, &a) else { return nil }
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr ? v : nil
    }
}

/// Bản trước của Mac2TV tắt loa bằng cách mute thiết bị và lưu trạng thái để khôi phục khi bị tắt đột ngột.
/// Giữ lại phần khôi phục để không bỏ quên loa đang bị mute từ bản cũ.
enum SystemAudioMuter {
    private static let defaults = UserDefaults(suiteName: "com.mac2tv.shared")
    private static let key = "mutedOutputDevices"

    static func recoverIfNeeded() {
        guard let stored = defaults?.dictionary(forKey: key), !stored.isEmpty else { return }
        for (uid, value) in stored {
            guard let dev = AudioDevices.device(forUID: uid), let d = value as? [String: Any] else { continue }
            if d["method"] as? String == "mute" {
                var addr = AudioDevices.address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
                var zero: UInt32 = 0
                AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &zero)
            } else if let v = (d["volume"] as? NSNumber)?.floatValue {
                _ = AudioDevices.setFloat(dev, AudioDevices.address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput), v)
            }
        }
        defaults?.removeObject(forKey: key)
    }
}

/// Thu toàn bộ âm thanh hệ thống bằng Core Audio Process Tap (macOS 14.2+).
/// Với `muteOutput`, âm thanh bị chặn trước khi ra loa Mac — thiết bị đầu ra không bị mute, nên phím âm lượng vẫn hoạt động.
/// Xuất PCM s16le 48 kHz stereo interleaved.
final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let q = DispatchQueue(label: "mac2tv.tap", qos: .userInteractive)
    private var inFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 2, interleaved: true)!

    func start(muteOutput: Bool, onPCM: @escaping (Data) -> Void) throws {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.name = "Mac2TV"
        desc.isPrivate = true
        desc.muteBehavior = muteOutput ? .muted : .unmuted
        var st = AudioHardwareCreateProcessTap(desc, &tapID)
        guard st == noErr else { throw EngineError(message: "không tạo được audio tap (\(st)) — cần quyền ghi âm thanh hệ thống") }

        do {
            guard let out = AudioDevices.defaultOutput(), let outUID = AudioDevices.uid(of: out) else {
                throw EngineError(message: "không tìm thấy thiết bị âm thanh đầu ra")
            }
            let config: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Mac2TV",
                kAudioAggregateDeviceUIDKey: "com.mac2tv.tap.\(UUID().uuidString)",
                kAudioAggregateDeviceMainSubDeviceKey: outUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                                   kAudioSubTapUIDKey: desc.uuid.uuidString]],
            ]
            st = AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregateID)
            guard st == noErr else { throw EngineError(message: "không tạo được thiết bị tổng hợp (\(st))") }

            var addr = AudioDevices.address(kAudioTapPropertyFormat)
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            st = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
            guard st == noErr, let fmt = AVAudioFormat(streamDescription: &asbd),
                  let conv = AVAudioConverter(from: fmt, to: outFormat) else {
                throw EngineError(message: "định dạng audio tap không hỗ trợ (\(st))")
            }
            inFormat = fmt
            converter = conv

            st = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, q) { [weak self] _, input, _, _, _ in
                self?.process(input, onPCM)
            }
            guard st == noErr else { throw EngineError(message: "không đọc được audio tap (\(st))") }
            st = AudioDeviceStart(aggregateID, procID)
            guard st == noErr else { throw EngineError(message: "không khởi động được audio tap (\(st))") }
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
        guard let inFormat, let converter,
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, bufferListNoCopy: input, deallocator: nil),
              inBuf.frameLength > 0 else { return }
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

/// Theo dõi âm lượng/mute của thiết bị đầu ra mặc định (và đổi thiết bị) để đồng bộ sang TV.
/// Callback: (âm lượng 0..1 như thanh âm lượng macOS, hệ số khuếch đại tuyến tính 0..1, đang mute?).
final class OutputVolumeMonitor {
    var onChange: ((Float, Float, Bool) -> Void)?

    private let q = DispatchQueue(label: "mac2tv.volume")
    private var device = AudioDeviceID(0)
    private var deviceListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var defaultListener: AudioObjectPropertyListenerBlock?
    private var defaultAddress = AudioDevices.address(kAudioHardwarePropertyDefaultOutputDevice)
    private var last: (Float, Float, Bool)?

    /// Các thuộc tính có thể đổi khi bấm phím âm lượng (tuỳ thiết bị: kênh chính hoặc từng kênh).
    private static let watched: [AudioObjectPropertyAddress] = {
        let out = kAudioDevicePropertyScopeOutput
        var list = [AudioDevices.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, out),
                    AudioDevices.address(kAudioDevicePropertyMute, out)]
        for el: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
            list.append(AudioDevices.address(kAudioDevicePropertyVolumeScalar, out, el))
        }
        return list
    }()

    func start() {
        q.async {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.attachToDefault() }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &self.defaultAddress, self.q, block) == noErr {
                self.defaultListener = block
            }
            self.attachToDefault()
        }
    }

    func stop() {
        q.sync {
            detach()
            if let block = defaultListener {
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddress, q, block)
                defaultListener = nil
            }
            onChange = nil
        }
    }

    private func attachToDefault() {
        guard let dev = AudioDevices.defaultOutput() else { return }
        if dev != device {
            detach()
            device = dev
            for var addr in Self.watched {
                guard AudioObjectHasProperty(dev, &addr) else { continue }
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.report() }
                if AudioObjectAddPropertyListenerBlock(dev, &addr, q, block) == noErr {
                    deviceListeners.append((addr, block))
                }
            }
        }
        report()
    }

    private func detach() {
        for (addr, block) in deviceListeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(device, &a, q, block)
        }
        deviceListeners.removeAll()
        device = 0
    }

    private func report() {
        let out = kAudioDevicePropertyScopeOutput
        let muted = (AudioDevices.getUInt32(device, AudioDevices.address(kAudioDevicePropertyMute, out)) ?? 0) != 0
        var element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
        var scalar = AudioDevices.getFloat(device, AudioDevices.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, out))
        if scalar == nil {
            for el: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1] {
                if let v = AudioDevices.getFloat(device, AudioDevices.address(kAudioDevicePropertyVolumeScalar, out, el)) {
                    scalar = v; element = el; break
                }
            }
        }
        // Thiết bị không có điều khiển âm lượng (vd. HDMI): giữ nguyên mức TV.
        let volume = scalar ?? 1
        var gain: Float = 1
        if volume <= 0 {
            gain = 0
        } else if scalar != nil {
            // Dùng đúng đường cong dB của thiết bị để TV to/nhỏ giống loa Mac.
            var db = volume
            var addr = AudioDevices.address(kAudioDevicePropertyVolumeScalarToDecibels, out, element)
            var size = UInt32(MemoryLayout<Float32>.size)
            if !AudioObjectHasProperty(device, &addr) { addr.mElement = 1 }
            if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &db) == noErr {
                gain = powf(10, db / 20)
            } else {
                gain = volume * volume
            }
        }
        if muted { gain = 0 }
        let value = (volume, min(max(gain, 0), 1), muted)
        if let last, last == value { return }
        last = value
        onChange?(value.0, value.1, value.2)
    }
}
