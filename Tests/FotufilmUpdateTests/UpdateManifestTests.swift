import Foundation
import XCTest
@testable import FotufilmUpdate

final class UpdateManifestTests: XCTestCase {
    private let pkgDigest = String(repeating: "a", count: 64)

    private func manifest(
        version: String = "1.6", build: String = "9",
        downloadURL: String = "https://github.com/DhaliwalX/fotufilm-downloads/releases/latest/download/Fotufilm-macOS.pkg",
        sha256: String? = nil, releaseNotesURL: String? = nil
    ) -> UpdateManifest {
        UpdateManifest(version: version, build: build, downloadURL: downloadURL,
                       sha256: sha256 ?? pkgDigest, releaseNotesURL: releaseNotesURL)
    }

    // MARK: - Decoding

    func testDecodesAFullFeedDocument() throws {
        let json = """
        {
          "version": "1.6",
          "build": "9",
          "downloadURL": "https://github.com/DhaliwalX/fotufilm-downloads/releases/latest/download/Fotufilm-macOS.pkg",
          "sha256": "\(String(repeating: "A", count: 64))",
          "releaseNotesURL": "https://fotufilm.com/blog/1.6.html"
        }
        """
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.version, "1.6")
        XCTAssertEqual(manifest.build, "9")
        XCTAssertEqual(manifest.normalizedSHA256, String(repeating: "a", count: 64))
        XCTAssertEqual(manifest.releaseNotes?.absoluteString,
                       "https://fotufilm.com/blog/1.6.html")
        try manifest.validate()
    }

    func testDecodesWithoutOptionalReleaseNotes() throws {
        let json = """
        {
          "version": "1.6",
          "build": "9",
          "downloadURL": "https://fotufilm.com/Fotufilm-macOS.pkg",
          "sha256": "\(String(repeating: "0", count: 64))"
        }
        """
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: Data(json.utf8))
        XCTAssertNil(manifest.releaseNotes)
        try manifest.validate()
    }

    // MARK: - Validation

    func testRefusesAManifestWithAnEmptyVersion() {
        XCTAssertThrowsError(try manifest(version: "").validate())
    }

    func testRefusesAManifestWithAnEmptyBuild() {
        XCTAssertThrowsError(try manifest(build: "").validate())
    }

    func testRefusesAManifestWhoseDownloadIsNotAnAbsoluteURL() {
        XCTAssertThrowsError(try manifest(downloadURL: "Fotufilm-macOS.pkg").validate())
        XCTAssertThrowsError(try manifest(downloadURL: "").validate())
    }

    func testRefusesAManifestWithADigestThatIsNotSixtyFourHexDigits() {
        XCTAssertThrowsError(try manifest(sha256: String(repeating: "a", count: 63)).validate())
        XCTAssertThrowsError(try manifest(sha256: String(repeating: "g", count: 64)).validate())
    }

    // MARK: - Newer-than comparison

    func testAMarketingVersionAheadIsNewer() {
        XCTAssertTrue(manifest(version: "1.6", build: "2")
            .isNewer(thanVersion: "1.5", build: "99"))
    }

    func testAMarketingVersionBehindIsNeverNewer() {
        XCTAssertFalse(manifest(version: "1.4", build: "99")
            .isNewer(thanVersion: "1.5", build: "8"))
    }

    func testNumericComponentsCompareNumerically() {
        XCTAssertTrue(manifest(version: "1.10", build: "1")
            .isNewer(thanVersion: "1.9", build: "8"))
        XCTAssertFalse(manifest(version: "1.9", build: "99")
            .isNewer(thanVersion: "1.10", build: "1"))
    }

    func testAMissingComponentIsZero() {
        XCTAssertFalse(manifest(version: "1.5", build: "8")
            .isNewer(thanVersion: "1.5.0", build: "8"))
        XCTAssertFalse(manifest(version: "1.5.0", build: "8")
            .isNewer(thanVersion: "1.5", build: "8"))
    }

    func testTheBuildBreaksTiesInsideOneMarketingVersion() {
        XCTAssertTrue(manifest(version: "1.5", build: "9")
            .isNewer(thanVersion: "1.5", build: "8"))
        XCTAssertFalse(manifest(version: "1.5", build: "8")
            .isNewer(thanVersion: "1.5", build: "8"))
        XCTAssertFalse(manifest(version: "1.5", build: "7")
            .isNewer(thanVersion: "1.5", build: "8"))
    }

    func testTextComponentsFallBackToTextComparison() {
        XCTAssertTrue(manifest(version: "1.6b", build: "8")
            .isNewer(thanVersion: "1.6a", build: "8"))
        // Case-insensitive equality is the same version, not an update.
        XCTAssertFalse(manifest(version: "1.6B", build: "8")
            .isNewer(thanVersion: "1.6b", build: "8"))
    }

    func testCompareVersionsIsExportedForTheVerifyVerb() {
        XCTAssertEqual(UpdateManifest.compareVersions("1.10", "1.9"), .orderedDescending)
        XCTAssertEqual(UpdateManifest.compareVersions("1.5", "1.5.0"), .orderedSame)
        XCTAssertEqual(UpdateManifest.compareVersions("1.4", "1.5"), .orderedAscending)
    }
}
