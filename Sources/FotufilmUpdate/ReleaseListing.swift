import Foundation

/// The releases a host has published, pre-releases among them, as GitHub's releases API lists
/// them. A pre-release is never the "latest" release, so the feed at `releases/latest/download`
/// cannot offer one; a copy that takes pre-releases reads the newest release's feed from here.
public enum ReleaseListing {
    private struct Release: Decodable {
        let draft: Bool
        let publishedAt: Date?
        let assets: [Asset]
    }

    private struct Asset: Decodable {
        let name: String
        let browserDownloadUrl: String
    }

    /// Where the most recently published release keeps its feed document named `feed`, or nil
    /// when no release carries one. Drafts are not published and never count.
    public static func newestFeed(named feed: String, in data: Data) throws -> URL? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Release].self, from: data)
            .compactMap { release -> (Date, String)? in
                guard !release.draft, let published = release.publishedAt,
                      let asset = release.assets.first(where: { $0.name == feed })
                else { return nil }
                return (published, asset.browserDownloadUrl)
            }
            .max { $0.0 < $1.0 }
            .flatMap { URL(string: $0.1) }
    }
}
