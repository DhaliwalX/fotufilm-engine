import Foundation
import FotufilmHalide

public struct TransportCompilation: Sendable {
    public let kernels: [TransportRadialKernel]
    /// [basis][receiver][wavelength], positive weights at amount zero and at the largest return.
    /// Each record's direct capture is its core at weight one in both; the returned light is
    /// added on top of it, never taken from it, as the light an anti-halation layer would have
    /// absorbed. A donor stock's fourth record is a fourth receiver.
    public let core: [[[Float]]]
    public let saturated: [[[Float]]]
    /// The largest returned-to-direct ratio, the scale of `saturated`'s returned weights.
    public let maximumReturnedRatio: Double
    public let maximumEdgeError: Double
    /// Uniform ESF error bound from equal-mass radial compression alone.
    public let radialCompressionErrorBound: Double
    public let maximumUnresolvedPower: Double

    /// How far toward `saturated` an amount reaches: at one, every record returns its own
    /// ratio of its direct light; the returned light scales with the amount from there.
    public func interpolation(amount: Double) -> Float {
        Float(max(amount, 0) * maximumReturnedRatio)
    }
}

public enum TransportKernelCompiler {
    /// Fits only convex combinations of actual solved kernels. An error limit failure is
    /// explicit; it never falls back to the legacy three-Gaussian approximation.
    ///
    /// `donorDepthMM` adds a donor stock's fourth record as a fourth receiver, solved at its own
    /// depth. It is coated against the green record and sensitive on that record's short-wave
    /// side, so it takes the green receiver's launch, capture, return and core.
    ///
    /// `hazeMM` blurs the returned light with the support's impurity scatter, a Gaussian sigma.
    /// `reference` is the film's own construction when `model` adjusts its geometry or absorbers;
    /// see `adjustedReturn` for how the red return follows. The other records keep the film's
    /// ratios to red.
    public static func compile(_ model: LayeredTransport, returnGain: [Float] = [],
                               sourceColour: Float = 0, hazeMM: Double = 0, donorDepthMM: Double? = nil,
                               reference: LayeredTransport? = nil,
                               maximumComponents: Int = 8, edgeTolerance: Double = 0.005,
                               angularSamples: Int = 512) throws -> TransportCompilation {
        try model.validate()
        try reference?.validate()
        guard (1...24).contains(maximumComponents), edgeTolerance.isFinite,
              edgeTolerance > 0 && edgeTolerance <= 0.02,
              returnGain.isEmpty || (returnGain.count == SpectralGrid.count && returnGain.allSatisfy { $0.isFinite && $0 >= 0 }),
              sourceColour.isFinite && (0...1).contains(sourceColour),
              hazeMM.isFinite && (0...0.5).contains(hazeMM) else {
            throw TransportError.invalid("invalid kernel compilation settings")
        }
        let bands = SpectralGrid.count
        // Each receiver solves as one of the construction's three: the donor as green, moved.
        func donor(_ model: LayeredTransport) throws -> LayeredTransport {
            var moved = model
            if let donorDepthMM { moved.recordDepthMM[1] = donorDepthMM; try moved.validate() }
            return moved
        }
        let donorModel = try donor(model)
        let references = try reference.map { reference in
            (film: reference, lossless: try reference.adjusted(antiHalation: 0, baseThickness: 1, pressurePlate: 0))
        }
        let receivers = donorDepthMM == nil ? 3 : 4
        func like(_ c: Int) -> Int { c < 3 ? c : 1 }
        var targets = [TransportRadialKernel]()
        var targetIndex = Array(repeating: Array(repeating: 0, count: bands), count: receivers)
        var ratios = Array(repeating: Array(repeating: 0.0, count: bands), count: receivers)
        var worstUnresolved = 0.0
        var compressionBound = 0.0
        func signature(_ solving: LayeredTransport, _ r: Int, _ band: Int) -> String {
            var signature: [Double] = [Double(r), solving.recordDepthMM[r],
                             LayeredTransport.sample(solving.angularExponent[r], band),
                             LayeredTransport.sample(solving.captureProbability[r], band),
                             LayeredTransport.sample(solving.frontIndex, band),
                             LayeredTransport.sample(solving.rearIndex, band),
                             solving.rearReflectance.map { LayeredTransport.sample($0, band) } ?? -1,
                             solving.rearPlateReflectance.map { LayeredTransport.sample($0, band) } ?? -1,
                             Double(angularSamples)]
            for layer in solving.layers {
                signature += [layer.thicknessMM, LayeredTransport.sample(layer.refractiveIndex, band),
                              LayeredTransport.sample(layer.absorptionPerMM, band)]
            }
            return signature.map { String($0.bitPattern) }.joined(separator: ":")
        }
        // Every solve the compilation reads, solved together up front.
        var requests = [(model: LayeredTransport, receiver: Int, band: Int)]()
        for c in 0..<receivers {
            for band in 0..<bands { requests.append((c < 3 ? model : donorModel, like(c), band)) }
        }
        if let references {
            for band in 0..<bands {
                requests += [(references.film, 0, band), (references.lossless, 0, band), (model, 0, band)]
            }
        }
        let solved = try solveAll(requests.map { (signature($0.model, $0.receiver, $0.band), $0) },
                                  angularSamples: angularSamples)
        func solve(_ solving: LayeredTransport, _ r: Int, _ band: Int) throws -> TransportSolveResult {
            solved[signature(solving, r, band)]!
        }
        // An adjusted construction moves the red record's return by its physics; the other
        // records keep their ratios to red, which carry the film's masking and filter layers.
        var redFactors = [Int: Double]()
        func redFactor(_ band: Int) throws -> Double {
            if let found = redFactors[band] { return found }
            guard let references else { return 1 }
            let film = try solve(references.film, 0, band)
            let lossless = try solve(references.lossless, 0, band)
            let adjusted = try solve(model, 0, band)
            worstUnresolved = max(worstUnresolved, film.unresolved, lossless.unresolved)
            let factor = adjustedReturn(
                filmRatio: LayeredTransport.sample(references.film.returnedToDirect[0], band),
                film: film.captured, adjusted: adjusted.captured, lossless: lossless.captured,
                launch: launch(capture: LayeredTransport.sample(model.captureProbability[0], band)))
            redFactors[band] = factor
            return factor
        }
        for c in 0..<receivers {
            let solving = c < 3 ? model : donorModel, r = like(c)
            for band in 0..<bands {
                let solved = try solve(solving, r, band)
                worstUnresolved = max(worstUnresolved, solved.unresolved)
                var ratio = LayeredTransport.sample(model.returnedToDirect[r], band)
                    * (returnGain.isEmpty ? 1 : Double(returnGain[band]))
                if ratio > 0 { ratio *= try redFactor(band) }
                ratios[c][band] = ratio
                if ratio > 0 && solved.kernel == nil {
                    throw TransportError.invalid("nonzero return ratio has no reflected capture")
                }
                let original = try solved.kernel ?? TransportRadialKernel(radiusMM: [0], mass: [1])
                if original.mass.count > 512 { compressionBound = 0.5 / 512 }
                let kernel = try original.coarsened(maximumNodes: 512)
                if let index = targets.firstIndex(of: kernel) { targetIndex[c][band] = index }
                else { targetIndex[c][band] = targets.count; targets.append(kernel) }
            }
        }
        // A hazed basis is compressed again, more finely, and that adds its own bound.
        if hazeMM > 0 { compressionBound += 0.5 / Double(TransportRadialKernel.hazedNodes) }
        let support = max(targets.map { $0.quantile(0.9999) }.max() ?? 0, 1e-5)
        let distances = (1...128).map { support * pow(Double($0) / 128, 2) }
        // Each target's edge spread and fit is its own, so they are computed side by side.
        func parallel<T>(_ count: Int, _ body: (Int) -> T) -> [T] {
            var results = [T?](repeating: nil, count: count)
            results.withUnsafeMutableBufferPointer { results in
                ParallelWork.forEach(iterations: count) { results[$0] = body($0) }
            }
            return results.map { $0! }
        }
        let vectors = parallel(targets.count) { i in distances.map { targets[i].edgeSpread(distanceMM: $0) } }
        var selected = [0]
        var fits = [[Double]](), worstError = Double.infinity
        while true {
            fits = parallel(vectors.count) { convexPairFit(basis: selected.map { vectors[$0] }, target: vectors[$0]) }
            let errors = parallel(vectors.count) { i in
                distances.indices.map { d in
                    abs(vectors[i][d] - selected.indices.reduce(0) { $0 + fits[i][$1] * vectors[selected[$1]][d] })
                }.max() ?? 0
            }
            var worstIndex = 0
            worstError = 0
            for (i, error) in errors.enumerated() where error > worstError { worstError = error; worstIndex = i }
            if worstError + compressionBound <= edgeTolerance { break }
            guard selected.count < maximumComponents, !selected.contains(worstIndex) else {
                throw TransportError.convergence("\(selected.count) radial components leave edge error \(worstError)")
            }
            selected.append(worstIndex)
        }
        var kernels = try model.coreSigmaMM.map { try TransportRadialKernel.gaussian(sigmaMM: $0) }
        // The returned light alone crosses the support, so the haze blurs the selected basis and
        // never the cores. A blur cannot raise the fitted edge error.
        kernels += try parallel(selected.count) { i in
            Result { hazeMM > 0 ? try targets[selected[i]].hazed(sigmaMM: hazeMM) : targets[selected[i]] }
        }.map { try $0.get() }
        let maxRatio = ratios.flatMap { $0 }.max() ?? 0
        var core = Array(repeating: Array(repeating: Array(repeating: Float(0), count: bands), count: receivers),
                         count: kernels.count)
        var saturated = core
        for c in 0..<receivers {
            for band in 0..<bands {
                core[like(c)][c][band] = 1
                saturated[like(c)][c][band] = 1
                let fraction = maxRatio > 0 ? ratios[c][band] / maxRatio : 0
                for k in selected.indices {
                    saturated[k + 3][c][band] = Float(fraction * fits[targetIndex[c][band]][k])
                }
            }
        }
        // A common spatial endpoint for the returned light is a deliberate creative operator,
        // independent of wavelength and receiver. Its positive average keeps each kernel's share.
        if sourceColour > 0 {
            let t = sourceColour
            for k in kernels.indices.dropFirst(3) {
                let mean = saturated[k].prefix(3).flatMap { $0 }.reduce(0, +) / Float(3 * bands)
                for c in 0..<receivers { for band in 0..<bands {
                    saturated[k][c][band] = (1 - t) * saturated[k][c][band] + t * mean
                } }
            }
        }
        return TransportCompilation(kernels: kernels, core: core, saturated: saturated,
                                    maximumReturnedRatio: maxRatio, maximumEdgeError: worstError + compressionBound,
                                    radialCompressionErrorBound: compressionBound,
                                    maximumUnresolvedPower: worstUnresolved)
    }

