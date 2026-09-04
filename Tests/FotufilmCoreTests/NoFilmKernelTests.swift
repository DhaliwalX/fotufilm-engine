import XCTest
@testable import FotufilmCore
#if canImport(FotufilmMetal)
@testable import FotufilmMetal
#endif

/// No film in the gate, as a kernel.
///
/// `PlainDevelop` is the Swift statement of this path and stays the reference: these hold the
/// Halide one to it, and hold the claim that makes naming a stock harmless — that a no-film
/// render reads nothing the stock filled in.
final class NoFilmKernelTests: XCTestCase {
    private func scene(width: Int, height: Int) -> ImageBuffer {
        var image = ImageBuffer(width: width, height: height)
        for index in 0..<image.pixelCount {
            let x = Float(index % width) / Float(max(width - 1, 1))
            let y = Float(index / width) / Float(max(height - 1, 1))
            let radiance = 0.004 * exp2(11 * x)
            image.planes[0][index] = radiance * (0.6 + 0.8 * y)
            image.planes[1][index] = radiance
            image.planes[2][index] = radiance * (1.4 - 0.8 * y)
        }
        return image
    }

    /// `PlainDevelop` over the same frame, interleaved as it wants and read back as planes.
    private func reference(_ image: ImageBuffer,
                           options: FotufilmEngine.Options) -> ImageBuffer {
        var plain = PlainDevelop(options: options)
        var interleaved = [Float](repeating: 0, count: image.pixelCount * 4)
        for index in 0..<image.pixelCount {
            for channel in 0..<3 {
                interleaved[index * 4 + channel] = image.planes[channel][index]
            }
            interleaved[index * 4 + 3] = 1
        }
        if plain.needsToneBase {
            var measurement = plain.toneBaseMeasurement(
                frameWidth: image.width, frameHeight: image.height)
            interleaved.withUnsafeBufferPointer {
                measurement.add(linearRGBA: $0.baseAddress!, rows: 0..<image.height)
            }
            plain.setToneBase(measurement)
        }
        interleaved.withUnsafeMutableBufferPointer {
            plain.apply(linearRGBA: $0, rows: 0..<image.height, width: image.width)
        }
        var result = ImageBuffer(width: image.width, height: image.height)
        for index in 0..<image.pixelCount {
            for channel in 0..<3 {
                result.planes[channel][index] = interleaved[index * 4 + channel]
            }
        }
        return result
    }

    private func assertMatches(_ kernel: ImageBuffer, _ host: ImageBuffer,
                               tolerance: Float,
                               file: StaticString = #filePath, line: UInt = #line) {
        for index in 0..<host.pixelCount {
            for channel in 0..<3 {
                XCTAssertEqual(kernel.planes[channel][index],
                               host.planes[channel][index], accuracy: tolerance,
                               "pixel \(index) channel \(channel)",
                               file: file, line: line)
            }
        }
    }

    private func run(_ options: FotufilmEngine.Options,
                     stock: FilmStock = TestStocks.negative,
                     width: Int = 96, height: Int = 48) throws -> (ImageBuffer, ImageBuffer) {
        let image = scene(width: width, height: height)
        let kernel = try XCTUnwrap(HalideBackend.process(
            image: image, stock: stock, options: options, noFilm: true))
        return (kernel, reference(image, options: options))
    }

    func testNeutralControlsMatchPlainDevelop() throws {
        guard HalideBackend.isAvailable else { throw XCTSkip("Halide not linked") }
        var options = FotufilmEngine.Options()
        options.exposureEV = 0.4
        let (kernel, host) = try run(options)
        assertMatches(kernel, host, tolerance: 2e-5)
    }

    func testToneAndChromaControlsMatchPlainDevelop() throws {
        guard HalideBackend.isAvailable else { throw XCTSkip("Halide not linked") }
        var options = FotufilmEngine.Options()
        options.exposureEV = -0.3
        options.highlights = -0.6
        options.shadows = 0.45
        options.saturation = 1.3
        options.vibrance = 0.5
        let (kernel, host) = try run(options)
        assertMatches(kernel, host, tolerance: 5e-5)
    }

