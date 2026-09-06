import Foundation
import CoreGraphics
#if canImport(FotufilmImaging)
import FotufilmImaging
#endif

#if canImport(FotufilmCore)
import FotufilmCore
#endif

extension FilmSourceInterpretation {
    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .fullRange: return "Full Range"
        case .standardRange: return "Standard Range"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            return "Preserve the file’s decoded highlight range"
        case .fullRange:
            return "Preserve all decoded highlight range"
        case .standardRange:
            return "Tone-map HDR before film exposure"
        }
    }
}

/// A selectable film stock with UI metadata.
struct StockPreset: Identifiable {
    let id: String
    let name: String
    let subtitle: String
    let stock: FilmStock

    /// Whether the user made this film or was given it.
    let isCustom: Bool

    /// Keyed on the pack generation rather than a `let`: materialising a definition re-normalises
    /// matrices and resamples spectra, too much for every view update, but a custom pack can arrive
    /// while the app runs.
    static var all: [StockPreset] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let generation = FilmStockPack.generation
        if let cached, cachedGeneration == generation { return cached }

        let installed = FilmStock.presetIDs.compactMap { id -> StockPreset? in
            guard let definition = FilmStock.presetDefinitions[id] else {
                return nil
            }
            return StockPreset(
                id: id,
                name: definition.name,
                subtitle: definition.subtitle ?? "",
                stock: definition.stock,
                isCustom: FilmStock.origin(of: id)?.isShareable ?? false
            )
        }

        let ordered = installed.filter { !$0.isCustom && !$0.stock.isMonochrome }
            + installed.filter { !$0.isCustom && $0.stock.isMonochrome }
            + installed.filter { $0.isCustom && !$0.stock.isMonochrome }
            + installed.filter { $0.isCustom && $0.stock.isMonochrome }

        cached = ordered
        cachedGeneration = generation
        return ordered
    }

    private static let cacheLock = NSLock()
    private static var cached: [StockPreset]?
    private static var cachedGeneration = -1

    /// The stock the app would choose for itself, before any pack or setting has a say: the first
    /// film on the wall.
    /// The first film this build may load — the purchase decides how deep into the catalogue
    /// "first" reaches, and a free launch must not start on a film its own picker refuses.
    static var houseDefaultID: String {
        (all.first { ProAccess.allowsStock($0.id) } ?? all.first)?.id ?? ""
    }

    /// What a new photograph starts on: the user's choice in settings, or the house default when
    /// they have not made one — or when the choice names a film this build may not load, as a
    /// refunded purchase leaves behind.
    static var defaultID: String {
        if let stored = AppSettings.storedStockID,
           all.contains(where: { $0.id == stored }),
           ProAccess.allowsStock(stored) {
            return stored
        }
        return houseDefaultID
    }

    /// The camera with nothing loaded in it: the picture the sensor gives, kept the way the phone's
    /// own camera would keep it.
    static let noFilmID = "no-film"

    /// What the viewfinder calls it.
    static let noFilmName = "Normal"

    /// And what it says for itself where there is room to, beside a pack whose films all say
    /// something.
    static let noFilmSubtitle = "The picture as the sensor gives it"

    static func isNoFilm(_ stockID: String) -> Bool { stockID == noFilmID }

    /// HDR is a delivery option for direct-positive film and Normal. Negative film still receives
    /// the complete scene exposure range internally, but its positive output is SDR.
    static func supportsHDRDelivery(for stockID: String) -> Bool {
        if isNoFilm(stockID) { return true }
        guard let stock = preset(id: stockID)?.stock else { return false }
        return PrintPaper.screen.supportsHDRDelivery(for: stock)
    }

    /// The named stock, falling back to the first available one so that a stale id (a pack removed
    /// since the id was persisted, say) still renders something.
    static func preset(id: String) -> StockPreset? {
        guard !isNoFilm(id) else { return nil }
        return all.first { $0.id == id } ?? all.first
    }

    /// The gauge a stock opens on when the user has not asked for one — the gauge the pack says the
    /// film is known on.
    static func nativeFormatID(for stockID: String) -> String {
        FilmFormat.nativeID(forStockID: preset(id: stockID)?.id ?? stockID)
    }

    /// What the camera opens on.
    static var cameraDefaultID: String {
        if let loaded = AppSettings.storedCameraStockID,
           isNoFilm(loaded)
            || (all.contains { $0.id == loaded }
                && ProAccess.allowsStock(loaded)) {
            return loaded
        }
        let id = defaultID
        return all.contains { $0.id == id } ? id : noFilmID
    }
}

