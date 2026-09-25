import Foundation
import FotufilmHalide

/// The fast road for `FilmGrain`: the film rendered once, sampled many times.
///
/// Rendering every crystal of a frame costs its film area, whatever the output size. But grain is
/// stationary: at one developed density, any patch of the emulation's film is statistically every
/// other. So each record is rendered by the reference model once, on a seamless square of film
/// `tileSide` texels of `tileTexelMM` a side, at `tileLevels` gross densities from D-min to D-max.
/// A texel is fine enough that the reference has converged there (its 48 µm granularity reads the
/// same at a quarter of the spacing). The same crystals are drawn at every level, so a denser
/// level is the lighter one with more of its crystals developed, and neighbouring levels blend
/// coherently.
///
/// **Pixels still average light, and still sample the film.** Each level keeps the running sum of
/// its transmittance less its mean — a summed-area table, periodic like the tile — so the light
/// through any rectangle of film is four lookups, exactly, whatever its size or position. A
/// pixel's density is `-log10` of the light its footprint passes. A render at any pitch samples
/// the same film, and averaging a fine render back as light gives the coarse one.
///
/// **No repeat shows.** The frame is cut into blocks `tileBlockMM` a side; each block takes the
/// tile at its own hashed offset and one of the eight flips and turns of the square, per record
/// and per frame seed. Grain decorrelates within microns, so the block seams are invisible, and
/// nothing repeats at the tile's period. The tiles themselves are the stock's, rendered once:
/// another seed is another placement of the same coating, as another frame of the roll is.
///
/// **The tone stays the curve's.** The mean density a footprint reads depends on its size and on
/// where its edges fall against the texels — light averages, density does not — so for each
/// frame's pitch the host reads every level's mean through footprints laid exactly as the
/// frame's pixels are, and a pixel's grain is its density less that mean. Between the two levels
/// either side of its developed density the pixel blends their grain, renormalised by the two
/// fields' correlation at that pitch so the blend keeps the levels' variance.
///
/// The same arithmetic runs in the Halide kernel (`Stages/FilmTiles.h`), which reads the tiles
/// `register` hands it and the tables `configurationBlock` packs.
extension FilmGrain {
    /// Side of one tile texel, mm.
    public static let tileTexelMM: Float = 0.001
    /// Texels per tile side.
    public static let tileSide = 256
    /// Gross densities rendered per record, D-min to D-max.
    public static let tileLevels = 17
    /// Side of the film blocks that each take the tile at their own offset and orientation, mm.
    public static let tileBlockMM: Float = 0.064
    /// The coating the tiles render: one per stock, whatever the frame's seed.
    static let tileSeed: UInt64 = 0xA11C_4057_5EED_0001
    /// Hash stream of the block placement, per record: the kernel's `kFilmTileStream`.
    static let tileStream: UInt32 = 200

    /// One record's tile at one gross density.
    public struct TileLevel: Sendable {
        /// `(tileSide + 1)²` running sums of transmittance less `meanLight`, row-major, with a
        /// zero first row and column.
        public var sums: [Float]
        public var meanLight: Float
    }

    /// What one frame's pitch needs from the tiles, per record: each level's mean density
    /// through the frame's footprints, and between neighbouring levels the correlation of their
    /// grain there, which the blend divides out to keep their variance.
    public struct PitchTables: Sendable {
        public var meanDensity: [[Float]]
        public var blendCorrelation: [[Float]]
    }

    public final class Tiles: @unchecked Sendable {
        /// Per record (empty where the record lays no grain), `tileLevels` levels.
        public let levels: [[TileLevel]]
        public let dMin: [Float]
        public let dMax: [Float]
        private let lock = NSLock()
        private var pitches: [(pitch: Float, tables: PitchTables)] = []
        init(levels: [[TileLevel]], dMin: [Float], dMax: [Float]) {
            self.levels = levels
            self.dMin = dMin
            self.dMax = dMax
        }

        /// The tables of `pitch` texels, measured on first use; a frame keeps its pitch, so the
        /// last few are kept.
        func tables(pitch: Float, measure: () -> PitchTables) -> PitchTables {
            lock.lock()
            if let hit = pitches.first(where: { $0.pitch == pitch }) { lock.unlock(); return hit.tables }
            lock.unlock()
            let measured = measure()
            lock.lock()
            pitches.removeAll { $0.pitch == pitch }
            pitches.append((pitch, measured))
            if pitches.count > 8 { pitches.removeFirst() }
            lock.unlock()
            return measured
        }

