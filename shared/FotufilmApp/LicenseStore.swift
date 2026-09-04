#if os(macOS)
import Foundation

/// The direct-download Mac app's local license state.
///
/// Licensing is the only network conversation. The server signs a certificate containing this
/// Mac's one-way device identifier and the license expiry. `FotufilmLicense` owns the one shared
/// certificate location used by this app, Resolve, and Final Cut. No website account or password
/// enters the app, and the license key itself is never stored.
enum LicenseStore {
    struct Status {
        let isActive: Bool
        let expiresAt: Date?
    }

    enum ActivationError: LocalizedError {
        case notConfigured
        case invalidServerResponse
        case refused(String)
        case invalidCertificate
        case deviceIdentityUnavailable

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "This build does not contain the Fotufilm license-server configuration."
            case .invalidServerResponse:
                return "The license server returned an unreadable response."
            case .refused(let message):
                return message
            case .invalidCertificate:
                return "The license server returned a certificate this copy of Fotufilm cannot verify."
            case .deviceIdentityUnavailable:
                return "This Mac does not provide a stable identity for license activation."
            }
        }
    }

    static var isActive: Bool { status.isActive }

    static var status: Status {
#if FOTUFILM_SOURCE_BUILD
        return Status(isActive: true, expiresAt: nil)
#else
        guard let publicKeyBase64 else {
            return Status(isActive: false, expiresAt: nil)
        }
        let sharedStatus = FotufilmLicense.status(publicKeyBase64: publicKeyBase64)
        return Status(isActive: sharedStatus.isActive,
                      expiresAt: sharedStatus.expiresAt)
#endif
    }

    static func activate(key: String) async throws -> Date {
        guard let endpoint = Bundle.main.object(
            forInfoDictionaryKey: "FotufilmLicenseServerURL") as? String,
              let url = URL(string: endpoint),
              let publicKeyBase64 else {
            throw ActivationError.notConfigured
        }
        guard let deviceID = FotufilmLicense.deviceID else {
            throw ActivationError.deviceIdentityUnavailable
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.httpBody = try JSONEncoder().encode(
            ActivationRequest(licenseKey: key,
                              deviceId: deviceID,
                              deviceName: Host.current().localizedName ?? "Mac"))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ActivationError.invalidServerResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let failure = try? JSONDecoder().decode(ServerFailure.self, from: data)
            throw ActivationError.refused(
                failure?.message ?? "The license server refused this key.")
        }
        guard let activation = try? JSONDecoder().decode(
            ActivationResponse.self, from: data),
              let payload = FotufilmLicense.verify(
                certificate: activation.certificate,
                publicKeyBase64: publicKeyBase64),
              payload.deviceId == deviceID,
              payload.product == FotufilmLicense.productID,
              payload.expiresAt > Date() else {
            throw ActivationError.invalidCertificate
        }

        try FotufilmLicense.install(certificate: activation.certificate,
                                    publicKeyBase64: publicKeyBase64)
        NotificationCenter.default.post(name: .proAccessChanged, object: nil)
        return payload.expiresAt
    }

    /// Removes the local certificate after the licensing server reports that this installation
    /// was revoked. Network failures leave the existing offline certificate untouched.
    static func refreshActivationStatus() async -> Bool {
#if FOTUFILM_SOURCE_BUILD
        return false
#else
        guard let certificate = FotufilmLicense.certificate,
              let publicKeyBase64,
              let payload = FotufilmLicense.verify(
                certificate: certificate, publicKeyBase64: publicKeyBase64),
              let licenseId = payload.licenseId,
              let deviceID = FotufilmLicense.deviceID,
              let activationEndpoint = Bundle.main.object(
                forInfoDictionaryKey: "FotufilmLicenseServerURL") as? String,
              let activationURL = URL(string: activationEndpoint) else {
            return false
        }

        let validationURL = activationURL.deletingLastPathComponent()
            .appendingPathComponent("validate")
        var request = URLRequest(url: validationURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 12
        request.httpBody = try? JSONEncoder().encode(
            ValidationRequest(licenseId: licenseId, deviceId: deviceID))

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let validation = try? JSONDecoder().decode(ValidationResponse.self, from: data),
              !validation.active else {
            return false
        }
        FotufilmLicense.removeCertificate()
        return true
#endif
    }

    static var purchaseURL: URL? {
        guard let value = Bundle.main.object(
            forInfoDictionaryKey: "FotufilmLicensePurchaseURL") as? String else { return nil }
        return URL(string: value)
    }

    private struct ActivationRequest: Encodable {
        let licenseKey: String
        let deviceId: String
        let deviceName: String
    }

    private struct ActivationResponse: Decodable {
        let certificate: String
    }

    private struct ValidationRequest: Encodable {
        let licenseId: String
        let deviceId: String
    }

    private struct ValidationResponse: Decodable {
        let active: Bool
    }

    private struct ServerFailure: Decodable {
        let message: String
    }

    private static var publicKeyBase64: String? {
        Bundle.main.object(forInfoDictionaryKey: "FotufilmLicensePublicKey") as? String
    }

}
#endif
