import CoreGraphics
import CoreImage
import Foundation

#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmEditModel)
import FotufilmEditModel
#endif
#if canImport(FotufilmImaging)
import FotufilmImaging
#endif

/// A scanned negative opened in the photo editor as a document, as the desktop opens one
/// (`HostNegativeScan`): the decoded scan, never changed, and what reading it needs. The editor
/// frames it like any photograph (`FilmRender.scene`); each develop reads the framed scan as the
/// edit's film and prints it (`NegativeScanPrint.Reading`), or with no film reads it as a plain
/// positive (`PlainNegativeScan`) developed like any photograph. The edit's reading is
/// `EditState.negative`.
final class NegativeDocument: @unchecked Sendable {
    let original: Data
    let typeHint: String?
    /// The scan as decoded, its extent at the origin. An untagged scan is the scanner's raw output,
    /// read as linear samples as the desktop reads it: a merged trichromatic scan is one.
    let image: CIImage
    var size: CGSize { image.extent.size }

    init(data: Data, typeHint: String?) throws {
        original = data
        self.typeHint = typeHint
        image = try NegativeScanImport.decode(data: data, identifierHint: typeHint,
                                              linearSamples: !NegativeScanImport.statesEncoding(data))
    }

    // MARK: - Preparation

    /// Work an app does on the scan before an edit reads it: what the work is, and the scan it
    /// makes, or nil when `shouldContinue` stopped it.
    struct Preparation: @unchecked Sendable {
        let identity: AnyHashable
        let prepare: (_ shouldContinue: (() -> Bool)?) -> CIImage?
    }

    /// How an app prepares a scan for an edit, such as taking dust off; nil, or nil from it, reads
    /// the scan as it is.
    nonisolated(unsafe) static var preparation: ((NegativeDocument, EditState) -> Preparation?)?

    /// What decides the scan an edit reads before it is framed.
    struct SourceKey: Hashable {
        var light: String?
        var prepared: AnyHashable?
    }

    func sourceKey(_ state: EditState) -> SourceKey {
        SourceKey(light: state.negative?.lightFrame,
                  prepared: Self.preparation?(self, state)?.identity)
    }

    /// The scan an edit reads: prepared by the app, then the light source it was scanned on
    /// evened out. Nil when `shouldContinue` stopped the preparation.
    func source(_ state: EditState, shouldContinue: (() -> Bool)? = nil) -> CIImage? {
        var scan = image
        if let preparation = Self.preparation?(self, state) {
            guard let prepared = preparation.prepare(shouldContinue) else {
                return shouldContinue?() == false ? nil : image
            }
            scan = prepared
        }
        if let id = state.negative?.lightFrame, let light = NegativeScanRoll.lightFrame(id) {
            scan = light.measured.flatten(scan)
        }
        return scan
    }

    // MARK: - Readings

    private let lock = NSLock()
    private var estimates: [EstimateKey: SIMD3<Float>] = [:]
    private var holders: [HolderKey: Holder?] = [:]
    private var measures: [(key: MeasureKey, measure: Measure)] = []

    private var readCapture: NegativeScanCapture?

    /// What the scan's file says of its camera and of how it was decoded
    /// (`NegativeScanImport.source`), which a reading through the scan's light and camera is
    /// made of. Read once, when a reading or a control first asks, whichever thread that is on.
    var capture: NegativeScanCapture {
        if let kept = lock.withLock({ readCapture }) { return kept }
        let read = NegativeScanImport.source(data: original, identifierHint: typeHint)
        lock.withLock { readCapture = read }
        return read
    }

    /// The camera the scan is read as taken with where its edit leaves that to the file
    /// (`NegativeScanCapture.readCamera`): its name, nil for the generic camera.
    var cameraName: String? { capture.readCamera.name }

    /// Whether a new edit of the scan starts with its dyes separated all the way: its camera's
    /// colour channels are measured, so the separation is worked out from what took the scan.
    /// For any other camera it is a guess at its channels and starts off, as the desktop starts
    /// it.
    var separates: Bool {
        let camera = capture.readCamera.id
        return camera != "generic" && camera != "scanner"
    }

