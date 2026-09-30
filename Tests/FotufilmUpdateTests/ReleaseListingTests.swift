import Foundation
import XCTest
@testable import FotufilmUpdate

final class ReleaseListingTests: XCTestCase {
    private let feed = "Fotufilm-macOS-update.json"

    private func release(_ tag: String, published: String?, draft: Bool = false,
                         prerelease: Bool = false, assets: [String]) -> [String: Any] {
        [
            "tag_name": tag, "draft": draft, "prerelease": prerelease,
            "published_at": published ?? NSNull(),
            "assets": assets.map {
                ["name": $0, "browser_download_url": "https://example.com/\(tag)/\($0)"]
            },
        ]
    }

    private func newest(_ releases: [[String: Any]]) throws -> URL? {
        try ReleaseListing.newestFeed(
            named: feed, in: JSONSerialization.data(withJSONObject: releases))
    }

    func testTheNewestPublishedFeedWinsWhetherPreReleaseOrNot() throws {
        let stable = release("v1.10", published: "2026-09-27T12:49:59Z", assets: [feed])
        let beta = release("v1.11-beta", published: "2026-09-28T21:18:09Z", prerelease: true,
                           assets: [feed, "Fotufilm-macOS.pkg"])
        XCTAssertEqual(try newest([stable, beta])?.absoluteString,
                       "https://example.com/v1.11-beta/\(feed)")
        let later = release("v1.11", published: "2026-09-30T08:00:00Z", assets: [feed])
        XCTAssertEqual(try newest([beta, later, stable])?.absoluteString,
                       "https://example.com/v1.11/\(feed)")
    }

    func testReleasesWithoutTheFeedAndDraftsAreSkipped() throws {
        let stable = release("v1.10", published: "2026-09-27T12:49:59Z", assets: [feed])
        let kernels = release("aot-device-1", published: "2026-09-29T10:00:00Z",
                              assets: ["kernels.tar.gz"])
        let draft = release("v1.12", published: nil, draft: true, assets: [feed])
        XCTAssertEqual(try newest([draft, kernels, stable])?.absoluteString,
                       "https://example.com/v1.10/\(feed)")
        XCTAssertNil(try newest([kernels]))
    }

    func testRefusesSomethingThatIsNotAReleaseList() {
        XCTAssertThrowsError(try ReleaseListing.newestFeed(named: feed, in: Data("{}".utf8)))
    }
}
