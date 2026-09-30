#if canImport(AppKit)
import AppKit

/// The Mac's release channel: the bundle names its feed (`FotufilmUpdateFeedURL`), its release
/// list (`FotufilmReleaseListURL`) and version, and the Installer or the browser opens what an
/// update hands over.
struct BundleUpdateChannel: HostUpdateChannel {
    /// `FOTUFILM_UPDATE_FEED` names another feed: a test seam for checking a release's feed,
    /// or a local file feed, before it is published.
    var feedURL: URL? {
        (ProcessInfo.processInfo.environment["FOTUFILM_UPDATE_FEED"]
            ?? Bundle.main.object(forInfoDictionaryKey: "FotufilmUpdateFeedURL") as? String)
            .flatMap(URL.init(string:))
    }
    /// `FOTUFILM_RELEASE_LIST` names another list, as `FOTUFILM_UPDATE_FEED` does the feed.
    var releaseListURL: URL? {
        (ProcessInfo.processInfo.environment["FOTUFILM_RELEASE_LIST"]
            ?? Bundle.main.object(forInfoDictionaryKey: "FotufilmReleaseListURL") as? String)
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