    /// What a framing measures: the clear film it is read against, and its own densest end before
    /// any roll's colour (`ApproximateNegativeScan.denseEnd`). A reading through the scan's light
    /// and camera also measures the rises across the framing's tonal steps, the stray light it
    /// takes off, which the densest end and the rises are net of, and where the scan's holder
    /// begins, which is left out of them; and carries what the scan's file says of its camera.
    struct Measure: Equatable, Sendable {
        var border: SIMD3<Float>
        var dense: SIMD3<Float>?
        var slopes: SIMD2<Float>?
        var flare: SIMD3<Float> = .zero
        var holder: Float?
        var capture: NegativeScanCapture?

        /// What the framing gives its roll (`ApproximateNegativeScan.RollBalance.Measure`).
        var forRoll: ApproximateNegativeScan.RollBalance.Measure {
            .init(denseEnd: dense, slopes: slopes)
        }
    }

    private struct EstimateKey: Hashable {
        var source: SourceKey
        var filmBase: Bool
    }

    private struct HolderKey: Hashable {
        var source: SourceKey
        var border: SIMD3<Float>
    }

    private typealias Holder = (light: SIMD3<Float>, stray: SIMD3<Float>, limit: Float)

    private struct MeasureKey: Equatable {
        var source: SourceKey
        var framing: FilmRender.SceneKey
        var border: [Float]?
        /// What of the edit's reading a measure turns on: which reading, and its flare.
        var readsModel: Bool
        var flare: Float?
    }

    /// The thinnest film of the whole scan, standing in for clear film until some is picked
    /// (`ApproximateNegativeScan.estimatedBorder`); for a reading through the scan's light and
    /// camera, the film's base where the scan shows its bare light past the film
    /// (`ApproximateNegativeScan.estimatedFilmBase`).
    func estimatedBorder(_ state: EditState) throws -> SIMD3<Float> {
        let filmBase = state.negative?.readsModel ?? false
        let key = EstimateKey(source: sourceKey(state), filmBase: filmBase)
        if let estimate = lock.withLock({ estimates[key] }) { return estimate }
        guard let source = source(state) else { throw CancellationError() }
        let preview = try Self.samples(FilmRender.downsample(source, longEdge: Self.readingEdge))
        guard let estimate = filmBase
            ? ApproximateNegativeScan.estimatedFilmBase(preview: preview)
            : ApproximateNegativeScan.estimatedBorder(preview: preview) else {
            throw NegativeScanImport.Failure.invalidBorder
        }
        lock.withLock { estimates[key] = estimate }
        return estimate
    }

    /// The light the whole scan's holder shows against `border`, the stray light read from it
    /// and where the holder ends (`ApproximateNegativeScan.holder`); nil where the scan shows no
    /// holder.
    private func holder(_ state: EditState, border: SIMD3<Float>) throws -> Holder? {
        let key = HolderKey(source: sourceKey(state), border: border)
        if let kept = lock.withLock({ holders[key] }) { return kept }
        guard let source = source(state) else { throw CancellationError() }
        let preview = try Self.samples(FilmRender.downsample(source, longEdge: Self.readingEdge))
        let found = ApproximateNegativeScan.holder(border: border, preview: preview)
        lock.withLock {
            if holders.count >= 8 { holders.removeAll() }
            holders[key] = .some(found)
        }
        return found
    }

