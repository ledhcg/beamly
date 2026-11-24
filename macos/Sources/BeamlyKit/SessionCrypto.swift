import CryptoKit
import Foundation

/// Cryptography of protocol version 2 (docs/PROTOCOL.md §6–§7, §4.2). Pure functions, unit-tested against
/// `protocol/test-vectors/crypto.json`, which the Android receiver's tests also verify.
enum SessionCrypto {
    static let publicKeyLength = 65
    static let nonceLength = 32

    /// TV's pairing commitment: `HMAC-SHA256(Nt, "beamly-pair-commit" ‖ IDt ‖ IDm)`.
    static func commitment(tvNonce: Data, tvIdentity: Data, macIdentity: Data) -> Data {
        var message = Data("beamly-pair-commit".utf8)
        message.append(tvIdentity)
        message.append(macIdentity)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: tvNonce)))
    }

    /// Six-digit code both users compare: `uint32(SHA-256("beamly-pair-code" ‖ IDm ‖ IDt ‖ Nm ‖ Nt)[0..4]) mod 10⁶`.
    static func pairingCode(macIdentity: Data, tvIdentity: Data, macNonce: Data, tvNonce: Data) -> String {
        var message = Data("beamly-pair-code".utf8)
        for part in [macIdentity, tvIdentity, macNonce, tvNonce] { message.append(part) }
        let digest = Array(SHA256.hash(data: message))
        let value = UInt32(digest[0]) << 24 | UInt32(digest[1]) << 16 | UInt32(digest[2]) << 8 | UInt32(digest[3])
        return String(format: "%06u", value % 1_000_000)
    }

    /// Formats a code for display: "123 456".
    static func displayCode(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }

    /// Session keys as seen by the Mac (the sender).
    static func sessionKeys(
        macIdentity: P256.KeyAgreement.PrivateKey, macEphemeral: P256.KeyAgreement.PrivateKey,
        tvIdentity: P256.KeyAgreement.PublicKey, tvEphemeral: P256.KeyAgreement.PublicKey,
        helloPayload: Data, serverHelloPayload: Data
    ) throws -> (macToTV: SymmetricKey, tvToMac: SymmetricKey) {
        var ikm = Data()
        ikm.append(try macEphemeral.sharedSecretFromKeyAgreement(with: tvEphemeral).rawData)  // ss1
        ikm.append(try macIdentity.sharedSecretFromKeyAgreement(with: tvEphemeral).rawData)  // ss2
        ikm.append(try macEphemeral.sharedSecretFromKeyAgreement(with: tvIdentity).rawData)  // ss3
        var transcript = helloPayload
        transcript.append(serverHelloPayload)
        let salt = Data(SHA256.hash(data: transcript))
        let okm = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm), salt: salt, info: Data("beamly v2 session".utf8),
            outputByteCount: 64
        ).rawData
        return (SymmetricKey(data: okm.prefix(32)), SymmetricKey(data: okm.suffix(32)))
    }

    static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

/// AES-256-GCM record layer for one direction (docs/PROTOCOL.md §4.2). Not thread-safe: use from one queue.
struct RecordCipher {
    /// Ciphertext length: header (9) + payload + tag (16).
    static let overhead = 9 + 16
    private let key: SymmetricKey
    private(set) var counter: UInt64 = 0

    init(key: SymmetricKey) {
        self.key = key
    }

    /// Returns a complete record: `u32 length ‖ ciphertext ‖ tag`.
    mutating func seal(_ type: UInt8, ptsMicros: UInt64, payload: Data) throws -> Data {
        var plaintext = Data(capacity: 9 + payload.count)
        plaintext.append(type)
        plaintext.appendBigEndian(ptsMicros)
        plaintext.append(payload)
        let box = try AES.GCM.seal(plaintext, using: key, nonce: try nextNonce())
        var record = Data(capacity: 4 + box.ciphertext.count + box.tag.count)
        record.appendBigEndian(UInt32(box.ciphertext.count + box.tag.count))
        record.append(box.ciphertext)
        record.append(box.tag)
        return record
    }

    /// Decrypts the ciphertext of one record (without its length prefix).
    mutating func open(_ ciphertext: Data) throws -> (type: UInt8, ptsMicros: UInt64, payload: Data) {
        guard ciphertext.count >= Self.overhead else { throw BeamlyError("Encrypted record is too short") }
        let body = ciphertext.prefix(ciphertext.count - 16)
        let tag = ciphertext.suffix(16)
        let box = try AES.GCM.SealedBox(nonce: try nextNonce(), ciphertext: body, tag: tag)
        let plaintext = try AES.GCM.open(box, using: key)
        let bytes = [UInt8](plaintext.prefix(9))
        let pts = bytes[1...8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return (bytes[0], pts, plaintext.dropFirst(9))
    }

    private mutating func nextNonce() throws -> AES.GCM.Nonce {
        guard counter < UInt64.max else { throw BeamlyError("Record counter exhausted") }
        var nonce = Data(repeating: 0, count: 4)
        nonce.appendBigEndian(counter)
        counter += 1
        return try AES.GCM.Nonce(data: nonce)
    }
}

extension SharedSecret {
    var rawData: Data { withUnsafeBytes { Data($0) } }
}

extension SymmetricKey {
    var rawData: Data { withUnsafeBytes { Data($0) } }
}
