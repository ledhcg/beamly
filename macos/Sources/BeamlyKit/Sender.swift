import Foundation
import Network

/// TCP connection to the receiver. All methods are thread-safe; state lives on `queue`.
final class Sender {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "app.beamly.net")
    /// Bytes handed to Network.framework but not yet sent; used to drop frames on congestion.
    private var pendingBytes = 0
    private let maxPendingBytes = 3 * 1024 * 1024
    private var ready = false
    private var closed = false
    private var heartbeat: DispatchSourceTimer?

    var onReady: (() -> Void)?
    var onFailure: ((String) -> Void)?

    init(endpoint: NWEndpoint) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        connection = NWConnection(to: endpoint, using: NWParameters(tls: nil, tcp: tcp))
    }

    var remoteDescription: String {
        if case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint { return "\(host):\(port)" }
        return "\(connection.endpoint)"
    }

    /// True when too much data is queued; callers should drop video frames instead of building latency.
    var congested: Bool { queue.sync { pendingBytes > maxPendingBytes } }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.ready = true
                self.startHeartbeat()
                // HELLO must be the first packet: the receiver only accepts connections that send data,
                // which filters out the parallel "Happy Eyeballs" attempts Network.framework abandons.
                let name = Host.current().localizedName ?? "Mac"
                self.send(.hello, payload: PacketCodec.helloPayload(deviceName: name))
                self.onReady?()
            case .waiting(let error):
                // NWConnection retries forever; give up after a few seconds.
                self.queue.asyncAfter(deadline: .now() + 5) {
                    if !self.ready {
                        self.onFailure?(
                            "Cannot connect to the TV (\(error.localizedDescription)). Is the Beamly app open on the TV?"
                        )
                    }
                }
            case .failed(let error):
                self.onFailure?("Connection lost: \(error.localizedDescription)")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.send(.ping) }
        timer.resume()
        heartbeat = timer
    }

    /// Closes immediately, without notifying the receiver (used after errors).
    func cancel() {
        queue.async {
            self.closed = true
            self.heartbeat?.cancel()
            self.connection.cancel()
        }
    }

    /// Graceful stop: sends BYE and a TCP FIN, then cancels. The receiver relies on BYE (or the
    /// heartbeat timeout), not on FIN, because FIN is not reliably delivered when the process exits.
    func close() {
        queue.async {
            guard !self.closed else { return }
            self.closed = true
            self.heartbeat?.cancel()
            guard self.ready else {
                self.connection.cancel()
                return
            }
            let connection = self.connection
            connection.send(
                content: PacketCodec.encode(.bye), contentContext: .finalMessage, isComplete: true,
                completion: .contentProcessed { _ in connection.cancel() })
            // Fallback in case the send never completes.
            self.queue.asyncAfter(deadline: .now() + 1) { connection.cancel() }
        }
    }

    func send(_ type: PacketType, ptsMicros: UInt64 = 0, payload: Data = Data()) {
        let packet = PacketCodec.encode(type, ptsMicros: ptsMicros, payload: payload)
        let size = packet.count
        queue.async { [self] in
            guard !self.closed else { return }
            self.pendingBytes += size
            self.connection.send(
                content: packet,
                completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    self.queue.async { self.pendingBytes -= size }
                    if let error, !self.closed { self.onFailure?("Send failed: \(error.localizedDescription)") }
                })
        }
    }
}