    /// What the edit's framing measures, read on `framed`, the scan as the edit frames it.
    func measure(_ state: EditState, framed: (CIImage) -> CIImage) throws -> Measure {
        let negative = state.negative ?? .init()
        let key = MeasureKey(source: sourceKey(state),
                             framing: FilmRender.SceneKey(state: state, longEdge: Self.readingEdge),
                             border: negative.border, readsModel: negative.readsModel,
                             flare: negative.flare)
        if let kept = lock.withLock({ measures.first { $0.key == key } }) { return kept.measure }
        let border: SIMD3<Float>
        if let picked = negative.border, picked.count == 3,
           picked.allSatisfy({ $0.isFinite && $0 > 0 }) {
            border = SIMD3(picked[0], picked[1], picked[2])
        } else {
            border = try estimatedBorder(state)
        }
        guard let source = source(state) else { throw CancellationError() }
        var preview = try Self.samples(FilmRender.downsample(framed(source),
                                                             longEdge: Self.readingEdge))
        var measure = Measure(border: border)
        if negative.readsModel {
            // As the desktop host measures a framing (`HostNegativeScan.measure`): the scan's
            // holder left out, then the stray light taken off.
            let holder = try self.holder(state, border: border)
            if let holder {
                preview = ApproximateNegativeScan.withoutHolder(preview, border: border,
                                                                limit: holder.limit)
            }
            let flare = negative.strayLight(
                border: border, frameLight: ApproximateNegativeScan.frameLight(preview: preview),
                holder: negative.flare == nil ? holder?.stray : nil)
            if flare != .zero {
                for c in 0..<3 { for i in preview.planes[c].indices { preview.planes[c][i] -= flare[c] } }
            }
            let clear = border - flare
            measure.dense = ApproximateNegativeScan.denseEnd(border: clear, preview: preview)
            measure.slopes = ApproximateNegativeScan.tonalSlopes(border: clear, preview: preview)
            measure.flare = flare
            measure.holder = holder?.limit
            measure.capture = capture
        } else {
            measure.dense = ApproximateNegativeScan.denseEnd(border: border, preview: preview)
        }
        lock.withLock {
            measures.removeAll { $0.key == key }
            measures.append((key, measure))
            if measures.count > 8 { measures.removeFirst() }
        }
        return measure
    }

    /// A framing's densest end on its roll's colour, when the edit is balanced on one.
    static func denseEnd(_ measure: Measure, state: EditState) -> SIMD3<Float>? {
        ApproximateNegativeScan.denseEnd(measure.dense, roll: state.negative?.roll)
    }

    /// The reading of a measured framing as `stock`, which prints it: as the edit's negative
    /// says to read it, the one way every surface does (`WebNativeEdit.Negative.balance`).
    static func reading(_ measure: Measure, state: EditState,
                        stock: FilmStock) throws -> NegativeScanPrint.Reading {
        let negative = state.negative ?? .init()
        return try NegativeScanPrint.Reading(
            stock: NegativeScanPrint.film(stock), border: measure.border,
            balance: negative.balance(stock: stock, border: measure.border, denseEnd: measure.dense,
                                      source: measure.capture, flare: measure.flare),
            flare: measure.flare, holder: measure.holder)
    }

    /// The scan read without a film, as Normal reads it (`WebNativeEdit.Negative.plain`).
    static func plain(_ measure: Measure, state: EditState) -> PlainNegativeScan {
        (state.negative ?? .init()).plain(border: measure.border, denseEnd: measure.dense,
                                          source: measure.capture, flare: measure.flare)
    }

    // MARK: - Clear film

    /// Clear film picked at `point`, a unit point from the top left of `framed`: the median over a
    /// patch a fortieth of the picture's long edge across, as the desktop samples it.
    static func sampleBorder(at point: CGPoint, in framed: CIImage) throws -> [Float] {
        let extent = framed.extent
        let side = 0.025 * max(extent.width, extent.height)
        let rect = CGRect(x: point.x - side / 2 / extent.width, y: point.y - side / 2 / extent.height,
                          width: side / extent.width, height: side / extent.height)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let border = try NegativeScanImport.sampleBorder(image: framed, rect: rect,
                                                         colorSpace: NegativeScanImport.filmSpace)
        return [border.x, border.y, border.z]
    }

    // MARK: - Points on the scan

    private static let coordinates = CIContext(options: [
        .workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
        .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false,
    ])

