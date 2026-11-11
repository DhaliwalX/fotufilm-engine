import Foundation

/// A film's negative as a scan sees it: the film's record densities carried to its spectral
/// density as the print stage does, and that spectrum's light through each of the scan's channels
/// (`NegativeScanSetup`). A reading of a scan is right for this model when it returns the record
/// densities that make the scan, since the print stage then prints the same film.
public struct NegativeScanModel: Sendable {
    /// What each scan channel sees per `SpectralGrid` wavelength, three rows.
    let response: [[Float]]
    private let dyes: [[Float]]
    private let offset: [Float]?
    private let basis: SpectralRuntime.NeutralDensityBasis
    /// The film's base densities, one per record.
    public let base: [Float]
    /// What the channels read of the clear film, the bare lamp reading one.
    public let clear: SIMD3<Float>

    public init(stock: FilmStock, setup: NegativeScanSetup) {
        self.init(stock: stock, response: setup.response())
    }

    init(stock: FilmStock, response: [[Float]]) {
        precondition(response.count == 3
                     && response.allSatisfy { $0.count == SpectralGrid.count })
        self.response = response
        dyes = stock.spectralProfile.imageDyeDensity
        offset = SpectralRuntime.filmDensityOffset(for: stock)
        basis = SpectralRuntime.neutralDensityBasis(for: stock)
        base = stock.curves.map(\.dMin)
        clear = Self.sample(amounts: basis(base), dyes: dyes, offset: offset, response: response)
    }

    /// What the scan's channels read of film at `density`, one density per record with the
    /// film's base in it: linear, the bare lamp reading one in every channel.
    public func sample(density: [Float]) -> SIMD3<Float> {
        Self.sample(amounts: basis(density), dyes: dyes, offset: offset, response: response)
    }

    private static func sample(amounts: [Float], dyes: [[Float]], offset: [Float]?,
                               response: [[Float]]) -> SIMD3<Float> {
        var read = SIMD3<Float>.zero
        for i in 0..<SpectralGrid.count {
            var d = offset?[i] ?? 0
            for dye in 0..<dyes.count { d += amounts[dye] * dyes[dye][i] }
            read += pow(10, -d) * SIMD3(response[0][i], response[1][i], response[2][i])
        }
        return read
    }

    /// Each channel's density of film at `density` over the clear film, which is what a reading
    /// takes from a scan and its sampled border. Nil where a channel reads no light, which a
    /// camera's channel can of a deep colour its matrix subtracts below zero.
    public func scannerDensity(density: [Float]) -> SIMD3<Float>? {
        let read = sample(density: density)
        guard (0..<3).allSatisfy({ read[$0] > 0 && clear[$0] > 0 }) else { return nil }
        return SIMD3((0..<3).map { -log10(read[$0] / clear[$0]) })
    }

    /// Film exposed alike on every record to `logExposure` over mid-grey, then record by record
    /// `shift` more: the record densities of a grey, or of a colour.
    public static func density(stock: FilmStock, logExposure: Float,
                               shift: SIMD3<Float> = .zero) -> [Float] {
        (0..<3).map { stock.developedDensity(layer: $0, logExposure: logExposure + shift[$0]) }
    }

    /// One film density to fit or check a reading on, and how much it counts.
    public struct Patch: Sendable {
        public var density: [Float]
        public var weight: Float
        /// The exposure over mid-grey it was made at, before its colour's shift.
        public var logExposure: Float
        public var isNeutral: Bool
    }

    /// The tones a picture holds: greys from deep shadow to bright highlight, and colours about
    /// each of them, one record exposed a stop or two either way. The greys count for half, so a
    /// reading fitted on these holds the film's grey scale first.
    public static func patches(stock: FilmStock) -> [Patch] {
        let exposures = stride(from: Float(-1.8), through: 1.2, by: 0.15).map { $0 }
        var shifts: [SIMD3<Float>] = []
        for amount in [Float(0.3), 0.6] {
            for sign in [Float(-1), 1] {
                shifts.append(SIMD3(sign * amount, 0, 0))
                shifts.append(SIMD3(0, sign * amount, 0))
                shifts.append(SIMD3(0, 0, sign * amount))
            }
        }
        var patches: [Patch] = []
        for exposure in exposures {
            patches.append(Patch(density: density(stock: stock, logExposure: exposure),
                                 weight: Float(shifts.count), logExposure: exposure,
                                 isNeutral: true))
            for shift in shifts {
                patches.append(Patch(
                    density: density(stock: stock, logExposure: exposure, shift: shift),
                    weight: 1, logExposure: exposure, isNeutral: false))
            }
        }
        return patches
    }

    /// How far a reading of this model's scans lands from the film that made them, in record
    /// density: the root mean square over the greys and over the colours, and the worst record
    /// of any patch.
    public struct ReadingError: Equatable, Sendable {
        public var greys: Float
        public var colours: Float
        public var worst: Float
        /// Patches the reading could not place, or a channel read no light of.
        public var unread: Int
    }

    /// Scans each of `patches` as this model sees it and reads it back with `reading`, whose
    /// border must be this model's `clear` film.
    public func error(of reading: ApproximateNegativeScan, patches: [Patch]) -> ReadingError {
        var squares = [Float](repeating: 0, count: 2), counts = [Float](repeating: 0, count: 2)
        var worst: Float = 0
        var unread = 0
        for patch in patches {
            let scan = sample(density: patch.density)
            guard let read = reading.density(of: scan) else {
                unread += 1
                continue
            }
            let kind = patch.isNeutral ? 0 : 1
            for record in 0..<3 {
                let miss = read[record] - patch.density[record]
                squares[kind] += miss * miss
                counts[kind] += 1
                worst = max(worst, abs(miss))
            }
        }
        return ReadingError(greys: (squares[0] / max(counts[0], 1)).squareRoot(),
                            colours: (squares[1] / max(counts[1], 1)).squareRoot(),
                            worst: worst, unread: unread)
    }
}
