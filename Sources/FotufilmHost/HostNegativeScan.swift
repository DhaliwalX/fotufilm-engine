import Foundation
#if canImport(Dispatch)
import Dispatch
#endif
#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmEditModel)
import FotufilmEditModel
#endif
#if canImport(FotufilmImaging)
import FotufilmImaging
#endif

/// A scanned negative open for conversion in the desktop host, as the apps' `NegativeScan` holds
/// one: the decoded scan, never changed, and prints of it made to a `NegativeScanRecipe`. The
/// scan is linear Rec. 2020 in memory; turning, straightening, cropping, the light source and the
/// reductions are plain arithmetic here, so any platform that decodes a scan can print it.
final class HostNegativeScan {
    /// The scan as decoded: linear Rec. 2020 RGBA, with the reductions previews ask for kept.
    let scan: HostImage
    /// Camera RAW has no file profile to choose against linear samples.
    let isRAW: Bool
    /// The light frames the recipe may name, by id (`HostNegativeLightFrames`).
    let lightFrame: (String) -> NegativeLightFrame?

    private let lock = NSLock()
    private var plans: [PlanKey: AutomaticNegativeScan] = [:]
    private var balances: [BalanceKey: ApproximateNegativeScan.Balance] = [:]
    private var estimates: [String: [Float]] = [:]
    /// The newest framings, so a change of colour or film on the same framing reads no scan.
    private var framings: [(key: FramedKey, framed: Framed)] = []

    init(scan: HostImage, isRAW: Bool, lightFrame: @escaping (String) -> NegativeLightFrame?) {
        self.scan = scan
        self.isRAW = isRAW
        self.lightFrame = lightFrame
    }

    var width: Int { scan.width }
    var height: Int { scan.height }

    // MARK: - Framing

    /// Linear RGBA rows of the framed scan: Rec. 2020 for a film reading, sRGB for the automatic
    /// one (`NegativeScanPrint.readsWideGamut`).
    struct Framed {
        var rgba: [Float]
        var width: Int
        var height: Int
    }

    /// What decides which part of the scan a picture shows, and how it is lit.
    private struct Framing: Hashable {
        var turns: Int, mirrored: Bool, straighten: Double, crop: [Double], light: String?

        init(_ recipe: NegativeScanRecipe) {
            turns = ((recipe.quarterTurns % 4) + 4) % 4
            mirrored = recipe.mirrored
            straighten = recipe.straighten
            let crop = recipe.crop
            self.crop = [crop.x, crop.y, crop.width, crop.height]
            light = recipe.lightFrameID
        }
    }

    private struct FramedKey: Hashable {
        var framing: Framing, cropped: Bool, longEdge: Int?, wide: Bool
    }

    private struct PlanKey: Hashable {
        var framing: Framing, monochrome: Bool
    }

    private struct BalanceKey: Hashable {
        var framing: Framing, border: [Float], stockID: String
    }

    /// Where the framed picture sits: the oriented, straightened frame's size, the kept rectangle
    /// of it in pixels from the top left, and the size it is drawn at. Rounded as the apps'
    /// Core Image framing rounds, so both deliver the same pixel sizes.
    struct Layout {
        var oriented: (width: Double, height: Double)
        var left: Double, top: Double, keptWidth: Double, keptHeight: Double
        /// Output pixels per oriented pixel, at most 1.
        var scale: Double
        var width: Int, height: Int
    }

    static func layout(scanWidth: Int, scanHeight: Int, recipe: NegativeScanRecipe,
                       longEdge: Int?, cropped: Bool) -> Layout {
        let turned = !recipe.quarterTurns.isMultiple(of: 2)
        let ow = Double(turned ? scanHeight : scanWidth)
        let oh = Double(turned ? scanWidth : scanHeight)
        var left = 0.0, top = 0.0, kw = ow, kh = oh
        if cropped {
            // Core Image's integral rectangle, y up, intersected with the frame.
            let crop = recipe.crop.clamped()
            let x = crop.x * ow, y = (1 - crop.y - crop.height) * oh
            let minX = max(0, x.rounded(.down)), minY = max(0, y.rounded(.down))
            let maxX = min(ow, (x + crop.width * ow).rounded(.up))
            let maxY = min(oh, (y + crop.height * oh).rounded(.up))
            left = minX
            top = oh - maxY
            kw = max(1, maxX - minX)
            kh = max(1, maxY - minY)
        }
        var scale = 1.0, width = Int(kw), height = Int(kh)
        if let longEdge {
            scale = min(1, Double(longEdge) / max(1, max(kw, kh)))
            if scale < 1 {
                width = max(1, Int((kw * scale).rounded(.down)))
                height = max(1, Int((kh * scale).rounded(.down)))
            }
        }
        return Layout(oriented: (ow, oh), left: left, top: top, keptWidth: kw, keptHeight: kh,
                      scale: scale, width: width, height: height)
    }