/// A film a surface can be loaded with, named for a list to offer it in.
struct FilmChoice: Identifiable, Hashable {
    let id: String
    let name: String
    /// What the film says for itself where a list has room for it; empty where it says nothing.
    var subtitle: String = ""

    /// Every stock the pack carries, in the pack's own order.
    static var stocks: [FilmChoice] {
        #if os(macOS)
        let available = StockPreset.all.filter { ProAccess.allowsStock($0.id) }
        #else
        let available = StockPreset.all
        #endif
        return available.map {
            FilmChoice(id: $0.id, name: $0.name, subtitle: $0.subtitle)
        }
    }

    /// What the camera's wall offers: no film, then the pack.
    static let cameraWall: [FilmChoice] = [noFilm] + stocks

    /// The editor's list, which offers the same choice the camera does: an editor develops a
    /// no-film photograph rather than refusing it.
    static var editorWall: [FilmChoice] { [noFilm] + stocks }

    private static let noFilm = FilmChoice(id: StockPreset.noFilmID,
                                           name: StockPreset.noFilmName,
                                           subtitle: StockPreset.noFilmSubtitle)

    /// What to call a loaded film.
    static func name(for id: String) -> String {
        if StockPreset.isNoFilm(id) { return StockPreset.noFilmName }
        return StockPreset.preset(id: id)?.name ?? ""
    }
}

/// One tile of a strip of developed thumbnails: a choice the photograph can be seen made with,
/// one tile per choice, each developed through the same grade. The film strip's tiles are films
/// on media; the lens strip's are filters.
protocol StripChoice: Identifiable where ID == String {
    /// The grade with what this kind of tile decides taken out of it. A run of prints is keyed on
    /// the rest, so changing the very thing the strip offers does not throw the whole run away.
    static func aside(_ grade: EditState) -> EditState
    /// Makes the grade the one this tile is a picture of.
    func develop(_ grade: inout EditState)
}

/// One tile of the editor's film strip: a film together with the medium it is finished on. The
/// strip offers every finished look that makes sense for the pack, not every emulsion — a Vision
/// negative on its release print and the same negative through a telecine are two different
/// pictures, and the strip is where they are compared side by side. Normal is one tile, because
/// the sensor's picture takes no medium.
struct FilmMediumChoice: Identifiable, Hashable, StripChoice {
    let film: FilmChoice
    /// Nil for Normal, which nothing finishes.
    let paper: PrintPaper?
    /// What the tile calls the medium, when it calls it anything: a print or a transfer is
    /// named, but the display — a film seen directly, a reversal's own positive — is the plain
    /// film, and its tile carries the film's name alone.
    let mediumName: String?

    var id: String { paper.map { "\(film.id)|\($0.rawValue)" } ?? film.id }
    var stockID: String { film.id }
    var name: String { film.name }

    /// Whether this tile is the one an edit stands on. `paper` is the edit's resolved medium.
    func matches(stockID: String, paper: PrintPaper) -> Bool {
        film.id == stockID && (self.paper == nil || self.paper == paper)
    }

    /// Every medium that makes sense for each film, film by film in the wall's order and medium by
    /// medium in `PrintPaper.stripChoices(for:)` order — the one the film was made for first, then
    /// video and display.
    static func combinations(of films: [FilmChoice]) -> [FilmMediumChoice] {
        films.flatMap { film -> [FilmMediumChoice] in
            guard let stock = StockPreset.preset(id: film.id)?.stock else {
                return [FilmMediumChoice(film: film, paper: nil, mediumName: nil)]
            }
            let gauge = FilmFormat.native(forStockID: film.id)
            return PrintPaper.stripChoices(for: stock, gauge: gauge).map {
                FilmMediumChoice(film: film, paper: $0,
                                 mediumName: $0 == .screen ? nil : $0.name)
            }
        }
    }

    /// The pack's films on every medium they reach, for a strip with no filmless path.
    static var stocks: [FilmMediumChoice] { combinations(of: FilmChoice.stocks) }

    /// The editor's strip: Normal, then the pack on every medium.
    static var editorWall: [FilmMediumChoice] { combinations(of: FilmChoice.editorWall) }

    /// Each tile carries its own film and medium, so neither the loaded one nor the chosen one is
    /// part of what a run of them is a picture of.
    static func aside(_ grade: EditState) -> EditState {
        var slice = grade
        slice.stockID = ""
        slice.paper = .editorDefault
        slice.paperFollowsStock = false
        return slice
    }

