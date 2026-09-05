import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Compression)
import Compression
#endif

/// The sealed distribution format for a stock pack.
public enum FilmPackContainer {
    /// Bumped only when an older container would open incorrectly rather than merely fail to open.
    public static let formatVersion: UInt8 = 1

    static let magic: [UInt8] = Array("FFPK".utf8)
    static let headerCount = 20
    static let nonceCount = 12
    static let tagCount = 16

    public enum Failure: Error, CustomStringConvertible {
        case notAContainer
        case unsupportedVersion(UInt8)
        case unknownKind(UInt8)
        case truncated
        case noKey(kind: FilmPackKind, id: UInt16)
        case authenticationFailed
        case malformedPayload(underlying: Error)
        case compressionFailed
        case unsupportedPlatform

        public var description: String {
            switch self {
            case .notAContainer:
                return "not a Fotufilm pack"
            case let .unsupportedVersion(version):
                return "pack format version \(version) is newer than this build reads"
            case let .unknownKind(raw):
                return "unknown pack kind \(raw)"
            case .truncated:
                return "pack file is truncated"
            case let .noKey(kind, id):
                return "no \(kind) key \(id) is registered; this build cannot open that pack"
            case .authenticationFailed:
                return "pack failed authentication — wrong key, or the file has been altered"
            case let .malformedPayload(error):
                return "pack contents are not a valid manifest: \(error)"
            case .compressionFailed:
                return "pack contents could not be compressed"
            case .unsupportedPlatform:
                return "sealed packs need CryptoKit, which this platform does not have"
            }
        }
    }

    /// Exports go through `FilmStockPack.sealForSharing`, which is what checks provenance first.
    public static func seal(_ manifest: FilmPackManifest,
                            kind: FilmPackKind,
                            keyID: UInt16,
                            key: FilmPackKey) throws -> Data {
        #if canImport(CryptoKit)
        try manifest.release.validate()
        let json = try JSONEncoder().encode(manifest)
        guard let payload = deflate(json) else { throw Failure.compressionFailed }

        var header = Data(magic)
        header.append(formatVersion)
        header.append(kind.rawValue)
        header.append(UInt8(keyID & 0xFF))
        header.append(UInt8(keyID >> 8))
        let nonce = AES.GCM.Nonce()
        header.append(contentsOf: nonce)

        let sealed = try AES.GCM.seal(payload, using: key.symmetric,
                                      nonce: nonce, authenticating: header)
        return header + sealed.ciphertext + sealed.tag
        #else
        throw Failure.unsupportedPlatform
        #endif
    }

    /// Readable without a key, so a caller can refuse a kind before looking
    /// for the key to open it with.
    public struct Head: Sendable {
        public var kind: FilmPackKind
        public var keyID: UInt16
    }

    public static func peek(_ data: Data) throws -> Head {
        guard data.count >= 4, Array(data.prefix(4)) == magic else {
            throw Failure.notAContainer
        }
        guard data.count >= headerCount + tagCount else { throw Failure.truncated }
        let bytes = [UInt8](data.prefix(headerCount))
        guard bytes[4] == formatVersion else { throw Failure.unsupportedVersion(bytes[4]) }
        guard let kind = FilmPackKind(rawValue: bytes[5]) else {
            throw Failure.unknownKind(bytes[5])
        }
        return Head(kind: kind, keyID: UInt16(bytes[6]) | (UInt16(bytes[7]) << 8))
    }

