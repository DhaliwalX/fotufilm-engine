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
        func tiles(_ key: String, build: () -> Tiles) -> Tiles {
            lock.lock()
            if let hit = entries.first(where: { $0.key == key }) { lock.unlock(); return hit.tiles }
            lock.unlock()
            let built = build()
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
        Self.tileCache.tiles(key) { buildTiles(seed: Self.tileSeed) }
    }

    /// Transmittance of one record's tile at `gross`, `tileSide²` texels.
    func tileLight(record r: Int, gross: Float, seed: UInt64) -> [Float] {
        let side = Self.tileSide
        let pxPerMM = 1 / Self.tileTexelMM
        var unused = [Float]()
        let field = render(record: r, width: side, height: side, pxPerMM: pxPerMM,
                           supersample: Self.supersample(pxPerMM: pxPerMM), seed: seed,
                           grossAt: { _, _ in gross }, pointMeans: &unused,
                           wantPointMeans: false, periodMM: Float(side) * Self.tileTexelMM)
        return field.map { pow(10, -$0) }
    }

    func buildTiles(seed: UInt64) -> Tiles {
        let active = monochrome ? [1] : [0, 1, 2]
        var levels = [[TileLevel]](repeating: [], count: 3)
        for r in active where !records[r].sublayers.isEmpty {
            let record = records[r]
            levels[r] = (0..<Self.tileLevels).map { k in
                let gross = record.dMin
                    + (record.dMax - record.dMin) * Float(k) / Float(Self.tileLevels - 1)
                return Self.tileLevel(light: tileLight(record: r, gross: gross, seed: seed))
            }
        }
        return Tiles(levels: levels, dMin: records.map(\.dMin), dMax: records.map(\.dMax))
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

    public func pitchTables(_ tiles: Tiles, pxPerMM: Float) -> PitchTables {
        let pitch = (1 / pxPerMM) / Self.tileTexelMM
        return tiles.tables(pitch: pitch) { Self.measurePitch(tiles, pitch: Double(pitch)) }
    }

    /// Each level read through pixels of `pitch` texels laid as a frame lays them — through the
    /// blocks' own placements — at `side²` pixels scattered over many blocks.
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
    /// and the density's is that over the light's mean, by `ln 10`.
    static func tileSigma48(_ light: [Float]) -> Float {
        let n = tileSide
        var total = 0.0
        for t in light { total += Double(t) }
        let mean = total / Double(n * n)
        let d = light.map { Double($0) - mean }
        let reach = 16
        var power = 0.0
        for dy in -reach...reach {
            for dx in -reach...reach {
                var c = 0.0
                for y in 0..<n {
                    let row = y * n, other = ((y + dy + n) % n) * n
                    for x in 0..<n { c += d[row + x] * d[other + (x + dx + n) % n] }
                }
                power += c / Double(n * n)
            }
        }
        let radius = Double(FilmStock.granularityApertureRadiusMM / tileTexelMM)
        let lightVariance = max(power, 0) / (Double.pi * radius * radius)
        return Float(lightVariance.squareRoot() / (mean * 2.302_585_093))
    }

    /// Lays the grain from the tiles: see `Tiles`.
    func applyTiled(to negative: ImageBuffer, pxPerMM: Float, seed: UInt32,
                    amount: Float) -> ImageBuffer {
        let tiles = tiles()
        let width = negative.width, height = negative.height
        let active = monochrome ? [1] : [0, 1, 2]
        let pitch = Double(1 / pxPerMM) / Double(Self.tileTexelMM)   // pixel side, texels
        let tables = pitchTables(tiles, pxPerMM: pxPerMM)
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
            DispatchQueue.concurrentPerform(iterations: height) { y in
                let y0 = Double(y) * pitch, y1 = y0 + pitch
                for x in 0..<width {
                    let gross = source[y * width + x]
                    let t = min(max((gross - lo) / max(hi - lo, 1e-6), 0), 1) * steps
                    let k = min(Int(t), Self.tileLevels - 2)
                    let w = t - Float(k)
                    let x0 = Double(x) * pitch, x1 = x0 + pitch
                    let (a, b) = Self.footprintLight(levels[k], levels[k + 1], x0, x1, y0, y1,
                                                     seed: seed, record: r)
                    let da = -log10(max(a, 1e-9)) - meanAt[k]
                    let db = -log10(max(b, 1e-9)) - meanAt[k + 1]
                    box.pointer[y * width + x] = amount * Self.blend(da, db, w, rho[k])
                }
            }
            fluctuations[r] = Array(out)
        }
        for r in 0..<3 {
            let grain = monochrome ? fluctuations[1] : fluctuations[r]
            guard !grain.isEmpty else { continue }
            for i in 0..<(width * height) { planes[r][i] += grain[i] }
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
    /// `amount`, naming tiles `id`: the pitch, the amount, the id, each record's density range,
    /// then per record the levels' mean light, their mean density at this pitch and the
    /// correlation of neighbouring levels' grain there.
    public func configurationBlock(pxPerMM: Float, amount: Float, id: Int32) -> [Float] {
        let tiles = tiles()
        let tables = pitchTables(tiles, pxPerMM: pxPerMM)
        let levels = Self.tileLevels
        var block: [Float] = [(1 / pxPerMM) / Self.tileTexelMM, amount, Float(id)]
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
        return block
    }
}

extension FilmGrain {
    /// The population of `stock` at its sheet's own granularity, its tiles handed to the Halide
    /// engine under the id returned: built and registered on first use, the last few kept. A
    /// frame's grain amount scales the grain in the kernel, so moving it rebuilds nothing.
    public static func registered(stock: FilmStock, reference: FilmStock?) -> (grain: FilmGrain, id: Int32) {
        registry.entry(stock: stock, reference: reference)
    }

    private static let registry = Registry()

    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(key: String, grain: FilmGrain, id: Int32)] = []
        private var nextID: Int32 = 1

        func entry(stock: FilmStock, reference: FilmStock?) -> (grain: FilmGrain, id: Int32) {
            let key = FilmGrain.anchorKey(stock: stock, grainScale: 1)
                + "|\(reference.map { $0.curves.map { [$0.dMin, $0.dMax] } } ?? [])"
            lock.lock()
            defer { lock.unlock() }
            if let hit = entries.first(where: { $0.key == key }) { return (hit.grain, hit.id) }
            let grain = FilmGrain(stock: stock, reference: reference)
            let packed = grain.tiles().packed()
            let id = nextID
            nextID += 1
            _ = packed.withUnsafeBufferPointer {
                fotufilm_halide_set_film_tiles(id, $0.baseAddress, Int64($0.count))
            }
            entries.append((key, grain, id))
            if entries.count > 4 {
                let evicted = entries.removeFirst()
                _ = fotufilm_halide_set_film_tiles(evicted.id, nil, 0)
            }
            return (grain, id)
        }
    }
}
