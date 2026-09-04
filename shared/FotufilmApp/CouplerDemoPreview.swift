import CoreGraphics
import Foundation

#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmImaging)
import FotufilmImaging
#endif
#if canImport(FotufilmMetal)
import FotufilmMetal
#endif

/// Develops `SpectrumScene` so the Film Model screen can show what its controls do.
///
/// This goes through `HalideMetalFilmRenderer`, which is the engine a photograph goes through, not
/// a drawing of what the engine would do. `FotufilmEngine`'s CPU path is not an option here:
/// `fotufilm_halide_available()` returns 0 in the iOS AOT build, so on a phone that path develops
/// nothing at all.
///
/// Everything except the coupler controls is left at the stock's own calibrated values — no
/// exposure, no grade, no grain. The screen is showing the film model, so anything the user has
/// done to a photograph would only be a confound.
enum CouplerDemoPreview {

    /// Half the size the browser demo ships the same picture at, keeping its proportions. The scene
    /// is laid out in fractions of the frame, so this changes nothing about what it shows;
    /// `SpectrumSceneTests` measures the difference the controls make at exactly this size.
    static let sceneSize = SpectrumScene.previewSize

    /// What a rendered strip is keyed on. Two strips that agree on all of this are the same
    /// picture, so the cache can answer without waking the GPU.
    struct Settings: Hashable {
        var stockID: String
        var gapReach: [Double]
        var selfScale: Double
        var estimatedHalation: Bool

        /// The film as its maker calibrated it: every control back at 1, and the halation shape
        /// wherever this device's default puts it — an untouched switch is not an adjustment.
        var calibrated: Settings {
            Settings(stockID: stockID, gapReach: gapReach.map { _ in 1 }, selfScale: 1,
                     estimatedHalation: AppSettings.defaultEstimatedHalationEnabled)
        }

        var isCalibrated: Bool {
            gapReach.allSatisfy { $0 == 1 } && selfScale == 1
                && estimatedHalation == AppSettings.defaultEstimatedHalationEnabled
        }

        /// What the user's controls currently say, on the film they are looking at. The film is
        /// passed in rather than read: these controls apply to every film, so which one is on
        /// screen is a question about the picture, not about the settings.
        static func current(stockID: String) -> Settings {
            Settings(stockID: stockID,
                     gapReach: [AppSettings.storedCouplerBarrierRedGreen,
                                AppSettings.storedCouplerBarrierGreenBlue],
                     selfScale: AppSettings.storedCouplerSelf,
                     estimatedHalation: AppSettings.storedEstimatedHalationEnabled)
        }
    }

    /// The film the screen opens on: the one new photographs start from, so the picture is of
    /// something the user recognises.
    static var defaultStockID: String { StockPreset.defaultID }

    /// A film the screen can show, and what to call it.
    struct Choice: Identifiable, Hashable {
        let id: String
        let name: String
    }

    /// The films the screen can show, in the order the rest of the app lists them.
    static var choices: [Choice] {
        StockPreset.all.map { Choice(id: $0.id, name: $0.name) }
    }

    /// Whether the controls can do anything at all to this stock. A pack without a
    /// `couplerGeometry` renders from its fixed `couplerInhibition`, which the scales never reach —
    /// so the screen should say so rather than show two identical strips.
    static func respondsToControls(stockID: String) -> Bool {
        stock(for: stockID)?.couplerGeometry != nil
    }

    /// Develops the scene. Cheap enough to call from a slider, but not free — call it off the main
    /// thread and let the cache absorb the repeats.
    static func image(for settings: Settings) -> CGImage? {
        if let hit = cacheLock.withLock({ cache[settings] }) { return hit }
        guard let stock = stock(for: settings.stockID),
              let engine = HalideMetalFilmRenderer.shared else { return nil }

        let width = sceneSize.width, height = sceneSize.height
        let scene = SpectrumScene.make(width: width, height: height)

        var options = FotufilmEngine.Options()
        options.grainScale = 0
        options.useEstimatedHalationProfile = settings.estimatedHalation
        options.couplerGapReachScales = settings.gapReach.map(Float.init)
        options.couplerSelfScale = Float(settings.selfScale)

        var developed = [Float](repeating: 0, count: width * height * 4)
        engine.prepare(stock: stock, options: options,
                       frameWidth: width, frameHeight: height)
        guard engine.processLinearFloat(scene.interleavedRGBA(), into: &developed,
                                        width: width, height: height,
                                        stock: stock, options: options) else { return nil }

        let pixels = UnsafeMutableBufferPointer<UInt16>
            .allocate(capacity: width * height * 4)
        pixels.initialize(repeating: 0)
        developed.withUnsafeBufferPointer { source in
            PrintEncoding.encodeRows(source, rows: 0..<height, width: width,
                                     into: pixels, transfer: .shoulderedSRGB)
        }
        guard let image = PrintEncoding.makeImage(
            takingOwnershipOf: pixels, width: width, height: height,
            colorSpace: displaySpace) else { return nil }

        cacheLock.withLock {
            // The calibrated render is what a held finger has to show without waiting, and it never
            // changes, so it must not be the entry a run of slider drags evicts.
            if cache.count >= cacheLimit {
                let keep = cache.filter { $0.key.isCalibrated }
                cache = keep
            }
            cache[settings] = image
        }
        return image
    }

    private static let displaySpace =
        CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()

    private static func stock(for id: String) -> FilmStock? {
        StockPreset.all.first { $0.id == id }?.stock
    }

    private static let cacheLimit = 48
    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var cache: [Settings: CGImage] = [:]
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