    /// Solved receivers, kept across compilations: an edit that moves the return, the haze or the
    /// colour solves nothing again, and an adjusted construction keeps its film's solves.
    private static let solvedLock = NSLock()
    nonisolated(unsafe) private static var solvedCache = BoundedCache<String, TransportSolveResult>(limit: 2048)

    /// The solves `requests` name, by signature: those not already kept are solved in parallel.
    private static func solveAll(_ requests: [(String, (model: LayeredTransport, receiver: Int, band: Int))],
                                 angularSamples: Int) throws -> [String: TransportSolveResult] {
        var results = [String: TransportSolveResult]()
        var missing = [(String, (model: LayeredTransport, receiver: Int, band: Int))]()
        var asked = Set<String>()
        solvedLock.lock()
        for (key, request) in requests where asked.insert(key).inserted {
            if let found = solvedCache.value(for: key) { results[key] = found }
            else { missing.append((key, request)) }
        }
        solvedLock.unlock()
        var fresh = [Result<TransportSolveResult, Error>?](repeating: nil, count: missing.count)
        fresh.withUnsafeMutableBufferPointer { fresh in
            ParallelWork.forEach(iterations: missing.count) { i in
                let request = missing[i].1
                fresh[i] = Result { try LayeredTransportSolver.solve(request.model, receiver: request.receiver,
                                                                    band: request.band, angularSamples: angularSamples) }
            }
        }
        solvedLock.lock(); defer { solvedLock.unlock() }
        for (i, result) in fresh.enumerated() {
            let value = try result!.get()
            results[missing[i].0] = value
            solvedCache.insert(value, for: missing[i].0)
        }
        return results
    }