    /// The scan turned, flipped and straightened as the recipe shows it, cropped unless `cropped`
    /// is false, drawn down to `longEdge`, with the recipe's light source evened out.
    func frame(_ recipe: NegativeScanRecipe, longEdge: Int?, cropped: Bool = true,
               wide: Bool) -> Framed {
        let key = FramedKey(framing: Framing(recipe), cropped: cropped, longEdge: longEdge,
                            wide: wide)
        if let kept = lock.withLock({ framings.first { $0.key == key }?.framed }) { return kept }
        let framed = Self.frame(scan, recipe: recipe, longEdge: longEdge, cropped: cropped,
                                wide: wide, light: recipe.lightFrameID.flatMap(lightFrame))
        // Full-resolution framings are delivered once; keeping them would hold the scan twice.
        if longEdge != nil {
            lock.withLock {
                framings.removeAll { $0.key == key }
                framings.append((key, framed))
                if framings.count > 3 { framings.removeFirst() }
            }
        }
        return framed
    }

    /// Frames `scan` for `recipe`: every output pixel's centre is followed back through the crop,
    /// the straightening, the turns and the flip to the scan, and read bilinearly from a copy of
    /// the scan reduced to the output's scale, so a drawn-down picture keeps its area means.
    static func frame(_ scan: HostImage, recipe: NegativeScanRecipe, longEdge: Int?,
                      cropped: Bool, wide: Bool, light: NegativeLightFrame?) -> Framed {
        let layout = layout(scanWidth: scan.width, scanHeight: scan.height, recipe: recipe,
                            longEdge: longEdge, cropped: cropped)
        let (width, height) = (layout.width, layout.height)
        // The scan at the output's scale; the straightening's enlargement is too small to alias.
        let sw = max(1, Int((Double(scan.width) * layout.scale).rounded()))
        let sh = max(1, Int((Double(scan.height) * layout.scale).rounded()))
        let source = scan.scene(width: sw, height: sh)

        // Output pixel → scan unit point is affine: the unit maps of turning and straightening
        // are linear, so three points fix it.
        let oriented = CGSize(width: layout.oriented.width, height: layout.oriented.height)
        func scanPoint(_ px: Double, _ py: Double) -> (x: Double, y: Double) {
            let u = (layout.left + px / layout.scale) / layout.oriented.width
            let v = (layout.top + py / layout.scale) / layout.oriented.height
            let p = recipe.unorient(recipe.unstraighten(CGPoint(x: u, y: v), orientedSize: oriented))
            return (Double(p.x), Double(p.y))
        }
        let origin = scanPoint(0, 0), right = scanPoint(1, 0), down = scanPoint(0, 1)
        let dxdx = right.x - origin.x, dydx = right.y - origin.y
        let dxdy = down.x - origin.x, dydy = down.y - origin.y
        let identity = light == nil && width == sw && height == sh
            && abs(origin.x) < 1e-12 && abs(origin.y) < 1e-12
            && abs(dxdx * Double(sw) - 1) < 1e-9 && abs(dydy * Double(sh) - 1) < 1e-9
            && dydx == 0 && dxdy == 0

        var rgba = [Float](repeating: 1, count: width * height * 4)
        if identity, wide {
            rgba = source
        } else {
            rgba.withUnsafeMutableBufferPointer { out in
                source.withUnsafeBufferPointer { src in
                    concurrentRows(height) { rows in
                        for y in rows {
                            for x in 0..<width {
                                let px = Double(x) + 0.5, py = Double(y) + 0.5
                                let ux = origin.x + dxdx * px + dxdy * py
                                let uy = origin.y + dydx * px + dydy * py
                                var rgb = identity
                                    ? pixel(src, width: sw, x, y)
                                    : bilinear(src, width: sw, height: sh,
                                               x: Float(ux * Double(sw) - 0.5),
                                               y: Float(uy * Double(sh) - 0.5))
                                if let light {
                                    // The light is measured, and divides out, in linear sRGB.
                                    rgb = AutomaticNegativeScan.rec2020ToSRGB(rgb)
                                        / light.gain(x: Float(ux), y: Float(uy))
                                    if wide { rgb = ColorScience.linearSRGBToRec2020(rgb) }
                                } else if !wide {
                                    rgb = AutomaticNegativeScan.rec2020ToSRGB(rgb)
                                }
                                let i = (y * width + x) * 4
                                out[i] = rgb.x
                                out[i + 1] = rgb.y
                                out[i + 2] = rgb.z
                            }
                        }
                    }
                }
            }
        }
        return Framed(rgba: rgba, width: width, height: height)
    }

