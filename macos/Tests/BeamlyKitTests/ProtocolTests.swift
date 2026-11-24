import Foundation
import Network
import Testing

@testable import BeamlyKit

/// Checks the sender's encoding against `protocol/test-vectors/packets.json`, the fixtures shared
/// with the Android receiver's tests.
struct ProtocolTests {
    struct Vectors: Decodable {
        struct Packet: Decodable {
            struct Input: Decodable {
                let volume: Float
                let gain: Float
                let muted: Bool
            }

            struct Expected: Decodable {
                let protocolVersion: UInt16?
                let deviceName: String?
                let deviceIdHex: String?
                let identityKeyHex: String?
                let ephemeralKeyHex: String?
                let knowsSender: Bool?
                let name: String?
                let width: Int?
                let height: Int?
                let spsHex: String?
                let ppsHex: String?
            }

            let name: String
            let type: UInt8
            let ptsMicros: UInt64
            let payloadHex: String
            let encodedHex: String
            let input: Input?
            let expected: Expected?
        }

        struct AnnexBCase: Decodable {
            let name: String
            let avccHex: String
            let annexBHex: String
        }

        let protocolVersion: UInt16
        let packets: [Packet]
        let avccToAnnexB: [AnnexBCase]
    }

    static let vectors: Vectors = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // BeamlyKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // macos
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("protocol/test-vectors/packets.json")
        do {
            return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
        } catch {
            fatalError("Cannot load \(url.path): \(error)")
        }
    }()

    static func packet(_ name: String) -> Vectors.Packet {
        guard let packet = vectors.packets.first(where: { $0.name == name }) else {
            fatalError("Missing test vector \(name)")
        }
        return packet
    }

    @Test func protocolVersionMatchesFixtures() {
        #expect(BeamlyProtocol.version == Self.vectors.protocolVersion)
    }

    @Test(arguments: vectors.packets.map(\.name))
    func framing(name: String) throws {
        let vector = Self.packet(name)
        let type = try #require(PacketType(rawValue: vector.type))
        let encoded = PacketCodec.encode(type, ptsMicros: vector.ptsMicros, payload: Data(hex: vector.payloadHex))
        #expect(encoded.hex == vector.encodedHex)
    }

    @Test func helloPayload() throws {
        let vector = Self.packet("hello")
        let expected = try #require(vector.expected)
        let deviceId = Data(hex: try #require(expected.deviceIdHex))
        let uuid = deviceId.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
        let payload = PacketCodec.helloPayload(
            deviceId: uuid, identityKey: Data(hex: try #require(expected.identityKeyHex)),
            ephemeralKey: Data(hex: try #require(expected.ephemeralKeyHex)),
            deviceName: try #require(expected.deviceName), version: try #require(expected.protocolVersion))
        #expect(payload.hex == vector.payloadHex)
    }

    @Test func serverHelloParsing() throws {
        let vector = Self.packet("server-hello")
        let expected = try #require(vector.expected)
        let hello = try ServerHello.parse(Data(hex: vector.payloadHex))
        #expect(hello.knowsSender == expected.knowsSender)
        #expect(hello.identityKey.hex == expected.identityKeyHex)
        #expect(hello.ephemeralKey.hex == expected.ephemeralKeyHex)
        #expect(hello.name == expected.name)
        #expect(throws: BeamlyError.self) { try ServerHello.parse(Data(hex: vector.payloadHex).prefix(100)) }
    }

    @Test(arguments: ["volume", "volume-muted"])
    func volumePayload(name: String) throws {
        let vector = Self.packet(name)
        let input = try #require(vector.input)
        let payload = PacketCodec.volumePayload(volume: input.volume, gain: input.gain, muted: input.muted)
        #expect(payload.hex == vector.payloadHex)
    }

    @Test func configPayload() throws {
        let vector = Self.packet("config")
        let expected = try #require(vector.expected)
        let payload = PacketCodec.configPayload(
            width: try #require(expected.width), height: try #require(expected.height),
            sps: Data(hex: try #require(expected.spsHex)), pps: Data(hex: try #require(expected.ppsHex)))
        #expect(payload.hex == vector.payloadHex)
    }

    @Test(arguments: vectors.avccToAnnexB.map(\.name))
    func avccToAnnexB(name: String) throws {
        let vector = try #require(Self.vectors.avccToAnnexB.first { $0.name == name })
        #expect(PacketCodec.annexB(fromAVCC: Data(hex: vector.avccHex)).hex == vector.annexBHex)
    }

    @Test func annexBHandlesSlicedData() {
        // Data slices keep their parent's indices; the converter must not assume startIndex == 0.
        let buffer = Data(hex: "ffff" + "00000002aabb")
        #expect(PacketCodec.annexB(fromAVCC: buffer.dropFirst(2)).hex == "00000001aabb")
    }

    @Test func discoveryKeepsOneEntryPerNameSortedByName() {
        func service(_ name: String, _ interface: String) -> NWEndpoint {
            .service(name: name, type: BeamlyProtocol.serviceType, domain: "local.", interface: nil)
        }
        let tvs = TVBrowser.uniqueTVs([
            service("Living Room", "en0"), service("Bedroom", "en0"), service("Living Room", "en1"),
        ])
        #expect(tvs.map(\.name) == ["Bedroom", "Living Room"])
    }
}

extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
