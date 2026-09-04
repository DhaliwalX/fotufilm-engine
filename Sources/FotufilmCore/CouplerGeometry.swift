import Foundation

/// Derives a DIR inhibition matrix from per-layer release and per-interlayer transmission.
/// `FilmStock.couplerDiffusionMM` models lateral spread separately; vertical propagation composes
/// the transmission of each crossed interlayer.
public struct CouplerGeometry: Sendable, Equatable, Codable {
    /// Centre depth of each sensitive layer below the emulsion surface, in micrometres, in the
    /// engine's usual R, G, B layer order. Only the ordering and the gaps between neighbours are
    /// used; depths must be strictly monotonic so array neighbours are stack neighbours.
    public var layerDepthUM: [Float]

    /// The fraction of a donor layer's inhibitor that survives one coated interlayer, one entry per
    /// gap between adjacent layers — two for the usual three-layer stack, index 0 spanning
    /// `layerDepthUM[0]`–`[1]` and index 1 spanning `[1]`–`[2]`. In the default R, G, B order that
    /// is the red–green scavenger interlayer and the green–blue yellow filter layer.
    public var interlayerTransmission: [Float]

    /// Inhibitor released per unit of development, per donor layer, in the same R, G, B order.
    public var release: [Float]

    /// The fraction of a layer's own released inhibitor that still acts on it as a *separate*
    /// effect, rather than one already absorbed elsewhere.
    public var selfRetention: Float

    /// The stack a colour negative is coated in, in micrometres of depth.
    public static let colorNegativeDepthUM: [Float] = [14, 8, 3]

    /// The self-retention fitted across the shipped packs.
    public static let houseSelfRetention: Float = 0.091

    public init(layerDepthUM: [Float] = CouplerGeometry.colorNegativeDepthUM,
                interlayerTransmission: [Float],
                release: [Float],
                selfRetention: Float = CouplerGeometry.houseSelfRetention) {
        precondition(layerDepthUM.count == 3, "layerDepthUM must have 3 entries")
        precondition(release.count == 3, "release must have 3 entries")
        precondition(interlayerTransmission.count == layerDepthUM.count - 1,
                     "interlayerTransmission needs one entry per gap")
        self.layerDepthUM = layerDepthUM
        self.interlayerTransmission = interlayerTransmission
        self.release = release
        self.selfRetention = selfRetention
    }

    /// The per-gap transmissions an exponential decay of `rangeUM` through the stack implies.
    ///
    /// This is how packs written before the field existed are read, and how `fit` reports its
    /// one-dimensional sweep. A non-positive range seals the layers, which is what the decay form
    /// did at its own lower limit.
    public static func transmission(forRangeUM range: Float,
                                    layerDepthUM: [Float]
                                        = CouplerGeometry.colorNegativeDepthUM) -> [Float] {
        (0..<(layerDepthUM.count - 1)).map { gap in
            guard range > 0 else { return 0 }
            let width = abs(layerDepthUM[gap] - layerDepthUM[gap + 1])
            return exp(-width / range)
        }
    }

    /// The inhibition matrix this geometry implies, indexed `[receiver][donor]` to match
    /// `FilmStock.couplerInhibition`.
    ///
    /// `gapReachScales` is the user's reach multiplier per gap, and it is an *exponent* on the
    /// transmission: the decay form's `exp(-w / (range * v))` is exactly
    /// `[exp(-w / range)] ^ (1/v)`, so scaling a reach and scaling a barrier are the same operation
    /// written two ways. 1 is identity, 0 seals the gap, and above 1 crosses more — the direction
    /// the slider has always had.
    public func matrix(gapReachScales: [Float]? = nil, selfScale: Float = 1) -> [[Float]] {
        let layers = layerDepthUM.count
        let scales = gapReachScales ?? [Float](repeating: 1, count: layers - 1)

        // Transmission of one gap at its reach setting. Identity short-circuits before `pow` so a
        // default render does not depend on `powf(x, 1)` being exact.
        func transmitted(_ gap: Int) -> Float {
            let scale = gap < scales.count ? scales[gap] : 1
            guard scale > 0 else { return 0 }
            let base = interlayerTransmission[gap]
            if scale == 1 { return base }
            return pow(base, 1 / scale)
        }

        return (0..<layers).map { receiver in
            (0..<layers).map { donor in
                if receiver == donor {
                    return release[receiver] * selfRetention * selfScale
                }
                // The inhibitor crosses every interlayer between the two, so the survivals
                // multiply. Sealing one gap therefore also cuts the crossings that span it.
                let span = min(receiver, donor)..<max(receiver, donor)
                let crossing = span.reduce(Float(1)) { $0 * transmitted($1) }
                return release[donor] * crossing
            }
        }
    }

