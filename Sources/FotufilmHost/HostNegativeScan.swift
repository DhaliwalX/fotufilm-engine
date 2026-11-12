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

/// A scanned negative open in the editor: the decoded scan, never changed, and what reading it as
/// a film needs. The editor frames it like any photograph; each develop reads the framed scan as
/// the edit's film and prints it (`NegativeScanPrint.Reading`). The scan is linear Rec. 2020.
final class HostNegativeScan {
    /// The scan as decoded.
    let scan: HostImage
    /// The light frames an edit may name, by id (`HostNegativeLightFrames`).
    let lightFrame: (String) -> NegativeLightFrame?
    /// What the scan's file says of its camera and of how it was decoded, nil where its decoder
    /// does not say: the readings then take a generic camera's channels.
    let source: NegativeScanSource?

    private let lock = NSLock()
    /// The scan evened under the newest light frame it was asked for.
    private var lit: (id: String, image: HostImage)?
    private var estimates: [String: [Float]] = [:]
    /// What framings measure (`Measure`), which every film reads.
    private var measures: [(key: String, measure: ApproximateNegativeScan.RollBalance.Measure)] = []
    /// The newest plain positive asked for (`positive`), by its framing's key.
    private var plain: (key: String, image: HostImage)?

    init(scan: HostImage, source: NegativeScanSource? = nil,
         lightFrame: @escaping (String) -> NegativeLightFrame?) {
        self.scan = scan
        self.source = source
        self.lightFrame = lightFrame
    }

    /// The scan with the light source's unevenness divided out, or as decoded when the edit names
    /// no light frame, or one no longer kept.
    func image(light id: String?) throws -> HostImage {
        guard let id, let light = lightFrame(id) else { return scan }
        if let lit = lock.withLock({ lit }), lit.id == id { return lit.image }
        let image = try prepared(light: light, plain: nil)
        lock.withLock { lit = (id, image) }
        return image
    }

    /// The scan prepared by the engine (`NegativeScanPreparation`).
    private func prepared(light: NegativeLightFrame?, plain: PlainNegativeScan?) throws -> HostImage {
        let (width, height) = (scan.width, scan.height)
        var rgba = scan.scene(width: width, height: height)
        try NegativeScanPreparation.prepare(
            &rgba, width: width, height: height,
            light: light.map { ($0.width, $0.height, $0.gains) }, plain: plain)
        return HostImage(rgba: rgba, width: width, height: height, contentHeadroom: 1)
    }

    /// A stand-in for the film border until one is sampled: the thinnest film of the whole scan
    /// (`ApproximateNegativeScan.estimatedBorder`).
    func estimatedBorder(light id: String?) throws -> [Float] {
        let key = id ?? ""
        if let estimate = lock.withLock({ estimates[key] }) { return estimate }
        guard let estimate = ApproximateNegativeScan.estimatedBorder(
            preview: Self.preview(try image(light: id)))
        else { throw Self.invalidBorder }
        let border = [estimate.x, estimate.y, estimate.z]
        lock.withLock { estimates[key] = border }
        return border
    }

    /// The reading of a framing on `stock` as the edit's `negative` says to read it
    /// (`WebNativeEdit.Negative.balance`). What the framing measures is kept by `key` (the
    /// framing, border and light), so each film and each way of reading it takes it without
    /// drawing the scan again; `preview` is the framed scan, made only when none is kept.
    func reading(_ key: String, stock: FilmStock, border: [Float],
                 negative: WebNativeEdit.Negative = .init(),
                 preview: () throws -> (rgba: [Float], width: Int, height: Int)) throws
        -> NegativeScanPrint.Reading {
        let (border, measure) = try measure(key, border: border, preview: preview)
        return try NegativeScanPrint.Reading(
            stock: stock, border: border,
            balance: negative.balance(stock: stock, border: border, denseEnd: measure.denseEnd,
                                      source: source))
    }

