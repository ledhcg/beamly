import CryptoKit
import Foundation
import Testing

@testable import BeamlyKit

/// Checks protocol version 2 cryptography against `protocol/test-vectors/crypto.json`, which the Android
/// receiver's tests verify too.
struct CryptoTests {
    struct Vectors: Decodable {
        struct Keys: Decodable {
            let macIdentityPrivateHex, macIdentityPublicHex, macEphemeralPrivateHex: String
            let tvIdentityPublicHex, tvEphemeralPublicHex: String
        }

        struct Handshake: Decodable {
            let helloPayloadHex, serverHelloPayloadHex, macToTvKeyHex, tvToMacKeyHex: String
        }

        struct Pairing: Decodable {
            let macNonceHex, tvNonceHex, commitmentHex, code: String
        }

        struct Record: Decodable {
            let direction: String
            let counter: UInt64
            let type: UInt8
            let ptsMicros: UInt64
            let payloadHex, recordHex: String
        }

        let protocolVersion: UInt16
        let keys: Keys
        let handshake: Handshake
        let pairing: Pairing
        let records: [Record]
    }

    static let vectors: Vectors = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("protocol/test-vectors/crypto.json")
        do {
            return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
        } catch {
            fatalError("Cannot load \(url.path): \(error)")
        }
    }()

    let v = Self.vectors

    @Test func versionMatches() {
        #expect(BeamlyProtocol.version == v.protocolVersion)
    }

    @Test func sessionKeysFromTheMacSide() throws {
        let keys = try SessionCrypto.sessionKeys(
            macIdentity: try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(hex: v.keys.macIdentityPrivateHex)),
            macEphemeral: try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(hex: v.keys.macEphemeralPrivateHex)),
            tvIdentity: try P256.KeyAgreement.PublicKey(x963Representation: Data(hex: v.keys.tvIdentityPublicHex)),
            tvEphemeral: try P256.KeyAgreement.PublicKey(x963Representation: Data(hex: v.keys.tvEphemeralPublicHex)),
            helloPayload: Data(hex: v.handshake.helloPayloadHex),
            serverHelloPayload: Data(hex: v.handshake.serverHelloPayloadHex))
        #expect(keys.macToTV.rawData.hex == v.handshake.macToTvKeyHex)
        #expect(keys.tvToMac.rawData.hex == v.handshake.tvToMacKeyHex)
    }

    @Test func pairingCommitmentAndCode() {
        let macKey = Data(hex: v.keys.macIdentityPublicHex)
        let tvKey = Data(hex: v.keys.tvIdentityPublicHex)
        let macNonce = Data(hex: v.pairing.macNonceHex)
        let tvNonce = Data(hex: v.pairing.tvNonceHex)
        #expect(
            SessionCrypto.commitment(tvNonce: tvNonce, tvIdentity: tvKey, macIdentity: macKey).hex
                == v.pairing.commitmentHex)
        #expect(
            SessionCrypto.pairingCode(macIdentity: macKey, tvIdentity: tvKey, macNonce: macNonce, tvNonce: tvNonce)
                == v.pairing.code)
        #expect(SessionCrypto.displayCode("012345") == "012 345")
    }

    @Test func recordsMatchFixturesAndRoundTrip() throws {
        var sealers = [
            "macToTv": RecordCipher(key: SymmetricKey(data: Data(hex: v.handshake.macToTvKeyHex))),
            "tvToMac": RecordCipher(key: SymmetricKey(data: Data(hex: v.handshake.tvToMacKeyHex))),
        ]
        var openers = sealers
        for record in v.records {
            let sealed = try #require(sealers[record.direction]).sealing {
                try $0.seal(record.type, ptsMicros: record.ptsMicros, payload: Data(hex: record.payloadHex))
            }
            sealers[record.direction] = sealed.cipher
            #expect(sealed.value.hex == record.recordHex)

            let opened = try #require(openers[record.direction]).sealing { try $0.open(sealed.value.dropFirst(4)) }
            openers[record.direction] = opened.cipher
            #expect(opened.value.type == record.type)
            #expect(opened.value.ptsMicros == record.ptsMicros)
            #expect(opened.value.payload.hex == record.payloadHex)
        }
    }

    @Test func tamperedRecordIsRejected() throws {
        var sealer = RecordCipher(key: SymmetricKey(data: Data(hex: v.handshake.macToTvKeyHex)))
        var opener = sealer
        var record = try sealer.seal(3, ptsMicros: 1, payload: Data([1, 2, 3]))
        record[record.startIndex + 6] ^= 0x01
        #expect(throws: (any Error).self) { try opener.open(record.dropFirst(4)) }
    }

    @Test func recordFromTheWrongCounterIsRejected() throws {
        var sealer = RecordCipher(key: SymmetricKey(data: Data(hex: v.handshake.macToTvKeyHex)))
        var opener = sealer
        _ = try sealer.seal(5, ptsMicros: 0, payload: Data())
        let second = try sealer.seal(5, ptsMicros: 0, payload: Data())
        // Replaying or reordering records changes the nonce, so authentication fails.
        #expect(throws: (any Error).self) { try opener.open(second.dropFirst(4)) }
    }
}

extension RecordCipher {
    /// Runs a mutating operation on a copy and returns both the result and the updated cipher.
    func sealing<T>(_ body: (inout RecordCipher) throws -> T) rethrows -> (value: T, cipher: RecordCipher) {
        var copy = self
        let value = try body(&copy)
        return (value, copy)
    }
}