    /// Light launched toward the base per unit of direct exposure: the receiver captures `p` of
    /// the light crossing it, and what it lets through goes on to the base.
    static func launch(capture p: Double) -> Double { (1 - p) / p }

    /// The factor an adjusted construction scales a film's return ratio by. A ratio is returned
    /// light `launch × capture`. A film's constructions place its returns' geometry, but their
    /// absorbers are fitted to the halo's shape, so `filmRatio / film` overstates the launch
    /// behind a dense one; scaling by the capture alone would let a thinned backing return
    /// thousands of times the light. The launch therefore moves, in log capture, from the film's
    /// own at its capture to the physical `launch` at the capture of the same stack without
    /// absorbers. The film's construction returns its own ratio; an adjusted one, the physics
    /// between those two ends. User gains multiply on top.
    static func adjustedReturn(filmRatio: Double, film: Double, adjusted: Double,
                               lossless: Double, launch physical: Double) -> Double {
        guard adjusted > 0, film > 0 else { return 0 }
        guard filmRatio > 0, lossless > film * (1 + 1e-9) else { return adjusted / film }
        let launch = filmRatio / film
        let w = log(lossless / adjusted) / log(lossless / film)
        return adjusted / film * pow(physical / launch, 1 - w)
    }

    /// The convex pair with the smallest largest error, the measure the compiler accepts by.
    private static func convexPairFit(basis: [[Double]], target: [Double]) -> [Double] {
        var best = Array(repeating: 0.0, count: basis.count)
        var bestCost = Double.infinity
        func worst(_ a: Double, _ j: Int, _ k: Int) -> Double {
            var e = 0.0
            for d in target.indices { e = max(e, abs(a * basis[j][d] + (1 - a) * basis[k][d] - target[d])) }
            return e
        }
        for j in basis.indices { for k in j..<basis.count {
            var lo = 0.0, hi = 1.0
            if j != k {
                for _ in 0..<48 {
                    let m1 = lo + (hi - lo) / 3, m2 = hi - (hi - lo) / 3
                    if worst(m1, j, k) <= worst(m2, j, k) { hi = m2 } else { lo = m1 }
                }
            }
            let a = j == k ? 1 : (lo + hi) / 2
            let cost = worst(a, j, k)
            if cost < bestCost {
                bestCost = cost; best = Array(repeating: 0, count: basis.count)
                best[j] += a; best[k] += 1 - a
            }
        } }
        return best
    }
}