        /// Every level's running sums as the kernel indexes them: `(tileSide + 1)²` entries, then
        /// `tileLevels` levels, then three records, innermost first. A record that lays no grain
        /// is zeros, which the kernel never reads.
        public func packed() -> [Float] {
            let entries = (FilmGrain.tileSide + 1) * (FilmGrain.tileSide + 1)
            var out = [Float](repeating: 0, count: entries * FilmGrain.tileLevels * 3)
            for r in 0..<3 {
                for (k, level) in levels[r].enumerated() {
                    let start = (r * FilmGrain.tileLevels + k) * entries
                    out.replaceSubrange(start..<(start + entries), with: level.sums)
                }
            }
            return out
        }
    }

    private final class TileCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(key: String, tiles: Tiles)] = []
        func tiles(_ key: String, build: () throws -> Tiles) rethrows -> Tiles {
            lock.lock()
            if let hit = entries.first(where: { $0.key == key }) { lock.unlock(); return hit.tiles }
            lock.unlock()
            let built = try build()
            lock.lock()
            entries.removeAll { $0.key == key }
            entries.append((key, built))
            if entries.count > 4 { entries.removeFirst() }
            lock.unlock()
            return built
        }
    }

    private static let tileCache = TileCache()

    /// This population's tiles, rendered on first use.
    public func tiles() -> Tiles {
        tiles(checkCancellation: {})
    }

    func tiles(checkCancellation: () throws -> Void) rethrows -> Tiles {
        try checkCancellation()
        return try assetTiles ?? Self.tileCache.tiles(key) {
            try buildTiles(seed: Self.tileSeed, checkCancellation: checkCancellation)
        }
    }

    /// Transmittance of one record's tile at `gross`, `tileSide²` texels.
    func tileLight(record r: Int, gross: Float, seed: UInt64) -> [Float] {
        builtLights(record: r, grosses: [gross], seed: seed)?[0]
            ?? referenceTileLight(record: r, gross: gross, seed: seed)
    }

    /// The same tile laid by the Swift reference.
    func referenceTileLight(record r: Int, gross: Float, seed: UInt64) -> [Float] {
        let side = Self.tileSide
        let pxPerMM = 1 / Self.tileTexelMM
        var unused = [Float]()
        let field = render(record: r, width: side, height: side, pxPerMM: pxPerMM,
                           supersample: Self.supersample(pxPerMM: pxPerMM), seed: seed,
                           grossAt: { _, _ in gross }, pointMeans: &unused,
                           wantPointMeans: false, periodMM: Float(side) * Self.tileTexelMM)
        return field.map { pow(10, -$0) }
    }

    /// What lays dye-cloud tiles faster than the Swift reference.
    enum TileBuilder: Equatable {
        /// Hand-written Metal, on every Apple platform.
        case metal
        /// The Halide builder on the CPU, where the Halide compiler is linked.
        case halide
    }

    /// One sublayer of a tile build: cells along a tile side, peak demand over capacity, capacity,
    /// the count thresholds `FilmRandom.countThresholds` gives and the developed fraction at each
    /// level.
    struct TileSublayer {
        var cells: Int
        var edge: Float
        var capacity: Float
        var thresholds: [Float]
        var fractions: [Float]
    }

    /// Builders tried in turn; the Swift reference lays whatever they cannot.
    /// `FOTUFILM_FILM_TILE_BUILD` = `metal`, `halide` or `swift` holds it to one.
    static let tileBuilders: [TileBuilder] = {
        switch ProcessInfo.processInfo.environment["FOTUFILM_FILM_TILE_BUILD"] {
        case "swift": return []
        case "metal": return [.metal]
        case "halide": return [.halide]
        default: return [.metal, .halide]
        }
    }()

    /// Light of a dye-cloud record's tile at each of `grosses`, `tileSide²` texels each, laid by
    /// the first of `builders` that can — the same crystals `renderTile` lays, on a tile that
    /// wraps. Nil where none can, which the Swift reference then does.
    func builtLights(record r: Int, grosses: [Float], seed: UInt64,
                     builders: [TileBuilder] = FilmGrain.tileBuilders) -> [[Float]]? {
        let record = records[r]
        let sublayerSlots = 4
        guard !builders.isEmpty, !record.sublayers.isEmpty,
              record.sublayers.count <= sublayerSlots,
              record.sublayers.allSatisfy({ $0.profile == .dyeCloud }),
              let decay = record.sublayers.first?.sigmaMM,
              record.sublayers.allSatisfy({ $0.sigmaMM == decay }) else { return nil }
        let side = Self.tileSide
        let supersample = Self.supersample(pxPerMM: 1 / Self.tileTexelMM)
        let h = Self.tileTexelMM / Float(supersample)
        let period = Float(side) * Self.tileTexelMM
        let terms = Self.dyeCloudTerms.map { (sigma: $0.sigma * decay / h, weight: $0.weight) }
        let tableScale = Float(Self.tableSamples - 1) / max(record.dMax - record.dMin, 1e-6)
        let layers = record.sublayers.map { layer in
            // The cells `renderTile` lays a periodic film in.
            let cells = max(Int((period / layer.cellMM).rounded()), 1)
            let cell = period / Float(cells)
            let fractions = grosses.map { gross in
                let t = min(max((gross - record.dMin) * tableScale, 0), Float(Self.tableSamples - 1))
                let ti = min(Int(t), Self.tableSamples - 2)
                let tf = t - Float(ti)
                return layer.forming[ti] * (1 - tf) + layer.forming[ti + 1] * tf
            }
            return TileSublayer(
                cells: cells, edge: layer.peakDemand / layer.capacity, capacity: layer.capacity,
                thresholds: FilmRandom.countThresholds(mean: layer.coatedPerMM2 * cell * cell),
                fractions: fractions)
        }
        let texels = side * side
        var light: [Float]?
        for builder in builders where light == nil {
            light = build(builder, texels: side, supersample: supersample, terms: terms,
                          sublayers: layers, seed: FilmRandom.seed32(seed), record: r)
        }
        guard let light else { return nil }
        return grosses.indices.map { k in Array(light[(k * texels)..<((k + 1) * texels)]) }
    }

    private func build(_ builder: TileBuilder, texels: Int, supersample: Int,
                       terms: [(sigma: Float, weight: Float)], sublayers: [TileSublayer],
                       seed: UInt32, record: Int) -> [Float]? {
        if builder == .metal {
            #if canImport(Metal)
            return FilmTileMetalBuilder.shared?.build(
                texels: texels, supersample: supersample, markShape: Self.markShape, terms: terms,
                sublayers: sublayers, seed: seed, record: record)
            #else
            return nil
            #endif
        }
        // The Halide builder holds every sublayer's deposits per level, so it lays a few at a time.
        let slots = 4, fields = 3 + FilmRandom.maxCount, perCall = 4
        var packed = [Float](repeating: 1, count: slots * fields)
        for (b, layer) in sublayers.enumerated() {
            packed[b * fields] = Float(layer.cells)
            packed[b * fields + 1] = layer.edge
            packed[b * fields + 2] = layer.capacity
            packed.replaceSubrange((b * fields + 3)..<((b + 1) * fields), with: layer.thresholds)
        }
        let flatTerms = terms.flatMap { [$0.sigma, $0.weight] }
        let total = sublayers[0].fractions.count
        var light: [Float] = []
        for start in stride(from: 0, to: total, by: perCall) {
            let levels = min(perCall, total - start)
            var fractions = [Float](repeating: 0, count: slots * levels)
            for (b, layer) in sublayers.enumerated() {
                fractions.replaceSubrange((b * levels)..<((b + 1) * levels),
                                          with: layer.fractions[start..<(start + levels)])
            }
            var part = [Float](repeating: 0, count: texels * texels * levels)
            let status = part.withUnsafeMutableBufferPointer { out in
                fotufilm_film_tile_build(Int32(texels), Int32(supersample), Int32(Self.markShape),
                                         flatTerms, Int32(terms.count), packed, fractions, Int32(levels),
                                         seed, Int32(record), out.baseAddress)
            }
            guard status == 0 else { return nil }
            light += part
        }
        return light
    }

    func buildTiles(seed: UInt64, parallel: Bool = true) -> Tiles {
        buildTiles(seed: seed, parallel: parallel, checkCancellation: {})
    }

    func buildTiles(seed: UInt64, parallel: Bool = true,
                    checkCancellation: () throws -> Void) rethrows -> Tiles {
        try checkCancellation()
        var active = (monochrome ? [1] : [0, 1, 2]).filter { !records[$0].sublayers.isEmpty }
        var levels = [[TileLevel]](repeating: [], count: 3)
        let grosses = { (r: Int) in (0..<Self.tileLevels).map { k in
            self.records[r].dMin
                + (self.records[r].dMax - self.records[r].dMin) * Float(k) / Float(Self.tileLevels - 1)
        } }
        for r in active {
            try checkCancellation()
            if let built = builtLights(record: r, grosses: grosses(r), seed: seed) {
                levels[r] = built.map(Self.tileLevel(light:))
            }
        }
        active.removeAll { !levels[$0].isEmpty }
        let count = active.count * Self.tileLevels
        let results = TileLevelResults(count: count)
        // A level already parallelizes its small image tiles. Two independent levels keep that
        // queue fed without opening all 51 levels' temporary render storage at once.
        let workers = min(parallel ? 2 : 1, count)
        if workers > 0 {
            // Join each pair before checking cancellation on the calling task. Dispatch workers
            // do not inherit Swift task cancellation. Never publish a partially generated bank.
            for start in stride(from: 0, to: count, by: workers) {
                try checkCancellation()
                DispatchQueue.concurrentPerform(iterations: min(workers, count - start)) { offset in
                    let index = start + offset
                    let r = active[index / Self.tileLevels], k = index % Self.tileLevels
                    let record = records[r]
                    let gross = record.dMin
                        + (record.dMax - record.dMin) * Float(k) / Float(Self.tileLevels - 1)
                    results.values[index] = Self.tileLevel(
                        light: referenceTileLight(record: r, gross: gross, seed: seed))
                }
            }
        }
        try checkCancellation()
        for (index, record) in active.enumerated() {
            levels[record] = (0..<Self.tileLevels).map { results.values[index * Self.tileLevels + $0]! }
        }
        return Tiles(levels: levels, dMin: records.map(\.dMin), dMax: records.map(\.dMax))
    }

    /// Workers publish distinct complete levels. Arrays are collected only after the join.
    private final class TileLevelResults: @unchecked Sendable {
        let values: UnsafeMutableBufferPointer<TileLevel?>
        init(count: Int) {
            values = .allocate(capacity: count)
            values.initialize(repeating: nil)
        }
        deinit { values.deinitialize(); values.deallocate() }
    }

    static func tileLevel(light: [Float]) -> TileLevel {
        let n = tileSide
        var total = 0.0
        for t in light { total += Double(t) }
        let mean = total / Double(light.count)
        var sums = [Float](repeating: 0, count: (n + 1) * (n + 1))
        var column = [Double](repeating: 0, count: n)
        for y in 0..<n {
            var run = 0.0
            for x in 0..<n {
                column[x] += Double(light[y * n + x]) - mean
                run += column[x]
                sums[(y + 1) * (n + 1) + x + 1] = Float(run)
            }
        }
        return TileLevel(sums: sums, meanLight: Float(mean))
    }

    /// The tables of pixels that each read `footprint` texels of film a side.
    public func pitchTables(_ tiles: Tiles, footprint: Float) -> PitchTables {
        tiles.tables(pitch: footprint) { Self.measurePitch(tiles, pitch: Double(footprint)) }
    }

    /// Each level read through footprints of `pitch` texels laid as a frame lays them — through
    /// the blocks' own placements — at `side²` footprints scattered over many blocks.
    static func measurePitch(_ tiles: Tiles, pitch: Double, side: Int = 128) -> PitchTables {
        let pixels = (0..<(side * side)).map { i in
            (Double((i % side) * 7919 % 4096) * pitch, Double((i / side) * 104_729 % 4096) * pitch)
        }
        var means = [[Float]](repeating: [], count: 3), scales = [[Float]](repeating: [], count: 3)
        for r in 0..<3 where !tiles.levels[r].isEmpty {
            let levels = tiles.levels[r]
            var fields = [[Double]](repeating: [], count: levels.count)
            for k in stride(from: 0, to: levels.count, by: 2) {
                let next = min(k + 1, levels.count - 1)
                let lights = pixels.map { p in
                    footprintLight(levels[k], levels[next], p.0, p.0 + pitch, p.1, p.1 + pitch,
                                   seed: 0x5A3F_1E1D, record: r)
                }
                fields[k] = lights.map { -log10(max(Double($0.0), 1e-9)) }
                fields[next] = lights.map { -log10(max(Double($0.1), 1e-9)) }
            }
            let m = fields.map { $0.reduce(0, +) / Double($0.count) }
            means[r] = m.map(Float.init)
            scales[r] = (0..<(fields.count - 1)).map { k in
                var aa = 0.0, bb = 0.0, ab = 0.0
                for i in pixels.indices {
                    let a = fields[k][i] - m[k], b = fields[k + 1][i] - m[k + 1]
                    aa += a * a; bb += b * b; ab += a * b
                }
                return Float(aa > 0 && bb > 0 ? min(max(ab / (aa * bb).squareRoot(), -1), 1) : 1)
            }
        }
        return PitchTables(meanDensity: means, blendCorrelation: scales)
    }

    /// Grain of two neighbouring levels blended at `w`, keeping their variance given the two
    /// fields' correlation `rho`.
    @inline(__always)
    static func blend(_ a: Float, _ b: Float, _ w: Float, _ rho: Float) -> Float {
        let kept = (1 - w) * (1 - w) + w * w + 2 * w * (1 - w) * rho
        return (a + (b - a) * w) / max(kept, 1e-4).squareRoot()
    }

    /// Running sum at a real point of the tile, texels from its corner, within one period:
    /// bilinear within a texel, which is exact for texels of constant light.
    @inline(__always)
    static func sumAt(_ sums: [Float], _ x: Double, _ y: Double) -> Double {
        let n = tileSide, stride = n + 1
        let ix = min(max(Int(x), 0), n - 1), iy = min(max(Int(y), 0), n - 1)
        let ax = x - Double(ix), ay = y - Double(iy)
        let s00 = Double(sums[iy * stride + ix]), s10 = Double(sums[iy * stride + ix + 1])
        let s01 = Double(sums[(iy + 1) * stride + ix]), s11 = Double(sums[(iy + 1) * stride + ix + 1])
        return s00 + (s10 - s00) * ax + (s01 - s00) * ay + (s11 - s10 - s01 + s00) * ax * ay
    }

    static func boxSum(_ sums: [Float], _ x0: Double, _ x1: Double, _ y0: Double, _ y1: Double) -> Double {
        sumAt(sums, x1, y1) - sumAt(sums, x0, y1) - sumAt(sums, x1, y0) + sumAt(sums, x0, y0)
    }

    /// RMS granularity through the 48 µm aperture of a periodic tile of light, as a
    /// microdensitometer reads it. The grain is far smaller than the aperture, so the aperture's
    /// light variance is the field's noise power at zero frequency over the aperture's area — the
    /// autocovariance summed over every lag it reaches, which every texel of the tile informs —
    /// and the density's is that over the light's mean, by `ln 10`. Frames lay the tile in blocks
    /// at independent offsets, so two points a lag apart share a block, and their covariance,
    /// only for `(1 - |dx| / B)(1 - |dy| / B)` of the pairs: each lag counts that share, and the
    /// anchor reads the grain as the frames lay it.
    static func tileSigma48(_ light: [Float]) -> Float {
        let n = tileSide
        var total = 0.0
        for t in light { total += Double(t) }
        let mean = total / Double(n * n)
        let d = light.map { Double($0) - mean }
        let reach = 16
        let lagSide = reach * 2 + 1
        let sums = LagSums(count: lagSide * lagSide)
        // Each row of lags is independent. Keep every texel sum serial, then combine the
        // finished lags in the original dy/dx order: calibration must retain the same bits.
        DispatchQueue.concurrentPerform(iterations: lagSide) { rowIndex in
            let dy = rowIndex - reach
            for dx in -reach...reach {
                var c = 0.0
                for y in 0..<n {
                    let row = y * n, other = ((y + dy + n) % n) * n
                    for x in 0..<n { c += d[row + x] * d[other + (x + dx + n) % n] }
                }
                sums.values[rowIndex * lagSide + dx + reach] = c / Double(n * n)
            }
        }
        let block = Double((tileBlockMM / tileTexelMM).rounded())
        var power = 0.0
        for rowIndex in 0..<lagSide {
            for column in 0..<lagSide {
                let shared = (1 - Double(abs(rowIndex - reach)) / block)
                    * (1 - Double(abs(column - reach)) / block)
                power += sums.values[rowIndex * lagSide + column] * shared
            }
        }
        let radius = Double(FilmStock.granularityApertureRadiusMM / tileTexelMM)
        let lightVariance = max(power, 0) / (Double.pi * radius * radius)
        return Float(lightVariance.squareRoot() / (mean * 2.302_585_093))
    }

    /// Concurrent writers own disjoint lag rows; the calling thread reads after the join.
    private final class LagSums: @unchecked Sendable {
        let values: UnsafeMutableBufferPointer<Double>
        init(count: Int) {
            values = .allocate(capacity: count)
            values.initialize(repeating: 0)
        }
        deinit { values.deallocate() }
    }

    /// Lays the grain from the tiles: see `Tiles`.
    func applyTiled(to negative: ImageBuffer, pxPerMM: Float, seed: UInt32,
                    amount: Float, look: Look) -> ImageBuffer {
        let tiles = tiles()
        let width = negative.width, height = negative.height
        let active = monochrome ? [1] : [0, 1, 2]
        let geometry = look.geometry(pxPerMM: pxPerMM)
        let pitch = Double(geometry.pitch), footprint = Double(geometry.footprint)
        let amounts = look.recordAmounts(amount)
        let tables = pitchTables(tiles, footprint: geometry.footprint)
        var planes = negative.planes
        var fluctuations = [[Float]](repeating: [], count: 3)
        for r in active where !tiles.levels[r].isEmpty {
            let levels = tiles.levels[r]
            let lo = tiles.dMin[r], hi = tiles.dMax[r]
            let steps = Float(Self.tileLevels - 1)
            let meanAt = tables.meanDensity[r], rho = tables.blendCorrelation[r]
            let source = negative.planes[r]
            let out = UnsafeMutableBufferPointer<Float>.allocate(capacity: width * height)
            defer { out.deallocate() }
            let box = TileOutput(out)
            let amount = amounts[r]
            DispatchQueue.concurrentPerform(iterations: height) { y in
                let y0 = (Double(y) + 0.5) * pitch - 0.5 * footprint, y1 = y0 + footprint
                for x in 0..<width {
                    let gross = source[y * width + x]
                    let t = min(max((gross - lo) / max(hi - lo, 1e-6), 0), 1) * steps
                    let k = min(Int(t), Self.tileLevels - 2)
                    let w = t - Float(k)
                    let x0 = (Double(x) + 0.5) * pitch - 0.5 * footprint, x1 = x0 + footprint
                    let (a, b) = Self.footprintLight(levels[k], levels[k + 1], x0, x1, y0, y1,
                                                     seed: seed, record: r)
                    let da = -log10(max(a, 1e-9)) - meanAt[k]
                    let db = -log10(max(b, 1e-9)) - meanAt[k + 1]
                    box.pointer[y * width + x] = amount * Self.blend(da, db, w, rho[k])
                }
            }
            fluctuations[r] = Array(out)
        }
        if monochrome {
            for r in 0..<3 where !fluctuations[1].isEmpty {
                for i in 0..<(width * height) { planes[r][i] += fluctuations[1][i] }
            }
        } else {
            let (own, shared) = Look.mix(colour: look.colour)
            let zero = [Float](repeating: 0, count: width * height)
            let grain = fluctuations.map { $0.isEmpty ? zero : $0 }
            for i in 0..<(width * height) {
                let mean = (grain[0][i] + grain[1][i] + grain[2][i]) / 3
                for r in 0..<3 { planes[r][i] += own * grain[r][i] + shared * mean }
            }
        }
        return ImageBuffer(width: width, height: height, planes: planes)
    }

    private final class TileOutput: @unchecked Sendable {
        let pointer: UnsafeMutableBufferPointer<Float>
        init(_ pointer: UnsafeMutableBufferPointer<Float>) { self.pointer = pointer }
    }

    /// The block's placement of the tile: an offset in texels that keeps the block inside one
    /// period, so no read wraps, and one of eight orientations, from the kernel's `pixel_hash` on
    /// the block's column and row.
    static func blockPlacement(seed: UInt32, record: Int, bx: Int, by: Int) -> (Double, Double, Int) {
        let stream = (tileStream &+ UInt32(record)) &* 0x9E37_79B9
        let h = pcgHash(UInt32(truncatingIfNeeded: bx)
                        ^ pcgHash(UInt32(truncatingIfNeeded: by) ^ pcgHash(seed ^ stream)))
        let reach = UInt32(tileSide) - UInt32((tileBlockMM / tileTexelMM).rounded()) + 1
        return (Double(h % reach), Double((h >> 8) % reach), Int((h >> 16) & 7))
    }

    /// Mean light through the film rectangle `[x0, x1) × [y0, y1)` (texels) at two levels. A
    /// footprint reads the two blocks either way from its corner, as the kernel does: all of it
    /// for any pixel up to a block wide, and an even sample of it past that.
    static func footprintLight(_ a: TileLevel, _ b: TileLevel, _ x0: Double, _ x1: Double,
                               _ y0: Double, _ y1: Double, seed: UInt32,
                               record: Int) -> (Float, Float) {
        let block = Double((tileBlockMM / tileTexelMM).rounded())
        let bx0 = Int((x0 / block).rounded(.down)), by0 = Int((y0 / block).rounded(.down))
        let bx1 = min(Int((x1 / block).rounded(.up)) - 1, bx0 + 1)
        let by1 = min(Int((y1 / block).rounded(.up)) - 1, by0 + 1)
        var sumA = 0.0, sumB = 0.0
        for by in by0...by1 {
            let v0 = max(y0, Double(by) * block) - Double(by) * block
            let v1 = min(y1, Double(by + 1) * block) - Double(by) * block
            for bx in bx0...bx1 {
                let u0 = max(x0, Double(bx) * block) - Double(bx) * block
                let u1 = min(x1, Double(bx + 1) * block) - Double(bx) * block
                let (ox, oy, turn) = blockPlacement(seed: seed, record: record, bx: bx, by: by)
                var (p0, p1, q0, q1) = (u0, u1, v0, v1)
                if turn & 1 != 0 { (p0, p1) = (block - u1, block - u0) }
                if turn & 2 != 0 { (q0, q1) = (block - v1, block - v0) }
                if turn & 4 != 0 { (p0, p1, q0, q1) = (q0, q1, p0, p1) }
                sumA += boxSum(a.sums, p0 + ox, p1 + ox, q0 + oy, q1 + oy)
                sumB += boxSum(b.sums, p0 + ox, p1 + ox, q0 + oy, q1 + oy)
            }
        }
        let area = max((min(x1, Double(bx1 + 1) * block) - x0)
                       * (min(y1, Double(by1 + 1) * block) - y0), 1e-6)
        return (a.meanLight + Float(sumA / area), b.meanLight + Float(sumB / area))
    }

    // MARK: - The kernel's inputs

    /// The configuration's FILM_TILE block for a frame of `pxPerMM` whose grain is scaled by
    /// `amount` and laid as `look` lays it, naming tiles `id`: the pitch and footprint, the id, each record's amount, the colour
    /// mix, each record's density range, then per record the levels' mean light, their mean
    /// density through the footprint and the correlation of neighbouring levels' grain there.
    public func configurationBlock(pxPerMM: Float, amount: Float, look: Look, id: Int32) -> [Float] {
        configurationBlock(pxPerMM: pxPerMM, amount: amount, look: look, id: id, tiles: nil)
    }

    fileprivate func configurationBlock(pxPerMM: Float, amount: Float, look: Look, id: Int32,
                                        tiles supplied: Tiles?) -> [Float] {
        var timing = StageTiming()
        let tiles = supplied ?? tiles()
        timing.mark("tiles")
        let geometry = look.geometry(pxPerMM: pxPerMM)
        let tables = pitchTables(tiles, footprint: geometry.footprint)
        timing.mark("pitch_tables")
        let levels = Self.tileLevels
        var block: [Float] = [geometry.pitch, geometry.footprint, Float(id)]
        block += look.recordAmounts(amount) + [monochrome ? 1 : look.colour]
        block += tiles.dMin + tiles.dMax
        for r in 0..<3 {
            guard !tiles.levels[r].isEmpty else {
                block += [Float](repeating: 1, count: levels)
                block += [Float](repeating: 0, count: levels)
                block += [Float](repeating: 1, count: levels)
                continue
            }
            block += tiles.levels[r].map(\.meanLight)
            block += tables.meanDensity[r]
            block += tables.blendCorrelation[r] + [1]
        }
        timing.mark("configuration")
        timing.report("Film configuration id=\(id) footprint=\(geometry.footprint)")
        return block
    }
}

