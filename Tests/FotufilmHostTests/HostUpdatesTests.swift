import XCTest
@testable import FotufilmHost

#if canImport(CryptoKit)
/// Check for Updates end to end on a file feed: the check's answers, a verified download handed
/// to the installer, and a tampered one refused.
final class HostUpdatesTests: XCTestCase {
    private final class Channel: HostUpdateChannel {
        var feedURL: URL?
        var releaseListURL: URL?
        var version = "1.10"
        var build = "12"
        var opened: [URL] = []
        func open(_ url: URL) throws { opened.append(url) }
    }

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("fotufilm-updates-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func feed(version: String, build: String, package: Data, digest: String? = nil,
                      named name: String = "feed") throws -> URL {
        let file = folder.appendingPathComponent("\(name).pkg")
        try package.write(to: file)
        let manifest: [String: Any] = [
            "version": version, "build": build, "downloadURL": file.absoluteString,
            "sha256": try digest ?? CryptoKitFileDigest().sha256(of: file),
            "releaseNotesURL": "https://fotufilm.com/releases",
        ]
        let url = folder.appendingPathComponent("\(name).json")
        try JSONSerialization.data(withJSONObject: manifest).write(to: url)
        return url
    }

    private func settle(_ updates: HostUpdates, from states: Set<String>) -> [String: Any] {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let status = updates.status()
            if !states.contains(status["state"] as? String ?? "") { return status }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return updates.status()
    }

    func testCheckSaysWhetherTheFeedIsNewer() throws {
        let channel = Channel()
        let updates = HostUpdates(channel: channel, digest: CryptoKitFileDigest())
        updates.check()
        XCTAssertEqual(settle(updates, from: ["checking"])["message"] as? String,
                       "This build does not contain the Fotufilm update-feed configuration.")

        channel.feedURL = try feed(version: "1.10", build: "12", package: Data("same".utf8))
        updates.check()
        var status = settle(updates, from: ["checking"])
        XCTAssertEqual(status["state"] as? String, "current")
        XCTAssertEqual(status["current"] as? String, "1.10 (build 12)")

        channel.feedURL = try feed(version: "1.11", build: "3", package: Data("newer".utf8))
        updates.check()
        status = settle(updates, from: ["checking"])
        XCTAssertEqual(status["state"] as? String, "available")
        XCTAssertEqual(status["version"] as? String, "1.11")
        XCTAssertEqual(status["release"] as? String, "1.11 (build 3)")
        XCTAssertEqual(status["notes"] as? String, "https://fotufilm.com/releases")

        try Data("{}".utf8).write(to: channel.feedURL!)
        updates.check()
        XCTAssertEqual(settle(updates, from: ["checking"])["message"] as? String,
                       "The update feed returned something this copy of Fotufilm cannot read.")
    }

    func testPreReleasesAreOfferedOnlyToThoseWhoTakeThem() throws {
        let channel = Channel()
        let updates = HostUpdates(channel: channel, digest: CryptoKitFileDigest())
        channel.feedURL = try feed(version: "1.10", build: "12", package: Data("same".utf8))
        // The pre-release's own copy of the feed, beside the stable one.
        let beta = try feed(version: "1.11", build: "1", package: Data("beta".utf8),
                            named: "beta")
        let list: [[String: Any]] = [
            ["draft": false, "prerelease": true, "published_at": "2026-09-28T21:18:09Z",
             "assets": [["name": "feed.json", "browser_download_url": beta.absoluteString]]],
            ["draft": false, "prerelease": false, "published_at": "2026-09-27T12:49:59Z",
             "assets": [["name": "feed.json",
                         "browser_download_url": channel.feedURL!.absoluteString]]],
        ]

        updates.check(prereleases: true)
        XCTAssertEqual(settle(updates, from: ["checking"])["message"] as? String,
                       "This build does not contain the Fotufilm pre-release configuration.")

        channel.releaseListURL = folder.appendingPathComponent("releases.json")
        try JSONSerialization.data(withJSONObject: list).write(to: channel.releaseListURL!)
        updates.check()
        XCTAssertEqual(settle(updates, from: ["checking"])["state"] as? String, "current")
        updates.check(prereleases: true)
        let status = settle(updates, from: ["checking"])
        XCTAssertEqual(status["state"] as? String, "available")
        XCTAssertEqual(status["release"] as? String, "1.11 (build 1)")
        try updates.install()
        XCTAssertEqual(settle(updates, from: ["downloading"])["state"] as? String, "opened")
        XCTAssertEqual(try Data(contentsOf: channel.opened[0]), Data("beta".utf8))
    }

    func testInstallOpensOnlyAVerifiedPackage() throws {
        let channel = Channel()
        let updates = HostUpdates(channel: channel, digest: CryptoKitFileDigest())
        channel.feedURL = try feed(version: "1.11", build: "1", package: Data("package".utf8))
        updates.check()
        _ = settle(updates, from: ["checking"])
        try updates.install()
        XCTAssertEqual(settle(updates, from: ["downloading"])["state"] as? String, "opened")
        XCTAssertEqual(channel.opened.count, 1)
        XCTAssertEqual(try Data(contentsOf: channel.opened[0]), Data("package".utf8))

        channel.feedURL = try feed(version: "1.11", build: "2", package: Data("tampered".utf8),
                                   digest: String(repeating: "0", count: 64))
        updates.check()
        _ = settle(updates, from: ["checking"])
        try updates.install()
        let status = settle(updates, from: ["downloading"])
        XCTAssertEqual(status["state"] as? String, "downloadFailed")
        XCTAssertTrue((status["message"] as? String)?.hasPrefix(
            "The downloaded update does not match the checksum") == true)
        XCTAssertEqual(channel.opened.count, 1)
    }
}
#endif