extension TransportRadialKernel {
    /// The pipeline's strides, 1 through 4096, and the largest stencil radius at any of them.
    public static let transportLevels = Int(FOTUFILM_TRANSPORT_LEVELS)
    public static let transportStencilRadius = Int(FOTUFILM_TRANSPORT_STENCIL_RADIUS)
    /// FOTUFILM_TRANSPORT_TABLE_FLOATS, which Swift cannot import.
    public static let transportTableCount = transportLevels
        * (1 + (2 * transportStencilRadius + 1) * (2 * transportStencilRadius + 1))

    /// The transport pipeline's table for this component: its bands, one per power-of-two
    /// stride, each stride's weights in a centred 25 x 25 slot scaled by the band's share, and
    /// one radius per stride ahead of them. Bands landing on one stride add.
    public func transportTable(pixelPitchMM: Double) throws -> [Float] {
        try Self.transportTable(bands: stencils(pixelPitchMM: pixelPitchMM, maximumRadius: Self.transportStencilRadius))
    }

    /// The table for any positive weighted stencils at power-of-two strides of 4096 or less.
    public static func transportTable(bands: [TransportWeightedStencil]) throws -> [Float] {
        let levels = transportLevels, limit = transportStencilRadius, side = 2 * limit + 1
        var table = [Float](repeating: 0, count: transportTableCount)
        for band in bands {
            let stencil = band.stencil, level = stencil.stride.trailingZeroBitCount
            guard stencil.stride.nonzeroBitCount == 1, level < levels, (1...limit).contains(stencil.radius),
                  band.weight.isFinite, band.weight >= 0 else {
                throw TransportError.unsupported("transport band outside the pipeline's strides")
            }
            table[level] = max(table[level], Float(stencil.radius))
            let width = 2 * stencil.radius + 1, base = levels + level * side * side
            for dy in -stencil.radius...stencil.radius { for dx in -stencil.radius...stencil.radius {
                table[base + (dy + limit) * side + dx + limit]
                    += band.weight * stencil.weights[(dy + stencil.radius) * width + dx + stencil.radius]
            } }
        }
        return table
    }

