import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmEditModel)
import FotufilmEditModel
#endif
#if canImport(FotufilmImaging)
import FotufilmImaging
#endif
#if canImport(FotufilmMetal)
import FotufilmMetal
#endif

/// A scanned negative open for conversion: the decoded scan, and prints of it made to a
/// `NegativeScanRecipe`. The scan is never changed; every print starts again from it.
final class NegativeScan: @unchecked Sendable {
    enum Failure: LocalizedError {
        case noFilm, reversalFilm, render
        var errorDescription: String? {
            switch self {
            case .noFilm: return "This film is not installed."
            case .reversalFilm: return "Slide film has no negative to convert. Choose a negative film."
            case .render: return "The positive could not be rendered."
            }
        }
    }

    let original: Data
    let typeHint: String?
    /// The scan in linear light, its extent at the origin.
    let image: CIImage
    var size: CGSize { image.extent.size }

    private let context = CIContext(options: [
        .workingColorSpace: NegativeScanImport.linearSpace,
        .cacheIntermediates: false,
    ])
    private let lock = NSLock()
    private var plans: [PlanKey: AutomaticNegativeScan] = [:]
    private var balances: [BalanceKey: ApproximateNegativeScan.Balance] = [:]
    private var estimates: [String: [Float]] = [:]
    private var sources: [String: CIImage] = [:]
    private var preparedSource: (key: SourceKey, image: CIImage)?
    private var preview: (key: FrameKey, samples: [Float], width: Int, height: Int)?

    init(data: Data, typeHint: String?) throws {
        original = data
        self.typeHint = typeHint
        image = try NegativeScanImport.decode(data: data, identifierHint: typeHint)
    }

    /// The films a scan can be read as: every installed negative.
    static var films: [StockPreset] {
        StockPreset.all.filter { !$0.stock.isReversal && !$0.stock.isReflectionPrint }
    }

    static func film(_ id: String) throws -> FilmStock {
        guard let stock = StockPreset.all.first(where: { $0.id == id })?.stock else {
            throw Failure.noFilm
        }
        guard !stock.isReversal, !stock.isReflectionPrint else { throw Failure.reversalFilm }
        return stock
    }

    /// Whether a reading's positive carries colour: a reading on a colour negative.
    static func carriesColour(_ recipe: NegativeScanRecipe) -> Bool {
        recipe.conversion == .automatic ? !recipe.monochrome
            : (try? film(recipe.stockID))?.isMonochrome != true
    }

    // MARK: - Light

    /// The scan with the recipe's light source evened out, or as scanned without one.
    private func source(_ lightFrameID: String?) -> CIImage {
        guard let lightFrameID, let light = NegativeScanRoll.lightFrame(lightFrameID) else {
            return image
        }
        if let even = lock.withLock({ sources[lightFrameID] }) { return even }
        let even = light.measured.flatten(image)
        lock.withLock { sources[lightFrameID] = even }
        return even
    }

    // MARK: - Preparation

    /// Work an app does on the scan before a recipe reads it: what the work is, and the scan it
    /// makes, or nil when `shouldContinue` stopped it.
    struct Preparation: @unchecked Sendable {
        let identity: AnyHashable
        let prepare: (_ shouldContinue: (() -> Bool)?) -> CIImage?
    }

    /// How an app prepares a scan for a recipe; nil, or nil from it, reads the scan as it is.
    nonisolated(unsafe) static var preparation: ((NegativeScan, NegativeScanRecipe) -> Preparation?)?

    private func preparation(_ recipe: NegativeScanRecipe) -> Preparation? {
        Self.preparation?(self, recipe)
    }

    private struct SourceKey: Equatable {
        var light: String?, prepared: AnyHashable
    }

    /// The scan the recipe reads: prepared by the app, then its light source evened out.
    private func source(_ recipe: NegativeScanRecipe) -> CIImage {
        guard let preparation = preparation(recipe) else { return source(recipe.lightFrameID) }
        let key = SourceKey(light: recipe.lightFrameID, prepared: preparation.identity)
        if let kept = lock.withLock({ preparedSource }), kept.key == key { return kept.image }
        guard let prepared = preparation.prepare(nil) else { return source(recipe.lightFrameID) }
        let even = recipe.lightFrameID.flatMap(NegativeScanRoll.lightFrame)
            .map { $0.measured.flatten(prepared) } ?? prepared
        lock.withLock { preparedSource = (key, even) }
        return even
    }