    /// Developed as if this film were the loaded one and this medium the chosen one — which is
    /// also what picks the tile's gauge while the gauge is still the film's to choose.
    func develop(_ grade: inout EditState) {
        grade.stockID = stockID
        // A tile names its medium outright, so the edit stops following the film's own.
        if let paper {
            grade.paper = paper
            grade.paperFollowsStock = false
        }
    }
}

/// The complete, value-typed description of an edit.
struct EditState: Equatable {
    /// Returns an openable copy, substituting the default stock when current purchase access does
    /// not allow the stored stock. The persisted record remains unchanged.
    func openableByPurchase() -> EditState {
        guard !ProAccess.allowsStock(stockID) else { return self }
        var opened = self
        opened.stockID = StockPreset.defaultID
        return opened
    }

    var stockID = StockPreset.defaultID
    /// The gauge the user asked for, or nil to let the film choose.
    var chosenFormatID: String? = AppSettings.storedFormatID

    /// How this document interprets a still source's dynamic range. Automatic follows metadata;
    /// overrides stay with this edit and never change the app's defaults.
    var sourceInterpretation = FilmSourceInterpretation.automatic

    var exposure = 0.0  // EV
    /// Scene illuminant, in mireds so the slider is perceptually even.
    var temperatureMired = Double(WhiteBalance.kelvinToMired(WhiteBalance.neutralKelvin))
    /// Fixed acquisition illuminant recorded by the camera path. Nil lets an imported RAW use its
    /// own as-shot record; camera captures persist the same emulsion-reference lock used by live
    /// Metal, so the decode reproduces the sensor's neutralization exactly.
    var captureIlluminantKelvin: Double? = nil
    /// The light the film integrates against, when the camera named one. Nil falls back to the
    /// acquisition illuminant, which is what every imported source has.
    var filmLightKelvin: Double? = nil
    /// Green/magenta offset from the locus, in units of 0.0001 Duv.
    var tint = 0.0
    /// Scene-referred tone shaping, -1...1 (0 = untouched).
    var highlights = 0.0
    var shadows = 0.0
    /// Whether the tone controls key to each pixel's *regional* brightness (recovering a sky moves
    /// the sky as one piece) rather than to the pixel itself.
    var localTone = true
    /// Chroma controls: saturation multiplies (1 = untouched), vibrance is a
    /// signed boost weighted toward the least colourful pixels (0 =
    /// untouched).
    var saturation = 1.0
    var vibrance = 0.0

    /// The grade laid over the finished print: three bands of lift, gamma and gain.
    var grade = ColorGrade.neutral
    /// Whether that corrector works on the encoded signal rather than on light. Seeded from the
    /// app-wide setting for the same reason `discGrain` is.
    var encodedGrade = AppSettings.storedGradeSpace == .encoded

    var grain = 1.0
    /// The share of the published granularity's *variance* carried by the coarse mottle field
    /// under the sharp grain, 0...0.9, or nil for whatever the stock's own sheet states.
    var grainMottleShare: Double? = nil
    /// Whether grain develops as resolved discs rather than as the clump field.
    ///
    /// Seeded from the app-wide setting, as the gauge is: an edit begun after Settings › Advanced ›
    /// Film Model was changed starts where that setting stands, and then travels with the
    /// photograph instead of following the device.
    var discGrain = AppSettings.storedDiscGrainEnabled
    var halation = 1.0
    /// How much the halo keeps the light's own colour instead of the film's layered red, 0…1.
    var halationColour = 0.0
    /// A gain on what the base returns at each wavelength, one value per handle of the
    /// catalogue's ladder. Flat at 1 is the film's own return trip.
    var halationSpectrum = EditState.restingHalationSpectrum
    var couplers = 1.0
    /// How far the released inhibitor crosses each interlayer, as a multiple of the stock's own
    /// geometry: index 0 is the red–green scavenger, index 1 the green–blue yellow filter layer.
    /// Seeded from the app-wide barriers, which is where this lived before it moved onto the edit.
    var couplerGapReach = [AppSettings.storedCouplerBarrierRedGreen,
                           AppSettings.storedCouplerBarrierGreenBlue]
    /// The inhibition matrix's diagonal — adjacency within one layer rather than across two.
    var couplerSelf = AppSettings.storedCouplerSelf
    var printCorrection = 0.05
    var seed: UInt64 = 0x46494C4D

