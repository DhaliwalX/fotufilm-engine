import Foundation

/// One release of the Mac app, as published to the update feed.
///
/// The feed is a single JSON document per release, uploaded beside the installer package it
/// points at. It carries nothing beyond what checking for an update needs: which release is
/// current, where its package is, and the digest that pins the download to the package this
/// release was cut from. The feed URL itself is build configuration (Info.plist), like the
/// license server's; the digest is what makes the payload trustworthy once it arrives.
public struct UpdateManifest: Codable, Sendable, Equatable {
    /// The marketing version, `CFBundleShortVersionString` — "1.7".
    public let version: String
    /// The build number, `CFBundleVersion`. It moves on every build, including rebuilds that
    /// keep the marketing version.
    public let build: String
    /// The installer package. The package is the update vehicle rather than the bare app: one
    /// installer run also refreshes the Resolve and Final Cut Pro plug-ins, which otherwise
    /// stay behind until `PluginInstallation` notices.
    public let downloadURL: String
    /// Lowercase-or-uppercase hex SHA-256 of the package above. Verified before the Installer
    /// is handed the file.
    public let sha256: String
    /// Optional page describing what the release changes, opened in the browser.
    public let releaseNotesURL: String?

    public init(version: String, build: String, downloadURL: String,
                sha256: String, releaseNotesURL: String? = nil) {
        self.version = version
        self.build = build
        self.downloadURL = downloadURL
        self.sha256 = sha256
        self.releaseNotesURL = releaseNotesURL
    }
}

public extension UpdateManifest {
    enum ValidationError: Error, Equatable {
        case missingVersion
        case missingBuild
        case unreadableDownloadURL
        case malformedDigest
    }

    /// A feed entry that fails any of these names a package the app must not open. The whole
    /// manifest is refused rather than the offending field: a truncated feed is not half an
    /// update.
    func validate() throws {
        guard !version.isEmpty else { throw ValidationError.missingVersion }
        guard !build.isEmpty else { throw ValidationError.missingBuild }
        guard let url = URL(string: downloadURL),
              url.scheme?.isEmpty == false else {
            throw ValidationError.unreadableDownloadURL
        }
        guard sha256.count == 64, sha256.allSatisfy(\.isHexDigit) else {
            throw ValidationError.malformedDigest
        }
    }

    var download: URL? { URL(string: downloadURL) }

    var releaseNotes: URL? { releaseNotesURL.flatMap(URL.init(string:)) }

    var normalizedSHA256: String { sha256.lowercased() }

    /// Whether this manifest describes a release newer than the one identified here.
    ///
    /// The marketing version decides, compared component by component and numerically where
    /// both sides carry numbers ("1.10" > "1.9"), so a version that merely looks bigger does
    /// not win. A missing component is zero: 1.5 and 1.5.0 are the same release. Inside one
    /// marketing version the build number decides, numerically when both parse. Components
    /// that do not parse fall back to plain text comparison, and equal text is never an
    /// update. A lower version never counts as newer, so a stale feed cannot walk anyone
    /// backwards.
    func isNewer(thanVersion currentVersion: String, build currentBuild: String) -> Bool {
        let order = Self.compareVersions(version, currentVersion)
        if order != .orderedSame { return order == .orderedDescending }
        return Self.compareVersions(build, currentBuild) == .orderedDescending
    }

    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".").map(String.init)
        let right = rhs.split(separator: ".").map(String.init)
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : "0"
            let r = index < right.count ? right[index] : "0"
            switch compareComponents(l, r) {
            case .orderedSame: continue
            case let order: return order
            }
        }
        return .orderedSame
    }

    private static func compareComponents(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if let l = Int(lhs), let r = Int(rhs) {
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
            return .orderedSame
        }
        // A text component ("5b") and a numeric one are different kinds of thing; only text
        // equality resolves the pair, and otherwise the lexicographic order is the honest
        // answer. Plain comparison rather than a locale-aware one: a version string has one
        // meaning everywhere.
        if lhs.caseInsensitiveCompare(rhs) == .orderedSame { return .orderedSame }
        return lhs.compare(rhs)
    }
}
