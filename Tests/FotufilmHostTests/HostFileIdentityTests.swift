import XCTest
@testable import FotufilmHost

final class HostFileIdentityTests: XCTestCase {
    private func temporaryFile(_ name: String, _ text: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fotufilm-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return url
    }

    /// The same forms the editor gives a file it was handed (web/src/saved-edits.js).
    func testStillsAreKnownByContentsAndMoviesByNameSizeAndDate() throws {
        let still = try temporaryFile("a.jpg", "abc")
        let copy = try temporaryFile("renamed.jpg", "abc")
        let date = Date(timeIntervalSince1970: 1_700_000_000.1234)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: still.path)

        #if canImport(CryptoKit)
        let digest = CryptoKitFileDigest()
        let expected = "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        XCTAssertEqual(HostFileIdentity.identity(of: still, isMovie: false, digest: digest), expected)
        XCTAssertEqual(HostFileIdentity.identity(of: copy, isMovie: false, digest: digest), expected)
        #endif

        let modified = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: still.path)[.modificationDate] as? Date)
        let milliseconds = Int((modified.timeIntervalSince1970 * 1000).rounded(.down))
        XCTAssertEqual(HostFileIdentity.identity(of: still, isMovie: true),
                       "file:a.jpg|3|\(milliseconds)")
        // A platform without a digest knows stills the same way.
        XCTAssertEqual(HostFileIdentity.identity(of: still, isMovie: false, digest: nil),
                       "file:a.jpg|3|\(milliseconds)")
        XCTAssertNil(HostFileIdentity.identity(of: still.appendingPathExtension("gone"),
                                               isMovie: false))
    }
}
