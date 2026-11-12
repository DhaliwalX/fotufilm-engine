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
    /// Framings drawn down for their readings, with their average light, by their keys.
    private var frames: [(key: String, planes: ImageBuffer, light: SIMD3<Float>?)] = []
    /// What framings measure (`Measure`) net of the stray light a reading takes off, which
    /// every film reads.
    private var measures: [(key: String, measure: ApproximateNegativeScan.RollBalance.Measure)] = []
    /// The stray light the whole scan's holder shows, by clear film and light frame; none where
    /// it shows no holder.
    private var holders: [String: SIMD3<Float>?] = [:]
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
    /// (`ApproximateNegativeScan.estimatedBorder`), or with `filmBase`, as a reading through the
    /// scan's light and camera takes it, the film's base where the scan shows its bare light
    /// past the film (`ApproximateNegativeScan.estimatedFilmBase`).
    func estimatedBorder(light id: String?, filmBase: Bool = false) throws -> [Float] {
        let key = "\(id ?? "")|\(filmBase)"
        if let estimate = lock.withLock({ estimates[key] }) { return estimate }
        let preview = Self.preview(try image(light: id))
        guard let estimate = filmBase
            ? ApproximateNegativeScan.estimatedFilmBase(preview: preview)
            : ApproximateNegativeScan.estimatedBorder(preview: preview)
        else { throw Self.invalidBorder }
        let border = [estimate.x, estimate.y, estimate.z]
        lock.withLock { estimates[key] = border }
        return border
    }

    /// The stray light the whole scan's holder shows against `border`, under the light frame
    /// `id` (`ApproximateNegativeScan.strayLight`); nil where the scan shows no holder.
    func holderLight(border: SIMD3<Float>, light id: String?) throws -> SIMD3<Float>? {
        let key = "\(id ?? "")|\(border)"
        if let kept = lock.withLock({ holders[key] }) { return kept }
        let stray = ApproximateNegativeScan.strayLight(
            border: border, preview: Self.preview(try image(light: id)))
        lock.withLock {
            if holders.count >= 8 { holders.removeAll() }
            holders[key] = .some(stray)
        }
        return stray
    }

    /// The reading of a framing on `stock` as the edit's `negative` says to read it
    /// (`WebNativeEdit.Negative.balance`). What the framing measures is kept by `key` (the
    /// framing, border and light), so each film and each way of reading it takes it without
    /// drawing the scan again; `preview` is the framed scan, made only when none is kept, and
    /// `id` the light frame the scan is evened under.
    func reading(_ key: String, stock: FilmStock, border: [Float], light id: String? = nil,
                 negative: WebNativeEdit.Negative = .init(),
                 preview: () throws -> (rgba: [Float], width: Int, height: Int)) throws
        -> NegativeScanPrint.Reading {
        let read = try measure(key, border: border, light: id, negative: negative,
                               preview: preview)
        return try NegativeScanPrint.Reading(
            stock: stock, border: read.border,
            balance: negative.balance(stock: stock, border: read.border,
                                      denseEnd: read.measure.denseEnd, source: source,
                                      flare: read.flare),
            flare: read.flare)
    }

    /// What a framing measures for its reading and its roll: the clear film it is read against,
    /// the stray light the reading takes off (`WebNativeEdit.Negative.strayLight`), and, net of
    /// that, its own densest end, before any roll's colour, and the rises across its tonal
    /// steps. Arguments as `reading`.
    func measure(_ key: String, border: [Float], light id: String? = nil,
                 negative: WebNativeEdit.Negative = .init(),
                 preview: () throws -> (rgba: [Float], width: Int, height: Int)) throws
        -> (border: SIMD3<Float>, flare: SIMD3<Float>,
            measure: ApproximateNegativeScan.RollBalance.Measure) {
        guard border.count == 3, border.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw Self.invalidBorder
        }
        let border = SIMD3(border[0], border[1], border[2])
        let frame: (planes: ImageBuffer, light: SIMD3<Float>?)
        if let kept = lock.withLock({ frames.first { $0.key == key } }) {
            frame = (kept.planes, kept.light)
        } else {
            let framed = try preview()
            let planes = Self.planes(framed.rgba, width: framed.width, height: framed.height)
            frame = (planes, ApproximateNegativeScan.frameLight(preview: planes))
            lock.withLock {
                frames.removeAll { $0.key == key }
                frames.append((key, frame.planes, frame.light))
                if frames.count > 8 { frames.removeFirst() }
            }
        }
        // The holder is looked for only where the edit leaves the stray light to be measured.
        let holder = negative.readsModel && negative.flare == nil
            ? try holderLight(border: border, light: id) : nil
        let flare = negative.strayLight(border: border, frameLight: frame.light, holder: holder)
        let measured = "\(key)|\(flare)"
        if let kept = lock.withLock({ measures.first { $0.key == measured } }) {
            return (border, flare, kept.measure)
        }
        var planes = frame.planes
        if flare != .zero {
            for c in 0..<3 { for i in planes.planes[c].indices { planes.planes[c][i] -= flare[c] } }
        }
        let clear = border - flare
        let measure = ApproximateNegativeScan.RollBalance.Measure(
            denseEnd: ApproximateNegativeScan.denseEnd(border: clear, preview: planes),
            slopes: ApproximateNegativeScan.tonalSlopes(border: clear, preview: planes))
        lock.withLock {
            measures.removeAll { $0.key == measured }
            measures.append((measured, measure))
            if measures.count > 8 { measures.removeFirst() }
        }
        return (border, flare, measure)
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
        let read = try measure(key, border: border, light: id, negative: negative,
                               preview: preview)
        let positive = try prepared(
            light: id.flatMap(lightFrame),
            plain: negative.plain(border: read.border, denseEnd: read.measure.denseEnd,
                                  source: source, flare: read.flare))
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