extension FilmGrain {
    /// A canonical tile bank and its backend registration. A frame keeps this binding so cache
    /// eviction cannot remove its grain while another stock is preparing or rendering.
    public final class TileBinding: Sendable {
        public let grain: FilmGrain
        public let id: Int32
        /// True only after a provider asset passed identity, bounds and finite-data validation.
        public var usedAsset: Bool { grain.assetTiles != nil }
        private let tiles: Tiles
        let registrationStatus: Int32

        fileprivate init(grain: FilmGrain, tiles: Tiles, id: Int32) {
            var timing = StageTiming()
            self.grain = grain
            self.id = id
            self.tiles = tiles
            timing.mark("tiles")
            let packed = tiles.packed()
            timing.mark("packing")
            registrationStatus = packed.withUnsafeBufferPointer {
                fotufilm_halide_set_film_tiles(id, $0.baseAddress, Int64($0.count))
            }
            timing.mark("registration")
            timing.report("Film binding id=\(id)")
        }

        /// Uses this binding's retained tiles and pitch cache even after the shared cache moves
        /// to other stocks. The numerical configuration has one implementation for both paths.
        func configurationBlock(pxPerMM: Float, amount: Float, look: Look) -> [Float] {
            grain.configurationBlock(pxPerMM: pxPerMM, amount: amount, look: look, id: id, tiles: tiles)
        }

