import XCTest
@testable import FotufilmCore
#if canImport(FotufilmMetal)
@testable import FotufilmMetal
#endif

/// The host's own last step, taken in the kernel.
///
/// `FilmOutputTransform` names a delivery in the terms the `encodeOut` variants read, so the
/// engine can hand a caller pixels that are already in the host's space instead of display-linear
/// light for the host to walk. These hold the two roads that carry it — the staged CPU pipeline
/// and the fused GPU one — to the converter they replace, and hold the shoulder to being a step
/// that is actually taken rather than a slot that is merely written.
final class KernelDeliveryTests: XCTestCase {
    /// A scene with real highlights in it: the shoulder only shows above its knee, so a frame
    /// that never gets there cannot tell a shouldered delivery from an unshouldered one.
    private func scene(width: Int, height: Int) -> ImageBuffer {
        var image = ImageBuffer(width: width, height: height)
        for index in 0..<image.pixelCount {
            let x = Float(index % width) / Float(max(width - 1, 1))
            let y = Float(index / width) / Float(max(height - 1, 1))
            // 0.005 to about 8 — well under the toe and well over diffuse white.
            let radiance = 0.005 * exp2(11 * x)
            image.planes[0][index] = radiance * (0.7 + 0.6 * y)
            image.planes[1][index] = radiance
            image.planes[2][index] = radiance * (1.3 - 0.6 * y)
        }
        return image
    }

    private func options() -> FotufilmEngine.Options {
        var options = FotufilmEngine.Options()
        options.format = .super8
        // Grain is the one stage whose output depends on where a strip started, and this is a
        // comparison of two renders of the same frame, not of the grain.
        options.grainScale = 0
        return options
    }

    /// What `FilmRender` asks the engine for, and what it asks the host for when the engine
    /// cannot carry it. One knee, one transfer, two spellings.
    private let knee = FilmSDRDelivery.standardShoulderKnee

    private func hostDelivered(_ printed: ImageBuffer,
                               shouldered: Bool) -> [Float] {
        let converter: AnyFilmOutputConverter = shouldered
            ? AnyFilmOutputConverter(FilmDisplayP3SDRConversion(shoulderKnee: knee))
            : AnyFilmOutputConverter(FilmOutputConversion.displayP3)
        var interleaved = [Float](repeating: 0, count: printed.pixelCount * 4)
        for index in 0..<printed.pixelCount {
            interleaved[index * 4] = printed.planes[0][index]
            interleaved[index * 4 + 1] = printed.planes[1][index]
            interleaved[index * 4 + 2] = printed.planes[2][index]
            interleaved[index * 4 + 3] = 1
        }
        var converted = [Float](repeating: 0, count: interleaved.count)
        interleaved.withUnsafeBufferPointer { source in
            converted.withUnsafeMutableBufferPointer { destination in
                converter.convert(source, from: 0, count: source.count,
                                  into: destination)
            }
        }
        return converted
    }

    /// The kernel floors before its matrix and does not clamp above white; the host converter
    /// clamps both ends before its transfer. Both land on the same code value once quantized, so
    /// compare where the comparison means something: inside the range a 16-bit print can hold.
    private func assertMatches(_ kernel: ImageBuffer, _ host: [Float],
                               tolerance: Float, file: StaticString = #filePath,
                               line: UInt = #line) {
        var compared = 0
        for index in 0..<kernel.pixelCount {
            for channel in 0..<3 {
                let expected = host[index * 4 + channel]
                guard expected > 0, expected < 1 else { continue }
                compared += 1
                XCTAssertEqual(kernel.planes[channel][index], expected,
                               accuracy: tolerance,
                               "pixel \(index) channel \(channel)",
                               file: file, line: line)
            }
        }
        XCTAssertGreaterThan(compared, kernel.pixelCount,
                             "the scene did not reach the range being compared",
                             file: file, line: line)
    }

    private func developed(_ stock: FilmStock, width: Int, height: Int)
        throws -> ImageBuffer
    {
        try XCTUnwrap(HalideBackend.develop(
            image: scene(width: width, height: height), stock: stock,
            options: options()))
    }

    // MARK: - The staged CPU road

