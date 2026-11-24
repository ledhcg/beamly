import CryptoKit
import Foundation
import Network

/// TCP connection to the receiver: handshake, pairing and the encrypted record layer (docs/PROTOCOL.md).
/// All state lives on `queue`; public methods are thread-safe.
final class Sender {
    /// A pairing code to show the user, and a callback that reports whether the user confirmed it.
    struct PairingRequest {
        let code: String
        let tvName: String
        let respond: (Bool) -> Void
    }

    private enum Phase {
        case connecting
        case awaitingServerHello
        case awaitingCommit
        case awaitingTVNonce(commitment: Data, macNonce: Data)
        case awaitingConfirmations(local: Bool?, remote: Bool?)
        case awaitingReady
        case established
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "app.beamly.net")
    private let trustStore: TrustStore
    private var phase = Phase.connecting
    private var ready = false
    private var closed = false
    private var heartbeat: DispatchSourceTimer?
    private var handshakeTimeout: DispatchWorkItem?

    private var identity: (deviceId: UUID, key: P256.KeyAgreement.PrivateKey)?
    private let ephemeral = P256.KeyAgreement.PrivateKey()
    private var helloPayload = Data()
    private var serverHelloPayload = Data()
    private var serverHello: ServerHello?
    private var outbound: RecordCipher?
    private var inbound: RecordCipher?
    private var inputBuffer = Data()

    /// Bytes handed to Network.framework but not yet sent; used to drop frames on congestion.
    private var pendingBytes = 0
    private let maxPendingBytes = 3 * 1024 * 1024

    /// TCP connection established (the handshake has not run yet).
    var onConnected: (() -> Void)?
    /// The TV needs the user to confirm a pairing code.
    var onPairing: ((PairingRequest) -> Void)?
    /// Handshake complete; media may be sent.
    var onReady: (() -> Void)?
    var onFailure: ((String) -> Void)?

    init(endpoint: NWEndpoint, trustStore: TrustStore) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        connection = NWConnection(to: endpoint, using: NWParameters(tls: nil, tcp: tcp))
        self.trustStore = trustStore
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
                self.onConnected?()
                self.startHeartbeat()
                self.beginHandshake()
                self.receive()
            case .waiting(let error):
                // NWConnection retries forever; give up after a few seconds.
                self.queue.asyncAfter(deadline: .now() + 5) {
                    if !self.ready {
                        self.fail(
                            "Cannot connect to the TV (\(error.localizedDescription)). Is the Beamly app open on the TV?"
                        )
                    }
                }
            case .failed(let error):
                self.fail("Connection lost: \(error.localizedDescription)")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    // MARK: Sending

    /// Queues a packet. Before `SESSION_START` packets go out in plaintext, afterwards as encrypted records.
    func send(_ type: PacketType, ptsMicros: UInt64 = 0, payload: Data = Data()) {
        queue.async { [self] in
            guard !self.closed else { return }
            self.write(type, ptsMicros: ptsMicros, payload: payload)
        }
    }