    /// Whether this geometry produces any inhibition at all.
    public var isActive: Bool {
        release.contains { $0 != 0 }
    }

    private enum CodingKeys: String, CodingKey {
        case layerDepthUM
        case interlayerTransmission
        case release
        case selfRetention
        /// Read, never written: the decay length packs carried before the barriers were named.
        case rangeUM
    }

    /// Validating decode, so a pack with the wrong number of layers is a decoding error naming the
    /// field rather than a `precondition` trap somewhere inside a render.
    ///
    /// A pack stating `rangeUM` and no `interlayerTransmission` is read through
    /// `transmission(forRangeUM:)`, which reproduces its matrix exactly — sealed packs and stocks a
    /// user built before the change render identically.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let depths = try container.decodeIfPresent(
            [Float].self, forKey: .layerDepthUM) ?? Self.colorNegativeDepthUM
        let release = try container.decode([Float].self, forKey: .release)
        guard depths.count == 3 else {
            throw DecodingError.dataCorruptedError(
                forKey: .layerDepthUM, in: container,
                debugDescription:
                    "layerDepthUM needs one depth per layer (3), got \(depths.count)")
        }
        guard release.count == 3 else {
            throw DecodingError.dataCorruptedError(
                forKey: .release, in: container,
                debugDescription:
                    "release needs one strength per layer (3), got \(release.count)")
        }

        let transmission: [Float]
        if let stated = try container.decodeIfPresent(
            [Float].self, forKey: .interlayerTransmission) {
            guard stated.count == depths.count - 1 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .interlayerTransmission, in: container,
                    debugDescription:
                        "interlayerTransmission needs one entry per gap "
                        + "(\(depths.count - 1)), got \(stated.count)")
            }
            transmission = stated
        } else if let range = try container.decodeIfPresent(Float.self, forKey: .rangeUM) {
            transmission = Self.transmission(forRangeUM: range, layerDepthUM: depths)
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.interlayerTransmission,
                .init(codingPath: container.codingPath,
                      debugDescription:
                        "couplerGeometry needs interlayerTransmission (or a legacy rangeUM)"))
        }

        self.layerDepthUM = depths
        self.interlayerTransmission = transmission
        self.release = release
        self.selfRetention = try container.decodeIfPresent(
            Float.self, forKey: .selfRetention) ?? Self.houseSelfRetention
    }

    /// Written in the canonical shape only; `rangeUM` is a read path, not a round trip.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(layerDepthUM, forKey: .layerDepthUM)
        try container.encode(interlayerTransmission, forKey: .interlayerTransmission)
        try container.encode(release, forKey: .release)
        try container.encode(selfRetention, forKey: .selfRetention)
    }
}