        /// The immutable bank in the canonical (entry, level, record) layout.
        public func packed() -> [Float] {
            var timing = StageTiming()
            let packed = tiles.packed()
            timing.mark("packing")
            timing.report("Film binding read id=\(id)")
            return packed
        }

        deinit {
            if registrationStatus == 0 { _ = fotufilm_halide_set_film_tiles(id, nil, 0) }
        }
    }

    /// The population of `stock` at its sheet's own granularity, its tiles handed to the Halide
    /// engine under the id returned. The registry caches the last few populations; complete
    /// rendering invocations retain their binding independently of that cache.
    public static func registered(stock: FilmStock, reference: FilmStock?) -> (grain: FilmGrain, id: Int32) {
        let binding = registry.entry(stock: stock, reference: reference, checkCancellation: {})
        return (binding.grain, binding.id)
    }

    static func binding(stock: FilmStock, reference: FilmStock?,
                        checkCancellation: () throws -> Void) rethrows -> TileBinding {
        try registry.entry(stock: stock, reference: reference, checkCancellation: checkCancellation)
    }

    /// The rolls a develop's Film grain population is prepared for — the developed roll and its
    /// reference-process twin — as `FilmEngineInvocation.filmGrainPopulation` names them.
    public struct Population: Sendable {
        let stock: FilmStock
        let reference: FilmStock?
        /// Equal for every develop that draws the same population.
        public var identity: Data { FilmGrainAsset.identity(stock: stock, reference: reference) }
    }