    /// Split narrow and broad radial bands before grid reduction. A low-energy distant tail
    /// must never force the high-energy shoulder onto that tail's coarse grid.
    public func stencils(pixelPitchMM: Double, maximumRadius: Int = 12) throws -> [TransportWeightedStencil] {
        guard pixelPitchMM.isFinite && pixelPitchMM > 0, (2...128).contains(maximumRadius) else {
            throw TransportError.invalid("invalid multiscale stencil request")
        }
        var groups = [Int: [(Double, Double)]]()
        for (r, m) in zip(radiusMM, mass) {
            var scale = 1
            while r / pixelPitchMM / Double(scale) + 1 > Double(maximumRadius), scale <= 4096 { scale *= 2 }
            guard scale <= 4096 else { throw TransportError.unsupported("transport support exceeds grid capacity") }
            groups[scale, default: []].append((r, m))
        }
        return try groups.keys.sorted().map { scale in
            let nodes = groups[scale]!
            let weight = nodes.reduce(0) { $0 + $1.1 }
            let band = try Self(radiusMM: nodes.map { $0.0 }, mass: nodes.map { $0.1 })
            return TransportWeightedStencil(weight: Float(weight),
                stencil: try band.stencil(pixelPitchMM: pixelPitchMM, maximumRadius: maximumRadius))
        }
    }

    /// Equal-mass quadrature compression, preserving nonnegative weights and their total.
    /// Nodes a hazed kernel keeps: finer than a solved target's, since it is compressed again.
    static let hazedNodes = 2048

    /// The kernel convolved with an isotropic Gaussian of `sigmaMM`. Each ring spreads over the
    /// distances from the centre of points a Gaussian offset from it, by deterministic
    /// equal-probability quadrature in the offset's radius and direction.
    func hazed(sigmaMM: Double, radialSamples: Int = 32, angularSamples: Int = 16) throws -> Self {
        guard sigmaMM > 0 else { return self }
        let offsets = (0..<radialSamples).map {
            sigmaMM * sqrt(-2 * log(1 - (Double($0) + 0.5) / Double(radialSamples)))
        }
        // Distance from the centre is symmetric in the offset's direction, so half a turn serves.
        let turns = (0..<angularSamples).map { cos(.pi * (Double($0) + 0.5) / Double(angularSamples)) }
        var radii = [Double](), weights = [Double]()
        radii.reserveCapacity(mass.count * radialSamples * angularSamples)
        weights.reserveCapacity(radii.capacity)
        for (r, m) in zip(radiusMM, mass) {
            let share = m / Double(radialSamples * angularSamples)
            for s in offsets { for c in turns {
                radii.append(sqrt(max(r * r + s * s + 2 * r * s * c, 0))); weights.append(share)
            } }
        }
        return try Self(radiusMM: radii, mass: weights).coarsened(maximumNodes: Self.hazedNodes)
    }