    /// The point of the scan's own frame, a unit point from its top left, that the edit shows at
    /// `point` of its framed picture, also from the top left; nil outside it. Read off a picture
    /// of the scan's own coordinates framed as the edit frames the scan, so every turn, flip,
    /// straighten, tilt and crop is undone exactly as the scene does it.
    func scanPoint(ofShown point: CGPoint, state: EditState) -> CGPoint? {
        let extent = CGRect(origin: .zero, size: size)
        func ramp(to end: CGPoint, _ colour: CIColor) -> CIImage? {
            CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(cgPoint: end),
                "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 1),
                "inputColor1": colour,
            ])?.outputImage?.cropped(to: extent)
        }
        guard let across = ramp(to: CGPoint(x: size.width, y: 0),
                                CIColor(red: 1, green: 0, blue: 0, alpha: 1)),
              let up = ramp(to: CGPoint(x: 0, y: size.height),
                            CIColor(red: 0, green: 1, blue: 0, alpha: 1)) else { return nil }
        let map = FilmRender.geometry(across.applyingFilter("CIAdditionCompositing", parameters: [
            kCIInputBackgroundImageKey: up,
        ]), state: state)
        let shown = map.extent
        let x = (shown.minX + point.x * shown.width).rounded(.down)
        let y = (shown.maxY - point.y * shown.height).rounded(.down)
        guard shown.contains(CGPoint(x: x, y: y)) else { return nil }
        var pixel = [Float](repeating: 0, count: 4)
        Self.coordinates.render(map, toBitmap: &pixel, rowBytes: 16,
                                bounds: CGRect(x: x, y: y, width: 1, height: 1),
                                format: .RGBAf, colorSpace: nil)
        guard pixel[0].isFinite, pixel[1].isFinite else { return nil }
        return CGPoint(x: CGFloat(pixel[0]), y: 1 - CGFloat(pixel[1]))
    }

    /// `picture`, laid over the scan's own frame, framed as the edit frames the scan and drawn
    /// down to `longEdge`: marks made on the film, placed over the picture the edit shows.
    func framed(_ picture: CIImage, state: EditState, longEdge: Int) -> CIImage {
        let placed = picture.transformed(by: CGAffineTransform(
            scaleX: size.width / max(1, picture.extent.width),
            y: size.height / max(1, picture.extent.height)))
            .cropped(to: CGRect(origin: .zero, size: size))
        return FilmRender.downsample(FilmRender.geometry(placed, state: state), longEdge: longEdge)
    }

    // MARK: - Pictures of the negative

    private static let pictures = CIContext(options: [
        .workingColorSpace: NegativeScanImport.linearSpace, .cacheIntermediates: false,
    ])

    /// A picture of the negative itself, as it would be seen on a light box, drawn down to
    /// `longEdge`: what the editor holds up as the original.
    static func picture(of scan: CIImage, longEdge: Int) -> CGImage? {
        let picture = FilmRender.downsample(scan, longEdge: longEdge)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return pictures.createCGImage(picture, from: picture.extent, format: .RGBA8,
                                      colorSpace: space)
    }

    // MARK: - Films
    // MARK: - Films

    /// Up to three readings of the film base, each naming the installed negatives it could be,
    /// most likely first. Read once, on the scan as decoded.
    private(set) lazy var suggestions: [NegativeFilmSuggestions.Suggestion] = {
        var stocks: [String: FilmStock] = [:]
        for preset in StockPreset.all where NegativeScanPrint.reads(preset.stock) {
            stocks[preset.id] = preset.stock
        }
        guard let preview = try? Self.samples(FilmRender.downsample(image, longEdge: Self.readingEdge)),
              let reading = NegativeFilmSuggestions.read(preview: preview) else { return [] }
        return NegativeFilmSuggestions(stocks: stocks).suggest(reading, limit: 3)
    }()

    // MARK: - Samples

    /// The readings' long edge, as the desktop and the scan editor read a frame.
    static let readingEdge = 512

    /// Linear Rec. 2020 samples, the space a film reading takes its samples in.
    static func samples(_ image: CIImage) throws -> ImageBuffer {
        try NegativeScanImport.samples(image, colorSpace: NegativeScanImport.filmSpace)
    }
}

/// What the frames of a roll share: the colour their densest ends have in common, measured over
/// every frame and kept with each frame's reading, as the desktop's Roll panel measures it
/// (web/src/negative-document.js `rollBalance`).
enum NegativeRollBalance {
    /// Densest ends too thin to tell a colour from.
    static let readable: Float = 0.05

    /// What a roll's frames share, from what each measures (`measure(of:edit:)`): the colour and
    /// level of their densest ends, and with six frames' tonal steps or more how steep their
    /// records read against each other (`ApproximateNegativeScan.RollBalance(measures:)`). Nil
    /// when fewer than two frames can be read.
    static func balance(
        of measures: [ApproximateNegativeScan.RollBalance.Measure?]
    ) -> ApproximateNegativeScan.RollBalance? {
        ApproximateNegativeScan.RollBalance(measures: measures.compactMap { $0 })
    }

