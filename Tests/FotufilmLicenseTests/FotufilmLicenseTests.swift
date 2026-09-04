#if os(macOS)
import CryptoKit
import Foundation
import XCTest
@testable import FotufilmLicense

final class FotufilmLicenseTests: XCTestCase {
    private struct TestPayload: Encodable {
        let version: Int
        let licenseId: String
        let activationId: String
        let product: String
        let deviceId: String
        let issuedAt: Date
        let expiresAt: Date
    }

    func testValidCertificateActivatesThisMac() throws {
        let deviceID = try XCTUnwrap(FotufilmLicense.deviceID)
        let signed = try certificate(deviceID: deviceID,
                                     expiresAt: Date().addingTimeInterval(3600))

        let payload = try XCTUnwrap(FotufilmLicense.verify(
            certificate: signed.value, publicKeyBase64: signed.publicKey))
        XCTAssertEqual(payload.product, FotufilmLicense.productID)
        XCTAssertEqual(payload.deviceId, deviceID)
        XCTAssertTrue(FotufilmLicense.status(
            certificate: signed.value, publicKeyBase64: signed.publicKey).isActive)
    }

    func testCertificateLocationIsSharedOutsideHostContainers() {
        let home = URL(fileURLWithPath: "/Users/license-test", isDirectory: true)
        XCTAssertEqual(
            FotufilmLicense.certificateURL(homeDirectory: home).path,
            "/Users/license-test/Library/Application Support/MUAStudio/Fotufilm/activation.cert")
    }

    func testCertificateCannotBeUsedOnAnotherMac() throws {
        let signed = try certificate(deviceID: UUID().uuidString,
                                     expiresAt: Date().addingTimeInterval(3600))
        let status = FotufilmLicense.status(
            certificate: signed.value, publicKeyBase64: signed.publicKey)
        XCTAssertFalse(status.isActive)
        XCTAssertNil(status.expiresAt)
    }

    func testExpiredCertificateStaysInactive() throws {
        let deviceID = try XCTUnwrap(FotufilmLicense.deviceID)
        let expiry = Date().addingTimeInterval(-1)
        let signed = try certificate(deviceID: deviceID, expiresAt: expiry)
        let status = FotufilmLicense.status(
            certificate: signed.value, publicKeyBase64: signed.publicKey)
        XCTAssertFalse(status.isActive)
        XCTAssertEqual(try XCTUnwrap(status.expiresAt).timeIntervalSince1970,
                       expiry.timeIntervalSince1970, accuracy: 1)
    }

    func testWrongProductAndTamperedSignatureAreRejected() throws {
        let deviceID = try XCTUnwrap(FotufilmLicense.deviceID)
        let wrongProduct = try certificate(
            deviceID: deviceID, expiresAt: Date().addingTimeInterval(3600),
            product: "another-product")
        XCTAssertFalse(FotufilmLicense.status(
            certificate: wrongProduct.value,
            publicKeyBase64: wrongProduct.publicKey).isActive)

        let valid = try certificate(deviceID: deviceID,
                                    expiresAt: Date().addingTimeInterval(3600))
        var parts = valid.value.split(separator: ".").map(String.init)
        var signature = try XCTUnwrap(Data(base64URL: parts[1]))
        signature[signature.startIndex] ^= 0x01
        parts[1] = signature.base64URL
        XCTAssertNil(FotufilmLicense.verify(
            certificate: parts.joined(separator: "."),
            publicKeyBase64: valid.publicKey))
    }

    private func certificate(
        deviceID: String,
        expiresAt: Date,
        product: String = FotufilmLicense.productID
    ) throws -> (value: String, publicKey: String) {
        let key = Curve25519.Signing.PrivateKey()
        let payload = TestPayload(
            version: 1, licenseId: "license_test", activationId: "activation_test",
            product: product, deviceId: deviceID,
            issuedAt: Date().addingTimeInterval(-60), expiresAt: expiresAt)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encodedPayload = try encoder.encode(payload).base64URL
        let signature = try key.signature(for: Data(encodedPayload.utf8)).base64URL
        return ("\(encodedPayload).\(signature)",
                key.publicKey.rawRepresentation.base64EncodedString())
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL value: String) {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
#endif
