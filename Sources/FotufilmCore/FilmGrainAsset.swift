import Foundation

/// Portable, lossless storage for a solved Film population and its canonical texture bank.
/// Applications provide the asset bytes; this API does not bundle texture banks.
public enum FilmGrainAsset {
    // Bump algorithmVersion whenever population fitting, calibration, random draws, tile
    // construction, or their numerical constants change. Format changes also bump formatVersion.
    private static let formatVersion: UInt32 = 2
    private static let algorithmVersion: UInt32 = 2
    private static let magic = Data("FFGRAIN\0".utf8)
    static let maximumByteCount = 32 * 1024 * 1024
    private static let maximumIdentityBytes = 1024 * 1024

    public enum AssetError: Error {
        case invalidData
    }

    /// Canonical little-endian input bits, suitable for hashing as an application asset key.
    /// Includes every input read by FilmGrain, CrystalGrainModel and granularityAnchorDensity,
    /// plus the complete grain metadata. Render seed, format, amount and Film look controls do
    /// not change the population/bank and deliberately remain runtime configuration.
    public static func identity(stock: FilmStock, reference: FilmStock? = nil) -> Data {
        var writer = Writer()
        writer.bytes(Data("FilmGrainIdentity".utf8))
        writer.word(algorithmVersion)
        writer.word(UInt32(FilmGrain.tileSide))
        writer.word(UInt32(FilmGrain.tileLevels))
        writer.word(UInt32(truncatingIfNeeded: FilmGrain.tileSeed))
        writer.word(UInt32(truncatingIfNeeded: FilmGrain.tileSeed >> 32))
        writer.floats([FilmGrain.tileTexelMM, FilmGrain.tileBlockMM,
                       FilmGrain.dyeCloudDecayMM, FilmGrain.silverGrainEdge,
                       FilmGrain.silverGrainDensity, FilmGrain.fastestCrystalMM,
                       FilmGrain.finestSampleMM])
        writer.floats(FilmGrain.dyeCloudTerms.flatMap { [$0.sigma, $0.weight] })
        writer.stock(stock)
        writer.word(reference == nil ? 0 : 1)
        if let reference { writer.stock(reference) }
        return writer.data
    }

    /// Generates canonical data independently of the installed provider. Callers may compress
    /// these bytes losslessly. Cross-platform generation must be verified before shipping a
    /// bank generated on another host: serialization preserves bits, not a host's libm behavior.
    public static func generate(stock: FilmStock, reference: FilmStock? = nil) throws -> Data {
        let identity = identity(stock: stock, reference: reference)
        let grain = FilmGrain(stock: stock, reference: reference, useCachedAnchor: false, checkCancellation: {})
        return try encode(grain: grain, identity: identity,
                          tiles: grain.buildTiles(seed: FilmGrain.tileSeed))
    }

    static func encode(grain: FilmGrain, identity: Data, tiles supplied: FilmGrain.Tiles? = nil) throws -> Data {
        var writer = Writer()
        writer.data.append(magic)
        writer.word(formatVersion)
        writer.bytes(identity)
        writer.word(grain.monochrome ? 1 : 0)
        writer.word(UInt32(grain.records.count))
        for record in grain.records {
            writer.float(record.dMin)
            writer.float(record.dMax)
            writer.word(UInt32(record.sublayers.count))
            for layer in record.sublayers {
                writer.word(layer.profile.rawValue)
                writer.floats([layer.coatedPerMM2, layer.sigmaMM, layer.peakDemand,
                               layer.capacity, layer.edge, layer.smallestSigmaMM,
                               layer.dyePerCloudMM2, layer.cellMM, layer.voidIntegralMM2])
                writer.floats(layer.forming)
            }
        }
        let tiles = supplied ?? grain.tiles()
        writer.floats(tiles.dMin)
        writer.floats(tiles.dMax)
        writer.word(UInt32(tiles.levels.count))
        for record in tiles.levels {
            writer.word(UInt32(record.count))
            for level in record {
                writer.float(level.meanLight)
                writer.floats(level.sums)
            }
        }
        guard writer.data.count <= maximumByteCount else { throw AssetError.invalidData }
        // Generated assets obey the same bounds and finite-data contract as loaded assets.
        _ = try decode(writer.data, identity: identity)
        return writer.data
    }

