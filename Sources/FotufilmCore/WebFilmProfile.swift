import Foundation

/// The browser can prepare a profile at its actual render size instead of interpolating a
/// prebuilt size ladder. The configuration and spectral tables are the native invocation's.
public enum WebFilmProfile {
    public enum Failure: Error, CustomStringConvertible {
        case invalidDimensions, layeredTransport
        public var description: String {
            switch self {
            case .invalidDimensions: return "Invalid profile dimensions."
            case .layeredTransport: return "Dynamic Layered Transport profiles are not available yet."
            }
        }
    }

    public static func prepare(stock: FilmStock, options: FotufilmEngine.Options,
                               width: Int, height: Int) throws -> Data {
        guard width > 0, height > 0, width <= 120_000, height <= 120_000,
              Int64(width) * Int64(height) <= 120_000_000 else {
            throw Failure.invalidDimensions
        }
        guard options.transportConstruction(for: stock) == nil else {
            throw Failure.layeredTransport
        }
        var options = options
        // The rendering worker supplies a tone base measured from the photograph.
        options.localTone = false
        let invocation = try FilmEngineInvocation(validating: stock, options: options,
                                                   width: width, height: height)
        let spectral = invocation.spectral
        let lutCount = spectral.exposure.values.count
        var data = Data("FSWP".utf8)
        func integer(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func floats(_ values: [Float]) {
            for value in values { integer(value.bitPattern) }
        }
        integer(2)
        integer(UInt32(width)); integer(UInt32(height))
        integer(UInt32(bitPattern: invocation.featureMask)); integer(invocation.seed)
        integer(UInt32(invocation.configuration.count))
        integer(UInt32(spectral.exposure.dimension)); integer(UInt32(lutCount))
        integer(spectral.paperOutput == nil ? 0 : 1)
        floats(invocation.configuration)
        floats(spectral.exposure.values)
        floats(spectral.filmOutput.values)
        floats(spectral.paperOutput?.values ?? [Float](repeating: 0, count: lutCount))
        // A single exact rung retains the existing browser tiling/apron contract.
        integer(1); integer(UInt32(min(width, height)))
        integer(UInt32(bitPattern: invocation.featureMask)); integer(invocation.seed)
        integer(UInt32(invocation.spatialSupport)); integer(0)
        // The film grain model's tiles close the pack, their count last; see `--dump-wasm-pack`.
        if let tiles = FilmGrain.registeredTiles(configuration: invocation.configuration) {
            floats(tiles)
            integer(UInt32(tiles.count))
        }
        return data
    }
}
