#if canImport(Metal)
import Foundation
import Metal

/// Film grain laid crystal by crystal over a whole frame by hand-written Metal, for renders that
/// must not show the tiles' repeats.
///
/// The film is the one the tiles hold — texels of `FilmGrain.tileTexelMM`, sampled `supersample`
/// times a side, every sublayer's crystals hashed by `FilmRandom` from their cell — but laid
/// without a period, and each crystal develops with the probability its sublayer has at the
/// frame's own developed density where it sits, as `FilmGrain.renderTile` develops it. The film
/// is laid in squares of `core` texels with a halo the widest cloud reaches across; a texel passes
/// the mean light of its samples. A pixel reads the light through its footprint, and its grain is
/// that density less the mean density its footprint reads at its developed density.
final class FilmFrameMetalRenderer: @unchecked Sendable {
    /// The renderer, or nil where Metal cannot run it.
    static let shared: FilmFrameMetalRenderer? = try? FilmFrameMetalRenderer()

    /// Texels a side of the square of film one pass lays, before its halo.
    static let core = 1024

    /// One sublayer as the kernels lay it.
    struct Sublayer {
        var silver: Bool
        var cellTexels: Float
        var limit: Int
        var thresholds: [Float]
        var forming: [Float]
        var edge: Float
        var capacity: Float
        /// A silver grain's share laid as a resolved Gaussian; the rest covers its samples.
        var resolvedShare: Float
        /// The demand's blur terms in samples, each with the mass it gives a crystal of peak 1.
        var terms: [(sigma: Float, scale: Float)]
        /// A silver grain's sigma in samples, which sets the side of the square it covers.
        var sigmaSamples: Float
        var crystalBase: UInt32
        var countBase: UInt32
    }