    static func decode(_ data: Data, identity: Data) throws -> FilmGrain {
        guard data.count <= maximumByteCount, data.starts(with: magic),
              identity.count <= maximumIdentityBytes else { throw AssetError.invalidData }
        var reader = Reader(data: data, offset: magic.count)
        guard try reader.word() == formatVersion,
              try reader.bytes(maximum: maximumIdentityBytes) == identity else {
            throw AssetError.invalidData
        }
        let mono = try reader.word()
        guard mono <= 1, try reader.word() == 3 else { throw AssetError.invalidData }
        var records: [FilmGrain.Record] = []
        for _ in 0..<3 {
            let dMin = try reader.float(), dMax = try reader.float()
            guard dMax > dMin else { throw AssetError.invalidData }
            let count = try reader.count(maximum: CrystalGrainModel.binCount)
            var sublayers: [FilmGrain.Sublayer] = []
            for _ in 0..<count {
                guard let profile = FilmGrain.Profile(rawValue: try reader.word()) else {
                    throw AssetError.invalidData
                }
                let fields = try reader.floats(count: 9)
                guard fields.allSatisfy({ $0 > 0 }) else { throw AssetError.invalidData }
                let forming = try reader.floats(count: FilmGrain.tableSamples)
                // A weighted Float reduction can round slightly beyond one. Preserve the
                // canonical finite coefficients rather than clamp or reject that rounding.
                sublayers.append(FilmGrain.Sublayer(profile: profile, coatedPerMM2: fields[0], sigmaMM: fields[1],
                    peakDemand: fields[2], capacity: fields[3], edge: fields[4],
                    smallestSigmaMM: fields[5], dyePerCloudMM2: fields[6], cellMM: fields[7],
                    forming: forming, voidIntegralMM2: fields[8]))
            }
            records.append(.init(sublayers: sublayers, dMin: dMin, dMax: dMax))
        }
        let dMin = try reader.floats(count: 3), dMax = try reader.floats(count: 3)
        guard zip(dMin, records).allSatisfy({ $0.bitPattern == $1.dMin.bitPattern }),
              zip(dMax, records).allSatisfy({ $0.bitPattern == $1.dMax.bitPattern }),
              try reader.word() == 3 else { throw AssetError.invalidData }
        var levels: [[FilmGrain.TileLevel]] = []
        let side = FilmGrain.tileSide + 1
        for r in 0..<3 {
            let active = (mono == 0 || r == 1) && !records[r].sublayers.isEmpty
            let count = try reader.count(maximum: FilmGrain.tileLevels)
            guard count == (active ? FilmGrain.tileLevels : 0) else { throw AssetError.invalidData }
            var record: [FilmGrain.TileLevel] = []
            for _ in 0..<count {
                let mean = try reader.float()
                guard mean > 0, mean <= 1 else { throw AssetError.invalidData }
                let sums = try reader.floats(count: side * side)
                guard sums.prefix(side).allSatisfy({ $0 == 0 }),
                      (0..<side).allSatisfy({ sums[$0 * side] == 0 }) else {
                    throw AssetError.invalidData
                }
                record.append(.init(sums: sums, meanLight: mean))
            }
            levels.append(record)
        }
        guard reader.offset == data.count else { throw AssetError.invalidData }
        return FilmGrain(records: records, monochrome: mono == 1, identity: identity,
                         tiles: .init(levels: levels, dMin: dMin, dMax: dMax))
    }

    private static let provider = Provider()

    static func install(_ value: (@Sendable (Data) -> Data?)?) { provider.set(value) }

    /// Whether the provider carries a population for `identity`, without decoding it.
    static func isProvided(identity: Data) -> Bool { provider.get()?(identity) != nil }

    static func provided(identity: Data) -> FilmGrain? {
        var timing = StageTiming()
        guard let data = provider.get()?(identity) else { return nil }
        let decoded = try? decode(data, identity: identity)
        timing.mark(decoded == nil ? "rejected" : "loaded")
        timing.report("Film asset")
        return decoded
    }