    /// Filter IDs ordered from the lens front element outward. Order affects air-gap veiling glare;
    /// uniform spectral absorption commutes with spatial diffusion.
    var lensFilterIDs: [String] = []

    /// How the exposure was set behind the fitted stack — the engine's three answers, surfaced
    /// because they are the difference between a filter that shows and one that cancels. Metered
    /// through is the default a TTL camera gives, and it makes a neutral density *exactly*
    /// invisible: the meter sees the flat loss and the gain puts it all back. A photographer who
    /// fits an ND to see it darken wants "none".
    var lensFilterMetering: LensFilterCompensation = .throughTheLens

    /// The lab's levers: stops of push (or pull) development, how much silver the
    /// bleach leaves behind, and years past the roll's process-by date. All rest at
    /// the datasheet's zero.
    var push = 0.0
    var bleach = 0.0
    var expiredYears = 0.0
    /// How long the shutter was open, for the stock's stated reciprocity failure. Nil is the
    /// instantaneous exposure every edit has been developed as until now, and so is any time at or
    /// under the sheet's threshold, where the law still holds.
    var shutterSeconds: Double? = nil
    /// The lamp a physical print is viewed under, in kelvin. Nil uses the medium reference:
    /// D50 for reflection paper and calibrated 5400 K xenon for a cinema print. Digital media
    /// ignore it.
    var printLightKelvin: Double? = nil

    /// Where the developed image is finished. Most choices form a positive; `.negative` keeps the
    /// developed film itself as the output.
    var paper = PrintPaper.editorDefault
    /// An edit can explicitly follow the loaded stock's physical reference path: still negative
    /// to RA-4 paper, motion negative to its native release print, and reversal to its direct
    /// positive. New edits instead use the HDR-capable digital reference selected above.
    var paperFollowsStock = false

    var rotation = 0  // clockwise quarter turns, 0...3
    var flipH = false
    var straighten = 0.0  // degrees, -15 ... 15
    /// The picture plane's keystone, in degrees, -15 ... 15 apiece.
    var perspectiveV = 0.0
    var perspectiveH = 0.0
    /// Unit-space crop in the straightened frame; nil = full frame.
    var crop: CGRect? = nil
    var cornerCrop: QuadrilateralCrop? = nil

    /// Whether to apply lens correction. Disabled by default because correction resamples the image.
    var lensCorrectionEnabled = false
    /// The profile the photographer pinned, overriding what the metadata matched. Nil lets the
    /// catalogue decide, which is what it does for almost every picture.
    var lensProfileID: String? = nil
    /// Fraction of the matched lens profile to apply, from 0 through 1.
    var lensProfileAmount = 1.0
    /// What the photographer dialled on top, which is all an unmatched lens gets.
    var lensAdjustment = LensAdjustment.neutral

    static let defaults = EditState()

    /// The flat return spectrum: the engine's own ladder, at rest.
    ///
    /// Taken from `HalationSpectrum` rather than from the row that draws it, so the storage
    /// depends on the engine and not on the editor's vocabulary. The catalogue builds its handles
    /// from the same place, and `EditorControlCatalogueTests` holds the two to each other — so
    /// this cannot drift from the graph without a test saying so.
    static let restingHalationSpectrum = HalationSpectrum.neutral.map(Double.init)

    var hasGeometryEdits: Bool {
        rotation != 0 || flipH || straighten != 0
            || perspectiveV != 0 || perspectiveH != 0 || crop != nil || cornerCrop != nil
    }

    /// Everything about the lens correction that changes the pixels, gathered so that the render
    /// key and the crop tool's own preview can ask the same question the same way.
    struct LensSettings: Equatable {
        var enabled: Bool
        var profileID: String?
        var profileAmount: Double
        var adjustment: LensAdjustment
    }

    var lensSettings: LensSettings {
        LensSettings(enabled: lensCorrectionEnabled, profileID: lensProfileID,
                     profileAmount: lensProfileAmount,
                     adjustment: lensAdjustment)
    }

    /// Whether anything about the lens has been said by hand. The switch itself is not an edit —
    /// turning correction on is asking for the measurement, not overriding it.
    var hasLensEdits: Bool {
        !lensAdjustment.isNeutral || lensProfileAmount != 1
            || lensProfileID != nil
    }

    mutating func resetLensCorrection() {
        lensAdjustment = .neutral
        lensProfileAmount = 1
        lensProfileID = nil
    }