    /// One record of a frame.
    struct Record {
        var sublayers: [Sublayer]
        var dMin: Float
        var tableScale: Float
        /// `FilmGrain.occupiedArea` of a silver grain against its peak, `areaStep` apart.
        var areas: [Float]
        var areaStep: Float
        /// Texels the widest demand reaches past a crystal.
        var reachTexels: Float
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let cellsPipeline, clear, fullRows, rows, columns, demand, light, boxRows, boxPixels:
        MTLComputePipelineState
    private let lock = NSLock()

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw RenderError.unavailable
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
            guard let function = library.makeFunction(name: name) else { throw RenderError.unavailable }
            return try device.makeComputePipelineState(function: function)
        }
        cellsPipeline = try pipeline("frame_cells")
        clear = try pipeline("frame_clear")
        fullRows = try pipeline("frame_full_rows")
        rows = try pipeline("frame_rows")
        columns = try pipeline("frame_columns")
        demand = try pipeline("frame_demand")
        light = try pipeline("frame_light")
        boxRows = try pipeline("frame_box_rows")
        boxPixels = try pipeline("frame_box_pixels")
    }

    enum RenderError: Error { case unavailable }

    /// Terms of each kind a sublayer blurs at most, and taps a full-resolution term holds at
    /// most: a term goes coarse from 3.2 samples, whose kernel is 3.5 σ either side.
    static let maxTerms = 4, maxTaps = 32

    /// The grain of one record at every pixel of a `width × height` frame whose developed gross
    /// density is `density`: `amount` times the density the pixel's footprint reads less
    /// `meanAt` the mean its footprint reads at that density, between levels `lo` and `hi`.
    /// `pitch` and `footprint` are in texels; pixel `(x, y)` reads the square of side
    /// `footprint` centred at `((x + ½) pitch, (y + ½) pitch)`. With `raw`, the density itself.
    func render(record: Record, density: [Float], width: Int, height: Int, pitch: Float,
                footprint: Float, supersample s: Int, amount: Float, meanAt: [Float],
                lo: Float, hi: Float, raw: Bool = false,
                shouldContinue: () -> Bool) -> [Float]? {
        guard width > 0, height > 0, density.count == width * height, pitch > 0, footprint > 0,
              s >= 1, !record.sublayers.isEmpty, meanAt.count >= 2 else { return nil }
        let core = Self.core
        guard footprint < Float(core) / 2 else { return nil }
        lock.lock()
        defer { lock.unlock() }

        // A halo every demand reaches across, wide enough that the grid is a multiple of every
        // coarse blur's factor.
        let factors = record.sublayers.flatMap { $0.terms.map { max(Int($0.sigma / 1.6), 1) } }
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let multiple = factors.reduce(1) { $0 / gcd($0, $1) * $1 }
        var halo = Int((record.reachTexels).rounded(.up)) + 2
        while ((core + 2 * halo) * s) % multiple != 0 { halo += 1 }
        let n = (core + 2 * halo) * s
        let plane = n * n
        // The film the frame reads: every pixel's footprint, a texel to spare either side.
        let half = footprint / 2
        let filmX0 = Int((0.5 * pitch - half).rounded(.down)) - 1
        let filmX1 = Int(((Float(width) - 0.5) * pitch + half).rounded(.up)) + 1
        let bandWidth = filmX1 - filmX0
        let tilesAcross = (bandWidth + core - 1) / core
        let bandStride = tilesAcross * core

        // Each sublayer's terms: the narrow ones blurred at full resolution, the wide ones on a
        // grid `factor` samples coarser.
        struct Coarse { var factor: Int; var tent: [Float]; var kernel: [Float]; var scale: Float }
        struct Terms { var full: [[Float]]; var fullScale: [Float]; var coarse: [Coarse] }
        let terms = record.sublayers.map { layer -> Terms in
            var full: [[Float]] = [], fullScale: [Float] = [], coarse: [Coarse] = []
            for term in layer.terms {
                let factor = max(Int(term.sigma / 1.6), 1)
                if factor == 1 {
                    full.append(FilmGrain.gaussianKernel(sigma: term.sigma))
                    fullScale.append(term.scale)
                } else {
                    let f = Float(factor)
                    coarse.append(Coarse(
                        factor: factor,
                        tent: (0..<(3 * factor)).map { t in max(0, 1 - abs((Float(t) + 0.5) / f - 1.5)) },
                        kernel: FilmGrain.gaussianKernel(sigma: (term.sigma * term.sigma - f * f / 3).squareRoot() / f),
                        scale: term.scale / (f * f)))
                }
            }
            return Terms(full: full, fullScale: fullScale, coarse: coarse)
        }
        guard terms.allSatisfy({ $0.full.count <= Self.maxTerms && $0.coarse.count <= Self.maxTerms
                    && $0.full.allSatisfy { $0.count <= Self.maxTaps } }),
              terms.allSatisfy({ $0.coarse.allSatisfy { n % $0.factor == 0 } }) else { return nil }
        let fullPlanes = max(terms.map(\.full.count).max() ?? 1, 1)
        let coarseCount = max(terms.map(\.coarse.count).max() ?? 1, 1)
        let finest = terms.flatMap(\.coarse).map(\.factor).min() ?? n
        let coarseSide = n / finest

        let shared = MTLResourceOptions.storageModeShared
        let held = MTLResourceOptions.storageModePrivate
        guard let densityBuffer = density.withUnsafeBytes({
                  device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: shared) }),
              let output = device.makeBuffer(length: width * height * 4, options: shared),
              let depositBuffer = device.makeBuffer(length: plane * 4, options: held),
              let uncovered = device.makeBuffer(length: plane * 4, options: held),
              let across = device.makeBuffer(length: fullPlanes * plane * 4, options: held),
              let coarseRows = device.makeBuffer(length: coarseSide * n * 4, options: held),
              let coarseA = device.makeBuffer(length: coarseSide * coarseSide * 4, options: held),
              let coarseB = device.makeBuffer(length: coarseSide * coarseSide * 4, options: held),
              let logLight = device.makeBuffer(length: plane * 4, options: held),
              let lightBand = device.makeBuffer(length: bandStride * core * 4, options: held),
              let rowSums = device.makeBuffer(length: width * core * 4, options: held)
        else { return nil }
        let grids = (0..<coarseCount).compactMap { _ in
            device.makeBuffer(length: coarseSide * coarseSide * 4, options: held)
        }
        guard grids.count == coarseCount else { return nil }
        let areaBuffer = record.areas.isEmpty ? nil : record.areas.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: shared)
        }

        // Each sublayer's cells: those whose crystals can land on a pass's samples.
        let extraTexels: Float = 2
        let cellSides = record.sublayers.map {
            Int(((Float(core + 2 * halo) + 2 * extraTexels) / $0.cellTexels).rounded(.up)) + 3
        }

        var nextRow = 0
        while nextRow < height {
            guard shouldContinue() else { return nil }
            // The band of film from the first unfinished row's footprint; the rows whose
            // footprint it holds whole.
            let bandY0 = Int(((Float(nextRow) + 0.5) * pitch - half).rounded(.down)) - 1
            var lastRow = nextRow
            while lastRow < height
                    && (Float(lastRow) + 0.5) * pitch + half <= Float(bandY0 + core) {
                lastRow += 1
            }
            guard lastRow > nextRow,
                  let commands = queue.makeCommandBuffer(),
                  let encoder = commands.makeComputeCommandEncoder() else { return nil }
            func dispatch(_ pipeline: MTLComputePipelineState, _ w: Int, _ h: Int) {
                encoder.setComputePipelineState(pipeline)
                let tw = pipeline.threadExecutionWidth
                let th = max(pipeline.maxTotalThreadsPerThreadgroup / tw, 1)
                encoder.dispatchThreads(MTLSize(width: w, height: h, depth: 1),
                                        threadsPerThreadgroup: MTLSize(width: tw, height: min(th, 8, h), depth: 1))
            }
            func bytes<T>(_ value: T, _ index: Int) {
                withUnsafeBytes(of: value) { encoder.setBytes($0.baseAddress!, length: $0.count, index: index) }
            }
            func floats(_ values: [Float], _ index: Int) {
                values.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: max($0.count, 4), index: index) }
            }
            // A blur along rows or columns: out[i] = Σ_t w[t] · in[stride·i + offset + t], zero
            // past the input.
            func pass(_ pipeline: MTLComputePipelineState, _ source: MTLBuffer, _ target: MTLBuffer,
                      in inSize: (Int, Int), out outSize: (Int, Int), weights: [Float],
                      stride: Int, offset: Int) {
                encoder.setBuffer(source, offset: 0, index: 0)
                encoder.setBuffer(target, offset: 0, index: 1)
                floats(weights, 2)
                bytes(PassArguments(inWidth: UInt32(inSize.0), inHeight: UInt32(inSize.1),
                                    outWidth: UInt32(outSize.0), outHeight: UInt32(outSize.1),
                                    taps: UInt32(weights.count), stride: UInt32(stride),
                                    offset: Int32(offset)), 3)
                dispatch(pipeline, outSize.0, outSize.1)
            }
            func quad<T>(_ values: [T], _ fill: T) -> (T, T, T, T) {
                let v = values + Array(repeating: fill, count: 4 - values.count)
                return (v[0], v[1], v[2], v[3])
            }

            for tile in 0..<tilesAcross {
                let tileX = filmX0 + tile * core
                let originX = Float(tileX - halo), originY = Float(bandY0 - halo)
                for (b, layer) in record.sublayers.enumerated() {
                    let side = cellSides[b]
                    let cx0 = Int(((originX - extraTexels) / layer.cellTexels).rounded(.down))
                    let cy0 = Int(((originY - extraTexels) / layer.cellTexels).rounded(.down))
                    let resolves = !layer.silver || layer.resolvedShare > 0
                    let covers = layer.silver && layer.resolvedShare < 1
                    let laid = terms[b]
                    for (buffer, used) in [(depositBuffer, resolves), (uncovered, covers)] where used {
                        encoder.setBuffer(buffer, offset: 0, index: 0)
                        bytes(UInt32(plane), 1)
                        dispatch(clear, plane, 1)
                    }
                    floats(layer.thresholds, 0)
                    floats(layer.forming, 1)
                    encoder.setBuffer(densityBuffer, offset: 0, index: 2)
                    encoder.setBuffer(areaBuffer ?? densityBuffer, offset: 0, index: 3)
                    bytes(CellArguments(
                        cx0: Int32(cx0), cy0: Int32(cy0), n: UInt32(n), cells: UInt32(side),
                        limit: UInt32(layer.limit), markShape: UInt32(FilmGrain.markShape),
                        crystalBase: layer.crystalBase, countBase: layer.countBase,
                        width: UInt32(width), height: UInt32(height),
                        tableSamples: UInt32(layer.forming.count), areaCount: UInt32(record.areas.count),
                        cellTexels: layer.cellTexels, originX: originX, originY: originY,
                        samples: Float(s), pitch: pitch, edge: layer.edge, dMin: record.dMin,
                        tableScale: record.tableScale, sigmaSamples: layer.sigmaSamples,
                        share: resolves ? (layer.silver ? layer.resolvedShare : 1) : 0,
                        covering: covers ? 1 - layer.resolvedShare : 0,
                        areaStep: record.areaStep), 4)
                    encoder.setBuffer(depositBuffer, offset: 0, index: 5)
                    encoder.setBuffer(uncovered, offset: 0, index: 6)
                    dispatch(cellsPipeline, side, side)
                    if resolves {
                        if !laid.full.isEmpty {
                            var weights = [Float](repeating: 0, count: Self.maxTerms * Self.maxTaps)
                            for (t, kernel) in laid.full.enumerated() {
                                weights.replaceSubrange((t * Self.maxTaps)..<(t * Self.maxTaps + kernel.count),
                                                        with: kernel)
                            }
                            encoder.setBuffer(depositBuffer, offset: 0, index: 0)
                            encoder.setBuffer(across, offset: 0, index: 1)
                            floats(weights, 2)
                            bytes(FullArguments(n: UInt32(n), terms: UInt32(laid.full.count),
                                                taps: quad(laid.full.map { UInt32($0.count) }, 0)), 3)
                            dispatch(fullRows, n, n)
                        }
                        for (c, term) in laid.coarse.enumerated() {
                            let m = n / term.factor, radius = term.kernel.count / 2
                            pass(rows, depositBuffer, coarseRows, in: (n, n), out: (m, n),
                                 weights: term.tent, stride: term.factor, offset: -term.factor)
                            pass(columns, coarseRows, coarseA, in: (m, n), out: (m, m),
                                 weights: term.tent, stride: term.factor, offset: -term.factor)
                            pass(rows, coarseA, coarseB, in: (m, m), out: (m, m),
                                 weights: term.kernel, stride: 1, offset: -radius)
                            pass(columns, coarseB, grids[c], in: (m, m), out: (m, m),
                                 weights: term.kernel, stride: 1, offset: -radius)
                        }
                    }
                    // The demand of every term, saturated against the capacity, the unresolved
                    // grains' cover, and the sublayer's light joined to the others'.
                    var weights = [Float](repeating: 0, count: Self.maxTerms * Self.maxTaps)
                    for (t, kernel) in laid.full.enumerated() {
                        weights.replaceSubrange((t * Self.maxTaps)..<(t * Self.maxTaps + kernel.count), with: kernel)
                    }
                    encoder.setBuffer(across, offset: 0, index: 0)
                    encoder.setBuffer(logLight, offset: 0, index: 1)
                    floats(weights, 2)
                    bytes(DemandArguments(
                        n: UInt32(n), fullTerms: UInt32(resolves ? laid.full.count : 0),
                        coarseTerms: UInt32(resolves ? laid.coarse.count : 0),
                        first: b == 0 ? 1 : 0, covers: covers ? 1 : 0, capacity: layer.capacity,
                        taps: quad(laid.full.map { UInt32($0.count) }, 0),
                        fullScale: quad(laid.fullScale, 0),
                        sides: quad(laid.coarse.map { UInt32(n / $0.factor) }, 1),
                        factors: quad(laid.coarse.map { UInt32($0.factor) }, 1),
                        coarseScale: quad(laid.coarse.map(\.scale), 0)), 3)
                    for slot in 0..<Self.maxTerms {
                        encoder.setBuffer(slot < grids.count ? grids[slot] : logLight, offset: 0, index: 4 + slot)
                    }
                    encoder.setBuffer(uncovered, offset: 0, index: 8)
                    dispatch(demand, n, n)
                }
                encoder.setBuffer(logLight, offset: 0, index: 0)
                encoder.setBuffer(lightBand, offset: 0, index: 1)
                bytes(LightArguments(core: UInt32(core), n: UInt32(n), halo: UInt32(halo),
                                     supersample: UInt32(s), bandStride: UInt32(bandStride),
                                     column: UInt32(tile * core)), 2)
                dispatch(light, core, core)
            }

            let box = BoxArguments(
                width: UInt32(width), height: UInt32(height), bandStride: UInt32(bandStride),
                bandRows: UInt32(core), firstRow: UInt32(nextRow), rows: UInt32(lastRow - nextRow),
                levels: UInt32(meanAt.count), raw: raw ? 1 : 0,
                pitch: pitch, footprint: footprint, filmX0: Float(filmX0), bandY0: Float(bandY0),
                amount: amount, lo: lo, hi: hi)
            encoder.setBuffer(lightBand, offset: 0, index: 0)
            encoder.setBuffer(rowSums, offset: 0, index: 1)
            bytes(box, 2)
            dispatch(boxRows, width, core)
            encoder.setBuffer(rowSums, offset: 0, index: 0)
            encoder.setBuffer(densityBuffer, offset: 0, index: 1)
            encoder.setBuffer(output, offset: 0, index: 2)
            floats(meanAt, 3)
            bytes(box, 4)
            dispatch(boxPixels, width, lastRow - nextRow)
            encoder.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
            guard commands.status == .completed else { return nil }
            nextRow = lastRow
        }
        let pointer = output.contents().bindMemory(to: Float.self, capacity: width * height)
        return Array(UnsafeBufferPointer(start: pointer, count: width * height))
    }

    private struct CellArguments {
        var cx0, cy0: Int32
        var n, cells, limit, markShape, crystalBase, countBase, width, height, tableSamples,
            areaCount: UInt32
        var cellTexels, originX, originY, samples, pitch, edge, dMin, tableScale, sigmaSamples,
            share, covering, areaStep: Float
    }
    private struct PassArguments {
        var inWidth, inHeight, outWidth, outHeight, taps, stride: UInt32
        var offset: Int32
    }
    private struct FullArguments {
        var n, terms: UInt32
        var taps: (UInt32, UInt32, UInt32, UInt32)
    }
    private struct DemandArguments {
        var n, fullTerms, coarseTerms, first, covers: UInt32
        var capacity: Float
        var taps: (UInt32, UInt32, UInt32, UInt32)
        var fullScale: (Float, Float, Float, Float)
        var sides, factors: (UInt32, UInt32, UInt32, UInt32)
        var coarseScale: (Float, Float, Float, Float)
    }
    private struct LightArguments { var core, n, halo, supersample, bandStride, column: UInt32 }
    private struct BoxArguments {
        var width, height, bandStride, bandRows, firstRow, rows, levels, raw: UInt32
        var pitch, footprint, filmX0, bandY0, amount, lo, hi: Float
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    constant uint kGolden = 0x9E3779B9u;
    constant uint kMaxCount = \(FilmRandom.maxCount);

    inline uint pcg(uint value) {
        uint state = value * 747796405u + 2891336453u;
        uint word = ((state >> ((state >> 28) + 4)) ^ state) * 277803737u;
        return (word >> 22) ^ word;
    }
    inline float uniform01(uint hash) { return (float(hash >> 8) + 0.5f) * (1.0f / 16777216.0f); }
    inline uint cell_key(uint base, uint x, uint y) { return pcg(x ^ pcg(y ^ pcg(base))); }
    inline float draw(uint key, uint index) { return uniform01(pcg(key ^ (index * kGolden))); }

    struct CellArguments {
        int cx0, cy0;
        uint n, cells, limit, markShape, crystalBase, countBase, width, height, tableSamples,
            areaCount;
        float cellTexels, originX, originY, samples, pitch, edge, dMin, tableScale, sigmaSamples,
            share, covering, areaStep;
    };

    kernel void frame_clear(device float *target [[buffer(0)]], constant uint &count [[buffer(1)]],
                            uint g [[thread_position_in_grid]]) {
        if (g < count) target[g] = 0.0f;
    }

    // The frame's developed density at a point in pixel coordinates, pixel centres at integers,
    // held to the frame: `FilmGrain.bilinear`.
    inline float gross_at(device const float *plane, uint width, uint height, float x, float y) {
        float fx = min(max(x, 0.0f), float(width - 1)), fy = min(max(y, 0.0f), float(height - 1));
        uint x0 = min(uint(fx), width > 1 ? width - 2 : 0), y0 = min(uint(fy), height > 1 ? height - 2 : 0);
        uint x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1);
        float ax = fx - float(x0), ay = fy - float(y0);
        float top = plane[y0 * width + x0] * (1.0f - ax) + plane[y0 * width + x1] * ax;
        float bottom = plane[y1 * width + x0] * (1.0f - ax) + plane[y1 * width + x1] * ax;
        return top * (1.0f - ay) + bottom * ay;
    }

    // A cell's crystals, each developed with the probability its sublayer has at the frame's
    // density where it sits: a dye cloud's or resolved silver grain's peak demand shared between
    // the four samples about it by distance, as the reference deposits it, and an unresolved
    // silver grain's square laid over the samples it covers, as the log of what it leaves open.
    kernel void frame_cells(constant float *thresholds [[buffer(0)]],
                            constant float *forming [[buffer(1)]],
                            device const float *density [[buffer(2)]],
                            device const float *areas [[buffer(3)]],
                            constant CellArguments &a [[buffer(4)]],
                            device atomic_float *deposit [[buffer(5)]],
                            device atomic_float *uncovered [[buffer(6)]],
                            uint2 g [[thread_position_in_grid]]) {
        if (g.x >= a.cells || g.y >= a.cells) return;
        int ux = a.cx0 + int(g.x), uy = a.cy0 + int(g.y);
        float u = draw(cell_key(a.countBase, uint(ux), uint(uy)), 0);
        uint count = 0;
        for (uint k = 0; k < kMaxCount; ++k) count += thresholds[k] < u ? 1 : 0;
        count = min(count, a.limit);
        uint key = cell_key(a.crystalBase, uint(ux), uint(uy));
        int n = int(a.n);
        for (uint c = 0; c < count; ++c) {
            uint first = c * (3 + a.markShape);
            float tx = (float(ux) + draw(key, first)) * a.cellTexels;
            float ty = (float(uy) + draw(key, first + 1)) * a.cellTexels;
            float gross = gross_at(density, a.width, a.height, tx / a.pitch - 0.5f, ty / a.pitch - 0.5f);
            float t = min(max((gross - a.dMin) * a.tableScale, 0.0f), float(a.tableSamples - 1));
            uint ti = min(uint(t), a.tableSamples - 2);
            float tf = t - float(ti);
            float fraction = forming[ti] * (1.0f - tf) + forming[ti + 1] * tf;
            if (!(draw(key, first + 2) < fraction)) continue;
            float mark = 0.0f;
            for (uint i = 0; i < a.markShape; ++i) mark -= log(max(draw(key, first + 3 + i), 1.0e-7f));
            mark /= float(a.markShape);
            float peak = a.edge * mark;
            float x = (tx - a.originX) * a.samples, y = (ty - a.originY) * a.samples;
            if (a.share > 0.0f) {
                float su = x - 0.5f, sv = y - 0.5f;
                int i0 = int(floor(su)), j0 = int(floor(sv));
                float au = su - float(i0), av = sv - float(j0);
                float amount = peak * a.share;
                for (int dj = 0; dj < 2; ++dj) {
                    int j = j0 + dj;
                    if (j < 0 || j >= n) continue;
                    float wy = dj == 0 ? 1.0f - av : av;
                    for (int di = 0; di < 2; ++di) {
                        int i = i0 + di;
                        if (i < 0 || i >= n) continue;
                        float wx = di == 0 ? 1.0f - au : au;
                        atomic_fetch_add_explicit(&deposit[uint(j) * a.n + uint(i)], amount * wx * wy,
                                                  memory_order_relaxed);
                    }
                }
            }
            if (a.covering > 0.0f && a.areaCount > 1) {
                float at = min(peak / a.areaStep, float(a.areaCount - 1));
                uint ai = min(uint(at), a.areaCount - 2);
                float area = areas[ai] + (areas[ai + 1] - areas[ai]) * (at - float(ai));
                float half_side = 0.5f * a.sigmaSamples * sqrt(max(area, 0.0f));
                float left = x - half_side, right = x + half_side;
                float top = y - half_side, bottom = y + half_side;
                int i0 = max(int(floor(left)), 0), i1 = min(int(floor(right)), n - 1);
                int j0 = max(int(floor(top)), 0), j1 = min(int(floor(bottom)), n - 1);
                for (int j = j0; j <= j1; ++j) {
                    float oy = min(bottom, float(j + 1)) - max(top, float(j));
                    if (oy <= 0.0f) continue;
                    for (int i = i0; i <= i1; ++i) {
                        float ox = min(right, float(i + 1)) - max(left, float(i));
                        if (ox <= 0.0f) continue;
                        atomic_fetch_add_explicit(&uncovered[uint(j) * a.n + uint(i)],
                                                  log(max(1.0f - a.covering * ox * oy, 1.0e-6f)),
                                                  memory_order_relaxed);
                    }
                }
            }
        }
    }

    struct PassArguments {
        uint inWidth, inHeight, outWidth, outHeight, taps, stride;
        int offset;
    };

    kernel void frame_rows(device const float *source [[buffer(0)]],
                           device float *target [[buffer(1)]],
                           constant float *weights [[buffer(2)]],
                           constant PassArguments &a [[buffer(3)]],
                           uint2 g [[thread_position_in_grid]]) {
        if (g.x >= a.outWidth || g.y >= a.outHeight) return;
        device const float *row = source + g.y * a.inWidth;
        int start = int(a.stride * g.x) + a.offset, width = int(a.inWidth);
        float sum = 0.0f;
        for (uint t = 0; t < a.taps; ++t) {
            int i = start + int(t);
            if (i >= 0 && i < width) sum += weights[t] * row[i];
        }
        target[g.y * a.outWidth + g.x] = sum;
    }

    kernel void frame_columns(device const float *source [[buffer(0)]],
                              device float *target [[buffer(1)]],
                              constant float *weights [[buffer(2)]],
                              constant PassArguments &a [[buffer(3)]],
                              uint2 g [[thread_position_in_grid]]) {
        if (g.x >= a.outWidth || g.y >= a.outHeight) return;
        int start = int(a.stride * g.y) + a.offset, height = int(a.inHeight);
        float sum = 0.0f;
        for (uint t = 0; t < a.taps; ++t) {
            int j = start + int(t);
            if (j >= 0 && j < height) sum += weights[t] * source[uint(j) * a.inWidth + g.x];
        }
        target[g.y * a.outWidth + g.x] = sum;
    }

    constant uint kMaxTaps = \(maxTaps);

    struct FullArguments { uint n, terms; uint taps[4]; };

    // Every full-resolution term's row blur of the deposits, reading them once, zero past them.
    kernel void frame_full_rows(device const float *deposit [[buffer(0)]],
                                device float *across [[buffer(1)]],
                                constant float *weights [[buffer(2)]],
                                constant FullArguments &a [[buffer(3)]],
                                uint2 g [[thread_position_in_grid]]) {
        if (g.x >= a.n || g.y >= a.n) return;
        int n = int(a.n);
        device const float *row = deposit + g.y * a.n;
        uint plane = a.n * a.n, index = g.y * a.n + g.x;
        for (uint term = 0; term < a.terms; ++term) {
            constant float *w = weights + term * kMaxTaps;
            uint taps = a.taps[term];
            int start = int(g.x) - int(taps / 2);
            float sum = 0.0f;
            if (start >= 0 && start + int(taps) <= n) {
                for (uint t = 0; t < taps; ++t) sum += w[t] * row[start + int(t)];
            } else {
                for (uint t = 0; t < taps; ++t) {
                    int i = start + int(t);
                    if (i >= 0 && i < n) sum += w[t] * row[i];
                }
            }
            across[term * plane + index] = sum;
        }
    }

    struct DemandArguments {
        uint n, fullTerms, coarseTerms, first, covers;
        float capacity;
        uint taps[4];
        float fullScale[4];
        uint sides[4], factors[4];
        float coarseScale[4];
    };

    inline float coarse_read(device const float *grid, uint m, uint factor, uint2 g) {
        float f = float(factor);
        float uf = (float(g.x) + 0.5f) / f - 0.5f, vf = (float(g.y) + 0.5f) / f - 0.5f;
        int side = int(m);
        int iu = min(max(int(floor(uf)), 0), side - 2), iv = min(max(int(floor(vf)), 0), side - 2);
        float au = clamp(uf - float(iu), 0.0f, 1.0f), av = clamp(vf - float(iv), 0.0f, 1.0f);
        uint b0 = uint(iv) * m, b1 = uint(iv + 1) * m;
        return (grid[b0 + iu] * (1.0f - au) + grid[b0 + iu + 1] * au) * (1.0f - av)
            + (grid[b1 + iu] * (1.0f - au) + grid[b1 + iu + 1] * au) * av;
    }

    // A sample's demand — the full terms' column sums, then the coarse terms read back
    // linearly — saturated against the sublayer's capacity; where unresolved grains cover the
    // sample it is at capacity. Its light joins the other sublayers' as a log.
    kernel void frame_demand(device const float *across [[buffer(0)]],
                             device float *log_light [[buffer(1)]],
                             constant float *weights [[buffer(2)]],
                             constant DemandArguments &a [[buffer(3)]],
                             device const float *grid0 [[buffer(4)]],
                             device const float *grid1 [[buffer(5)]],
                             device const float *grid2 [[buffer(6)]],
                             device const float *grid3 [[buffer(7)]],
                             device const float *uncovered [[buffer(8)]],
                             uint2 g [[thread_position_in_grid]]) {
        if (g.x >= a.n || g.y >= a.n) return;
        int n = int(a.n);
        uint plane = a.n * a.n, index = g.y * a.n + g.x;
        float demand = 0.0f;
        for (uint term = 0; term < a.fullTerms; ++term) {
            constant float *w = weights + term * kMaxTaps;
            uint taps = a.taps[term];
            device const float *column = across + term * plane + g.x;
            int start = int(g.y) - int(taps / 2);
            float sum = 0.0f;
            if (start >= 0 && start + int(taps) <= n) {
                for (uint t = 0; t < taps; ++t) sum += w[t] * column[uint(start + int(t)) * a.n];
            } else {
                for (uint t = 0; t < taps; ++t) {
                    int j = start + int(t);
                    if (j >= 0 && j < n) sum += w[t] * column[uint(j) * a.n];
                }
            }
            demand += a.fullScale[term] * sum;
        }
        device const float *grids[4] = {grid0, grid1, grid2, grid3};
        for (uint c = 0; c < a.coarseTerms; ++c) {
            demand += a.coarseScale[c] * coarse_read(grids[c], a.sides[c], a.factors[c], g);
        }
        float covered = a.covers != 0 ? uncovered[index] : 0.0f;
        float add = 0.0f;
        float resolved = demand > 0.0f ? a.capacity * (1.0f - exp(-demand)) : 0.0f;
        float open = covered < 0.0f ? exp(covered) : 1.0f;
        if (resolved != 0.0f || open != 1.0f) {
            float passed = open * exp(-2.302585093f * resolved)
                + (1.0f - open) * exp(-2.302585093f * a.capacity);
            add = log(max(passed, 1.0e-12f));
        }
        log_light[index] = a.first != 0 ? add : log_light[index] + add;
    }

    struct LightArguments { uint core, n, halo, supersample, bandStride, column; };

    // A core texel passes the mean of its samples' light.
    kernel void frame_light(device const float *log_light [[buffer(0)]],
                            device float *band [[buffer(1)]],
                            constant LightArguments &a [[buffer(2)]],
                            uint2 g [[thread_position_in_grid]]) {
        if (g.x >= a.core || g.y >= a.core) return;
        uint s = a.supersample;
        uint sx = (g.x + a.halo) * s, sy = (g.y + a.halo) * s;
        float sum = 0.0f;
        for (uint j = 0; j < s; ++j) {
            for (uint i = 0; i < s; ++i) sum += exp(log_light[(sy + j) * a.n + sx + i]);
        }
        band[g.y * a.bandStride + a.column + g.x] = sum / float(s * s);
    }

    struct BoxArguments {
        uint width, height, bandStride, bandRows, firstRow, rows, levels, raw;
        float pitch, footprint, filmX0, bandY0, amount, lo, hi;
    };

    // Each band row's light through every pixel column's footprint, texels weighed by how much
    // of them it covers.
    kernel void frame_box_rows(device const float *band [[buffer(0)]],
                               device float *sums [[buffer(1)]],
                               constant BoxArguments &a [[buffer(2)]],
                               uint2 g [[thread_position_in_grid]]) {
        if (g.x >= a.width || g.y >= a.bandRows) return;
        float x0 = (float(g.x) + 0.5f) * a.pitch - 0.5f * a.footprint - a.filmX0;
        float x1 = x0 + a.footprint;
        int i0 = max(int(floor(x0)), 0), i1 = min(int(ceil(x1)), int(a.bandStride));
        device const float *row = band + g.y * a.bandStride;
        float sum = 0.0f;
        for (int i = i0; i < i1; ++i) {
            float w = min(x1, float(i + 1)) - max(x0, float(i));
            if (w > 0.0f) sum += w * row[i];
        }
        sums[g.y * a.width + g.x] = sum;
    }

    // A pixel's light through its footprint, as density, less the mean its footprint reads at
    // its developed density.
    kernel void frame_box_pixels(device const float *sums [[buffer(0)]],
                                 device const float *density [[buffer(1)]],
                                 device float *grain [[buffer(2)]],
                                 constant float *mean_at [[buffer(3)]],
                                 constant BoxArguments &a [[buffer(4)]],
                                 uint2 g [[thread_position_in_grid]]) {
        if (g.x >= a.width || g.y >= a.rows) return;
        uint y = a.firstRow + g.y;
        float y0 = (float(y) + 0.5f) * a.pitch - 0.5f * a.footprint - a.bandY0;
        float y1 = y0 + a.footprint;
        int j0 = max(int(floor(y0)), 0), j1 = min(int(ceil(y1)), int(a.bandRows));
        float sum = 0.0f;
        for (int j = j0; j < j1; ++j) {
            float w = min(y1, float(j + 1)) - max(y0, float(j));
            if (w > 0.0f) sum += w * sums[uint(j) * a.width + g.x];
        }
        float light = sum / (a.footprint * a.footprint);
        float d = -log10(max(light, 1.0e-9f));
        uint index = y * a.width + g.x;
        if (a.raw != 0) {
            grain[index] = d;
            return;
        }
        float steps = float(a.levels - 1);
        float t = clamp((density[index] - a.lo) / max(a.hi - a.lo, 1.0e-6f), 0.0f, 1.0f) * steps;
        uint k = min(uint(t), a.levels - 2);
        float w = t - float(k);
        float mean = mean_at[k] * (1.0f - w) + mean_at[k + 1] * w;
        grain[index] = a.amount * (d - mean);
    }
    """
}
#endif
