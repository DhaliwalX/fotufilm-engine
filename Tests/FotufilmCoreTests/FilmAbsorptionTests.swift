import XCTest
@testable import FotufilmCore
#if canImport(Metal)
import FotufilmMetal
#endif

final class FilmAbsorptionTests: XCTestCase {
    private func fixture() -> FilmStock {
        var stock = TestStocks.negative
        stock.spectralProfile.minimumDensity = SpectralGrid.wavelengths.map {
            0.2 + 0.6 * exp(-pow(($0 - 440) / 95, 2))
        }
        // Absolute dye amplitudes are deliberately not a partition of unity.
        stock.spectralProfile.imageDyeDensity = stock.spectralProfile.imageDyeDensity.map {
            $0.map { $0 * 1.35 }
        }
        return stock
    }

    private func assertEqual(_ a: SIMD3<Float>, _ b: SIMD3<Float>, accuracy: Float = 1e-5,
                             file: StaticString = #filePath, line: UInt = #line) {
        for c in 0..<3 { XCTAssertEqual(a[c], b[c], accuracy: accuracy, file: file, line: line) }
    }

    func testMinimumUsesMeasuredBaseWithoutCountingRecordMinimaTwice() {
        var stock = fixture()
        let transmission = stock.spectralProfile.minimumDensity!.map { pow(10, -$0) }
        let expected = SpectralGrid.toLinearDisplayP3(reflectance: transmission)
        for minima: [Float] in [[0.1, 0.4, 0.8], [0.5, 0.2, 0.3]] {
            for c in 0..<3 { stock.curves[c].dMin = minima[c] }
            assertEqual(SpectralRuntime.transmissionRGB(density: minima, stock: stock), expected)
        }
    }

    func testPaperReceivesBasePlusNetDyesWithCondenserAndSilver() {
        let stock = fixture(), dyes = stock.spectralProfile.imageDyeDensity
        let minimum = stock.spectralProfile.minimumDensity!
        let net: [Float] = [0.3, 0.8, 0.4]
        let total = (0..<3).map { stock.curves[$0].dMin + net[$0] }
        let lamp = SpectralGrid.enlarger3200K
        let response = PrintPaper.ektacolorEdge.sensitivity
        for scale: Float in [1, 1.4] {
            var expected = SIMD3<Float>(repeating: 0)
            for i in 0..<SpectralGrid.count {
                let d = scale * (minimum[i] + net[0] * dyes[0][i]
                    + net[1] * dyes[1][i] + net[2] * dyes[2][i]) + 0.17
                for c in 0..<3 { expected[c] += lamp[i] * pow(10, -d) * response[c][i] }
            }
            assertEqual(SpectralRuntime.paperExposure(density: total.map { $0 * scale },
                stock: stock, lamp: lamp, paperSensitivity: response, neutralDensity: 0.17,
                densityScale: scale), expected, accuracy: 2e-5)
        }
    }

    func testAgeingRetainsDevelopedFogInIndependentMinimum() {
        let fresh = fixture()
        let aged = fresh.expired(years: 20)
        let density = aged.curves.map(\.dMin)
        // The aged minimum must absorb exactly like adding its developed fog to the
        // fresh negative; changing the record origin must not erase that absorption.
        assertEqual(SpectralRuntime.transmissionRGB(density: density, stock: aged),
                    SpectralRuntime.transmissionRGB(density: density, stock: fresh))
        XCTAssertTrue(zip(aged.spectralProfile.minimumDensity!,
                          fresh.spectralProfile.minimumDensity!).allSatisfy { $0 > $1 })
        XCTAssertEqual(fresh.expired(years: 0).spectralProfile.minimumDensity,
                       fresh.spectralProfile.minimumDensity)
    }

    func testLegacyAbsorptionIsBitIdentical() {
        let stock = TestStocks.negative, dyes = stock.spectralProfile.imageDyeDensity
        XCTAssertNil(SpectralRuntime.filmDensityOffset(for: stock))
        for density: [Float] in [[0.2, 0.6, 0.8], [1.4, 1.7, 2.2]] {
            XCTAssertEqual(SpectralRuntime.transmissionRGB(density: density, stock: stock),
                           SpectralRuntime.transmissionRGB(density: density, dyes: dyes))
            XCTAssertEqual(SpectralRuntime.paperExposure(density: density, stock: stock,
                lamp: SpectralGrid.equalEnergy, paperSensitivity: PrintPaper.labScan.sensitivity),
                SpectralRuntime.paperExposure(density: density, dyes: dyes,
                lamp: SpectralGrid.equalEnergy, paperSensitivity: PrintPaper.labScan.sensitivity))
        }
    }