    /// Whether a develop would find `population` without preparing it: kept from an earlier
    /// develop, or carried by the asset provider. Preparing one takes seconds.
    public static func isPrepared(_ population: Population) -> Bool {
        registry.isPrepared(population.identity)
    }

    /// Prepares `population` and keeps it. A population depends on the roll, not on the grade, so
    /// a caller that develops again at every edit prepares it here, on a task only a change of
    /// roll cancels, rather than inside develops that each edit cancels.
    public static func prepare(_ population: Population,
                               checkCancellation: () throws -> Void) rethrows {
        _ = try registry.entry(stock: population.stock, reference: population.reference,
                               checkCancellation: checkCancellation)
    }

    /// The packed tiles a frame's configuration names in its `FILM_TILE` block; nil when the
    /// frame uses another model or neither a frame nor the cache retains its binding.
    public static func registeredTiles(configuration: [Float]) -> [Float]? {
        let base = Int(FOTUFILM_CONFIG_FILM_TILE)
        guard configuration.count > base + 2,
              configuration[Int(FOTUFILM_CONFIG_GRAIN_MODE)] == 1,
              let id = Int32(exactly: configuration[base + 2]) else { return nil }
        return registry.binding(id: id)?.packed()
    }

    private static let registry = Registry()

    private final class Registry: @unchecked Sendable {
        private final class WeakBinding {
            weak var value: TileBinding?
            init(_ value: TileBinding) { self.value = value }
        }

