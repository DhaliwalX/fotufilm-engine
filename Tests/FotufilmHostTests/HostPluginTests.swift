#if os(macOS)
import XCTest
import CFotufilmHost
@testable import FotufilmHost
import FotufilmPlugins

/// The plug-ins dialog's calls, installing into a temporary directory: stand-in bundles carry the
/// identifiers and versions the real ones do, and nothing is registered with macOS.
final class HostPluginTests: XCTestCase {
    private var root: URL!
    private var revealed: [URL] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fotufilm-plugins-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeBundle(_ url: URL, identifier: String, version: String) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleVersion": version]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
    }

    /// An app's resources carrying both plug-ins at `version`.
    private func makeResources(version: String) throws -> URL {
        let resources = root.appendingPathComponent("App/Contents/Resources", isDirectory: true)
        try writeBundle(resources.appendingPathComponent(OFXPluginInstaller.bundleName),
                        identifier: OFXPluginInstaller.bundleIdentifier, version: version)
        let wrapper = resources.appendingPathComponent(FxPlugInstaller.appName)
        try writeBundle(wrapper, identifier: FxPlugInstaller.bundleIdentifier, version: version)
        let template = wrapper.appendingPathComponent("Contents/Resources/MotionTemplate")
        try FileManager.default.createDirectory(at: template, withIntermediateDirectories: true)
        try Data("""
        <ozml><factory id="C4D9D06C-A2A7-48B4-830B-9AE81B970140" pluginDynamicParams="0"/>\
        <publishSettings></publishSettings></ozml>
        """.utf8).write(to: template.appendingPathComponent("Fotufilm.moef"))
        for image in ["small.png", "large.png"] {
            try Data([0x89]).write(to: template.appendingPathComponent(image))
        }
        return resources
    }

    private func makeService(resources: URL?) throws -> (HostService, () -> Void) {
        var error: UnsafeMutablePointer<CChar>?
        guard let engine = fotufilm_engine_create(&error) else {
            defer { fotufilm_free(error) }
            throw XCTSkip(error.map { String(cString: $0) } ?? "no engine")
        }
        let service = Unmanaged<HostEngine>.fromOpaque(UnsafeRawPointer(engine))
            .takeUnretainedValue().service
        service.plugins = MacPluginInstaller(
            locations: .temporary(root: root, bundled: resources),
            revealer: { [unowned self] in self.revealed.append($0) })
        return (service, { fotufilm_engine_destroy(engine) })
    }

    private func call(_ service: HostService, _ method: String, _ params: String = "{}") throws
        -> Any
    {
        let answer = try service.call(method, params: Data(params.utf8), payload: nil)
        return try JSONSerialization.jsonObject(with: answer.json, options: .fragmentsAllowed)
    }

    private func states(_ list: Any?) -> [String: String] {
        Dictionary(uniqueKeysWithValues: ((list as? [[String: Any]]) ?? []).compactMap {
            guard let id = $0["id"] as? String, let state = $0["state"] as? String else {
                return nil
            }
            return (id, state)
        })
    }

    func testTheMacPlatformOffersBothPlugins() throws {
        let catalogue = try XCTUnwrap(HostPlatform.current.capabilities["plugins"]
            as? [[String: String]])
        XCTAssertEqual(catalogue.map { $0["id"] }, ["resolve", "finalCut"])
        XCTAssertEqual(catalogue.map { $0["name"] }, ["DaVinci Resolve", "Final Cut Pro"])
        XCTAssertEqual(HostPlatform().capabilities["plugins"] as? [[String: String]], [])
    }

    /// Listed, installed, found outdated when another build's is there, reinstalled, revealed.
    func testInstallsListsAndReveals() throws {
        let (service, close) = try makeService(resources: try makeResources(version: "7"))
        defer { close() }

        let before = try XCTUnwrap(call(service, "plugins") as? [[String: Any]])
        XCTAssertEqual(states(before), ["resolve": "notInstalled", "finalCut": "notInstalled"])
        XCTAssertEqual(before.first?["bundledVersion"] as? String, "7")
        XCTAssertNil(before.first?["installedVersion"])
        XCTAssertThrowsError(try call(service, "revealPlugin", #"{"id": "resolve"}"#))

        let resolve = try XCTUnwrap(call(service, "installPlugin", #"{"id": "resolve"}"#)
            as? [String: Any])
        XCTAssertEqual(resolve["message"] as? String,
                       "Restart DaVinci Resolve to load the new plug-in.")
        XCTAssertEqual(states(resolve["plugins"]),
                       ["resolve": "installed", "finalCut": "notInstalled"])
        let ofx = root.appendingPathComponent("Library/OFX/Plugins/Fotufilm.ofx.bundle")
        XCTAssertEqual(PluginVersion.of(ofx), "7")

        // The Final Cut wrapper and its Motion template, which Final Cut lists the effect by.
        let finalCut = try XCTUnwrap(call(service, "installPlugin", #"{"id": "finalCut"}"#)
            as? [String: Any])
        XCTAssertEqual(states(finalCut["plugins"])["finalCut"], "installed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(
            "Movies/Motion Templates.localized/Effects.localized/Fotufilm.localized/"
                + "Fotufilm.localized/Fotufilm.moef").path))

        // A plug-in from another build, newer or older, is this build's to replace.
        try writeBundle(ofx, identifier: OFXPluginInstaller.bundleIdentifier, version: "8")
        let outdated = try XCTUnwrap(call(service, "plugins") as? [[String: Any]])
        XCTAssertEqual(states(outdated)["resolve"], "outdated")
        XCTAssertEqual(outdated.first?["installedVersion"] as? String, "8")
        _ = try call(service, "installPlugin", #"{"id": "resolve"}"#)
        XCTAssertEqual(PluginVersion.of(ofx), "7")
        let staging = try FileManager.default.contentsOfDirectory(
            atPath: ofx.deletingLastPathComponent().path).filter { $0.hasPrefix(".") }
        XCTAssertEqual(staging, [], "no staging directory is left behind")

        _ = try call(service, "revealPlugin", #"{"id": "finalCut"}"#)
        XCTAssertEqual(revealed.map(\.lastPathComponent), [FxPlugInstaller.appName])
        XCTAssertThrowsError(try call(service, "installPlugin", #"{"id": "premiere"}"#))
    }

    /// A build that carries no plug-ins says so and installs nothing.
    func testABuildWithoutPluginsInstallsNothing() throws {
        let (service, close) = try makeService(resources: root.appendingPathComponent("Empty"))
        defer { close() }
        XCTAssertEqual(states(try call(service, "plugins")),
                       ["resolve": "notBundled", "finalCut": "notBundled"])
        XCTAssertThrowsError(try call(service, "installPlugin", #"{"id": "resolve"}"#)) {
            XCTAssertEqual($0.localizedDescription,
                           "This copy of Fotufilm does not contain the DaVinci Resolve plug-in.")
        }
        service.plugins = nil
        XCTAssertThrowsError(try call(service, "plugins"))
    }

    /// The rule both apps install by: any difference from what this build carries.
    func testTheInstallRule() {
        XCTAssertFalse(PluginVersion.needsInstall(bundled: nil, installed: nil))
        XCTAssertFalse(PluginVersion.needsInstall(bundled: nil, installed: "6"))
        XCTAssertTrue(PluginVersion.needsInstall(bundled: "6", installed: nil))
        XCTAssertFalse(PluginVersion.needsInstall(bundled: "6", installed: "6"))
        XCTAssertTrue(PluginVersion.needsInstall(bundled: "7", installed: "6"))
        XCTAssertTrue(PluginVersion.needsInstall(bundled: "6", installed: "7"))
    }
}
#endif