    /// Opens whatever it is handed if the keyring has the key.
    public static func open(_ data: Data,
                            keyring: FilmPackKeyring = .shared,
                            macAppVersion: String? = nil)
        throws -> (manifest: FilmPackManifest, head: Head) {
        #if canImport(CryptoKit)
        let head = try peek(data)
        guard let key = keyring.key(kind: head.kind, id: head.keyID) else {
            throw Failure.noKey(kind: head.kind, id: head.keyID)
        }

        let header = data.prefix(headerCount)
        let body = data.dropFirst(headerCount)
        let nonceBytes = header.suffix(nonceCount)
        let ciphertext = body.dropLast(tagCount)
        let tag = body.suffix(tagCount)

        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonceBytes),
                                            ciphertext: ciphertext, tag: tag)
            plaintext = try AES.GCM.open(box, using: key.symmetric, authenticating: header)
        } catch {
            throw Failure.authenticationFailed
        }

        guard let json = inflate(plaintext) else { throw Failure.compressionFailed }
        // Read compatibility before stocks: a newer pack may use stock fields this app cannot decode.
        let release = try JSONDecoder().decode(FilmPackRelease.self, from: json)
        try release.validate()
        if let macAppVersion { try release.requireMacApp(version: macAppVersion) }
        do {
            return (try JSONDecoder().decode(FilmPackManifest.self, from: json), head)
        } catch {
            throw Failure.malformedPayload(underlying: error)
        }
        #else
        throw Failure.unsupportedPlatform
        #endif
    }

    /// Bounded because DEFLATE expands by up to 1000:1 and a shared pack is a
    /// file off the internet.
    static let inflatedLimit = 32 << 20

    /// Checked before any of the file is decrypted.
    public static let fileLimit = 16 << 20

    private static func deflate(_ data: Data) -> Data? {
        #if canImport(Compression)
        return try? (data as NSData).compressed(using: .zlib) as Data
        #else
        return nil
        #endif
    }

    private static func inflate(_ data: Data, limit: Int = inflatedLimit) -> Data? {
        #if canImport(Compression)
        guard !data.isEmpty else { return nil }
        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0,
            state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE,
                                      COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK
        else { return nil }
        defer { compression_stream_destroy(&stream) }

        let chunk = 64 << 10
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: chunk)

        return data.withUnsafeBytes { source -> Data? in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return nil }
            stream.src_ptr = base
            stream.src_size = source.count

            while true {
                let status = buffer.withUnsafeMutableBufferPointer { destination -> compression_status in
                    stream.dst_ptr = destination.baseAddress!
                    stream.dst_size = destination.count
                    let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    output.append(destination.baseAddress!, count: destination.count - stream.dst_size)
                    return status
                }
                switch status {
                case COMPRESSION_STATUS_END:
                    return output
                case COMPRESSION_STATUS_OK:
                    guard output.count <= limit else { return nil }
                default:
                    return nil
                }
            }
        }
        #else
        return nil
        #endif
    }
}

/// The kinds differ only in where their key lives, which is the whole of the
/// protection this format offers.
public enum FilmPackKind: UInt8, Sendable, CustomStringConvertible {
    /// The shipped pack.
    case vault = 0
    /// User to user.
    case community = 1
    /// At rest on one device, under a key that stays in its keychain.
    case local = 2

    public var description: String {
        switch self {
        case .vault: return "vault"
        case .community: return "community"
        case .local: return "local"
        }
    }
}

/// A 256-bit container key.
public struct FilmPackKey: Sendable {
    public static let byteCount = 32
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) throws {
        guard bytes.count == FilmPackKey.byteCount else {
            throw Failure.wrongLength(bytes.count)
        }
        self.bytes = bytes
    }

    /// 64 hex characters — what a build script and an environment variable
    /// can both carry unmangled.
    public init(hex: String) throws {
        let cleaned = hex.filter { !$0.isWhitespace }
        guard cleaned.count == FilmPackKey.byteCount * 2 else {
            throw Failure.wrongLength(cleaned.count / 2)
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(FilmPackKey.byteCount)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else {
                throw Failure.notHex
            }
            bytes.append(byte)
            index = next
        }
        self.bytes = bytes
    }

    public var hex: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func random() -> FilmPackKey {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return try! FilmPackKey(bytes: bytes)
    }

    public enum Failure: Error, CustomStringConvertible {
        case wrongLength(Int)
        case notHex

        public var description: String {
            switch self {
            case let .wrongLength(count):
                return "a pack key is \(FilmPackKey.byteCount) bytes; got \(count)"
            case .notHex:
                return "a pack key in text form is hexadecimal"
            }
        }
    }

    #if canImport(CryptoKit)
    var symmetric: SymmetricKey { SymmetricKey(data: bytes) }
    #endif
}