    /// The roll's colour over the frames whose densest ends can be read. Nil when fewer than
    /// two frames can be read.
    static func balance(of denseEnds: [SIMD3<Float>?]) -> ApproximateNegativeScan.RollBalance? {
        balance(of: denseEnds.map { $0.map { .init(denseEnd: $0) } })
    }

    /// What a frame gives its roll under its edit's framing, light and clear film: its own
    /// densest end, and for a reading through the scan's light and camera the rises across its
    /// tonal steps. Nil for a frame that cannot be read.
    static func measure(of document: NegativeDocument,
                        edit: EditState) -> ApproximateNegativeScan.RollBalance.Measure? {
        try? document.measure(edit) { FilmRender.geometry($0, state: edit) }.forRoll
    }

    /// A frame's own densest end: what it gives the roll of an edit made with the first reading.
    static func denseEnd(of document: NegativeDocument, edit: EditState) -> SIMD3<Float>? {
        measure(of: document, edit: edit)?.denseEnd
    }
}

extension NegativeDocument {
    /// A small print of the scan as `state` develops it, for the shelf.
    func print(_ state: EditState, longEdge: Int = 512) -> CGImage? {
        FilmRender.render(source: .scan(self), state: state, longEdge: longEdge)?.image
    }

    /// The film a new scan opens on, as the desktop chooses it: the first installed film its base
    /// looks like, else the house film when it reads negatives, else the first that does.
    static func startingStockID(
        suggestions: [NegativeFilmSuggestions.Suggestion]) -> String {
        let wall = FilmChoice.negativeWall.map(\.id).filter { !StockPreset.isNoFilm($0) }
        if let suggested = suggestions.flatMap({ $0.films.map(\.id) }).first(where: wall.contains) {
            return suggested
        }
        return wall.contains(StockPreset.defaultID) ? StockPreset.defaultID
            : wall.first ?? StockPreset.noFilmID
    }
}

extension EditState {
    /// A scanned negative's first edit: the reading starts estimated, as scanned, on `stockID`,
    /// made with the current reading as the desktop makes a new negative's. `separates` is
    /// whether its dyes start separated all the way (`NegativeDocument.separates`).
    static func negativeDocument(stockID: String, separates: Bool = false) -> EditState {
        var edit = EditState()
        edit.stockID = stockID
        edit.negative = WebNativeEdit.Negative(
            crosstalk: separates ? 1 : 0, reading: WebNativeEdit.Negative.currentReading)
        // A scan opens on the print the scan editor and the desktop open on: the display
        // conversion, each frame timed on its own highlights as a lab times a negative, whatever
        // conversion a photograph's edit starts with. A print at a fixed exposure shows a thin
        // negative dark and a dense one light.
        edit.paper = .screen
        edit.paperFollowsStock = false
        edit.digitalReference = .default
        return edit
    }

    /// The scan editor's recipe as the photo editor's edit of the same scan: its film, print,
    /// clear film, light source, attachments and framing. An automatic reading has no film, and
    /// opens in Normal; the recipe's own tone sliders have no counterpart and start at rest.
    init(scanRecipe recipe: NegativeScanRecipe) {
        let film = recipe.conversion == .film
            ? StockPreset.all.first { $0.id == recipe.stockID } : nil
        self = .negativeDocument(stockID: film?.id ?? StockPreset.noFilmID)
        if let film { paper = recipe.paper(for: film.stock) }
        // A recipe was made with the first reading, and its edit keeps it until it is updated.
        negative = WebNativeEdit.Negative(border: recipe.border, lightFrame: recipe.lightFrameID,
                                          attachments: recipe.attachments)
        // The recipe flips before it turns; this edit turns before it flips, and a turn then a
        // flip is the flip then the opposite turn.
        let turns = ((recipe.quarterTurns % 4) + 4) % 4
        rotation = recipe.mirrored ? (4 - turns) % 4 : turns
        flipH = recipe.mirrored
        straighten = recipe.straighten
        // The recipe's crop is from the top left; this edit's from the bottom left.
        let crop = recipe.crop.clamped()
        self.crop = recipe.crop == .full ? nil
            : CGRect(x: crop.x, y: 1 - crop.y - crop.height, width: crop.width, height: crop.height)
    }
}
