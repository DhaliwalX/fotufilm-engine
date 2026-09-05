import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif
// The script builds compile the whole app as one module, where these types are already in scope and
// there is no such module to import; the Xcode build takes them from the package.
#if canImport(FotufilmEditModel)
import FotufilmEditModel
#endif

/// Mobile purchase state. Desktop features are always available.
enum ProAccess {
    #if os(iOS)
    /// Open either because it was bought or because this is not a build anyone
    /// can buy from.
    static var isPro: Bool { purchased || isComplimentary }

    /// What the store says this Apple Account owns.
    static var purchased: Bool {
        get { read(&boughtCache, boughtKey) }
        set {
            guard store(newValue, &boughtCache) else { return }
            publish(newValue, boughtKey)
        }
    }

    /// A build that is not the App Store's: TestFlight, a sandbox account, or
    /// one run straight from Xcode. Everything is open in those, because there
    /// is nothing to sell to a tester — they were handed the build.
    ///
    /// Not a security boundary, and not meant as one. A TestFlight build goes
    /// to people who were invited, and anyone holding one has the catalogue.
    /// The line that matters is the App Store build, which reports
    /// `.production` and is the only one that charges.
    static var isComplimentary: Bool {
        get { read(&freeCache, freeKey) }
        set {
            guard store(newValue, &freeCache) else { return }
            publish(newValue, freeKey)
        }
    }

    private static func read(_ cache: inout Bool?, _ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let cache { return cache }
        let stored = UserDefaults.standard.bool(forKey: key)
        cache = stored
        return stored
    }

    private static func store(_ value: Bool, _ cache: inout Bool?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let changed = cache != value
        cache = value
        return changed
    }

    private static func publish(_ value: Bool, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
        NotificationCenter.default.post(name: .proAccessChanged, object: nil)
    }

    private static let lock = NSLock()
    private static let boughtKey = "fotufilm.pro-unlocked"
    private static let freeKey = "fotufilm.pro-complimentary"
    nonisolated(unsafe) private static var boughtCache: Bool?
    nonisolated(unsafe) private static var freeCache: Bool?
    #else
    static let isPro = true
    static let purchased = true
    static let isComplimentary = false
    #endif

    /// Whether this film may be loaded. A film the photographer authored, or was sent, is theirs
    /// whatever the build has been paid for — only the sealed catalogue is the product's to gate.
    static func allowsStock(_ id: String) -> Bool {
        // Nothing is loaded, so there is nothing to sell: "Normal" is the
        // picture the sensor gives, which the camera hands out to everyone —
        // `StockPreset.cameraDefaultID` admits it without asking here, and
        // falls back to it when the chosen film is refused. A padlock on it in
        // the editor's strip is the same build contradicting itself.
        if StockPreset.isNoFilm(id) { return true }
        if ProUnlock.allowsStock(id: id, isPro: isPro) { return true }
        switch FilmStock.origin(of: id) {
        case .community, .local: return true
        case .installed, .vault, nil: return false
        }
    }

    static func allows(_ feature: ProUnlock.Feature) -> Bool {
        ProUnlock.allows(feature, isPro: isPro)
    }
}

extension Notification.Name {
    /// Posted when the purchase state changes, so standing UI can let the locks fall away.
    static let proAccessChanged = Notification.Name("fotufilm.pro-access-changed")
}