    @inline(__always)
    private static func pixel(_ src: UnsafeBufferPointer<Float>, width: Int, _ x: Int,
                              _ y: Int) -> SIMD3<Float> {
        let i = (y * width + x) * 4
        return SIMD3(src[i], src[i + 1], src[i + 2])
    }

    @inline(__always)
    private static func bilinear(_ src: UnsafeBufferPointer<Float>, width: Int, height: Int,
                                 x: Float, y: Float) -> SIMD3<Float> {
        let fx = min(max(x, 0), Float(width - 1)), fy = min(max(y, 0), Float(height - 1))
        let x0 = Int(fx), y0 = Int(fy)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let tx = fx - Float(x0), ty = fy - Float(y0)
        let top = pixel(src, width: width, x0, y0) * (1 - tx) + pixel(src, width: width, x1, y0) * tx
        let bottom = pixel(src, width: width, x0, y1) * (1 - tx)
            + pixel(src, width: width, x1, y1) * tx
        return top * (1 - ty) + bottom * ty
    }

    /// Runs `body` over bands of rows on the worker pool.
    static func concurrentRows(_ count: Int, _ body: (Range<Int>) -> Void) {
        let band = 32
        let bands = (count + band - 1) / band
        guard bands > 1 else { return body(0..<count) }
        DispatchQueue.concurrentPerform(iterations: bands) { index in
            body(index * band..<min(count, (index + 1) * band))
        }
    }

    // MARK: - Film border

    /// Samples clear film over `area`, a unit rectangle of the oriented, straightened, uncropped
    /// picture. Returns the linear Rec. 2020 border and the area it came from in the scan's own
    /// frame, as the apps keep it (`NegativeScanRecipe.borderArea`).
    func sampleBorder(_ area: NegativeScanRecipe.Area, recipe: NegativeScanRecipe) throws
        -> (border: [Float], area: NegativeScanRecipe.Area) {
        let shown = recipe.orientedSize(of: CGSize(width: width, height: height))
        let corners = [(area.x, area.y), (area.x + area.width, area.y),
                       (area.x, area.y + area.height), (area.x + area.width, area.y + area.height)]
            .map { recipe.unorient(recipe.unstraighten(CGPoint(x: $0.0, y: $0.1), orientedSize: shown)) }
        let xs = corners.map { Double($0.x) }, ys = corners.map { Double($0.y) }
        let own = NegativeScanRecipe.Area(x: xs.min()!, y: ys.min()!,
                                          width: xs.max()! - xs.min()!,
                                          height: ys.max()! - ys.min()!).clamped(minimum: 0.001)
        return (try border(in: own, light: recipe.lightFrameID), own)
    }

