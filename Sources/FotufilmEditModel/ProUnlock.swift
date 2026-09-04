/// Feature policy for the Fotufilm Pro non-consumable purchase. StoreKit state is resolved by the
/// app layer and passed here as `isPro`.
public enum ProUnlock {
    /// App Store product identifier of the unlock. Registered in App Store
    /// Connect as a non-consumable; mirrored in `ios/Fotufilm.storekit` for
    /// local testing. The price lives in App Store Connect, not in code.
    public static let productID = "com.muastudio.fotufilm.pro"

    /// Built-in stocks available without purchase, one from each film family.
    public static let freeStockIDs: Set<String> = ["gold200", "trix400", "astia100f"]

    /// The surfaces the purchase opens. Still development on a free stock is
    /// never gated; what recurs with calibration work is.
    public enum Feature: CaseIterable, Sendable {
        /// The remaining built-in stocks beyond ``freeStockIDs``.
        case fullCatalogue
        /// Developing video, in the editor and the camera's recorder.
        case videoDevelop
        /// The Lab section: push/pull, expired film, bleach bypass,
        /// reciprocity.
        case labControls
        /// Authoring custom films and importing packs.
        case customStocks
        /// The lens filter deck.
        case lensFilters
        /// RAW capture in the camera.
        case rawCapture
        /// Importing and developing camera raw files.
        case rawImport
    }

    /// Whether a built-in stock can be selected. Custom stocks a user
    /// authored are theirs and are never gated here; authoring them is the
    /// ``Feature/customStocks`` gate instead.
    public static func allowsStock(id: String, isPro: Bool) -> Bool {
        isPro || freeStockIDs.contains(id)
    }

    /// Whether a gated surface is open.
    public static func allows(_ feature: Feature, isPro: Bool) -> Bool {
        isPro
    }

    /// Number of locked built-in films. Custom and imported films are excluded.
    public static func unlockedFilmCount(builtInIDs: some Collection<String>)
        -> Int {
        builtInIDs.filter { !freeStockIDs.contains($0) }.count
    }

    /// Formats a count as a lower bound rounded down to the nearest five. Counts below five remain
    /// exact.
    public static func approximateFilmCount(_ count: Int) -> String {
        guard count >= 5 else { return "\(max(count, 0))" }
        return "\(count - count % 5)+"
    }
}
