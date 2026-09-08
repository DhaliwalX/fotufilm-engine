import Foundation

public struct TransportCompilation: Sendable {
    public let kernels: [TransportRadialKernel]
    /// [basis][receiver][wavelength], positive unit partitions at amount zero and saturation.
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
    public static func compile(_ model: LayeredTransport, returnGain: [Float] = [],
                               sourceColour: Float = 0, hazeMM: Double = 0,
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
        var targets = [TransportRadialKernel]()
        var targetIndex = Array(repeating: Array(repeating: 0, count: bands), count: 3)
        var shares = Array(repeating: Array(repeating: 0.0, count: bands), count: 3)
        var solveCache = [String: TransportSolveResult]()
        var worstUnresolved = 0.0
        var compressionBound = 0.0
        for c in 0..<3 {
            for band in 0..<bands {
                var signature = [Double(c), model.recordDepthMM[c],
                                 LayeredTransport.sample(model.angularExponent[c], band),
                                 LayeredTransport.sample(model.captureProbability[c], band),
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
                    solved = try LayeredTransportSolver.solve(model, receiver: c, band: band,
                                                              angularSamples: angularSamples)
                    solveCache[key] = solved
                }
                worstUnresolved = max(worstUnresolved, solved.unresolved)
                let ratio = LayeredTransport.sample(model.returnedToDirect[c], band)
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
        var core = Array(repeating: Array(repeating: Array(repeating: Float(0), count: bands), count: 3), count: kernels.count)
        var saturated = core
        for c in 0..<3 {
            for band in 0..<bands {
                core[c][c][band] = 1
                let fraction = maxShare > 0 ? shares[c][band] / maxShare : 0
                saturated[c][c][band] = Float(1 - fraction)
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
                let mean = saturated[k].flatMap { $0 }.reduce(0, +) / Float(3 * bands)
                for c in 0..<3 { for band in 0..<bands {
                    saturated[k][c][band] = (1 - t) * saturated[k][c][band] + t * mean
                } }
            }
        }
        return TransportCompilation(kernels: kernels, core: core, saturated: saturated,
                                    maximumReturnedShare: maxShare, maximumEdgeError: worstError + compressionBound,
                                    radialCompressionErrorBound: compressionBound,
                                    maximumUnresolvedPower: worstUnresolved)
    }

    private static func convexPairFit(basis: [[Double]], target: [Double]) -> [Double] {
        var best = Array(repeating: 0.0, count: basis.count)
        var bestCost = Double.infinity
        for j in basis.indices { for k in j..<basis.count {
            var numerator = 0.0, denominator = 0.0
            for d in target.indices {
                let v = basis[j][d] - basis[k][d]
                numerator += (target[d] - basis[k][d]) * v; denominator += v * v
            }
            let a = denominator > 0 ? min(max(numerator / denominator, 0), 1) : 1
            var cost = 0.0
            for d in target.indices { cost += pow(a * basis[j][d] + (1-a) * basis[k][d] - target[d], 2) }
            if cost < bestCost {
                bestCost = cost; best = Array(repeating: 0, count: basis.count)
                best[j] += a; best[k] += 1 - a
            }
        } }
        return best
    }
}

extension TransportRadialKernel {
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
