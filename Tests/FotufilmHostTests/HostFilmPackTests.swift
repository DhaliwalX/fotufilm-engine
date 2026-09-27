import XCTest
import FotufilmCore
@testable import FotufilmHost

/// Import Film Pack as the Mac app does it, against a library in a temporary directory and packs
/// sealed here under a key only this test registers.
final class HostFilmPackTests: XCTestCase {
    private static let keyID: UInt16 = 0xF17E
    private static let key: FilmPackKey = {
        let key = FilmPackKey.random()
        FilmPackKeyring.shared.register(key, kind: .community, id: keyID)
        FilmPackKeyring.shared.register(key, kind: .local, id: keyID)
        return key
    }()

    private var directory: URL!
    private var engine: HostEngine!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fotufilm-packs-" + UUID().uuidString, isDirectory: true)
        do { engine = try HostEngine() } catch { throw XCTSkip("\(error)") }
        engine.filmPacks = HostFilmPackLibrary(directory: directory, appVersion: "1.10",
                                               addedNote: "Also in the plugins.")
        engine.service.filmsChanged()
    }

    override func tearDown() {
        engine?.filmPacks = nil
        engine?.service.filmsChanged()
        try? FileManager.default.removeItem(at: directory)
    }

    /// A one-film pack made from a shipped film's public definition.
    private func pack(_ packID: String = "test-pack", kind: FilmPackKind = .community,
                      minimum: String? = nil) throws -> Data {
        var film = try XCTUnwrap(FilmStock.presetDefinitions["gold200"])
        film.id = "sample"
        film.name = "Sample Gold"
        let manifest = FilmPackManifest(packID: packID, name: "Test Pack", version: "1.0",
                                        minimumMacAppVersion: minimum, stocks: [film])
        return try FilmPackContainer.seal(manifest, kind: kind, keyID: Self.keyID, key: Self.key)
    }

    private func call(_ method: String, _ params: [String: Any] = [:],
                      payload: Data? = nil) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: params)
        let answer = try payload.map { bytes in
            try bytes.withUnsafeBytes { try engine.service.call(method, params: data, payload: $0) }
        } ?? engine.service.call(method, params: data, payload: nil)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: answer.json) as? [String: Any])
    }

    func testImportedPackJoinsTheFilmsAndLeavesWithRemoval() throws {
        XCTAssertEqual((try call("filmPacks")["packs"] as? [Any])?.count, 0)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".fotufilmpack")
        try pack().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let added = try call("importFilmPack", ["path": file.path])
        XCTAssertEqual(added["added"] as? Bool, true)
        XCTAssertEqual(added["title"] as? String, "Pack added")
        XCTAssertEqual(added["message"] as? String,
                       "Test Pack v1.0 — Sample Gold\n\nAlso in the plugins.")
        XCTAssertTrue(engine.stockIDs.contains("test-pack.sample"))
        let prepared = try call("prepare")
        XCTAssertTrue((prepared["stocks"] as? [String])?.contains("test-pack.sample") == true)
        XCTAssertTrue((prepared["catalogue"] as? [[String: Any]])?
            .contains { $0["id"] as? String == "test-pack.sample" } == true)
        let packs = try XCTUnwrap(try call("filmPacks")["packs"] as? [[String: Any]])
        XCTAssertEqual(packs.first?["packID"] as? String, "test-pack")
        XCTAssertEqual(packs.first?["films"] as? [String], ["Sample Gold"])
        XCTAssertEqual(packs.first?["version"] as? String, "1.0")

        // The new film develops without restarting the engine.
        let handle = engine.service.register(HostImage(
            rgba: [Float](repeating: 0.18, count: 32 * 24 * 4), width: 32, height: 24,
            contentHeadroom: 1))
        let rendered = try call("render", [
            "handle": handle, "maxEdge": 32, "previewQuality": "draft",
            "edit": ["stock": "test-pack.sample", "params": ["ev": 0]],
            "profileRequest": ["controls": [String: Any]()],
        ])
        XCTAssertEqual(rendered["width"] as? Int, 32)

        // The same pack again, as bytes from the page, replaces it.
        let updated = try call("importFilmPack", ["name": "pack.fotufilmpack"], payload: pack())
        XCTAssertEqual(updated["title"] as? String, "Pack updated")

        let removed = try call("removeFilmPack", ["packID": "test-pack"])
        XCTAssertEqual((removed["packs"] as? [Any])?.count, 0)
        XCTAssertFalse(engine.stockIDs.contains("test-pack.sample"))
        XCTAssertThrowsError(try call("removeFilmPack", ["packID": "test-pack"]))
    }

    func testRefusalsUseTheMacAppsWords() throws {
        let local = try call("importFilmPack", [:], payload: pack(kind: .local))
        XCTAssertEqual(local["added"] as? Bool, false)
        XCTAssertEqual(local["title"] as? String, "Pack not added")
        XCTAssertEqual(local["message"] as? String,
                       "That pack was made for a single device and cannot be moved.")

        let own = try call("importFilmPack", [:], payload: pack(FilmPackLibrary.ownFilmsPackID))
        XCTAssertEqual(own["message"] as? String, "That pack collides with your own films.")

        let newer = try call("importFilmPack", [:], payload: pack(minimum: "99.0"))
        XCTAssertEqual(newer["update"] as? Bool, true)
        XCTAssertEqual(newer["title"] as? String, "Update Fotufilm to use this pack")
        XCTAssertEqual(newer["message"] as? String,
                       FilmPackRelease.Failure.requiresMacApp("99.0").description)

        let damaged = try call("importFilmPack", [:], payload: Data("not a pack".utf8))
        XCTAssertEqual(damaged["title"] as? String, "Pack not added")
        XCTAssertEqual((try call("filmPacks")["packs"] as? [Any])?.count, 0)
        XCTAssertThrowsError(try call("importFilmPack"))
    }

    /// A pack the Mac app added to the shared store while this host ran joins on the next list.
    func testListingPicksUpPacksAnotherAppAdded() throws {
        XCTAssertEqual(try call("filmPacks")["changed"] as? Bool, false)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try pack("from-mac").write(to: directory.appendingPathComponent("from-mac.fotufilmpack"))
        XCTAssertEqual(try call("filmPacks")["changed"] as? Bool, true)
        XCTAssertTrue(engine.stockIDs.contains("from-mac.sample"))
        XCTAssertEqual(try call("filmPacks")["changed"] as? Bool, false)
    }

    func testCapabilityFollowsThePlatform() {
        XCTAssertEqual(HostPlatform.current.capabilities["filmPacks"] as? Bool,
                       HostPlatform.current.filmPacks != nil)
        XCTAssertEqual(HostPlatform().capabilities["filmPacks"] as? Bool, false)
    }
}
