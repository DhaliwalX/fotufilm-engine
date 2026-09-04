import Foundation

/// Exposure compensation applied for a filter stack.
public enum LensFilterCompensation: String, Equatable, Sendable, Codable, CaseIterable {
    /// No exposure adjustment; filter transmission loss reaches the film as underexposure.
    case none
    /// Through-the-lens metering based on photopic transmittance. This can underexpose film behind
    /// narrow spectral filters because the meter does not use the film's sensitivity.
    case throughTheLens
    /// Published filter-factor compensation derived from film sensitivity. It restores the
    /// green-sensitive luminance record without cancelling inter-record colour changes.
    case filmSpeed

    public var label: String {
        switch self {
        case .none: return "None"
        case .throughTheLens: return "Metered through"
        case .filmSpeed: return "Filter factor"
        }
    }
}

/// Ordered lens-filter stack. In addition to combined transmission, each filter contributes two
/// air-glass surfaces and the gaps contribute veiling glare.
public struct LensFilterStack: Equatable, Sendable {
    public var filters: [LensFilter]
    public var compensation: LensFilterCompensation
    /// Reflectance of the lens's own front element, which is the other half of every ghost the
    /// rearmost filter makes. A modern multicoated front element sits near half a percent; an
    /// older single-coated one is nearer one and a half, and a filter in front of it costs
    /// visibly more.
    public var lensFrontReflectance: Float

    public static let none = LensFilterStack()

    public init(_ filters: [LensFilter] = [],
                compensation: LensFilterCompensation = .throughTheLens,
                lensFrontReflectance: Float = 0.005) {
        self.filters = filters
        self.compensation = compensation
        self.lensFrontReflectance = lensFrontReflectance
    }

    public init(_ filter: LensFilter,
                compensation: LensFilterCompensation = .throughTheLens,
                lensFrontReflectance: Float = 0.005) {
        self.init([filter], compensation: compensation,
                  lensFrontReflectance: lensFrontReflectance)
    }

    public var isEmpty: Bool { filters.isEmpty }

    /// Product of each element's spectral transmittance. Inter-element reflections are represented
    /// by `addedVeilingGlare` instead of direct transmission.
    public var transmittance: [Float] {
        guard !filters.isEmpty else {
            return [Float](repeating: 1, count: SpectralGrid.count)
        }
        var total = [Float](repeating: 1, count: SpectralGrid.count)
        for filter in filters {
            let element = filter.transmittance
            for i in 0..<SpectralGrid.count { total[i] *= element[i] }
        }
        return total
    }

    /// Added veiling-glare fraction from inter-element and filter-to-lens reflections.
    /// Each gap contributes the product of its bounding reflectances. The result is reduced to a
    /// D65 photopic scalar. Filters are assumed to be added in simulation; a filter present during
    /// capture would already contain this glare and should contribute zero here.
    public var addedVeilingGlare: Float {
        guard !filters.isEmpty else { return 0 }
        let faces = filters.map(\.surfaceReflectance)
        var perBand = [Float](repeating: 0, count: SpectralGrid.count)
        for index in 0..<faces.count {
            // The face behind this element, and the face it looks at across the gap: the next
            // filter's front, or the lens itself for the last one.
            let behind = faces[index]
            let ahead = index + 1 < faces.count ? faces[index + 1] : nil
            for i in 0..<SpectralGrid.count {
                let far = ahead?[i] ?? lensFrontReflectance
                perBand[i] += behind[i] * far
            }
        }
        var weighted: Float = 0, weight: Float = 0
        for i in 0..<SpectralGrid.count {
            let w = SpectralGrid.d65[i] * SpectralGrid.yBar[i]
            weight += w
            weighted += w * perBand[i]
        }
        return weight > 0 ? weighted / weight : 0
    }

    /// Photopic transmittance of the stack under a stated light — what a meter cell reads.
    public func luminousTransmittance(illuminant: [Float] = SpectralGrid.d65) -> Float {
        let stack = transmittance
        var through: Float = 0, open: Float = 0
        for i in 0..<SpectralGrid.count {
            let weight = illuminant[i] * SpectralGrid.yBar[i]
            open += weight
            through += weight * stack[i]
        }
        return open > 0 ? through / open : 1
    }

    /// What fraction of its unfiltered exposure each of the emulsion's three layers keeps.
    ///
    /// This is the whole of the filter's effect on colour, and the reason it is worth doing
    /// spectrally: the answer depends on the shapes of the three sensitivities, so the same
    /// filter is a different filter on a different stock, exactly as it is in the world.
    public func layerTransmittances(stock: FilmStock,
                                    illuminant: [Float] = SpectralGrid.d65) -> SIMD3<Float> {
        let stack = transmittance
        let sensitivity = stock.spectralProfile.layerSensitivity
        var through = SIMD3<Float>(repeating: 0)
        var open = SIMD3<Float>(repeating: 0)
        for i in 0..<SpectralGrid.count {
            let light = illuminant[i]
            for layer in 0..<3 {
                let w = light * sensitivity[layer][i]
                open[layer] += w
                through[layer] += w * stack[i]
            }
        }
        return SIMD3(through.x / max(open.x, 1e-12),
                     through.y / max(open.y, 1e-12),
                     through.z / max(open.z, 1e-12))
    }

    /// The filter factor in stops, the way the film's own datasheet states it: how much more
    /// exposure the emulsion needs to develop the same neutral density behind this stack. Keyed
    /// to the luminance record — see `LensFilterCompensation.filmSpeed` for why that one.
    public func filterFactorStops(stock: FilmStock,
                                  illuminant: [Float] = SpectralGrid.d65) -> Float {
        -log2(max(luminanceRecordTransmittance(stock: stock, illuminant: illuminant), 1e-9))
    }

    func luminanceRecordTransmittance(stock: FilmStock, illuminant: [Float]) -> Float {
        layerTransmittances(stock: stock, illuminant: illuminant).y
    }

    /// The scalar the exposure is multiplied by, given how it was set.
    ///
    /// Compensation is a gain on the light the emulsion integrates, so it belongs in the same
    /// place the filter's absorption does — one scale on the exposure table, costing the render
    /// nothing.
    public func exposureGain(stock: FilmStock,
                             illuminant: [Float] = SpectralGrid.d65) -> Float {
        guard !filters.isEmpty else { return 1 }
        switch compensation {
        case .none:
            return 1
        case .throughTheLens:
            return 1 / max(luminousTransmittance(illuminant: illuminant), 1e-6)
        case .filmSpeed:
            return 1 / max(luminanceRecordTransmittance(stock: stock, illuminant: illuminant), 1e-6)
        }
    }

    /// Identity of everything that changes the exposure table, so a cached table is never served
    /// for a different stack. Hashed over the transmittance the film actually sees rather than
    /// over the filters' names: two ways of spelling the same stack are the same table.
    public var signature: UInt64 {
        guard !filters.isEmpty else { return 0 }
        var h: UInt64 = 0xcbf29ce484222325
        for value in transmittance {
            h = (h ^ UInt64(value.bitPattern)) &* 0x100000001b3
        }
        // A stable ordinal, not the string's hash: Swift seeds String hashing per process, and
        // this identity decides whether the GPU re-uploads a table.
        let ordinal = LensFilterCompensation.allCases.firstIndex(of: compensation) ?? 0
        h = (h ^ UInt64(ordinal &+ 1)) &* 0x100000001b3
        return h
    }
}
