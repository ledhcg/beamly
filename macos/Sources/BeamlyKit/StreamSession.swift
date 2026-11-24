import Foundation
import Network
import ScreenCaptureKit

/// Settings for one streaming session.
public struct StreamOptions: Sendable {
    public var fps = 60
    public var bitrate = 12_000_000
    /// Width of the encoded video; the height follows the display's aspect ratio.
    public var width = 1920
    /// Index into `SCShareableContent.displays` (0 = main display).
    public var display = 0
    public var audio = true
    /// Play sound only on the TV: system audio is captured with a muted Core Audio process tap,
    /// so the Mac's speakers stay silent while the Mac's volume keys control the TV.
    public var muteMacOutput = false
    /// How often `StreamEvent.stats` is emitted.
    public var statsInterval: TimeInterval = 2

    public init() {}
}

public enum StopReason: Sendable {
    /// `StreamSession.stop()` was called.
    case user
    /// Screen Recording permission is missing.
    case permission
    case error(String)
}

public enum StreamEvent: Sendable {
    /// TCP connection established; the associated value is the TV's address.
    case connected(String)
    /// Capture started; the associated value describes the stream.
    case streaming(String)
    case stats(fps: Double, dropped: Int)
    case stopped(StopReason)
}

public struct BeamlyError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// One streaming session to one TV. Events are delivered on the main queue.
/// `stop()` may be called from any thread and is idempotent.
public final class StreamSession {
    private let sender: Sender
    private let capturer: ScreenCapturer
    private let emit: (StreamEvent) -> Void
    private let lock = NSLock()
    private var finished = false

    public init(endpoint: NWEndpoint, options: StreamOptions, onEvent: @escaping (StreamEvent) -> Void) {
        emit = { event in DispatchQueue.main.async { onEvent(event) } }
        sender = Sender(endpoint: endpoint)
        capturer = ScreenCapturer(sender: sender, options: options)

        sender.onFailure = { [weak self] message in self?.finish(.error(message)) }
        capturer.onFailure = { [weak self] message in self?.finish(.error(message)) }
        capturer.onStats = { [weak self] fps, dropped in self?.emit(.stats(fps: fps, dropped: dropped)) }
        sender.onReady = { [weak self] in
            guard let self else { return }
            self.emit(.connected(self.sender.remoteDescription))
            Task {
                do {
                    let description = try await self.capturer.start()
                    if self.isFinished { self.capturer.stop() } else { self.emit(.streaming(description)) }
                } catch {
                    self.finish(isPermissionError(error) ? .permission : .error(error.localizedDescription))
                }
            }
        }
    }

    public func start() { sender.start() }
    public func stop() { finish(.user) }

    private var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    private func finish(_ reason: StopReason) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        capturer.stop()
        if case .user = reason { sender.close() } else { sender.cancel() }
        emit(.stopped(reason))
    }
}

func isPermissionError(_ error: Error) -> Bool {
    let nsError = error as NSError
    return nsError.domain == SCStreamErrorDomain && nsError.code == SCStreamError.userDeclined.rawValue
}
