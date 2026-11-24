import Foundation

/// Constants of the Beamly wire protocol. The normative specification is `docs/PROTOCOL.md`;
/// the Android counterpart is `android/app/src/main/java/app/beamly/tv/net/Protocol.kt`.
public enum BeamlyProtocol {
    /// Bumped on any incompatible change. Receivers reject a different version.
    public static let version: UInt16 = 2
    public static let defaultPort: UInt16 = 7878
    /// DNS-SD service type advertised by the TV receiver.
    public static let serviceType = "_beamly._tcp"
    static let headerSize = 13
    /// Upper bound for a single payload, mirrored by the receiver.
    static let maxPayload = 32 * 1024 * 1024
    /// The receiver gives up on pairing after this long; the sender waits slightly longer.
    static let pairingTimeout: TimeInterval = 130
}

/// Packet types. Values are part of the wire format and must never change.
enum PacketType: UInt8 {
    /// `u16 width | u16 height | u16 spsLength | sps | u16 ppsLength | pps`
    case config = 0
    /// H.264 access unit (Annex-B) that starts with an IDR frame.
    case keyFrame = 1
    /// H.264 access unit (Annex-B).
    case frame = 2
    /// PCM s16le, 48 kHz, stereo, interleaved.
    case audio = 3
    /// Empty. The sender is stopping on purpose.
    case bye = 4
    /// Empty. Heartbeat sent every second.
    case ping = 5
    /// `u16 version | u8[16] deviceId | u8[65] identityKey | u8[65] ephemeralKey | UTF-8 name`. First packet.
    case hello = 6
    /// `f32 volume | f32 gain | u8 muted`.
    case volume = 7
    /// TV → Mac: `u8 flags | u8[65] identityKey | u8[65] ephemeralKey | UTF-8 name`.
    case serverHello = 8
    /// Mac → TV, empty: start pairing.
    case pairStart = 9
    /// TV → Mac: `u8[32]` commitment to the TV's nonce.
    case pairCommit = 10
    /// Both directions: `u8[32]` nonce.
    case pairNonce = 11
    /// Both directions: `u8 accepted`.
    case pairConfirm = 12
    /// Mac → TV, empty: the last plaintext packet; records are encrypted afterwards.
    case sessionStart = 13
    /// TV → Mac, encrypted and empty: the TV accepted the session.
    case ready = 14
    /// TV → Mac: `u8 reason` (see `RejectReason`).
    case reject = 15
}

/// Reasons carried by `PacketType.reject`.
enum RejectReason: UInt8 {
    case notPaired = 1
    case pairingDeclined = 2
    case pairingTimedOut = 3

    var message: String {
        switch self {
        case .notPaired: "The TV does not recognize this Mac. Pair again."
        case .pairingDeclined: "Pairing was declined on the TV."
        case .pairingTimedOut: "Pairing timed out on the TV."
        }
    }
}

/// Parsed `SERVER_HELLO`.
struct ServerHello: Equatable {
    /// Bit 0 of the flags: the TV has paired this Mac.
    let knowsSender: Bool
    let identityKey: Data
    let ephemeralKey: Data
    let name: String

    static func parse(_ payload: Data) throws -> ServerHello {
        let keyLength = SessionCrypto.publicKeyLength
        guard payload.count >= 1 + 2 * keyLength else { throw BeamlyError("Malformed SERVER_HELLO from the TV") }
        let bytes = Data(payload)
        return ServerHello(
            knowsSender: bytes[0] & 1 != 0,
            identityKey: Data(bytes[1..<1 + keyLength]),
            ephemeralKey: Data(bytes[1 + keyLength..<1 + 2 * keyLength]),
            name: String(decoding: bytes[(1 + 2 * keyLength)...], as: UTF8.self))
    }
}

/// Pure encoding helpers, kept free of I/O so they can be unit-tested against
/// the shared fixtures in `protocol/test-vectors/`.
enum PacketCodec {
    /// Frames a payload: `u32 length | u8 type | u64 ptsMicros | payload` (big-endian).
    static func encode(_ type: PacketType, ptsMicros: UInt64 = 0, payload: Data = Data()) -> Data {
        var packet = Data(capacity: BeamlyProtocol.headerSize + payload.count)
        packet.appendBigEndian(UInt32(payload.count))
        packet.append(type.rawValue)
        packet.appendBigEndian(ptsMicros)
        packet.append(payload)
        return packet
    }

    static func helloPayload(
        deviceId: UUID, identityKey: Data, ephemeralKey: Data, deviceName: String,
        version: UInt16 = BeamlyProtocol.version
    ) -> Data {
        var payload = Data()
        payload.appendBigEndian(version)
        withUnsafeBytes(of: deviceId.uuid) { payload.append(contentsOf: $0) }
        payload.append(identityKey)
        payload.append(ephemeralKey)
        payload.append(Data(deviceName.utf8))
        return payload
    }

    static func volumePayload(volume: Float, gain: Float, muted: Bool) -> Data {
        var payload = Data()
        payload.appendBigEndian(volume.bitPattern)
        payload.appendBigEndian(gain.bitPattern)
        payload.append(muted ? 1 : 0)
        return payload
    }

    static func configPayload(width: Int, height: Int, sps: Data, pps: Data) -> Data {
        var payload = Data()
        payload.appendBigEndian(UInt16(width))
        payload.appendBigEndian(UInt16(height))
        payload.appendBigEndian(UInt16(sps.count))
        payload.append(sps)
        payload.appendBigEndian(UInt16(pps.count))
        payload.append(pps)
        return payload
    }

    /// Converts length-prefixed NAL units (AVCC, 4-byte lengths, as produced by VideoToolbox)
    /// to Annex-B start-code format (as expected by Android's MediaCodec).
    /// Stops at the first malformed length instead of reading out of bounds.
    static func annexB(fromAVCC avcc: Data) -> Data {
        let startCode: [UInt8] = [0, 0, 0, 1]
        var out = Data(capacity: avcc.count)
        var index = avcc.startIndex
        while avcc.endIndex - index >= 4 {
            let length =
                Int(avcc[index]) << 24 | Int(avcc[index + 1]) << 16 | Int(avcc[index + 2]) << 8 | Int(avcc[index + 3])
            index += 4
            guard length > 0, avcc.endIndex - index >= length else { break }
            out.append(contentsOf: startCode)
            out.append(avcc[index..<index + length])
            index += length
        }
        return out
    }
}

extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
