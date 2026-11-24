import CryptoKit
import Foundation

/// This Mac's identity key and the TVs it has paired with.
///
/// Stored in `~/Library/Application Support/Beamly/` with owner-only permissions (0700 directory, 0600 files).
/// The app and the CLI share it, which rules out the Keychain: they have different code signatures, so each
/// would be prompted for the other's items.
public final class TrustStore {
    public struct PairedTV: Codable, Sendable {
        public let name: String
        /// Base64 of the 65-byte uncompressed P-256 identity key.
        public let identityKey: String
        public let pairedAt: Date
    }

    private struct IdentityFile: Codable {
        let deviceId: UUID
        /// Base64 of the 32-byte raw P-256 private scalar.
        let privateKey: String
    }

    public static let shared = TrustStore()

    private let directory: URL
    private let lock = NSLock()

    public init(directory: URL? = nil) {
        self.directory =
            directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Beamly", isDirectory: true)
    }

    private var identityURL: URL { directory.appendingPathComponent("identity.json") }
    private var pairedURL: URL { directory.appendingPathComponent("paired-tvs.json") }

    /// Loads the identity, creating it on first use.
    func identity() throws -> (deviceId: UUID, key: P256.KeyAgreement.PrivateKey) {
        lock.lock()
        defer { lock.unlock() }
        if let data = try? Data(contentsOf: identityURL),
            let file = try? JSONDecoder().decode(IdentityFile.self, from: data),
            let raw = Data(base64Encoded: file.privateKey),
            let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: raw)
        {
            return (file.deviceId, key)
        }
        let key = P256.KeyAgreement.PrivateKey()
        let file = IdentityFile(deviceId: UUID(), privateKey: key.rawRepresentation.base64EncodedString())
        try write(JSONEncoder().encode(file), to: identityURL)
        return (file.deviceId, key)
    }

    public var pairedTVs: [PairedTV] {
        lock.lock()
        defer { lock.unlock() }
        return loadPaired()
    }

    func isTrusted(_ identityKey: Data) -> Bool {
        pairedTVs.contains { $0.identityKey == identityKey.base64EncodedString() }
    }

    func trust(_ identityKey: Data, name: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let encoded = identityKey.base64EncodedString()
        var list = loadPaired().filter { $0.identityKey != encoded }
        list.append(PairedTV(name: name, identityKey: encoded, pairedAt: Date()))
        try write(JSONEncoder().encode(list), to: pairedURL)
    }

    /// Forgets one TV, e.g. after it reported that it no longer knows this Mac.
    func forget(_ identityKey: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        let encoded = identityKey.base64EncodedString()
        try write(JSONEncoder().encode(loadPaired().filter { $0.identityKey != encoded }), to: pairedURL)
    }

    /// Forgets every paired TV; the next connection to each TV pairs again.
    public func forgetAllTVs() throws {
        lock.lock()
        defer { lock.unlock() }
        if FileManager.default.fileExists(atPath: pairedURL.path) {
            try FileManager.default.removeItem(at: pairedURL)
        }
    }

    private func loadPaired() -> [PairedTV] {
        guard let data = try? Data(contentsOf: pairedURL) else { return [] }
        return (try? JSONDecoder().decode([PairedTV].self, from: data)) ?? []
    }

    private func write(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = url.appendingPathExtension("tmp")
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw BeamlyError("Cannot write \(url.lastPathComponent)")
        }
        if manager.fileExists(atPath: url.path) {
            _ = try manager.replaceItemAt(url, withItemAt: temporary)
        } else {
            try manager.moveItem(at: temporary, to: url)
        }
    }
}