    /// The median clear film over `area` of the scan's own frame, each channel read from the
    /// positive, finite samples, which must be nine in ten of them
    /// (`NegativeScanImport.sampleBorder`).
    func border(in area: NegativeScanRecipe.Area, light id: String?) throws -> [Float] {
        let x0 = max(0, Int((area.x * Double(width)).rounded(.down)))
        let y0 = max(0, Int((area.y * Double(height)).rounded(.down)))
        let x1 = min(width, Int(((area.x + area.width) * Double(width)).rounded(.up)))
        let y1 = min(height, Int(((area.y + area.height) * Double(height)).rounded(.up)))
        guard x1 - x0 >= 2, y1 - y0 >= 2 else { throw HostNegativeScan.invalidBorder }
        // At most 128 samples a side, as the apps read the patch drawn down.
        let step = max(1, Double(max(x1 - x0, y1 - y0)) / 128)
        let columns = max(1, Int(Double(x1 - x0) / step)), rows = max(1, Int(Double(y1 - y0) / step))
        let light = id.flatMap(lightFrame)
        let full = scan.scene(width: width, height: height)
        var channels = [[Float]](repeating: [], count: 3)
        for row in 0..<rows {
            let y = min(y1 - 1, y0 + Int((Double(row) + 0.5) * step))
            for column in 0..<columns {
                let x = min(x1 - 1, x0 + Int((Double(column) + 0.5) * step))
                let i = (y * width + x) * 4
                var rgb = SIMD3(full[i], full[i + 1], full[i + 2])
                if let light {
                    rgb = ColorScience.linearSRGBToRec2020(AutomaticNegativeScan.rec2020ToSRGB(rgb)
                        / light.gain(x: (Float(x) + 0.5) / Float(width),
                                     y: (Float(y) + 0.5) / Float(height)))
                }
                for c in 0..<3 where rgb[c].isFinite && rgb[c] > 0 { channels[c].append(rgb[c]) }
            }
        }
        let count = rows * columns
        return try channels.map { values in
            guard values.count >= count * 9 / 10, !values.isEmpty else {
                throw HostNegativeScan.invalidBorder
            }
            return values.sorted()[values.count / 2]
        }
    }

    static let invalidBorder = HostEngine.Failure(description: "Sample a larger area of clear, unexposed film. Avoid the holder, sprocket holes, lettering and image detail.")

    /// A stand-in for the film border until one is sampled: the thinnest film of the whole scan
    /// (`ApproximateNegativeScan.estimatedBorder`).
    func estimatedBorder(light id: String?) throws -> [Float] {
        let key = id ?? ""
        if let estimate = lock.withLock({ estimates[key] }) { return estimate }
        var whole = NegativeScanRecipe()
        whole.lightFrameID = id
        let preview = frame(whole, longEdge: 512, cropped: false, wide: true)
        guard let estimate = ApproximateNegativeScan.estimatedBorder(
            preview: Self.planes(preview)) else { throw HostNegativeScan.invalidBorder }
        let border = [estimate.x, estimate.y, estimate.z]
        lock.withLock { estimates[key] = border }
        return border
    }

    /// The border the recipe reads against: the sampled one, or the scan's own estimate.
    func border(for recipe: NegativeScanRecipe) throws -> [Float] {
        try recipe.border ?? estimatedBorder(light: recipe.lightFrameID)
    }

    /// Where the exposed picture sits in the recipe's straightened frame, as a crop; nil when it
    /// already fills the frame or none stands out.
    func detectedFrame(_ recipe: NegativeScanRecipe) throws -> NegativeScanRecipe.Area? {
        let border = try border(for: recipe)
        let preview = frame(recipe, longEdge: 512, cropped: false, wide: true)
        return NegativeFrameDetection.imageArea(of: Self.planes(preview),
                                                border: SIMD3(border[0], border[1], border[2]))
            .map(NegativeScanRecipe.Area.init)
    }

    static func planes(_ framed: Framed) -> ImageBuffer {
        var buffer = ImageBuffer(width: framed.width, height: framed.height)
        for i in 0..<(framed.width * framed.height) {
            for c in 0..<3 { buffer.planes[c][i] = framed.rgba[i * 4 + c] }
        }
        return buffer
    }

    // MARK: - Printing

    private func automaticPlan(_ recipe: NegativeScanRecipe) throws -> AutomaticNegativeScan {
        let key = PlanKey(framing: Framing(recipe), monochrome: recipe.monochrome)
        if let plan = lock.withLock({ plans[key] }) { return plan }
        let plan = try AutomaticNegativeScan(
            preview: Self.planes(frame(recipe, longEdge: 512, wide: false)),
            monochrome: recipe.monochrome)
        lock.withLock { plans[key] = plan }
        return plan
    }