    func coarsened(maximumNodes: Int) throws -> Self {
        if mass.count <= maximumNodes { return self }
        let capacity = 1 / Double(maximumNodes)
        var radii = [Double](), weights = [Double]()
        var used = 0.0, moment = 0.0
        for (r, m) in zip(radiusMM, mass) {
            var remaining = m
            while remaining > 1e-16 {
                let take = min(remaining, capacity - used)
                used += take; moment += r * take; remaining -= take
                if used >= capacity - 1e-14 {
                    radii.append(moment / used); weights.append(used); used = 0; moment = 0
                }
            }
        }
        if used > 1e-14 { radii.append(moment / used); weights.append(used) }
        return try Self(radiusMM: radii, mass: weights)
    }

    /// The overlap of translated source/destination pixel cells is a bilinear tent. Integrating
    /// that tent over the angular quadrature gives positive, cell-integrated stencil weights.
    public func stencil(pixelPitchMM: Double, tailTolerance: Double = 1e-4,
                        maximumRadius: Int = 12) throws -> TransportStencil {
        guard pixelPitchMM.isFinite && pixelPitchMM > 0, tailTolerance > 0 && tailTolerance < 0.01,
              (2...128).contains(maximumRadius) else { throw TransportError.invalid("invalid pixel stencil request") }
        let reach = quantile(1 - tailTolerance) / pixelPitchMM
        var stride = 1
        while reach / Double(stride) + 1 > Double(maximumRadius), stride <= 4096 { stride *= 2 }
        guard stride <= 4096 else { throw TransportError.unsupported("transport support exceeds grid capacity") }
        let radius = max(1, Int(ceil(reach / Double(stride))) + 1)
        let side = radius * 2 + 1
        var weights = Array(repeating: 0.0, count: side * side)
        var discarded = 0.0
        for (r, mass) in zip(radiusMM, mass) {
            let px = r / pixelPitchMM
            if px > reach + 1e-9 { discarded += mass; continue }
            let distance = px / Double(stride)
            let angles = max(32, Int(ceil(2 * .pi * distance * 12)))
            for angle in 0..<angles {
                let phi = 2 * Double.pi * (Double(angle) + 0.5) / Double(angles)
                let x = distance * cos(phi), y = distance * sin(phi)
                let ix = Int(floor(x)), iy = Int(floor(y))
                let fx = x - Double(ix), fy = y - Double(iy)
                for dy in 0...1 { for dx in 0...1 {
                    let w = (dx == 0 ? 1-fx : fx) * (dy == 0 ? 1-fy : fy)
                    weights[(iy + dy + radius) * side + ix + dx + radius] += mass * w / Double(angles)
                } }
            }
        }
        let sum = weights.reduce(0, +)
        guard sum > 0, discarded <= tailTolerance + 1e-9 else { throw TransportError.convergence("invalid truncated stencil mass") }
        return TransportStencil(radius: radius, stride: stride, weights: weights.map { Float($0 / sum) },
                                omittedMass: discarded)
    }
}

public struct TransportStencil: Sendable {
    public let radius: Int
    public let stride: Int
    public let weights: [Float]
    public let omittedMass: Double
}

public struct TransportWeightedStencil: Sendable {
    public let weight: Float
    public let stencil: TransportStencil
}