    /// Linked inhibitor reach. The getter uses the first gap; the setter updates every gap.
    var couplerReach: Double {
        get { couplerGapReach.first ?? 1 }
        set {
            couplerGapReach = [Double](repeating: newValue,
                                       count: max(couplerGapReach.count, 2))
        }
    }

    /// The gauge this edit actually develops on.
    var formatID: String {
        chosenFormatID ?? StockPreset.nativeFormatID(for: stockID)
    }

    /// True once the gauge is the user's rather than the film's, which is what a picker needs to
    /// know to say so.
    var followsStockGauge: Bool { chosenFormatID == nil }

    /// The gauge this edit develops a photograph on, given what that photograph's file says it was
    /// exposed on. Nobody having asked for a gauge, the camera's own frame answers before the film's
    /// default does — see `FilmFormat.resolved`.
    func resolvedFormat(sensor: SensorFrame?) -> FilmFormat {
        FilmFormat.resolved(chosenID: chosenFormatID, sensor: sensor, stockID: stockID)
    }

    /// The preset a gauge picker should light up. The camera's answer is a preset like any other
    /// now that a frame is matched to a gauge rather than used as one, so it lights up the gauge the
    /// picture is genuinely being developed on.
    func selectedFormatID(sensor: SensorFrame?) -> String? {
        if let chosenFormatID { return chosenFormatID }
        if let sensor { return sensor.gauge.id }
        return StockPreset.nativeFormatID(for: stockID)
    }

    /// What the automatic row is following, said in one line for a picker: the camera where the file
    /// measured the frame, the film otherwise.
    func gaugeFollowingNote(sensor: SensorFrame?) -> String {
        guard let sensor else {
            let gauge = FilmFormat.native(forStockID: stockID).name
            // Normal has no emulsion or native gauge, so describe the fallback as enlargement.
            guard hasFilm else {
                return "With no film loaded there is nothing cut to a gauge, so this only "
                    + "decides how far the picture is enlarged — \(gauge) until you "
                    + "choose otherwise."
            }
            let name = StockPreset.preset(id: stockID)?.name ?? "This film"
            return "\(name) uses \(gauge), and changing the film changes the format with it."
        }
        return """
        This picture was taken on a \(sensor.frameSize) frame, so it is developed on \
        \(sensor.gauge.format.name) — the nearest gauge film was ever cut to.
        """
    }

    /// Pin the gauge to the user's choice.
    mutating func selectFormat(_ id: String) { chosenFormatID = id }

    /// Hand the gauge back to the film.
    mutating func followStockGauge() { chosenFormatID = nil }

    /// `nil` when no stock pack is installed, and in Normal, where there is no emulsion by choice.
    var stock: FilmStock? { StockPreset.preset(id: stockID)?.stock }

    /// Whether a film is loaded at all. False only in Normal — a stale id still means a film was
    /// asked for — and it is what the film's own controls ask before offering themselves: its
    /// character, its paper's correction, the develop sheet. Everything scene-referred still
    /// applies either way.
    var hasFilm: Bool { !StockPreset.isNoFilm(stockID) }

    /// The medium this edit really develops on. Silence follows the stock's physical reference
    /// path; an explicit selection is honoured wherever that stock can reach it. A reversal stock
    /// always resolves to its direct positive.
    var resolvedPaper: PrintPaper {
        guard let stock else { return paper }
        if paperFollowsStock { return PrintPaper.default(for: stock) }
        return paper.resolved(for: stock)
    }

    /// Whether the selected film and medium can carry a local HDR output request. The app setting
    /// decides the initial request when an editor opens; it does not remain a live dependency of
    /// the edit. Negative film is always delivered as SDR.
    var supportsHDROutput: Bool {
        resolvedPaper.showsHDR && StockPreset.supportsHDRDelivery(for: stockID)
    }

    var whiteBalance: WhiteBalance {
        WhiteBalance(kelvin: WhiteBalance.miredToKelvin(Float(temperatureMired)),
                     tint: Float(tint))
    }

    /// Kelvin, for the slider's readout.
    var temperatureKelvin: Double {
        Double(WhiteBalance.miredToKelvin(Float(temperatureMired)))
    }

    /// Returns render options with the gauge resolved from the explicit edit, sensor, or film.
    func options(sensor: SensorFrame?) -> FotufilmEngine.Options {
        var o = options
        o.format = resolvedFormat(sensor: sensor)
        return o
    }