    private func balance(_ recipe: NegativeScanRecipe, stock: FilmStock,
                         border: [Float]) -> ApproximateNegativeScan.Balance {
        let key = BalanceKey(framing: Framing(recipe), border: border, stockID: recipe.stockID)
        if let balance = lock.withLock({ balances[key] }) { return balance }
        let balance = ApproximateNegativeScan.balance(
            stock: stock, border: SIMD3(border[0], border[1], border[2]),
            preview: Self.planes(frame(recipe, longEdge: 512, wide: true)))
        lock.withLock { balances[key] = balance }
        return balance
    }

    /// Prints the recipe as display-linear Display P3 RGBA. `longEdge` nil is full resolution.
    func print(_ recipe: NegativeScanRecipe, longEdge: Int?, cropped: Bool = true,
               engine: HostEngine) throws -> Framed {
        switch recipe.conversion {
        case .automatic:
            let plan = try automaticPlan(recipe)
            var framed = frame(recipe, longEdge: longEdge, cropped: cropped, wide: false)
            let band = 512
            try framed.rgba.withUnsafeMutableBufferPointer { rgba in
                for top in stride(from: 0, to: framed.height, by: band) {
                    let rows = min(band, framed.height - top)
                    try NegativeScanPrint.printAutomatic(
                        UnsafeMutableBufferPointer(rebasing: rgba[(top * framed.width * 4)...]),
                        width: framed.width, rows: rows, plan: plan, recipe: recipe)
                }
            }
            return framed
        case .film:
            let stock = try NegativeScanPrint.film(recipe.stockID)
            let border = try border(for: recipe)
            let film = try NegativeScanPrint.film(
                recipe, stock: stock, border: border,
                balance: balance(recipe, stock: stock, border: border))
            let scan = frame(recipe, longEdge: longEdge, cropped: cropped, wide: true)
            let (width, height) = (scan.width, scan.height)
            var printed = [Float](repeating: 1, count: width * height * 4)
            var graded = [Float]()
            try engine.printScan(
                width: width, height: height, stock: stock, options: film.options,
                calibration: film.calibration,
                readScan: { rows, into in
                    let start = rows.lowerBound * width * 4
                    scan.rgba.withUnsafeBufferPointer {
                        into.baseAddress!.update(from: $0.baseAddress! + start,
                                                 count: rows.count * width * 4)
                    }
                },
                writeRows: { rows, from in
                    let start = rows.lowerBound * width * 4, count = rows.count * width * 4
                    if film.isNeutral {
                        printed.withUnsafeMutableBufferPointer {
                            ($0.baseAddress! + start).update(from: from.baseAddress!, count: count)
                        }
                        return
                    }
                    graded.removeAll(keepingCapacity: true)
                    graded.append(contentsOf: UnsafeBufferPointer(rebasing: from[0..<count]))
                    film.grade(&graded)
                    printed.replaceSubrange(start..<(start + count), with: graded)
                })
            return Framed(rgba: printed, width: width, height: height)
        }
    }

    /// A display-linear print as the 8-bit Display P3 picture the screen shows: the SDR shoulder
    /// and the sRGB transfer, as the apps encode a print.
    static func encode8(_ print: Framed) -> [UInt8] {
        DisplayEncoding.encode8(print.rgba, width: print.width, height: print.height,
                                knee: FilmSDRDelivery.boundedShoulderKnee, seed: 0)
    }

    /// A display-linear print as scene-linear Rec. 2020, the photograph the editor opens: the
    /// print's shoulder applied, so it reads as the apps' delivered file does.
    static func positive(_ print: Framed) -> [Float] {
        var rgba = print.rgba
        concurrentRows(print.height) { rows in
            for i in rows.lowerBound * print.width..<rows.upperBound * print.width {
                var p3 = SIMD3<Float>()
                for c in 0..<3 {
                    let value = rgba[i * 4 + c]
                    p3[c] = ColorScience.displayShoulder(value.isFinite ? max(value, 0) : 0,
                                                         knee: FilmSDRDelivery.boundedShoulderKnee)
                }
                let rec2020 = ColorScience.linearDisplayP3ToRec2020(p3)
                rgba[i * 4] = rec2020.x
                rgba[i * 4 + 1] = rec2020.y
                rgba[i * 4 + 2] = rec2020.z
                rgba[i * 4 + 3] = 1
            }
        }
        return rgba
    }
}
