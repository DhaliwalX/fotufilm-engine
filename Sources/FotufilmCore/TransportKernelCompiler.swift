import Foundation
import FotufilmHalide

public struct TransportCompilation: Sendable {
    public let kernels: [TransportRadialKernel]
    /// [basis][receiver][wavelength], positive unit partitions at amount zero and saturation.
    /// A donor stock's fourth record is a fourth receiver.
    public let core: [[[Float]]]
    public let saturated: [[[Float]]]
    public let maximumReturnedShare: Double
    public let maximumEdgeError: Double
    /// Uniform ESF error bound from equal-mass radial compression alone.
    public let radialCompressionErrorBound: Double
    public let maximumUnresolvedPower: Double

    public func interpolation(amount: Double) -> Float {
        guard maximumReturnedShare > 0 else { return 0 }
        let a = max(amount, 0)
        let ceiling = 1 / maximumReturnedShare
        let gain: Double
        if a <= 1 { gain = a }
        else if ceiling <= 1 { gain = 1 }
        else { gain = 1 + (ceiling - 1) / (1 + (ceiling - 1) / (a - 1)) }
        return Float(min(max(gain * maximumReturnedShare, 0), 1))
    }
}

public enum TransportKernelCompiler {
    /// Fits only convex combinations of actual solved kernels. An error limit failure is
    /// explicit; it never falls back to the legacy three-Gaussian approximation.
    ///
    /// `donorDepthMM` adds a donor stock's fourth record as a fourth receiver, solved at its own
    /// depth. It is coated against the green record and sensitive on that record's short-wave
    /// side, so it takes the green receiver's launch, capture, return and core.
    public static func compile(_ model: LayeredTransport, returnGain: [Float] = [],
                               sourceColour: Float = 0, hazeMM: Double = 0, donorDepthMM: Double? = nil,
                               maximumComponents: Int = 8, edgeTolerance: Double = 0.005,
                               angularSamples: Int = 512) throws -> TransportCompilation {
        try model.validate()
        guard (1...24).contains(maximumComponents), edgeTolerance.isFinite,
              edgeTolerance > 0 && edgeTolerance <= 0.02,
              returnGain.isEmpty || (returnGain.count == SpectralGrid.count && returnGain.allSatisfy { $0.isFinite && $0 >= 0 }),
              sourceColour.isFinite && (0...1).contains(sourceColour),
              hazeMM.isFinite && (0...0.5).contains(hazeMM) else {
            throw TransportError.invalid("invalid kernel compilation settings")
        }
        // A separate physical haze model is needed before composing it with arbitrary radial
        // distributions. Reject it rather than quietly adding a Gaussian variance to a ring.
        guard hazeMM == 0 else { throw TransportError.unsupported("additional haze with layered transport") }
        let bands = SpectralGrid.count
        // Each receiver solves as one of the construction's three: the donor as green, moved.
        var donorModel = model
        if let donorDepthMM {
            donorModel.recordDepthMM[1] = donorDepthMM
            try donorModel.validate()
        }
        let receivers = donorDepthMM == nil ? 3 : 4
        func like(_ c: Int) -> Int { c < 3 ? c : 1 }
        var targets = [TransportRadialKernel]()
        var targetIndex = Array(repeating: Array(repeating: 0, count: bands), count: receivers)
        var shares = Array(repeating: Array(repeating: 0.0, count: bands), count: receivers)
        var solveCache = [String: TransportSolveResult]()
        var worstUnresolved = 0.0
        var compressionBound = 0.0
        for c in 0..<receivers {
            let solving = c < 3 ? model : donorModel, r = like(c)
            for band in 0..<bands {
                var signature = [Double(r), solving.recordDepthMM[r],
                                 LayeredTransport.sample(model.angularExponent[r], band),
                                 LayeredTransport.sample(model.captureProbability[r], band),
                                 LayeredTransport.sample(model.frontIndex, band),
                                 LayeredTransport.sample(model.rearIndex, band),
                                 model.rearReflectance.map { LayeredTransport.sample($0, band) } ?? -1]
                for layer in model.layers {
                    signature += [layer.thicknessMM, LayeredTransport.sample(layer.refractiveIndex, band),
                                  LayeredTransport.sample(layer.absorptionPerMM, band)]
                }
                let key = signature.map { String($0.bitPattern) }.joined(separator: ":")
                let solved: TransportSolveResult
                if let found = solveCache[key] { solved = found }
                else {
                    solved = try LayeredTransportSolver.solve(solving, receiver: r, band: band,
                                                              angularSamples: angularSamples)
                    solveCache[key] = solved
                }
                worstUnresolved = max(worstUnresolved, solved.unresolved)
                let ratio = LayeredTransport.sample(model.returnedToDirect[r], band)
                    * (returnGain.isEmpty ? 1 : Double(returnGain[band]))
                shares[c][band] = ratio / (1 + ratio)
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
        let support = max(targets.map { $0.quantile(0.9999) }.max() ?? 0, 1e-5)
        let distances = (1...128).map { support * pow(Double($0) / 128, 2) }
        let vectors = targets.map { target in distances.map { target.edgeSpread(distanceMM: $0) } }
        var selected = [0]
        var fits = [[Double]](), worstError = Double.infinity
        while true {
            fits = vectors.map { convexPairFit(basis: selected.map { vectors[$0] }, target: $0) }
            var worstIndex = 0
            worstError = 0
            for i in vectors.indices {
                let error = distances.indices.map { d in
                    abs(vectors[i][d] - selected.indices.reduce(0) { $0 + fits[i][$1] * vectors[selected[$1]][d] })
                }.max() ?? 0
                if error > worstError { worstError = error; worstIndex = i }
            }
            if worstError + compressionBound <= edgeTolerance { break }
            guard selected.count < maximumComponents, !selected.contains(worstIndex) else {
                throw TransportError.convergence("\(selected.count) radial components leave edge error \(worstError)")
            }
            selected.append(worstIndex)
        }
        var kernels = try model.coreSigmaMM.map { try TransportRadialKernel.gaussian(sigmaMM: $0) }
        kernels += selected.map { targets[$0] }
        let maxShare = shares.flatMap { $0 }.max() ?? 0
        var core = Array(repeating: Array(repeating: Array(repeating: Float(0), count: bands), count: receivers),
                         count: kernels.count)
        var saturated = core
        for c in 0..<receivers {
            for band in 0..<bands {
                core[like(c)][c][band] = 1
                let fraction = maxShare > 0 ? shares[c][band] / maxShare : 0
                saturated[like(c)][c][band] = Float(1 - fraction)
                for k in selected.indices {
                    saturated[k + 3][c][band] = Float(fraction * fits[targetIndex[c][band]][k])
                }
            }
        }
        // A common spatial endpoint is a deliberate creative operator, independent of wavelength
        // and receiver. Its positive average keeps every component partition normalized.
        if sourceColour > 0 {
            let t = sourceColour
            for k in kernels.indices {
                let mean = saturated[k].prefix(3).flatMap { $0 }.reduce(0, +) / Float(3 * bands)
                for c in 0..<receivers { for band in 0..<bands {
                    saturated[k][c][band] = (1 - t) * saturated[k][c][band] + t * mean
                } }
            }
        }
        return TransportCompilation(kernels: kernels, core: core, saturated: saturated,
                                    maximumReturnedShare: maxShare, maximumEdgeError: worstError + compressionBound,
                                    radialCompressionErrorBound: compressionBound,
                                    maximumUnresolvedPower: worstUnresolved)
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
