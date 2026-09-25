#if canImport(Metal)
import Foundation
import Metal

/// Dye-cloud Film tiles laid on the GPU by hand-written Metal: the arithmetic of
/// `FilmGrain.renderTile` on a tile that wraps, for every requested level at once.
///
/// Each film cell draws its crystals once — place, development draw and peak demand, hashed as
/// `FilmRandom` hashes them. Each sample then gathers the crystals whose bilinear footprint covers
/// it, per level; the cloud's terms blur those deposits, the narrow ones at full resolution and
/// the wide ones on a coarser periodic grid; each sublayer's demand saturates against its
/// capacity, and a texel passes the mean of its samples' transmittance.
final class FilmTileMetalBuilder: @unchecked Sendable {
    /// The builder, or nil where Metal cannot run it.
    static let shared: FilmTileMetalBuilder? = try? FilmTileMetalBuilder()

    /// Levels one build lays at most: the deposit kernel holds a sample's levels in registers.
    static let maxLevels = 17

    typealias Sublayer = FilmGrain.TileSublayer

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let crystals, deposit, fullRows, rows, columns, demand, light: MTLComputePipelineState
    private let lock = NSLock()
    private var scratch: [String: MTLBuffer] = [:]

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw BuildError.unavailable
        }
        self.device = device
        self.queue = queue
        // Fast math off, so the GPU keeps the reference's arithmetic.
        let options = MTLCompileOptions()
        if #available(macOS 15.0, iOS 18.0, *) {
            options.mathMode = .safe
        } else {
            options.fastMathEnabled = false
        }
        let library = try device.makeLibrary(source: Self.source, options: options)
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else { throw BuildError.unavailable }
            return try device.makeComputePipelineState(function: function)
        }
        crystals = try pipeline("film_tile_crystals")
        deposit = try pipeline("film_tile_deposit")
        fullRows = try pipeline("film_tile_full_rows")
        rows = try pipeline("film_tile_rows")
        columns = try pipeline("film_tile_columns")
        demand = try pipeline("film_tile_demand")
        light = try pipeline("film_tile_light")
    }

    enum BuildError: Error { case unavailable }

    /// Terms of each kind a build blurs at most, and taps a full-resolution term holds at most: a
    /// term goes coarse from 3.2 samples, whose kernel is 3.5 σ either side.
    static let maxTerms = 4, maxTaps = 32
    /// Memory the per-sample planes of one pass over the levels may take.
    static let planeBudget = 64 << 20

    /// Light of one record's tile, `texels²` per level, level-major. `terms` are the cloud's
    /// Gaussian terms in samples.
    func build(texels: Int, supersample: Int, markShape: Int, terms: [(sigma: Float, weight: Float)],
               sublayers: [Sublayer], seed: UInt32, record: Int) -> [Float]? {
        let levels = sublayers.first?.fractions.count ?? 0
        let n = texels * supersample
        let factors = terms.map { FilmGrain.tileTermFactor(sigma: $0.sigma, samples: n) }
        let full = terms.indices.filter { factors[$0] == 1 }
        let coarse = terms.indices.filter { factors[$0] > 1 }
        let fullKernels = full.map { FilmGrain.gaussianKernel(sigma: terms[$0].sigma) }
        guard levels > 0, !sublayers.isEmpty, !terms.isEmpty,
              full.count <= Self.maxTerms, coarse.count <= Self.maxTerms,
              fullKernels.allSatisfy({ $0.count <= Self.maxTaps }),
              // Full terms come first, as the reference adds them.
              full.allSatisfy({ i in coarse.allSatisfy { i < $0 } }),
              sublayers.allSatisfy({ $0.cells >= 1 && Float(n) / Float($0.cells) >= 0.75
                  && $0.thresholds.count == FilmRandom.maxCount && $0.fractions.count == levels })
        else { return nil }
        lock.lock()
        defer { lock.unlock() }

        // Levels one pass lays: the deposit, each full term's row blur and the dye are held per
        // sample and level.
        let perPass = min(max(Self.planeBudget / ((2 + full.count) * n * n * 4), 1), Self.maxLevels)
        let chunk = min(perPass, levels)
        let plane = n * n * chunk
        let coarseSides = coarse.map { n / factors[$0] }
        guard let depositBuffer = buffer("deposit", floats: plane),
              let across = buffer("across", floats: max(full.count, 1) * plane),
              let dye = buffer("dye", floats: plane),
              let coarseRows = buffer("coarseRows", floats: (coarseSides.max() ?? 1) * n * chunk),
              let coarseA = buffer("coarseA", floats: (coarseSides.map { $0 * $0 }.max() ?? 1) * chunk),
              let coarseB = buffer("coarseB", floats: (coarseSides.map { $0 * $0 }.max() ?? 1) * chunk),
              let output = device.makeBuffer(length: texels * texels * levels * 4, options: .storageModeShared),
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeComputeCommandEncoder() else { return nil }
        let grids = coarse.indices.compactMap { buffer("grid\($0)", floats: coarseSides[$0] * coarseSides[$0] * chunk) }
        guard grids.count == coarse.count else { encoder.endEncoding(); return nil }

        func dispatch(_ pipeline: MTLComputePipelineState, _ width: Int, _ height: Int, _ depth: Int = 1) {
            encoder.setComputePipelineState(pipeline)
            let w = pipeline.threadExecutionWidth
            let h = max(pipeline.maxTotalThreadsPerThreadgroup / w, 1)
            encoder.dispatchThreads(MTLSize(width: width, height: height, depth: depth),
                                    threadsPerThreadgroup: MTLSize(width: w, height: min(h, 8, height), depth: 1))
        }
        func bytes<T>(_ value: T, _ index: Int) {
            withUnsafeBytes(of: value) { encoder.setBytes($0.baseAddress!, length: $0.count, index: index) }
        }
        func floats(_ values: [Float], _ index: Int) {
            values.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: index) }
        }
        // A blur pass: out[i] = Σ_t weights[t] · in[(stride·i + offset + t) mod inSide] along one
        // axis.
        func pass(_ pipeline: MTLComputePipelineState, from source: MTLBuffer, to target: MTLBuffer,
                  inSize: (Int, Int), outSize: (Int, Int), weights: [Float], stride: Int, offset: Int,
                  levels: Int) {
            encoder.setBuffer(source, offset: 0, index: 0)
            encoder.setBuffer(target, offset: 0, index: 1)
            floats(weights, 2)
            bytes(PassArguments(inWidth: UInt32(inSize.0), inHeight: UInt32(inSize.1),
                                outWidth: UInt32(outSize.0), outHeight: UInt32(outSize.1),
                                taps: UInt32(weights.count), stride: UInt32(stride), offset: Int32(offset),
                                levels: UInt32(levels)), 3)
            dispatch(pipeline, outSize.0, outSize.1, levels)
        }
        func quad<T>(_ values: [T], _ fill: T) -> (T, T, T, T) {
            let v = values + Array(repeating: fill, count: 4 - values.count)
            return (v[0], v[1], v[2], v[3])
        }

        // Every crystal, drawn once for all levels.
        let golden: UInt32 = 0x9E37_79B9
        var cellBuffers: [(counts: MTLBuffer, crystals: MTLBuffer, arguments: CrystalArguments)] = []
        for (b, layer) in sublayers.enumerated() {
            let cells = layer.cells
            let limit = max(layer.thresholds.lastIndex(where: { $0 < 1 }).map { $0 + 1 } ?? 0, 1)
            guard let counts = buffer("counts\(b)", floats: cells * cells),
                  let crystalBuffer = buffer("crystals\(b)", floats: cells * cells * limit * 4) else {
                encoder.endEncoding(); return nil
            }
            let stream = UInt32(truncatingIfNeeded: record * 8 + b * 2)
            let arguments = CrystalArguments(
                cells: UInt32(cells), limit: UInt32(limit), n: UInt32(n), levels: 0,
                crystalBase: seed ^ (stream &* golden), countBase: seed ^ ((stream &+ 1) &* golden),
                markShape: UInt32(markShape), cellSize: Float(n) / Float(cells), edge: layer.edge)
            encoder.setBuffer(counts, offset: 0, index: 0)
            encoder.setBuffer(crystalBuffer, offset: 0, index: 1)
            floats(layer.thresholds, 2)
            bytes(arguments, 3)
            dispatch(crystals, cells, cells)
            cellBuffers.append((counts, crystalBuffer, arguments))
        }

        var fullWeights = [Float](repeating: 0, count: Self.maxTerms * Self.maxTaps)
        for (t, kernel) in fullKernels.enumerated() {
            fullWeights.replaceSubrange((t * Self.maxTaps)..<(t * Self.maxTaps + kernel.count), with: kernel)
        }
        let fullTaps = quad(fullKernels.map { UInt32($0.count) }, 0)
        let scale = { (i: Int) in terms[i].weight * 2 * Float.pi * terms[i].sigma * terms[i].sigma }

        for start in stride(from: 0, to: levels, by: chunk) {
            let count = min(chunk, levels - start)
            for (b, layer) in sublayers.enumerated() {
                var arguments = cellBuffers[b].arguments
                arguments.levels = UInt32(count)
                encoder.setBuffer(cellBuffers[b].counts, offset: 0, index: 0)
                encoder.setBuffer(cellBuffers[b].crystals, offset: 0, index: 1)
                floats(Array(layer.fractions[start..<(start + count)]), 2)
                bytes(arguments, 3)
                encoder.setBuffer(depositBuffer, offset: 0, index: 4)
                dispatch(deposit, n, n)

                // The narrow terms blurred along rows at full resolution; their columns are
                // summed where the demand is.
                if !full.isEmpty {
                    encoder.setBuffer(depositBuffer, offset: 0, index: 0)
                    encoder.setBuffer(across, offset: 0, index: 1)
                    floats(fullWeights, 2)
                    bytes(FullArguments(n: UInt32(n), levels: UInt32(count), terms: UInt32(full.count),
                                        taps: fullTaps), 3)
                    dispatch(fullRows, n, n, count)
                }
                // The wide terms: deposits shared linearly into cells `factor` samples a side,
                // blurred there by what is left of the term after the two tents.
                for (c, i) in coarse.enumerated() {
                    let factor = factors[i], m = coarseSides[c], f = Float(factor)
                    let tent = (0..<(3 * factor)).map { t in max(0, 1 - abs((Float(t) + 0.5) / f - 1.5)) }
                    let kernel = FilmGrain.gaussianKernel(
                        sigma: (terms[i].sigma * terms[i].sigma - f * f / 3).squareRoot() / f)
                    let radius = kernel.count / 2
                    pass(rows, from: depositBuffer, to: coarseRows, inSize: (n, n), outSize: (m, n),
                         weights: tent, stride: factor, offset: -factor, levels: count)
                    pass(columns, from: coarseRows, to: coarseA, inSize: (m, n), outSize: (m, m),
                         weights: tent, stride: factor, offset: -factor, levels: count)
                    pass(rows, from: coarseA, to: coarseB, inSize: (m, m), outSize: (m, m),
                         weights: kernel, stride: 1, offset: -radius, levels: count)
                    pass(columns, from: coarseB, to: grids[c], inSize: (m, m), outSize: (m, m),
                         weights: kernel, stride: 1, offset: -radius, levels: count)
                }
                // The demand of every term, saturated against the sublayer's capacity.
                encoder.setBuffer(across, offset: 0, index: 0)
                encoder.setBuffer(dye, offset: 0, index: 1)
                floats(fullWeights, 2)
                for slot in 0..<Self.maxTerms {
                    encoder.setBuffer(slot < grids.count ? grids[slot] : dye, offset: 0, index: 4 + slot)
                }
                bytes(DemandArguments(
                    n: UInt32(n), levels: UInt32(count), fullTerms: UInt32(full.count),
                    coarseTerms: UInt32(coarse.count), accumulate: b > 0 ? 1 : 0, capacity: layer.capacity,
                    taps: fullTaps, fullScale: quad(full.map(scale), 0),
                    sides: quad(coarseSides.map { UInt32($0) }, 1),
                    factors: quad(coarse.map { UInt32(factors[$0]) }, 1),
                    coarseScale: quad(coarse.map { scale($0) / Float(factors[$0] * factors[$0]) }, 0)), 3)
                dispatch(demand, n, n, count)
            }
            encoder.setBuffer(dye, offset: 0, index: 0)
            encoder.setBuffer(output, offset: start * texels * texels * 4, index: 1)
            bytes(LightArguments(texels: UInt32(texels), supersample: UInt32(supersample), levels: UInt32(count)), 2)
            dispatch(light, texels, texels, count)
        }
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        guard commands.status == .completed else { return nil }
        let pointer = output.contents().bindMemory(to: Float.self, capacity: texels * texels * levels)
        return Array(UnsafeBufferPointer(start: pointer, count: texels * texels * levels))
    }

    /// Scratch kept between builds, grown when a build needs more.
    private func buffer(_ name: String, floats: Int) -> MTLBuffer? {
        let length = max(floats, 1) * 4
        if let held = scratch[name], held.length >= length { return held }
        let made = device.makeBuffer(length: length, options: .storageModePrivate)
        scratch[name] = made
        return made
    }

    private struct CrystalArguments {
        var cells, limit, n, levels, crystalBase, countBase, markShape: UInt32
        var cellSize, edge: Float
    }
    private struct PassArguments {
        var inWidth, inHeight, outWidth, outHeight, taps, stride: UInt32
        var offset: Int32
        var levels: UInt32
    }
    private struct FullArguments {
        var n, levels, terms: UInt32
        var taps: (UInt32, UInt32, UInt32, UInt32)
    }
    private struct DemandArguments {
        var n, levels, fullTerms, coarseTerms, accumulate: UInt32
        var capacity: Float
        var taps: (UInt32, UInt32, UInt32, UInt32)
        var fullScale: (Float, Float, Float, Float)
        var sides, factors: (UInt32, UInt32, UInt32, UInt32)
        var coarseScale: (Float, Float, Float, Float)
    }
    private struct LightArguments { var texels, supersample, levels: UInt32 }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    constant uint kGolden = 0x9E3779B9u;
    constant uint kMaxCount = \(FilmRandom.maxCount);
    constant uint kMaxLevels = \(maxLevels);
    constant uint kMaxTaps = \(maxTaps);

    inline uint pcg(uint value) {
        uint state = value * 747796405u + 2891336453u;
        uint word = ((state >> ((state >> 28) + 4)) ^ state) * 277803737u;
        return (word >> 22) ^ word;
    }
    inline float uniform01(uint hash) { return (float(hash >> 8) + 0.5f) * (1.0f / 16777216.0f); }
    inline uint cell_key(uint base, uint x, uint y) { return pcg(x ^ pcg(y ^ pcg(base))); }
    inline float draw(uint key, uint index) { return uniform01(pcg(key ^ (index * kGolden))); }
    inline int wrap(int v, int period) { int r = v % period; return r < 0 ? r + period : r; }

    struct CrystalArguments {
        uint cells, limit, n, levels, crystalBase, countBase, markShape;
        float cellSize, edge;
    };

    // A cell's count, then each of its crystals: place in the cell, development draw, peak
    // demand over capacity.
    kernel void film_tile_crystals(device uint *counts [[buffer(0)]],
                                   device float4 *crystals [[buffer(1)]],
                                   constant float *thresholds [[buffer(2)]],
                                   constant CrystalArguments &a [[buffer(3)]],
                                   uint2 g [[thread_position_in_grid]]) {
        if (g.x >= a.cells || g.y >= a.cells) return;
        uint cell = g.y * a.cells + g.x;
        float u = draw(cell_key(a.countBase, g.x, g.y), 0);
        uint count = 0;
        for (uint k = 0; k < kMaxCount; ++k) count += thresholds[k] < u ? 1 : 0;
        count = min(count, a.limit);
        counts[cell] = count;
        uint key = cell_key(a.crystalBase, g.x, g.y);
        for (uint c = 0; c < count; ++c) {
            uint first = c * (3 + a.markShape);
            float mark = 0.0f;
            for (uint i = 0; i < a.markShape; ++i) mark -= log(max(draw(key, first + 3 + i), 1.0e-7f));
            mark /= float(a.markShape);
            crystals[cell * a.limit + c] = float4(draw(key, first), draw(key, first + 1),
                                                  draw(key, first + 2), a.edge * mark);
        }
    }

    // Each sample's share of the peak demand of every crystal whose bilinear footprint covers
    // it, per level.
    kernel void film_tile_deposit(device const uint *counts [[buffer(0)]],
                                  device const float4 *crystals [[buffer(1)]],
                                  constant float *fractions [[buffer(2)]],
                                  constant CrystalArguments &a [[buffer(3)]],
                                  device float *deposit [[buffer(4)]],
                                  uint2 g [[thread_position_in_grid]]) {
        if (g.x >= a.n || g.y >= a.n) return;
        float sx = float(g.x) + 0.5f, sy = float(g.y) + 0.5f;
        int cx0 = int(floor((sx - 1.0f) / a.cellSize)), cx1 = int(floor((sx + 1.0f) / a.cellSize));
        int cy0 = int(floor((sy - 1.0f) / a.cellSize)), cy1 = int(floor((sy + 1.0f) / a.cellSize));
        float sum[kMaxLevels];
        for (uint l = 0; l < kMaxLevels; ++l) sum[l] = 0.0f;
        int cells = int(a.cells);
        for (int uy = cy0; uy <= cy1; ++uy) {
            uint hy = uint(wrap(uy, cells));
            for (int ux = cx0; ux <= cx1; ++ux) {
                uint hx = uint(wrap(ux, cells));
                uint cell = hy * a.cells + hx;
                uint count = counts[cell];
                for (uint c = 0; c < count; ++c) {
                    float4 crystal = crystals[cell * a.limit + c];
                    float px = (float(ux) + crystal.x) * a.cellSize;
                    float py = (float(uy) + crystal.y) * a.cellSize;
                    float share = max(0.0f, 1.0f - fabs(px - sx)) * max(0.0f, 1.0f - fabs(py - sy));
                    if (share <= 0.0f) continue;
                    float amount = share * crystal.w;
                    for (uint l = 0; l < a.levels; ++l) {
                        if (crystal.z < fractions[l]) sum[l] += amount;
                    }
                }
            }
        }
        uint plane = a.n * a.n, index = g.y * a.n + g.x;
        for (uint l = 0; l < a.levels; ++l) deposit[l * plane + index] = sum[l];
    }

    struct PassArguments {
        uint inWidth, inHeight, outWidth, outHeight, taps, stride;
        int offset;
        uint levels;
    };

    // out[i] = Σ_t weights[t] · in[(stride·i + offset + t) mod width] along rows.
    kernel void film_tile_rows(device const float *source [[buffer(0)]],
                               device float *target [[buffer(1)]],
                               constant float *weights [[buffer(2)]],
                               constant PassArguments &a [[buffer(3)]],
                               uint3 g [[thread_position_in_grid]]) {
        if (g.x >= a.outWidth || g.y >= a.outHeight || g.z >= a.levels) return;
        device const float *row = source + (g.z * a.inHeight + g.y) * a.inWidth;
        int start = int(a.stride * g.x) + a.offset, width = int(a.inWidth);
        float sum = 0.0f;
        if (start >= 0 && start + int(a.taps) <= width) {
            device const float *tap = row + start;
            for (uint t = 0; t < a.taps; ++t) sum += weights[t] * tap[t];
        } else {
            for (uint t = 0; t < a.taps; ++t) sum += weights[t] * row[wrap(start + int(t), width)];
        }
        target[(g.z * a.outHeight + g.y) * a.outWidth + g.x] = sum;
    }

    // The same along columns.
    kernel void film_tile_columns(device const float *source [[buffer(0)]],
                                  device float *target [[buffer(1)]],
                                  constant float *weights [[buffer(2)]],
                                  constant PassArguments &a [[buffer(3)]],
                                  uint3 g [[thread_position_in_grid]]) {
        if (g.x >= a.outWidth || g.y >= a.outHeight || g.z >= a.levels) return;
        device const float *column = source + g.z * a.inHeight * a.inWidth + g.x;
        int start = int(a.stride * g.y) + a.offset, height = int(a.inHeight);
        float sum = 0.0f;
        if (start >= 0 && start + int(a.taps) <= height) {
            device const float *tap = column + uint(start) * a.inWidth;
            for (uint t = 0; t < a.taps; ++t) sum += weights[t] * tap[t * a.inWidth];
        } else {
            for (uint t = 0; t < a.taps; ++t) sum += weights[t] * column[wrap(start + int(t), height) * a.inWidth];
        }
        target[(g.z * a.outHeight + g.y) * a.outWidth + g.x] = sum;
    }

    struct FullArguments { uint n, levels, terms; uint taps[4]; };

    // Every full-resolution term's row blur of the deposits, reading them once.
    kernel void film_tile_full_rows(device const float *deposit [[buffer(0)]],
                                    device float *across [[buffer(1)]],
                                    constant float *weights [[buffer(2)]],
                                    constant FullArguments &a [[buffer(3)]],
                                    uint3 g [[thread_position_in_grid]]) {
        if (g.x >= a.n || g.y >= a.n || g.z >= a.levels) return;
        int n = int(a.n);
        device const float *row = deposit + (g.z * a.n + g.y) * a.n;
        uint plane = a.n * a.n * a.levels, index = (g.z * a.n + g.y) * a.n + g.x;
        for (uint term = 0; term < a.terms; ++term) {
            constant float *w = weights + term * kMaxTaps;
            uint taps = a.taps[term];
            int start = int(g.x) - int(taps / 2);
            float sum = 0.0f;
            if (start >= 0 && start + int(taps) <= n) {
                for (uint t = 0; t < taps; ++t) sum += w[t] * row[start + int(t)];
            } else {
                for (uint t = 0; t < taps; ++t) sum += w[t] * row[wrap(start + int(t), n)];
            }
            across[term * plane + index] = sum;
        }
    }

    struct DemandArguments {
        uint n, levels, fullTerms, coarseTerms, accumulate;
        float capacity;
        uint taps[4];
        float fullScale[4];
        uint sides[4], factors[4];
        float coarseScale[4];
    };

    inline float coarse_read(device const float *grid, uint m, uint factor, uint3 g) {
        float f = float(factor);
        float uf = (float(g.x) + 0.5f) / f - 0.5f, vf = (float(g.y) + 0.5f) / f - 0.5f;
        int iu = int(floor(uf)), iv = int(floor(vf));
        float au = uf - float(iu), av = vf - float(iv);
        int side = int(m);
        uint a0 = uint(iu < 0 ? iu + side : iu), a1 = uint(iu + 1 >= side ? iu + 1 - side : iu + 1);
        uint b0 = uint(iv < 0 ? iv + side : iv) * m, b1 = uint(iv + 1 >= side ? iv + 1 - side : iv + 1) * m;
        device const float *plane = grid + g.z * m * m;
        return (plane[b0 + a0] * (1.0f - au) + plane[b0 + a1] * au) * (1.0f - av)
            + (plane[b1 + a0] * (1.0f - au) + plane[b1 + a1] * au) * av;
    }

    // A sample's demand — the full terms' column sums, then the coarse terms read back
    // linearly — saturated against the sublayer's capacity and added to the dye.
    kernel void film_tile_demand(device const float *across [[buffer(0)]],
                                 device float *dye [[buffer(1)]],
                                 constant float *weights [[buffer(2)]],
                                 constant DemandArguments &a [[buffer(3)]],
                                 device const float *grid0 [[buffer(4)]],
                                 device const float *grid1 [[buffer(5)]],
                                 device const float *grid2 [[buffer(6)]],
                                 device const float *grid3 [[buffer(7)]],
                                 uint3 g [[thread_position_in_grid]]) {
        if (g.x >= a.n || g.y >= a.n || g.z >= a.levels) return;
        int n = int(a.n);
        uint plane = a.n * a.n * a.levels;
        float demand = 0.0f;
        for (uint term = 0; term < a.fullTerms; ++term) {
            constant float *w = weights + term * kMaxTaps;
            uint taps = a.taps[term];
            device const float *column = across + term * plane + g.z * a.n * a.n + g.x;
            int start = int(g.y) - int(taps / 2);
            float sum = 0.0f;
            if (start >= 0 && start + int(taps) <= n) {
                for (uint t = 0; t < taps; ++t) sum += w[t] * column[uint(start + int(t)) * a.n];
            } else {
                for (uint t = 0; t < taps; ++t) sum += w[t] * column[uint(wrap(start + int(t), n)) * a.n];
            }
            demand += a.fullScale[term] * sum;
        }
        device const float *grids[4] = {grid0, grid1, grid2, grid3};
        for (uint c = 0; c < a.coarseTerms; ++c) {
            demand += a.coarseScale[c] * coarse_read(grids[c], a.sides[c], a.factors[c], g);
        }
        uint index = (g.z * a.n + g.y) * a.n + g.x;
        float value = a.capacity * (1.0f - exp(-demand));
        dye[index] = a.accumulate ? dye[index] + value : value;
    }

    struct LightArguments { uint texels, supersample, levels; };

    // A texel passes the mean of its samples' transmittance.
    kernel void film_tile_light(device const float *dye [[buffer(0)]],
                                device float *light [[buffer(1)]],
                                constant LightArguments &a [[buffer(2)]],
                                uint3 g [[thread_position_in_grid]]) {
        if (g.x >= a.texels || g.y >= a.texels || g.z >= a.levels) return;
        uint s = a.supersample, n = a.texels * s;
        device const float *plane = dye + g.z * n * n;
        float sum = 0.0f;
        for (uint j = 0; j < s; ++j) {
            for (uint i = 0; i < s; ++i) {
                sum += exp(-2.302585093f * plane[(s * g.y + j) * n + s * g.x + i]);
            }
        }
        light[(g.z * a.texels + g.y) * a.texels + g.x] = sum / float(s * s);
    }
    """
}
#endif
