#if canImport(AppKit)
import AppKit

/// The Mac's release channel: the bundle names its feed (`FotufilmUpdateFeedURL`) and version,
/// and the Installer or the browser opens what an update hands over.
struct BundleUpdateChannel: HostUpdateChannel {
    /// `FOTUFILM_UPDATE_FEED` names another feed: a test seam for checking a release's feed,
    /// or a local file feed, before it is published.
    var feedURL: URL? {
        (ProcessInfo.processInfo.environment["FOTUFILM_UPDATE_FEED"]
            ?? Bundle.main.object(forInfoDictionaryKey: "FotufilmUpdateFeedURL") as? String)
            .flatMap(URL.init(string:))
    }
    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
    var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    func open(_ url: URL) throws {
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
    }
}
#endif