    func testCPUKernelDeliveryMatchesTheHostConverter() throws {
        guard HalideBackend.isAvailable else { throw XCTSkip("Halide not linked") }
        let width = 64, height = 32
        let stock = TestStocks.negative
        let density = try developed(stock, width: width, height: height)
        let linear = try XCTUnwrap(HalideBackend.print(
            density: density, stock: stock, options: options()))
        let inKernel = try XCTUnwrap(HalideBackend.print(
            density: density, stock: stock, options: options(),
            outputTransform: .displayP3(shoulderKnee: knee)))
        assertMatches(inKernel, hostDelivered(linear, shouldered: true),
                      tolerance: 1e-5)
    }

    func testCPUKernelDeliveryCarriesTheUnshoulderedEncodeToo() throws {
        guard HalideBackend.isAvailable else { throw XCTSkip("Halide not linked") }
        let width = 64, height = 32
        let stock = TestStocks.negative
        let density = try developed(stock, width: width, height: height)
        let linear = try XCTUnwrap(HalideBackend.print(
            density: density, stock: stock, options: options()))
        let inKernel = try XCTUnwrap(HalideBackend.print(
            density: density, stock: stock, options: options(),
            outputTransform: .displayP3()))
        assertMatches(inKernel, hostDelivered(linear, shouldered: false),
                      tolerance: 1e-5)
    }

    /// The shoulder has to be a step the kernel takes, not a configuration slot it writes and
    /// ignores: without this, both comparisons above would still pass with the shoulder deleted,
    /// because each is compared against the converter it was told to match.
    func testTheShoulderChangesTheHighlightsItIsThereToRollOff() throws {
        guard HalideBackend.isAvailable else { throw XCTSkip("Halide not linked") }
        let width = 64, height = 32
        let stock = TestStocks.negative
        let density = try developed(stock, width: width, height: height)
        // The display-linear print the two deliveries encode, which is what says whether a given
        // pixel is above the knee — the encoded value cannot, because a print's white sits just
        // under 1 and every encoded highlight is bunched against it.
        let linear = try XCTUnwrap(HalideBackend.print(
            density: density, stock: stock, options: options()))
        let bare = try XCTUnwrap(HalideBackend.print(
            density: density, stock: stock, options: options(),
            outputTransform: .displayP3()))
        let rolled = try XCTUnwrap(HalideBackend.print(
            density: density, stock: stock, options: options(),
            outputTransform: .displayP3(shoulderKnee: knee)))

        var moved = 0
        var held = 0
        for index in 0..<bare.pixelCount {
            for channel in 0..<3 {
                let light = linear.planes[channel][index]
                let above = bare.planes[channel][index]
                let under = rolled.planes[channel][index]
                // Below the knee the shoulder is the identity, and the two deliveries are the
                // same encode of the same light.
                if light < knee - 0.05 {
                    XCTAssertEqual(under, above, accuracy: 1e-5)
                    held += 1
                } else if light > knee + 0.01 {
                    XCTAssertLessThan(under, above,
                                      "the shoulder must pull white down, not leave it")
                    moved += 1
                }
            }
        }
        XCTAssertGreaterThan(held, 100, "no shadow to hold")
        XCTAssertGreaterThan(moved, 100, "no highlight to roll off")
    }