    /// Must run on `queue`: encryption counters advance in send order.
    private func write(_ type: PacketType, ptsMicros: UInt64 = 0, payload: Data = Data()) {
        let packet: Data
        if var cipher = outbound {
            do {
                packet = try cipher.seal(type.rawValue, ptsMicros: ptsMicros, payload: payload)
            } catch {
                fail("Encryption failed: \(error.localizedDescription)")
                return
            }
            outbound = cipher
        } else {
            packet = PacketCodec.encode(type, ptsMicros: ptsMicros, payload: payload)
        }
        let size = packet.count
        pendingBytes += size
        connection.send(
            content: packet,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.queue.async { self.pendingBytes -= size }
                if let error, !self.closed { self.fail("Send failed: \(error.localizedDescription)") }
            })
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, !self.closed else { return }
            self.write(.ping)
        }
        timer.resume()
        heartbeat = timer
    }

    // MARK: Handshake

    private func beginHandshake() {
        do {
            let identity = try trustStore.identity()
            self.identity = identity
            helloPayload = PacketCodec.helloPayload(
                deviceId: identity.deviceId, identityKey: identity.key.publicKey.x963Representation,
                ephemeralKey: ephemeral.publicKey.x963Representation,
                deviceName: Host.current().localizedName ?? "Mac")
        } catch {
            fail("Cannot load this Mac's identity key: \(error.localizedDescription)")
            return
        }
        // HELLO must be the first packet: the TV only accepts connections that send data, which filters out
        // the parallel "Happy Eyeballs" attempts Network.framework abandons.
        write(.hello, payload: helloPayload)
        phase = .awaitingServerHello
        armTimeout(10, message: "The TV did not answer the handshake. Update Beamly on the TV.")
    }

    private func armTimeout(_ seconds: TimeInterval, message: String) {
        handshakeTimeout?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.fail(message) }
        handshakeTimeout = item
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func handle(_ type: UInt8, payload: Data) throws {
        guard let packetType = PacketType(rawValue: type) else { return }  // unknown types are ignored
        if packetType == .reject {
            let reason = payload.first.flatMap(RejectReason.init(rawValue:))
            if reason == .notPaired, let key = serverHello?.identityKey {
                // The TV forgot this Mac; forget the TV too so the next connection pairs again.
                try? trustStore.forget(key)
            }
            throw BeamlyError(reason?.message ?? "The TV refused the connection.")
        }

        switch (phase, packetType) {
        case (.awaitingServerHello, .serverHello):
            let hello = try ServerHello.parse(payload)
            serverHello = hello
            serverHelloPayload = payload
            if hello.knowsSender && trustStore.isTrusted(hello.identityKey) {
                try startSession()
            } else {
                write(.pairStart)
                phase = .awaitingCommit
                armTimeout(BeamlyProtocol.pairingTimeout, message: "Pairing timed out.")
            }

        case (.awaitingCommit, .pairCommit):
            guard payload.count == 32 else { throw BeamlyError("Malformed pairing commitment") }
            let macNonce = SessionCrypto.randomBytes(SessionCrypto.nonceLength)
            phase = .awaitingTVNonce(commitment: Data(payload), macNonce: macNonce)
            write(.pairNonce, payload: macNonce)

        case (.awaitingTVNonce(let commitment, let macNonce), .pairNonce):
            guard let hello = serverHello, let identity, payload.count == SessionCrypto.nonceLength else {
                throw BeamlyError("Malformed pairing nonce")
            }
            let tvNonce = Data(payload)
            let macKey = identity.key.publicKey.x963Representation
            let expected = SessionCrypto.commitment(
                tvNonce: tvNonce, tvIdentity: hello.identityKey, macIdentity: macKey)
            guard expected == commitment else {
                throw BeamlyError("Pairing failed: the TV's answer did not match its commitment.")
            }
            let code = SessionCrypto.pairingCode(
                macIdentity: macKey, tvIdentity: hello.identityKey, macNonce: macNonce, tvNonce: tvNonce)
            phase = .awaitingConfirmations(local: nil, remote: nil)
            onPairing?(
                PairingRequest(code: SessionCrypto.displayCode(code), tvName: hello.name) { [weak self] accepted in
                    self?.queue.async { self?.localPairingDecision(accepted) }
                })

        case (.awaitingConfirmations(let local, _), .pairConfirm):
            guard payload.first == 1 else { throw BeamlyError(RejectReason.pairingDeclined.message) }
            phase = .awaitingConfirmations(local: local, remote: true)
            try finishPairingIfConfirmed()

        case (_, .ping):
            break

        case (.awaitingReady, .ready):
            handshakeTimeout?.cancel()
            phase = .established
            onReady?()

        default:
            throw BeamlyError("Unexpected packet \(packetType) from the TV during the handshake.")
        }
    }

    private func localPairingDecision(_ accepted: Bool) {
        guard !closed, case .awaitingConfirmations(_, let remote) = phase else { return }
        guard accepted else {
            // Deliver the refusal before closing so the TV can tell the user why pairing ended.
            closeAfterSending(.pairConfirm, payload: Data([0]), failure: "Pairing was cancelled on this Mac.")
            return
        }
        write(.pairConfirm, payload: Data([1]))
        phase = .awaitingConfirmations(local: true, remote: remote)
        do {
            try finishPairingIfConfirmed()
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func finishPairingIfConfirmed() throws {
        guard case .awaitingConfirmations(true, true) = phase, let hello = serverHello else { return }
        try trustStore.trust(hello.identityKey, name: hello.name)
        try startSession()
    }

    /// Derives the session keys, sends the last plaintext packet and switches both directions to encryption.
    private func startSession() throws {
        guard let hello = serverHello, let identity else { throw BeamlyError("Handshake state is incomplete") }
        let keys = try SessionCrypto.sessionKeys(
            macIdentity: identity.key, macEphemeral: ephemeral,
            tvIdentity: try P256.KeyAgreement.PublicKey(x963Representation: hello.identityKey),
            tvEphemeral: try P256.KeyAgreement.PublicKey(x963Representation: hello.ephemeralKey),
            helloPayload: helloPayload, serverHelloPayload: serverHelloPayload)
        write(.sessionStart)
        outbound = RecordCipher(key: keys.macToTV)
        inbound = RecordCipher(key: keys.tvToMac)
        phase = .awaitingReady
        armTimeout(10, message: "The TV did not accept the session.")
    }

    // MARK: Receiving

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data { self.inputBuffer.append(data) }
            do {
                try self.processInput()
            } catch {
                self.fail(error.localizedDescription)
                return
            }
            if let error {
                self.fail("Connection lost: \(error.localizedDescription)")
            } else if complete {
                self.fail("The TV closed the connection.")
            } else {
                self.receive()
            }
        }
    }

    private func processInput() throws {
        while !closed {
            if var cipher = inbound {
                guard inputBuffer.count >= 4 else { return }
                let length = Int(inputBuffer.readUInt32(at: 0))
                guard length >= RecordCipher.overhead, length <= BeamlyProtocol.maxPayload + RecordCipher.overhead
                else {
                    throw BeamlyError("Invalid record length from the TV")
                }
                guard inputBuffer.count >= 4 + length else { return }
                let record = try cipher.open(
                    inputBuffer.subdata(in: inputBuffer.startIndex + 4..<inputBuffer.startIndex + 4 + length))
                inbound = cipher
                inputBuffer.removeFirst(4 + length)
                try handle(record.type, payload: record.payload)
            } else {
                guard inputBuffer.count >= BeamlyProtocol.headerSize else { return }
                let length = Int(inputBuffer.readUInt32(at: 0))
                guard length <= BeamlyProtocol.maxPayload else {
                    throw BeamlyError("Invalid packet length from the TV")
                }
                guard inputBuffer.count >= BeamlyProtocol.headerSize + length else { return }
                let start = inputBuffer.startIndex
                let type = inputBuffer[start + 4]
                let payload = inputBuffer.subdata(
                    in: start + BeamlyProtocol.headerSize..<start + BeamlyProtocol.headerSize + length)
                inputBuffer.removeFirst(BeamlyProtocol.headerSize + length)
                try handle(type, payload: payload)
            }
        }
    }

    // MARK: Closing

    private func fail(_ message: String) {
        guard !closed else { return }
        closeConnection()
        onFailure?(message)
    }

    private func closeConnection() {
        closed = true
        heartbeat?.cancel()
        handshakeTimeout?.cancel()
        connection.cancel()
    }

    /// Sends one last plaintext packet, closes once it is delivered (or after 1 s), and reports `failure`.
    private func closeAfterSending(_ type: PacketType, payload: Data, failure: String) {
        guard !closed else { return }
        closed = true
        heartbeat?.cancel()
        handshakeTimeout?.cancel()
        let connection = self.connection
        connection.send(
            content: PacketCodec.encode(type, payload: payload), contentContext: .finalMessage, isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() })
        queue.asyncAfter(deadline: .now() + 1) { connection.cancel() }
        onFailure?(failure)
    }

    /// Closes immediately, without notifying the receiver (used after errors).
    func cancel() {
        queue.async { if !self.closed { self.closeConnection() } }
    }

    /// Graceful stop: sends BYE and a TCP FIN, then cancels. The receiver relies on BYE (or the heartbeat
    /// timeout), not on FIN, because FIN is not reliably delivered when the process exits.
    func close() {
        queue.async {
            guard !self.closed else { return }
            guard case .established = self.phase, var cipher = self.outbound,
                let bye = try? cipher.seal(PacketType.bye.rawValue, ptsMicros: 0, payload: Data())
            else {
                self.closeConnection()
                return
            }
            self.outbound = cipher
            self.closed = true
            self.heartbeat?.cancel()
            let connection = self.connection
            connection.send(
                content: bye, contentContext: .finalMessage, isComplete: true,
                completion: .contentProcessed { _ in connection.cancel() })
            // Fallback in case the send never completes.
            self.queue.asyncAfter(deadline: .now() + 1) { connection.cancel() }
        }
    }
}

extension Data {
    func readUInt32(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }
}