    func testTheGradeMatchesPlainDevelop() throws {
        guard HalideBackend.isAvailable else { throw XCTSkip("Halide not linked") }
        var options = FotufilmEngine.Options()
        options.grade = ColorGrade(
            shadows: .init(balanceX: 0.2, balanceY: 0.1, level: 0.1),
            midtones: .init(balanceX: -0.1, balanceY: 0.15, level: 0.2),
            highlights: .init(balanceX: 0.1, balanceY: -0.1, level: 0.25))
        let (kernel, host) = try run(options)
        assertMatches(kernel, host, tolerance: 5e-5)
    }

    func testWhiteBalanceMatchesPlainDevelop() throws {
        guard HalideBackend.isAvailable else { throw XCTSkip("Halide not linked") }
        var options = FotufilmEngine.Options()
        options.whiteBalance = .init(kelvin: 3200, tint: 0.1)
        options.saturation = 1.15
        let (kernel, host) = try run(options)
        assertMatches(kernel, host, tolerance: 5e-5)
    }

    // MARK: - The fused GPU road

    #if canImport(FotufilmMetal)
    /// The same frame on the road the app develops on. Both roads read one `plain_print`, so
    /// this is the test that says the fused pipeline reaches it.
    func testGPUNoFilmMatchesPlainDevelop() throws {
        guard let gpu = HalideMetalFilmRenderer.shared else { throw XCTSkip("no Metal") }
        let width = 96, height = 48
        var options = FotufilmEngine.Options()
        options.exposureEV = -0.3
        options.highlights = -0.6
        options.shadows = 0.45
        options.saturation = 1.3
        options.vibrance = 0.5

        let image = scene(width: width, height: height)
        var interleaved = [Float](repeating: 0, count: width * height * 4)
        for index in 0..<image.pixelCount {
            for channel in 0..<3 {
                interleaved[index * 4 + channel] = image.planes[channel][index]
            }
            interleaved[index * 4 + 3] = 1
        }
        var out = [Float](repeating: 0, count: width * height * 4)
        var none: FilmOutputTransform? = nil
        let ok = gpu.developStreaming(
            width: width, height: height, stock: TestStocks.negative,
            options: options, outputTransform: &none, noFilm: true,
            readRows: { rows, into in
                let start = rows.lowerBound * width * 4
                for i in 0..<(rows.count * width * 4) { into[i] = interleaved[start + i] }
            },
            writeRows: { rows, from in
                let start = rows.lowerBound * width * 4
                for i in 0..<(rows.count * width * 4) { out[start + i] = from[i] }
            })
        XCTAssertTrue(ok)

        var kernel = ImageBuffer(width: width, height: height)
        for index in 0..<(width * height) {
            for channel in 0..<3 {
                kernel.planes[channel][index] = out[index * 4 + channel]
            }
        }
        assertMatches(kernel, reference(image, options: options), tolerance: 3e-4)
    }
    #endif

    /// The claim that makes naming a stock harmless. A no-film variant compiles no stage the
    /// emulsion owns and reads no slot the stock filled — except the highlight window, which is
    /// why the invocation takes its own when there is no film to take one from.
    func testNoFilmIgnoresWhichStockWasNamed() throws {
        guard HalideBackend.isAvailable else { throw XCTSkip("Halide not linked") }
        var options = FotufilmEngine.Options()
        options.highlights = -0.4
        options.saturation = 1.2
        // Declared headroom is what reaches the one stock-dependent slot; without it the test
        // could pass on a path that never consults the window at all.
        options.sceneHeadroom = 4
        let (negative, _) = try run(options, stock: TestStocks.negative)
        let (reversal, _) = try run(options, stock: TestStocks.reversal)
        assertMatches(negative, reversal, tolerance: 0)
    }
}