    func testSeparatedBaseRoundTripsAndRejectsMalformedSamples() throws {
        let stock = fixture()
        let definition = FilmStockDefinition(id: "absorption-fixture", stock: stock)
        let data = try JSONEncoder().encode(definition)
        let decoded = try JSONDecoder().decode(FilmStockDefinition.self, from: data).validated()
        XCTAssertEqual(decoded.stock.spectralProfile.minimumDensity, stock.spectralProfile.minimumDensity)
        XCTAssertEqual(decoded.stock.spectralProfile.imageDyeDensity, stock.spectralProfile.imageDyeDensity)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("separatedBase"))
        for base in [Array(repeating: Float(0.2), count: 80),
                     Array(repeating: Float(-0.1), count: 81),
                     Array(repeating: Float.nan, count: 81)] {
            var invalid = definition
            invalid.spectral = .separatedBase(layerSensitivity: stock.spectralProfile.layerSensitivity,
                imageDyeDensity: stock.spectralProfile.imageDyeDensity, minimumDensity: base)
            XCTAssertThrowsError(try invalid.validate())
        }
    }

    func testBaseEditsInvalidateViewingAndPrintTables() {
        let first = fixture()
        var second = first
        second.spectralProfile.minimumDensity = first.spectralProfile.minimumDensity!.enumerated().map {
            $0.element + ($0.offset < 35 ? 0.5 : 0)
        }
        XCTAssertNotEqual(first.spectralProfile.signature, second.spectralProfile.signature)
        let a = SpectralRuntime.negativeViewing(for: first, look: .lightBox).sample(.zero)
        let b = SpectralRuntime.negativeViewing(for: second, look: .lightBox).sample(.zero)
        XCTAssertGreaterThan(abs(a.z - b.z), 0.02)
        XCTAssertEqual(SpectralRuntime.negativeViewing(for: second, look: .scanner).sample(.zero),
                       SIMD3<Float>(repeating: 1))
        for paper in [PrintPaper.screen, .labScan, .telecine, .ektacolorEdge] {
            let lhs = SpectralRuntime.tables(for: first, paper: paper).filmOutput.values
            let rhs = SpectralRuntime.tables(for: second, paper: paper).filmOutput.values
            XCTAssertNotEqual(lhs, rhs, paper.rawValue)
            XCTAssertTrue(rhs.allSatisfy(\.isFinite))
        }
    }

    #if canImport(Metal)
    func testSeparatedBaseCPUMetalAgreementAtDeliveryBoundary() throws {
        guard let gpu = HalideMetalFilmRenderer.shared else { throw XCTSkip("Metal unavailable") }
        var stock = fixture()
        stock.emulsionDiffusionMM = [0, 0, 0]
        stock.emulsionDiffusionSecondaryMM = [0, 0, 0]
        stock.adjacencyStrength = 0
        let size = 64
        // Float Rec.2020 input and float P3 output avoid the SRGB8 convenience path's
        // extra 8-bit P3 conversion, which quantizes dark saturated colors differently.
        var pixels = [Float](repeating: 1, count: size * size * 4)
        var input = ImageBuffer(width: size, height: size)
        for y in 0..<size { for x in 0..<size {
            let i = y * size + x
            let color = ColorScience.linearSRGBToRec2020(SIMD3<Float>(
                Float(x) / 32, Float(y) / 32, Float(x + y) / 64))
            for c in 0..<3 { pixels[i * 4 + c] = color[c]; input.planes[c][i] = color[c] }
        } }

        for paper in [PrintPaper.screen, .labScan, .telecine, .negative, .ektacolorEdge] {
            var options = FotufilmEngine.Options()
            options.paper = paper; options.grainScale = 0; options.halationScale = 0
            options.couplerScale = 0; options.localTone = false
            let cpu = try FotufilmEngine(stock: stock, options: options).processChecked(linearRGB: input)
            var metal = [Float]()
            XCTAssertTrue(gpu.processLinearFloat(pixels, into: &metal, width: size, height: size,
                                                stock: stock, options: options))
            var maximum: Float = 0
            for i in 0..<size * size { for c in 0..<3 {
                // Metal delivery floors negative P3 coordinates; the unencoded CPU
                // stage retains them. Compare at the documented delivery boundary.
                maximum = max(maximum, abs(max(cpu.planes[c][i], 0) - metal[i * 4 + c]))
            } }
            XCTAssertLessThan(maximum, 0.0002, paper.rawValue)

        }
    }
    #endif
}