    /// The matrix and the shoulder in the order the kernel takes them, which is the order
    /// `FilmOutputConversion.sRGBSDR` takes them: into the host's primaries first, and the
    /// shoulder against the value that arrives there. With the identity matrix the two orders are
    /// indistinguishable, so this is the test that says which one the kernel implements.
    func testKernelDeliveryShouldersAfterTheMatrixNotBeforeIt() throws {
        guard HalideBackend.isAvailable else { throw XCTSkip("Halide not linked") }
        let width = 64, height = 32
        let stock = TestStocks.negative
        let density = try developed(stock, width: width, height: height)
        let linear = try XCTUnwrap(HalideBackend.print(
            density: density, stock: stock, options: options()))
        // Row-major linear Display P3 to linear sRGB, the matrix
        // `ColorScience.linearDisplayP3ToSRGB` applies.
        let toSRGB: [Float] = [
             1.22494018, -0.224940176, 0,
            -0.042056955, 1.04205695, 0,
            -0.019637555, -0.078636046, 1.09827360,
        ]
        let inKernel = try XCTUnwrap(HalideBackend.print(
            density: density, stock: stock, options: options(),
            outputTransform: FilmOutputTransform(
                matrix: toSRGB, transfer: .powerLaw,
                coefficients: FilmOutputTransform.srgbCoefficients,
                premultiplied: false, shoulderKnee: knee)))

        var host = [Float](repeating: 0, count: linear.pixelCount * 4)
        for index in 0..<linear.pixelCount {
            let p3 = SIMD3(linear.planes[0][index], linear.planes[1][index],
                           linear.planes[2][index])
            let srgb = ColorScience.linearDisplayP3ToSRGB(p3)
            for channel in 0..<3 {
                host[index * 4 + channel] = ColorScience.linearToSrgb(
                    ColorScience.displayShoulder(srgb[channel], knee: knee))
            }
        }
        assertMatches(inKernel, host, tolerance: 1e-5)
    }

    /// A negative knee is no shoulder at all — the sentinel a linear or unshouldered delivery
    /// writes, and the value every configuration carries until a delivery replaces it.
    func testNoShoulderIsTheDefaultTheConfigurationCarries() throws {
        let invocation = FilmEngineInvocation(
            stock: TestStocks.negative, options: options(), width: 8, height: 8)
        XCTAssertLessThan(
            invocation.configuration[FilmEngineInvocation.outputShoulderOffset], 0,
            "a configuration nobody has given a delivery must carry no shoulder")
    }

    // MARK: - The fused GPU road

    #if canImport(FotufilmMetal)
    func testGPUKernelDeliveryMatchesTheHostConverter() throws {
        guard let gpu = HalideMetalFilmRenderer.shared else { throw XCTSkip("no Metal") }
        let width = 64, height = 32
        let stock = TestStocks.negative
        let options = self.options()
        guard gpu.carriesOutputTransform(
            stock: stock, options: options, width: width, height: height)
        else { throw XCTSkip("this build has no encoding variant for the frame") }

        let source = scene(width: width, height: height)
        var interleaved = [Float](repeating: 0, count: width * height * 4)
        for index in 0..<source.pixelCount {
            for channel in 0..<3 {
                interleaved[index * 4 + channel] = source.planes[channel][index]
            }
            interleaved[index * 4 + 3] = 1
        }

        func render(_ transform: FilmOutputTransform?) throws -> [Float] {
            var wanted = transform
            var out = [Float](repeating: 0, count: width * height * 4)
            let ok = gpu.developStreaming(
                width: width, height: height, stock: stock, options: options,
                outputTransform: &wanted,
                readRows: { rows, into in
                    let start = rows.lowerBound * width * 4
                    for i in 0..<(rows.count * width * 4) {
                        into[i] = interleaved[start + i]
                    }
                },
                writeRows: { rows, from in
                    let start = rows.lowerBound * width * 4
                    for i in 0..<(rows.count * width * 4) { out[start + i] = from[i] }
                })
            XCTAssertTrue(ok)
            XCTAssertEqual(wanted != nil, transform != nil,
                           "carriesOutputTransform and developStreaming disagreed")
            return out
        }

        let linear = try render(nil)
        let inKernel = try render(.displayP3(shoulderKnee: knee))

        var planes = ImageBuffer(width: width, height: height)
        for index in 0..<(width * height) {
            for channel in 0..<3 {
                planes.planes[channel][index] = inKernel[index * 4 + channel]
            }
        }
        var linearPlanes = ImageBuffer(width: width, height: height)
        for index in 0..<(width * height) {
            for channel in 0..<3 {
                linearPlanes.planes[channel][index] = linear[index * 4 + channel]
            }
        }
        // Looser than the CPU comparison: the two renders are the same schedule, but the
        // delivered one folds the transfer into the producing kernel, where the arithmetic is
        // done in the kernel's own order rather than a separate host pass over its result.
        assertMatches(planes, hostDelivered(linearPlanes, shouldered: true),
                      tolerance: 2e-4)
    }
    #endif
}