/// Empty until a host registers something: an engine build that registers
/// nothing reads plain JSON packs and no sealed ones.
public final class FilmPackKeyring: @unchecked Sendable {
    public static let shared = FilmPackKeyring()

    private var keys: [Slot: FilmPackKey] = [:]
    private let lock = NSLock()

    private struct Slot: Hashable {
        var kind: FilmPackKind
        var id: UInt16
    }

    public init() {}

    public func register(_ key: FilmPackKey, kind: FilmPackKind, id: UInt16) {
        lock.lock()
        defer { lock.unlock() }
        keys[Slot(kind: kind, id: id)] = key
    }

    public func key(kind: FilmPackKind, id: UInt16) -> FilmPackKey? {
        lock.lock()
        defer { lock.unlock() }
        return keys[Slot(kind: kind, id: id)]
    }

    /// The newest registered key of a kind — what a fresh seal uses.
    public func newest(kind: FilmPackKind) -> (key: FilmPackKey, id: UInt16)? {
        lock.lock()
        defer { lock.unlock() }
        return keys.filter { $0.key.kind == kind }
            .max { $0.key.id < $1.key.id }
            .map { ($0.value, $0.key.id) }
    }

    public var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return keys.isEmpty
    }
}

public struct FilmPackManifest: Codable, Sendable {
    /// Bumped only when an older manifest would decode incorrectly.
    public var manifestVersion: Int
    /// Imported stock ids are qualified with this, so two shared packs may both carry the same id
    /// without either replacing the other.
    public var packID: String
    public var name: String
    public var author: String?
    public var notes: String?
    /// Presentation only; nothing trusts it.
    public var created: Date
    /// Release versions are independent of the container and manifest schemas.
    public var version: String?
    public var minimumMacAppVersion: String?
    public var stocks: [FilmStockDefinition]

    public var release: FilmPackRelease {
        FilmPackRelease(version: version, minimumMacAppVersion: minimumMacAppVersion)
    }

    public init(packID: String, name: String, author: String? = nil,
                notes: String? = nil, created: Date = Date(),
                version: String? = nil, minimumMacAppVersion: String? = nil,
                stocks: [FilmStockDefinition]) {
        self.manifestVersion = 1
        self.packID = packID
        self.name = name
        self.author = author
        self.notes = notes
        self.created = created
        self.version = version
        self.minimumMacAppVersion = minimumMacAppVersion
        self.stocks = stocks
    }
}

/// Optional for packs created before release versioning was introduced.
public struct FilmPackRelease: Codable, Sendable {
    public var version: String?
    public var minimumMacAppVersion: String?

    public init(version: String? = nil, minimumMacAppVersion: String? = nil) {
        self.version = version
        self.minimumMacAppVersion = minimumMacAppVersion
    }

    public enum Failure: Error, CustomStringConvertible {
        case invalidVersion(String)
        case requiresMacApp(String)

        public var description: String {
            switch self {
            case .invalidVersion(let value):
                return "Invalid pack version: \(value). Use numbers such as 1.2.0."
            case .requiresMacApp(let version):
                return "This pack needs Fotufilm \(version) or later. Please update to the latest version, then load the pack again."
            }
        }
    }

    private static func components(_ value: String) throws -> [Int] {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), parts.allSatisfy({
            !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } && Int($0) != nil
        }) else { throw Failure.invalidVersion(value) }
        return parts.map { Int($0)! } + Array(repeating: 0, count: 3 - parts.count)
    }

    public func validate() throws {
        if let version { _ = try Self.components(version) }
        if let minimumMacAppVersion { _ = try Self.components(minimumMacAppVersion) }
    }

    public func requireMacApp(version current: String) throws {
        guard let minimumMacAppVersion else { return }
        let required = try Self.components(minimumMacAppVersion)
        guard let running = try? Self.components(current),
              !running.lexicographicallyPrecedes(required) else {
            throw Failure.requiresMacApp(minimumMacAppVersion)
        }
    }
}