    /// The develop for a source that measured nothing — a clip, a scan, the live camera.
    var options: FotufilmEngine.Options {
        var o = FotufilmEngine.Options()
        o.exposureEV = Float(exposure)
        o.whiteBalance = whiteBalance
        o.highlights = Float(highlights)
        o.shadows = Float(shadows)
        o.localTone = localTone
        o.saturation = Float(saturation)
        o.vibrance = Float(vibrance)
        o.grade = grade
        o.gradeSpace = encodedGrade ? .encoded : .linear
        o.grainScale = Float(grain)
        o.grainMottleShare = grainMottleShare.map(Float.init)
        o.grainModel = discGrain ? .discs : .clumpField
        o.halationScale = Float(halation)
        o.halationSourceColour = Float(halationColour)
        // Resampled here rather than in the engine: the ladder of handles is the editor's shape,
        // and what the engine takes is a curve on its own grid. A flat ladder resamples to nothing
        // at all, which is the option's own default and the render every earlier build made.
        o.halationReturnGain =
            HalationSpectrum.resampled(halationSpectrum.map(Float.init))
        o.useEstimatedHalationProfile = AppSettings.storedEstimatedHalationEnabled
        o.couplerScale = Float(couplers)
        // Per-gap only: each barrier already stands for itself, so setting `couplerRangeScale` as
        // well would be a value the engine never reads.
        o.couplerGapReachScales = couplerGapReach.map(Float.init)
        o.couplerSelfScale = Float(couplerSelf)
        o.printCorrection = Float(printCorrection)
        // The filters sit in front of everything the engine does, so they are resolved here with
        // the rest of the develop: the absorbing ones through the exposure table, the scattering
        // one as the stage ahead of the emulsion.
        let fitted = FilterChoice.resolve(lensFilterIDs)
        if !fitted.absorbing.isEmpty {
            o.lensFilters = LensFilterStack(fitted.absorbing,
                                            compensation: lensFilterMetering)
        }
        o.diffusionFilter = fitted.diffusion
        // Old edits can carry the generic push value removed from the engine. A stock-specific
        // measured condition survives; anything else returns to reference development instead of
        // reaching the engine as an unmeasured request.
        let requestedDevelopment = Float(push)
        if stock?.supportsDevelopment(stops: requestedDevelopment) == true {
            o.developmentEV = requestedDevelopment
        }
        o.bleachBypass = Float(bleach)
        o.expiredYears = Float(expiredYears)
        o.shutterSeconds = shutterSeconds.map(Float.init)
        o.printViewingKelvin = printLightKelvin.map(Float.init)
        let outputMedium = resolvedPaper
        o.paper = outputMedium
        if outputMedium.isNegative {
            o.negativeViewing = AppSettings.storedNegativeViewing
        }
        o.format = FilmFormat.preset(id: formatID) ?? .still35
        o.seed = seed
        return o
    }

    /// Whether the photograph's own shape is changed by this edit — the question an editor asks
    /// before it puts the undeveloped original on screen, because a print of this state will not be
    /// that shape.
    var hasGeometry: Bool {
        rotation != 0 || flipH || straighten != 0
            || perspectiveV != 0 || perspectiveH != 0 || crop != nil || cornerCrop != nil
    }

    mutating func resetGeometry() {
        rotation = 0
        flipH = false
        straighten = 0
        perspectiveV = 0
        perspectiveH = 0
        crop = nil
        cornerCrop = nil
    }

    mutating func rerollGrain() {
        seed = UInt64.random(in: UInt64.min...UInt64.max)
    }
}

/// The crop tools' aspect choices.
enum AspectOption: String, CaseIterable {
    case free = "Free"
    case original = "Original"
    case square = "1:1"
    case r4x5 = "4:5"
    case r3x2 = "3:2"
    case r16x9 = "16:9"

    /// Locked width/height ratio for an image of the given size; ratios are oriented to match the
    /// image (portrait images get portrait crops).
    func ratio(for size: CGSize) -> CGFloat? {
        let portrait = size.height > size.width
        func oriented(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
            portrait ? min(a, b) / max(a, b) : max(a, b) / min(a, b)
        }
        switch self {
        case .free: return nil
        case .original:
            return size.height > 0 ? size.width / size.height : nil
        case .square: return 1
        case .r4x5: return oriented(4, 5)
        case .r3x2: return oriented(3, 2)
        case .r16x9: return oriented(16, 9)
        }
    }
}