        private let lock = NSCondition()
        private var entries: [(key: Data, binding: TileBinding)] = []
        private var live: [Int32: WeakBinding] = [:]
        private var nextID: Int32 = 1
        // Bound cold preparation to one bank, while allowing cached banks to be read immediately.
        private var preparing = false

        func entry(stock: FilmStock, reference: FilmStock?,
                   checkCancellation: () throws -> Void) rethrows -> TileBinding {
            let key = FilmGrainAsset.identity(stock: stock, reference: reference)
            if let hit = cached(key) { return hit }
            // A provided population only decodes, so it does not queue behind a cold preparation.
            if let provided = FilmGrainAsset.provided(identity: key) {
                return publish(key, grain: provided,
                               tiles: try provided.tiles(checkCancellation: checkCancellation))
            }
            lock.lock()
            while true {
                do { try checkCancellation() } catch { lock.unlock(); throw error }
                if let hit = entries.first(where: { $0.key == key }) {
                    lock.unlock()
                    return hit.binding
                }
                if !preparing { break }
                _ = lock.wait(until: Date(timeIntervalSinceNow: 0.02))
            }
            preparing = true
            lock.unlock()
            defer {
                lock.lock()
                preparing = false
                lock.broadcast()
                lock.unlock()
            }
            let grain = try FilmGrain(stock: stock, reference: reference, useCachedAnchor: true,
                                      checkCancellation: checkCancellation)
            try checkCancellation()
            let tiles = try grain.tiles(checkCancellation: checkCancellation)
            try checkCancellation()
            return publish(key, grain: grain, tiles: tiles)
        }

        func isPrepared(_ key: Data) -> Bool {
            cached(key) != nil || FilmGrainAsset.isProvided(identity: key)
        }

        private func cached(_ key: Data) -> TileBinding? {
            lock.lock()
            defer { lock.unlock() }
            return entries.first(where: { $0.key == key })?.binding
        }

        /// Registers a finished population, or hands back the one another caller finished first.
        private func publish(_ key: Data, grain: FilmGrain, tiles: Tiles) -> TileBinding {
            lock.lock()
            let id = nextID
            nextID += 1
            lock.unlock()
            let binding = TileBinding(grain: grain, tiles: tiles, id: id)
            lock.lock()
            defer { lock.unlock() }
            if let hit = entries.first(where: { $0.key == key }) { return hit.binding }
            live = live.filter { $0.value.value != nil }
            live[binding.id] = WeakBinding(binding)
            entries.append((key, binding))
            if entries.count > 4 { entries.removeFirst() }
            return binding
        }

        func binding(id: Int32) -> TileBinding? {
            lock.lock()
            defer { lock.unlock() }
            return live[id]?.value
        }
    }
}
