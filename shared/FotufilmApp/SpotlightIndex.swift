import Foundation

#if canImport(CoreSpotlight)
import CoreSpotlight
#endif

/// The shelf, as the system's search sees it.
enum SpotlightIndex {
    /// Everything the app files, kept under one domain so it can all be withdrawn in a single call
    /// when the shelf is emptied.
    static let domain = "com.muastudio.fotufilm.edits"

    /// The activity type a Spotlight hit continues into.
    static let activityType = "com.muastudio.fotufilm.edit"

    /// Indexes an edit under the user-visible stock name rather than its internal pack ID.
    static func index(id: String, stockName: String, modified: Date,
                      thumbnailURL: URL?) {
        #if canImport(CoreSpotlight)
        let attributes = CSSearchableItemAttributeSet(contentType: .image)
        attributes.title = stockName
        attributes.contentDescription = Self.dateFormatter.string(from: modified)
        attributes.contentModificationDate = modified
        attributes.keywords = [stockName, "Fotufilm", "film"]
        if let thumbnailURL, FileManager.default.fileExists(
            atPath: thumbnailURL.path) {
            attributes.thumbnailURL = thumbnailURL
        }
        let item = CSSearchableItem(uniqueIdentifier: id,
                                    domainIdentifier: domain,
                                    attributeSet: attributes)
        CSSearchableIndex.default().indexSearchableItems([item])
        #endif
    }

    static func remove(id: String) {
        #if canImport(CoreSpotlight)
        CSSearchableIndex.default()
            .deleteSearchableItems(withIdentifiers: [id])
        #endif
    }

    static func removeAll() {
        #if canImport(CoreSpotlight)
        CSSearchableIndex.default()
            .deleteSearchableItems(withDomainIdentifiers: [domain])
        #endif
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
