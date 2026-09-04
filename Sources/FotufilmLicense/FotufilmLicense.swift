#if os(macOS)
import CryptoKit
import Darwin
import Foundation

/// Signed, device-bound activation shared by the desktop app and the host plug-ins.
///
/// The shared file contains only the server-issued certificate. It does not contain the license
/// key, a Google identity, a Stripe identity, or credentials that can be used with the website.
public enum FotufilmLicense {
    public static let productID = "fotufilm-desktop"
    public static let productionPublicKeyBase64 =
        "V3G93GNTOTU0zR3xMxKda6k7QlYV0ynm5iDH/ErLQCg="
    public static let inactiveMessage =
        "Fotufilm is not activated. Open the Fotufilm app and enter a purchased license key."

    public struct Payload: Decodable, Sendable {
        public let version: Int
        public let licenseId: String?
        public let activationId: String?
        public let product: String
        public let deviceId: String
        public let issuedAt: Date
        public let expiresAt: Date
    }

    public struct Status: Sendable {
        public let isActive: Bool
        public let expiresAt: Date?
    }

    public enum StorageError: LocalizedError {
        case deviceIdentityUnavailable
        case invalidCertificate

        public var errorDescription: String? {
            switch self {
            case .deviceIdentityUnavailable:
                return "This Mac does not provide a stable identity for license activation."
            case .invalidCertificate:
                return "The license certificate is not valid for this Mac."
            }
        }
    }

    /// A one-way identifier derived from macOS's stable host UUID. The raw hardware UUID never
    /// leaves this Mac, and a certificate copied to another Mac fails its device binding.
    public static let deviceID: String? = {
        var hostID: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0,
                              0, 0, 0, 0, 0, 0, 0, 0)
        var timeout = timespec(tv_sec: 5, tv_nsec: 0)
        guard gethostuuid(&hostID, &timeout) == 0 else { return nil }
        let value = UUID(uuid: hostID).uuidString.lowercased()
        let scoped = Data("com.muastudio.fotufilm.device.v1:\(value)".utf8)
        return SHA256.hash(data: scoped).map { String(format: "%02x", $0) }.joined()
    }()

    public static var certificate: String? {
        guard let data = try? Data(contentsOf: certificateStorageURL),
              let value = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func status(
        publicKeyBase64: String = productionPublicKeyBase64,
        now: Date = Date()
    ) -> Status {
#if FOTUFILM_SOURCE_BUILD
        return Status(isActive: true, expiresAt: nil)
#else
#if FOTUFILM_LICENSE_TESTING
        if ProcessInfo.processInfo.environment["FOTUFILM_LICENSE_TEST_BYPASS"] == "1" {
            return Status(isActive: true, expiresAt: .distantFuture)
        }
#endif
        statusCache.lock.lock()
        defer { statusCache.lock.unlock() }
        if statusCache.publicKey == publicKeyBase64,
           let checkedAt = statusCache.checkedAt,
           now.timeIntervalSince(checkedAt) < 5,
           let cached = statusCache.status {
            if let expiry = cached.expiresAt, expiry <= now {
                return Status(isActive: false, expiresAt: expiry)
            }
            return cached
        }
        let current = status(certificate: certificate,
                             publicKeyBase64: publicKeyBase64, now: now)
        statusCache.publicKey = publicKeyBase64
        statusCache.checkedAt = now
        statusCache.status = current
        return current
#endif
    }

    public static func status(
        certificate: String?,
        publicKeyBase64: String = productionPublicKeyBase64,
        now: Date = Date()
    ) -> Status {
        guard let certificate, let deviceID,
              let payload = verify(certificate: certificate,
                                   publicKeyBase64: publicKeyBase64),
              payload.product == productID,
              payload.deviceId == deviceID else {
            return Status(isActive: false, expiresAt: nil)
        }
        return Status(isActive: payload.expiresAt > now, expiresAt: payload.expiresAt)
    }

    public static func verify(
        certificate: String,
        publicKeyBase64: String = productionPublicKeyBase64
    ) -> Payload? {
        let parts = certificate.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let payloadData = Data(base64URL: String(parts[0])),
              let signature = Data(base64URL: String(parts[1])),
              let keyData = Data(base64Encoded: publicKeyBase64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              publicKey.isValidSignature(signature, for: Data(parts[0].utf8)) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = fractional.date(from: value) ?? plain.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Invalid ISO 8601 date")
        }
        guard let payload = try? decoder.decode(Payload.self, from: payloadData),
              payload.version == 1 else { return nil }
        return payload
    }

    public static func install(certificate: String,
                               publicKeyBase64: String = productionPublicKeyBase64) throws {
        guard let deviceID else { throw StorageError.deviceIdentityUnavailable }
        guard let payload = verify(certificate: certificate,
                                   publicKeyBase64: publicKeyBase64),
              payload.product == productID,
              payload.deviceId == deviceID else {
            throw StorageError.invalidCertificate
        }
        let manager = FileManager.default
        try manager.createDirectory(
            at: certificateDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try Data(certificate.utf8).write(to: certificateStorageURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600],
                                  ofItemAtPath: certificateStorageURL.path)
        invalidateCache()
    }

    public static func removeCertificate() {
        try? FileManager.default.removeItem(at: certificateStorageURL)
        invalidateCache()
    }

    private final class StatusCache: @unchecked Sendable {
        let lock = NSLock()
        var publicKey: String?
        var checkedAt: Date?
        var status: Status?
    }

    private static let statusCache = StatusCache()

    private static func invalidateCache() {
        statusCache.lock.lock()
        statusCache.publicKey = nil
        statusCache.checkedAt = nil
        statusCache.status = nil
        statusCache.lock.unlock()
    }

    /// FxPlug runs in an extension container. Foundation's user-domain lookup can therefore point
    /// at the container while the app points at the login user's Library, making two callers of
    /// this module read two different files. The passwd database is the non-containerized account
    /// home, so the app, Resolve, and Final Cut all resolve the same certificate without a Keychain
    /// access group or another sign-in prompt.
    static var certificateStorageURL: URL {
        certificateURL(homeDirectory: loginHomeDirectory)
    }

    static func certificateURL(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("MUAStudio", isDirectory: true)
            .appendingPathComponent("Fotufilm", isDirectory: true)
            .appendingPathComponent("activation.cert", isDirectory: false)
    }

    private static var certificateDirectory: URL {
        certificateStorageURL.deletingLastPathComponent()
    }

    private static var loginHomeDirectory: URL {
        let fallback = FileManager.default.homeDirectoryForCurrentUser
        let suggested = sysconf(_SC_GETPW_R_SIZE_MAX)
        let capacity = suggested > 0 ? Int(suggested) : 16_384
        var buffer = [CChar](repeating: 0, count: capacity)
        return buffer.withUnsafeMutableBufferPointer { storage in
            var entry = passwd()
            var result: UnsafeMutablePointer<passwd>?
            guard let baseAddress = storage.baseAddress,
                  getpwuid_r(getuid(), &entry, baseAddress, storage.count, &result) == 0,
                  result != nil,
                  let path = entry.pw_dir else { return fallback }
            return URL(fileURLWithFileSystemRepresentation: path,
                       isDirectory: true, relativeTo: nil)
        }
    }
}

private extension Data {
    init?(base64URL value: String) {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
#endif