public extension CouplerGeometry {
    /// The geometry whose `matrix()` comes closest to an authored matrix.
    ///
    /// The sweep stays one-dimensional, over the decay length the packs were written against,
    /// rather than searching the two transmissions independently: a 2-D search would find pairs off
    /// the curve the shipped packs sit on and silently re-render them.
    static func fit(to matrix: [[Float]],
                    layerDepthUM: [Float] = CouplerGeometry.colorNegativeDepthUM)
        -> CouplerGeometry
    {
        precondition(matrix.count == 3 && matrix.allSatisfy { $0.count == 3 },
                     "inhibition matrix must be 3x3")

        var best: (error: Float, geometry: CouplerGeometry)?
        let steps = 2000
        let low: Float = 0.5, high: Float = 60
        for step in 0..<steps {
            let t = Float(step) / Float(steps - 1)
            let range = low * exp(t * log(high / low))

            var release = [Float](repeating: 0, count: 3)
            for donor in 0..<3 {
                var numerator: Float = 0, denominator: Float = 0
                for receiver in 0..<3 where receiver != donor {
                    let w = exp(
                        -abs(layerDepthUM[receiver] - layerDepthUM[donor]) / range)
                    numerator += w * matrix[receiver][donor]
                    denominator += w * w
                }
                release[donor] = denominator > 0 ? numerator / denominator : 0
            }

            var numerator: Float = 0, denominator: Float = 0
            for layer in 0..<3 {
                numerator += release[layer] * matrix[layer][layer]
                denominator += release[layer] * release[layer]
            }
            let selfRetention = denominator > 0 ? numerator / denominator : 0

            let candidate = CouplerGeometry(
                layerDepthUM: layerDepthUM,
                interlayerTransmission: transmission(forRangeUM: range,
                                                     layerDepthUM: layerDepthUM),
                release: release,
                selfRetention: selfRetention)
            let produced = candidate.matrix()
            var error: Float = 0
            for i in 0..<3 {
                for j in 0..<3 {
                    let d = produced[i][j] - matrix[i][j]
                    error += d * d
                }
            }
            if best == nil || error < best!.error { best = (error, candidate) }
        }
        return best!.geometry
    }

    /// RMS disagreement between this geometry and an authored matrix, in the matrix's own units.
    func residual(against matrix: [[Float]]) -> Float {
        let produced = self.matrix()
        var sum: Float = 0
        for i in 0..<3 {
            for j in 0..<3 {
                let d = produced[i][j] - matrix[i][j]
                sum += d * d
            }
        }
        return (sum / 9).squareRoot()
    }
}

public extension CouplerGeometry {
    /// Per-layer release strengths solved from a stock's measured inter-image
    /// effect, holding the interlayers and self-retention fixed.
    static func releaseSolvedFromInterImage(
        _ ratios: [Float],
        activationSlopes slopes: [Float],
        interlayerTransmission: [Float],
        selfRetention: Float = CouplerGeometry.houseSelfRetention,
        layerDepthUM: [Float] = CouplerGeometry.colorNegativeDepthUM
    ) -> [Float]? {
        guard ratios.count == 3, slopes.count == 3,
              interlayerTransmission.count == layerDepthUM.count - 1,
              interlayerTransmission.allSatisfy({ $0 > 0 }) else { return nil }
        guard ratios.allSatisfy({ $0 > 1 }) else { return nil }

        var a = [[Float]](repeating: [Float](repeating: 0, count: 3), count: 3)
        var b = [Float](repeating: 0, count: 3)
        for c in 0..<3 {
            for j in 0..<3 {
                let w: Float = c == j
                    ? selfRetention
                    : (min(c, j)..<max(c, j)).reduce(Float(1)) {
                        $0 * interlayerTransmission[$1]
                    }
                a[c][j] = w * slopes[j] * ratios[c]
            }
            a[c][c] -= selfRetention * slopes[c]
            b[c] = ratios[c] - 1
        }

        guard let release = solve3x3(a, b), release.allSatisfy({ $0 >= 0 })
        else { return nil }
        return release
    }
}

/// Gaussian elimination with partial pivoting on a 3x3.
private func solve3x3(_ matrix: [[Float]], _ rhs: [Float]) -> [Float]? {
    var a = matrix, b = rhs
    for column in 0..<3 {
        var pivot = column
        for row in (column + 1)..<3 where abs(a[row][column]) > abs(a[pivot][column]) {
            pivot = row
        }
        guard abs(a[pivot][column]) > 1e-9 else { return nil }
        if pivot != column {
            a.swapAt(pivot, column)
            b.swapAt(pivot, column)
        }
        for row in (column + 1)..<3 {
            let factor = a[row][column] / a[column][column]
            guard factor != 0 else { continue }
            for k in column..<3 { a[row][k] -= factor * a[column][k] }
            b[row] -= factor * b[column]
        }
    }
    var x = [Float](repeating: 0, count: 3)
    for row in stride(from: 2, through: 0, by: -1) {
        var sum = b[row]
        for k in (row + 1)..<3 { sum -= a[row][k] * x[k] }
        x[row] = sum / a[row][row]
    }
    return x
}