    private final class Provider: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (@Sendable (Data) -> Data?)?
        func set(_ value: (@Sendable (Data) -> Data?)?) {
            lock.lock(); self.value = value; lock.unlock()
        }
        func get() -> (@Sendable (Data) -> Data?)? {
            lock.lock(); defer { lock.unlock() }; return value
        }
    }

    private struct Writer {
        var data = Data()
        mutating func word(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        mutating func float(_ value: Float) { word(value.bitPattern) }
        mutating func bytes(_ value: Data) {
            word(UInt32(value.count)); data.append(value)
        }
        mutating func floats(_ values: [Float]) {
            word(UInt32(values.count))
            let bits = values.map { $0.bitPattern.littleEndian }
            bits.withUnsafeBytes { data.append(contentsOf: $0) }
        }
        mutating func curve(_ value: CharacteristicCurve) {
            floats([value.dMin, value.gamma, value.toe, value.toeWidth,
                    value.shoulder, value.shoulderWidth])
            word(value.secondary == nil ? 0 : 1)
            if let secondary = value.secondary {
                floats([secondary.gamma, secondary.toe, secondary.toeWidth,
                        secondary.shoulder, secondary.shoulderWidth])
            }
            word(value.sampled == nil ? 0 : 1)
            if let sampled = value.sampled {
                floats(sampled.logExposure); floats(sampled.density); floats(sampled.slopes)
            }
        }
        mutating func stock(_ value: FilmStock) {
            bytes(Data(value.name.utf8))
            word(value.isMonochrome ? 1 : 0); word(value.isReversal ? 1 : 0)
            word(UInt32(bitPattern: value.grainDensityLaw.rawValue))
            bytes(Data(value.granularityReadDensity.rawValue.utf8))
            word(UInt32(value.curves.count))
            for item in value.curves { curve(item) }
            floats([value.grainStrength, value.grainSizeMM, value.grainFogDensity,
                    value.grainLumaCorrelation, value.grainMottleShare, value.grainMottleSizeRatio])
            floats(value.grainLayerWeights); floats(value.grainLayerSizeRatio)
            word(UInt32(value.grainDensityProfile.records.count))
            for record in value.grainDensityProfile.records { floats(record) }
            floats(value.grainReversalProfile)
            let population = value.crystalGrainPopulation
            floats([population.radiusSpan, population.coatingDensityScale])
            floats(population.sublayerShares)
        }
    }

    private struct Reader {
        let data: Data
        var offset: Int
        mutating func word() throws -> UInt32 {
            guard offset <= data.count - 4 else { throw AssetError.invalidData }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            offset += 4
            return UInt32(littleEndian: value)
        }
        mutating func count(maximum: Int) throws -> Int {
            let value = Int(try word())
            guard value <= maximum else { throw AssetError.invalidData }
            return value
        }
        mutating func bytes(maximum: Int) throws -> Data {
            let length = try count(maximum: maximum)
            guard length <= data.count - offset else { throw AssetError.invalidData }
            defer { offset += length }
            let start = data.startIndex + offset
            return data.subdata(in: start..<(start + length))
        }
        mutating func float() throws -> Float {
            let value = Float(bitPattern: try word())
            guard value.isFinite else { throw AssetError.invalidData }
            return value
        }
        mutating func floats(count expected: Int) throws -> [Float] {
            guard try count(maximum: expected) == expected,
                  expected <= (data.count - offset) / 4 else { throw AssetError.invalidData }
            let start = offset
            let values: [Float] = data.withUnsafeBytes { bytes in
                (0..<expected).map { index in
                    Float(bitPattern: UInt32(littleEndian:
                        bytes.loadUnaligned(fromByteOffset: start + index * 4, as: UInt32.self)))
                }
            }
            offset += expected * 4
            guard values.allSatisfy(\.isFinite) else { throw AssetError.invalidData }
            return values
        }
    }
}

extension FilmGrain {
    /// Installs an optional application-owned source of lossless banks. Called only when a new
    /// binding is needed; existing bindings keep their immutable bank. Missing or invalid assets
    /// fall back to canonical generation. The closure must not request another Film binding.
    public static func installAssetProvider(_ provider: (@Sendable (Data) -> Data?)?) {
        FilmGrainAsset.install(provider)
    }
}
