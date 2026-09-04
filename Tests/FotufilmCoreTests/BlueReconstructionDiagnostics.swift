import XCTest
@testable import FotufilmCore

final class BlueReconstructionDiagnostics: XCTestCase {

    static let sky = SIMD3<Float>(0.16009, 0.26319, 0.41579)

    func testWhereBlueSkyExposureComesFrom() throws {
        for (name, rgb) in [("sky (measured)", Self.sky),
                            ("blue primary", SIMD3<Float>(0.02, 0.05, 0.80)),
                            ("mid blue", SIMD3<Float>(0.10, 0.20, 0.50)),
                            ("neutral", SIMD3<Float>(0.30, 0.30, 0.30))] {
            let spectrum = SpectralRuntime.reconstructedReflectance(linearRGB: rgb)
            let waves = SpectralGrid.wavelengths
            let total = spectrum.reduce(0, +)
            let long = zip(waves, spectrum)
                .filter { $0.0 >= 620 }.map(\.1).reduce(0, +)
            let veryLong = zip(waves, spectrum)
                .filter { $0.0 >= 680 }.map(\.1).reduce(0, +)
            let peak = spectrum.max() ?? 0
            let tail = spectrum.suffix(6).reduce(0, +) / 6

            print(String(
                format: "%-16@  total %7.3f  >=620nm %5.1f%%  >=680nm %5.1f%%"
                      + "  peak %.3f  mean 730-780nm %.4f",
                name as NSString, total, 100 * long / total,
                100 * veryLong / total, peak, tail))
        }
    }

    func testLayerExposureFromBlueSky() throws {
        let stock = try XCTUnwrap(FilmStock.named("portra400")
                                  ?? FilmStock.named("example-negative-400"))
        let profile = stock.spectralProfile
        let waves = SpectralGrid.wavelengths

        for (name, rgb) in [("sky (measured)", Self.sky),
                            ("neutral", SIMD3<Float>(0.30, 0.30, 0.30))] {
            let spectrum = SpectralRuntime.reconstructedReflectance(linearRGB: rgb)
            for layer in 0..<3 {
                let sensitivity = profile.layerSensitivity[layer]
                let product = zip(spectrum, sensitivity).map(*)
                let total = product.reduce(0, +)
                guard total > 0 else { continue }
                let long = zip(waves, product)
                    .filter { $0.0 >= 620 }.map(\.1).reduce(0, +)
                print(String(
                    format: "%-16@ layer %d  exposure %8.4f  from >=620nm %5.1f%%",
                    name as NSString, layer, total, 100 * long / total))
            }
        }
    }
}