    // MARK: - Geometry

    /// The scan turned, flipped and straightened as the recipe shows it, cropped unless `cropped`
    /// is false, and drawn down to `longEdge` when that is smaller.
    func frame(_ recipe: NegativeScanRecipe, longEdge: Int?, cropped: Bool = true) -> CIImage {
        framed(source(recipe), recipe, longEdge: longEdge, cropped: cropped)
    }

    /// Any picture of the scan's frame, turned, flipped, straightened and cropped as `frame` is.
    func framed(_ picture: CIImage, _ recipe: NegativeScanRecipe, longEdge: Int?,
                        cropped: Bool) -> CIImage {
        var picture = picture
        if recipe.mirrored {
            picture = atOrigin(picture.transformed(by: CGAffineTransform(scaleX: -1, y: 1)))
        }
        let turns = ((recipe.quarterTurns % 4) + 4) % 4
        if turns > 0 {
            // Core Image's y axis points up, so a clockwise turn is a negative angle.
            picture = atOrigin(picture.transformed(
                by: CGAffineTransform(rotationAngle: -CGFloat(turns) * .pi / 2)))
        }
        picture = Self.straighten(picture, degrees: recipe.straighten)
        let e = picture.extent
        if cropped {
            let crop = recipe.crop.clamped()
            let rect = CGRect(x: crop.x * e.width, y: (1 - crop.y - crop.height) * e.height,
                              width: crop.width * e.width, height: crop.height * e.height)
                .integral.intersection(e)
            picture = atOrigin(picture.cropped(to: rect))
        }
        guard let longEdge else { return picture }
        let longest = max(picture.extent.width, picture.extent.height)
        let scale = min(1, CGFloat(longEdge) / max(1, longest))
        guard scale < 1 else { return picture }
        let width = max(1, (picture.extent.width * scale).rounded(.down))
        let height = max(1, (picture.extent.height * scale).rounded(.down))
        return atOrigin(picture.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1,
        ])).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// Turns a picture counter-clockwise by `degrees` about its centre and enlarges it by
    /// `NegativeScanRecipe.straightenScale` so it still fills its own frame.
    static func straighten(_ picture: CIImage, degrees: Double) -> CIImage {
        guard degrees != 0 else { return picture }
        let e = picture.extent
        let scale = NegativeScanRecipe.straightenScale(size: e.size, degrees: degrees)
        let turn = CGAffineTransform(translationX: -e.midX, y: -e.midY)
            .concatenating(CGAffineTransform(rotationAngle: degrees * .pi / 180))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: e.midX, y: e.midY))
        return picture.transformed(by: turn).cropped(to: e)
    }

    /// A shown picture straightened as the scan's frame is, for the crop's live ruler.
    func straightened(_ picture: CGImage, degrees: Double) -> CGImage? {
        let turned = Self.straighten(CIImage(cgImage: picture), degrees: degrees)
        return context.createCGImage(turned, from: turned.extent, format: .RGBA8,
                                     colorSpace: picture.colorSpace
                                        ?? CGColorSpace(name: CGColorSpace.displayP3)!)
    }

    private func atOrigin(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.minX,
                                                y: -image.extent.minY))
    }

    // MARK: - Film border

    /// Samples clear film around `point`, a unit point in the oriented, straightened, uncropped
    /// picture. Returns the linear border and the area it came from in the scan's own frame.
    func sampleBorder(at point: CGPoint, recipe: NegativeScanRecipe) throws
        -> (border: [Float], area: NegativeScanRecipe.Area) {
        let side = 0.03
        let shown = recipe.orientedSize(of: size)
        let point = recipe.unstraighten(point, orientedSize: shown)
        let w = side * Double(min(shown.width, shown.height)) / Double(shown.width)
        let h = side * Double(min(shown.width, shown.height)) / Double(shown.height)
        let oriented = NegativeScanRecipe.Area(
            x: Double(point.x) - w / 2, y: Double(point.y) - h / 2, width: w, height: h)
            .clamped(minimum: 0.001)
        let area = recipe.unorient(oriented)
        let border = try NegativeScanImport.sampleBorder(image: source(recipe.lightFrameID), rect: CGRect(
            x: area.x, y: area.y, width: area.width, height: area.height),
            colorSpace: NegativeScanImport.filmSpace)
        return ([border.x, border.y, border.z], area)
    }

    /// A stand-in for the film border until one is sampled: the thinnest film in the scan, read
    /// as the median of the percent that passes the most light across all three channels. An
    /// open holder in the frame passes more, which is why a sampled border replaces this.
    func estimatedBorder(lightFrameID: String? = nil) throws -> [Float] {
        let key = lightFrameID ?? ""
        if let estimate = lock.withLock({ estimates[key] }) { return estimate }
        let scale = min(1, 512 / max(size.width, size.height))
        let samples = try NegativeScanImport.samples(
            source(lightFrameID).transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
            colorSpace: NegativeScanImport.filmSpace)
        let film = (0..<samples.pixelCount).filter { i in
            (0..<3).allSatisfy { c in samples.planes[c][i].isFinite && samples.planes[c][i] > 0 }
        }
        guard !film.isEmpty else { throw NegativeScanImport.Failure.invalidBorder }
        let transmission = { (i: Int) -> Float in
            (0..<3).reduce(0) { $0 + log10(samples.planes[$1][i]) }
        }
        let brightest = film.sorted { transmission($0) > transmission($1) }
            .prefix(max(1, film.count / 100))
        let border = (0..<3).map { c -> Float in
            let values = brightest.map { samples.planes[c][$0] }.sorted()
            return values[values.count / 2]
        }
        lock.withLock { estimates[key] = border }
        return border
    }

    /// The border the recipe reads against: the sampled one, or the scan's own estimate.
    func border(for recipe: NegativeScanRecipe) throws -> [Float] {
        try recipe.border ?? estimatedBorder(lightFrameID: recipe.lightFrameID)
    }

    // MARK: - Frame

    /// Where the exposed picture sits in the recipe's straightened frame, as a crop; nil when it
    /// already fills the frame or none stands out.
    func detectedFrame(_ recipe: NegativeScanRecipe) throws -> NegativeScanRecipe.Area? {
        let border = try border(for: recipe)
        let samples = try NegativeScanImport.samples(
            frame(recipe, longEdge: 512, cropped: false), colorSpace: NegativeScanImport.filmSpace)
        return NegativeFrameDetection.imageArea(
            of: samples, border: SIMD3(border[0], border[1], border[2]))
            .map(NegativeScanRecipe.Area.init)
    }

    // MARK: - Printing

    /// What decides which part of the scan a picture shows, and how it is lit.
    private struct Framing: Hashable {
        var turns: Int, mirrored: Bool, straighten: Double, crop: [Double], light: String?
        var prepared: AnyHashable?

        init(_ scan: NegativeScan, _ recipe: NegativeScanRecipe) {
            prepared = scan.preparation(recipe)?.identity
            let crop = recipe.crop
            turns = recipe.quarterTurns
            mirrored = recipe.mirrored
            straighten = recipe.straighten
            self.crop = [crop.x, crop.y, crop.width, crop.height]
            light = recipe.lightFrameID
        }
    }

    private struct PlanKey: Hashable {
        var framing: Framing, monochrome: Bool
    }

    private struct BalanceKey: Hashable {
        var framing: Framing, border: [Float], stockID: String
    }

    private struct FrameKey: Equatable {
        var framing: Framing, cropped: Bool, longEdge: Int?, film: Bool
    }

    /// How the framed picture reads on the recipe's film, measured once per framing.
    private func balance(_ recipe: NegativeScanRecipe, stock: FilmStock,
                         border: [Float]) throws -> ApproximateNegativeScan.Balance {
        let key = BalanceKey(framing: Framing(self, recipe), border: border, stockID: recipe.stockID)
        lock.lock()
        if let balance = balances[key] { lock.unlock(); return balance }
        lock.unlock()
        let preview = try NegativeScanImport.samples(frame(recipe, longEdge: 512),
                                                     colorSpace: NegativeScanImport.filmSpace)
        let balance = ApproximateNegativeScan.balance(
            stock: stock, border: SIMD3(border[0], border[1], border[2]), preview: preview)
        lock.lock()
        balances[key] = balance
        lock.unlock()
        return balance
    }

    private func automaticPlan(_ recipe: NegativeScanRecipe) throws -> AutomaticNegativeScan {
        let key = PlanKey(framing: Framing(self, recipe), monochrome: recipe.monochrome)
        lock.lock()
        if let plan = plans[key] { lock.unlock(); return plan }
        lock.unlock()
        let plan = try NegativeScanImport.automaticPlan(
            image: frame(recipe, longEdge: 512), monochrome: recipe.monochrome)
        lock.lock()
        plans[key] = plan
        lock.unlock()
        return plan
    }

    /// Prints the recipe as a 16-bit Display P3 picture. `longEdge` nil is full resolution.
    /// A bounded print keeps its scan samples, so the next change of colour or film on the same
    /// framing does not read the scan again.
    func develop(_ recipe: NegativeScanRecipe, longEdge: Int?, cropped: Bool = true,
                 shouldContinue: (() -> Bool)? = nil) throws -> CGImage {
        // The app's preparation runs first, under the print's own stop, so a newer print need
        // not wait.
        if let preparation = preparation(recipe), preparation.prepare(shouldContinue) == nil {
            throw CancellationError()
        }
        let picture = frame(recipe, longEdge: longEdge, cropped: cropped)
        let width = Int(picture.extent.width), height = Int(picture.extent.height)
        guard width > 0, height > 0 else { throw Failure.render }
        let key = FrameKey(framing: Framing(self, recipe), cropped: cropped, longEdge: longEdge,
                           film: recipe.conversion == .film)
        // The automatic stage is defined on linear sRGB; a film reading wants every dye positive.
        let space = recipe.conversion == .film ? NegativeScanImport.filmSpace
                                               : NegativeScanImport.linearSpace
        let kept = longEdge == nil ? nil : previewSamples(picture, key: key, space: space)
        let readScan: (Range<Int>, UnsafeMutableBufferPointer<Float>) -> Void = { rows, into in
            if let kept {
                let start = rows.lowerBound * width * 4
                _ = into.update(fromContentsOf: kept[start..<(start + rows.count * width * 4)])
            } else {
                self.read(picture, rows: rows, into: into, space: space)
            }
        }

        let output = UnsafeMutableBufferPointer<UInt16>.allocate(capacity: width * height * 4)
        let finished: Bool
        switch recipe.conversion {
        case .automatic:
            finished = try developAutomatic(recipe, width: width, height: height,
                                            readScan: readScan, into: output,
                                            shouldContinue: shouldContinue)
        case .film:
            finished = try developFilm(recipe, width: width, height: height,
                                       readScan: readScan, into: output,
                                       shouldContinue: shouldContinue)
        }
        guard finished, let space = CGColorSpace(name: CGColorSpace.displayP3),
              let print = PrintEncoding.makeImage(takingOwnershipOf: output, width: width,
                                                  height: height, colorSpace: space)
        else {
            if !finished { output.deallocate() }
            throw Failure.render
        }
        return print
    }

    /// The last bounded framing's scan samples, read once.
    private func previewSamples(_ picture: CIImage, key: FrameKey,
                                space: CGColorSpace) -> [Float] {
        lock.lock()
        if let preview, preview.key == key {
            lock.unlock()
            return preview.samples
        }
        lock.unlock()
        let width = Int(picture.extent.width), height = Int(picture.extent.height)
        var samples = [Float](repeating: 0, count: width * height * 4)
        samples.withUnsafeMutableBufferPointer {
            read(picture, rows: 0..<height, into: $0, space: space)
        }
        lock.lock()
        preview = (key, samples, width, height)
        lock.unlock()
        return samples
    }

    private func developAutomatic(
        _ recipe: NegativeScanRecipe, width: Int, height: Int,
        readScan: (Range<Int>, UnsafeMutableBufferPointer<Float>) -> Void,
        into output: UnsafeMutableBufferPointer<UInt16>, shouldContinue: (() -> Bool)?
    ) throws -> Bool {
        let plan = try automaticPlan(recipe)
        let gains = recipe.displayGains(printingOn: nil)
        let tone = recipe.tone
        let band = 256
        var rgba = [Float](repeating: 0, count: band * width * 4)
        for top in stride(from: 0, to: height, by: band) {
            if shouldContinue?() == false { return false }
            let rows = top..<min(height, top + band)
            let count = rows.count * width
            rgba.withUnsafeMutableBufferPointer { readScan(rows, $0) }
            var scan = ImageBuffer(width: width, height: rows.count)
            for i in 0..<count { for c in 0..<3 { scan.planes[c][i] = rgba[i * 4 + c] } }
            let positive = try plan.convert(scan)
            for i in 0..<count {
                // The automatic stage delivers display sRGB primaries; the print is tagged P3.
                let rgb = ColorScience.linearSRGBToDisplayP3(tone.apply(SIMD3(
                    positive.planes[0][i], positive.planes[1][i], positive.planes[2][i]) * gains))
                rgba[i * 4] = rgb.x
                rgba[i * 4 + 1] = rgb.y
                rgba[i * 4 + 2] = rgb.z
                rgba[i * 4 + 3] = 1
            }
            rgba.withUnsafeBufferPointer {
                PrintEncoding.encodeRows($0, rows: rows, width: width, into: output)
            }
        }
        return true
    }

    private func developFilm(
        _ recipe: NegativeScanRecipe, width: Int, height: Int,
        readScan: (Range<Int>, UnsafeMutableBufferPointer<Float>) -> Void,
        into output: UnsafeMutableBufferPointer<UInt16>, shouldContinue: (() -> Bool)?
    ) throws -> Bool {
        let stock = try Self.film(recipe.stockID)
        let sampled = try border(for: recipe)
        let balance = try balance(recipe, stock: stock, border: sampled)
        let calibration = try ApproximateNegativeScan(
            stock: stock, border: SIMD3(sampled[0], sampled[1], sampled[2]), gains: balance.gains)
        let options = recipe.printOptions(for: stock, highlightStops: balance.highlightStops)
        guard let gpu = HalideMetalFilmRenderer.shared else { throw Failure.render }
        let gains = recipe.displayGains(printingOn: stock)
        let tone = recipe.tone
        let neutral = gains == SIMD3(repeating: 1) && tone.isNeutral
        var graded = [Float]()
        return gpu.printScan(
            width: width, height: height, stock: stock,
            options: options, calibration: calibration,
            shouldContinue: shouldContinue, readScan: readScan,
            writeRows: { rows, from in
                guard !neutral else {
                    return PrintEncoding.encodeRows(from, rows: rows, width: width, into: output,
                                                    transfer: .shoulderedSRGB)
                }
                graded.removeAll(keepingCapacity: true)
                graded.append(contentsOf: from)
                for i in stride(from: 0, to: graded.count, by: 4) {
                    graded[i] *= gains.x
                    graded[i + 1] *= gains.y
                    graded[i + 2] *= gains.z
                }
                tone.apply(rgba: &graded)
                graded.withUnsafeBufferPointer {
                    PrintEncoding.encodeRows($0, rows: rows, width: width, into: output,
                                             transfer: .shoulderedSRGB)
                }
            })
    }

    /// Reads rows of `picture`, counted from the top, as linear RGBA in `space`.
    private func read(_ picture: CIImage, rows: Range<Int>,
                      into buffer: UnsafeMutableBufferPointer<Float>, space: CGColorSpace) {
        let width = Int(picture.extent.width), height = Int(picture.extent.height)
        guard let base = buffer.baseAddress else { return }
        context.render(picture, toBitmap: base, rowBytes: width * 16,
                       bounds: CGRect(x: 0, y: height - rows.upperBound,
                                      width: width, height: rows.count),
                       format: .RGBAf, colorSpace: space)
    }

    // MARK: - Delivery

    enum Format: CaseIterable {
        case jpeg, tiff
        var type: UTType { self == .jpeg ? .jpeg : .tiff }
        var title: String { self == .jpeg ? "JPEG" : "16-bit TIFF" }
        var fileExtension: String { type.preferredFilenameExtension ?? "dat" }
    }

    /// The scan itself as the recipe frames it, for showing the negative beside its positive.
    func negative(_ recipe: NegativeScanRecipe, longEdge: Int, cropped: Bool = true) -> CGImage? {
        let picture = frame(recipe, longEdge: longEdge, cropped: cropped)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return context.createCGImage(picture, from: picture.extent, format: .RGBA8,
                                     colorSpace: space)
    }

    /// Writes a full-resolution print of the recipe to `url`.
    func export(_ recipe: NegativeScanRecipe, as format: Format, to url: URL,
                shouldContinue: (() -> Bool)? = nil) throws {
        let print = try develop(recipe, longEdge: nil, shouldContinue: shouldContinue)
        try? FileManager.default.removeItem(at: url)
        switch format {
        case .tiff:
            guard PrintEncoding.writeTIFF(print, to: url) else { throw Failure.render }
        case .jpeg:
            guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw Failure.render
            }
            CGImageDestinationAddImage(destination, print, [
                kCGImageDestinationLossyCompressionQuality: 0.95,
            ] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw Failure.render }
        }
    }
}