    /// What a framing measures for its roll: the clear film it is read against, its own densest
    /// end, before any roll's colour, and the rises across its tonal steps. Arguments as
    /// `reading`.
    func measure(_ key: String, border: [Float],
                 preview: () throws -> (rgba: [Float], width: Int, height: Int)) throws
        -> (border: SIMD3<Float>, measure: ApproximateNegativeScan.RollBalance.Measure) {
        guard border.count == 3, border.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw Self.invalidBorder
        }
        let border = SIMD3(border[0], border[1], border[2])
        if let kept = lock.withLock({ measures.first { $0.key == key } }) {
            return (border, kept.measure)
        }
        let framed = try preview()
        let planes = Self.planes(framed.rgba, width: framed.width, height: framed.height)
        let measure = ApproximateNegativeScan.RollBalance.Measure(
            denseEnd: ApproximateNegativeScan.denseEnd(border: border, preview: planes),
            slopes: ApproximateNegativeScan.tonalSlopes(border: border, preview: planes))
        lock.withLock {
            measures.removeAll { $0.key == key }
            measures.append((key, measure))
            if measures.count > 8 { measures.removeFirst() }
        }
        return (border, measure)
    }

    /// The scan read without a film (`PlainNegativeScan`), evened under the light frame `light`:
    /// a scene-linear positive of the whole scan, which the editor frames and develops as it does
    /// any photograph, read as the edit's `negative` says (`WebNativeEdit.Negative.plain`).
    /// Arguments as `reading`.
    func positive(_ key: String, border: [Float], light id: String?,
                  negative: WebNativeEdit.Negative = .init(),
                  preview: () throws -> (rgba: [Float], width: Int, height: Int)) throws -> HostImage {
        let plainKey = "\(key)|\(negative.readingKey)"
        if let kept = lock.withLock({ plain }), kept.key == plainKey { return kept.image }
        let (border, measure) = try measure(key, border: border, preview: preview)
        let positive = try prepared(
            light: id.flatMap(lightFrame),
            plain: negative.plain(border: border, denseEnd: measure.denseEnd, source: source))
        lock.withLock { plain = (plainKey, positive) }
        return positive
    }

    /// `rgba` drawn down to the readings' 512 pixels by area: the readings take a scan's extremes,
    /// which a sharper resampler's ringing at hard edges would push past any pixel of the scan.
    static func preview(_ rgba: [Float], width: Int, height: Int) -> (rgba: [Float], width: Int, height: Int) {
        let size = AreaResample.size(width: width, height: height, maxEdge: 512)
        return (AreaResample.reduce(rgba, width: width, height: height, to: size.width, size.height),
                size.width, size.height)
    }

    /// The whole scan, drawn down for its readings (`preview(_:width:height:)`).
    static func preview(_ image: HostImage) -> ImageBuffer {
        let reduced = preview(image.scene(width: image.width, height: image.height),
                              width: image.width, height: image.height)
        return planes(reduced.rgba, width: reduced.width, height: reduced.height)
    }

    /// The median clear film over a patch of framed scan RGBA, each channel read from the
    /// positive, finite samples, which must be nine in ten of them.
    static func border(_ rgba: [Float], width: Int, height: Int,
                       x0: Int, y0: Int, x1: Int, y1: Int) throws -> [Float] {
        let x0 = max(0, x0), y0 = max(0, y0), x1 = min(width, x1), y1 = min(height, y1)
        guard x1 - x0 >= 2, y1 - y0 >= 2 else { throw invalidBorder }
        var channels = [[Float]](repeating: [], count: 3)
        for y in y0..<y1 {
            for x in x0..<x1 {
                let i = (y * width + x) * 4
                for c in 0..<3 where rgba[i + c].isFinite && rgba[i + c] > 0 {
                    channels[c].append(rgba[i + c])
                }
            }
        }
        let count = (x1 - x0) * (y1 - y0)
        return try channels.map { values in
            guard values.count >= count * 9 / 10, !values.isEmpty else { throw invalidBorder }
            return values.sorted()[values.count / 2]
        }
    }

    static let invalidBorder = HostEngine.Failure(description: "Pick clear, unexposed film: the gap between frames or the film's edge, away from the holder, sprocket holes and lettering.")

    static func planes(_ rgba: [Float], width: Int, height: Int) -> ImageBuffer {
        var buffer = ImageBuffer(width: width, height: height)
        for i in 0..<(width * height) {
            for c in 0..<3 { buffer.planes[c][i] = rgba[i * 4 + c] }
        }
        return buffer
    }
}
