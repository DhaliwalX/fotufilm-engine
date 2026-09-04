#if canImport(Metal)
import Metal
import XCTest
@testable import FotufilmCore
@testable import FotufilmMetal

final class SceneReferredTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable, "Halide engine required")
    }

    func scene(width: Int, height: Int, peak: Float) -> [Float] {
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let bright = abs(x - width / 2) < width / 12
                    && abs(y - height / 2) < height / 12
                let v = bright ? peak : 0.18 * Float(x) / Float(width) + 0.02
                pixels[i] = v * 1.05
                pixels[i + 1] = v
                pixels[i + 2] = v * 0.92
                pixels[i + 3] = 1
            }
        }
        return pixels
    }

    func barredScene(width: Int, height: Int, peak: Float, period: Int) -> [Float] {
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let bright = y % period < period / 4
            for x in 0..<width {
                let i = (y * width + x) * 4
                let v = bright ? peak : 0.18 * Float(x) / Float(width) + 0.02
                pixels[i] = v * 1.05
                pixels[i + 1] = v
                pixels[i + 2] = v * 0.92
                pixels[i + 3] = 1
            }
        }
        return pixels
    }

    func maxDifference(_ a: [Float], _ b: [Float]) -> Float {
        var worst: Float = 0
        for i in 0..<min(a.count, b.count) { worst = max(worst, abs(a[i] - b[i])) }
        return worst
    }

    func testStripedRenderMatchesWholeFrame() throws {
        guard let gpu = HalideMetalFilmRenderer.shared else { throw XCTSkip("no Metal") }
        let width = 256, height = 2048
        let pixels = scene(width: width, height: height, peak: 6)
        var options = FotufilmEngine.Options()
        options.format = .super8
        for stock in TestStocks.all {
            let whole = try XCTUnwrap(gpu.processLinearFloat(
                pixels, width: width, height: height, stock: stock,
                options: options, memoryBudget: 1 << 30))
            var strips = 0
            let tiled = try XCTUnwrap(gpu.processLinearFloat(
                pixels, width: width, height: height, stock: stock,
                options: options, memoryBudget: 21 << 20,
                progress: { phase in
                    if case .developing(_, let count) = phase { strips = count }
                }))
            XCTAssertGreaterThan(strips, 1, "\(stock.name) did not actually tile")
            XCTAssertLessThan(maxDifference(whole, tiled), 1.0 / 512,
                              "\(stock.name) seams between strips")
        }
    }

    func testStripedStillMatchesWholeFrameWithGrain() throws {
        guard let gpu = HalideMetalFilmRenderer.shared else { throw XCTSkip("no Metal") }
        let width = 640, height = 3000
        let pixels = scene(width: width, height: height, peak: 9)
        let options = FotufilmEngine.Options()
        for stock in TestStocks.all {
            let whole = try XCTUnwrap(gpu.processLinearFloat(
                pixels, width: width, height: height, stock: stock,
                options: options, memoryBudget: 1 << 30))
            var strips = 0
            let tiled = try XCTUnwrap(gpu.processLinearFloat(
                pixels, width: width, height: height, stock: stock,
                options: options, memoryBudget: 40 << 20,
                progress: { if case .developing(_, let c) = $0 { strips = c } }))
            XCTAssertGreaterThan(strips, 1, "\(stock.name) did not actually tile")
            XCTAssertLessThan(maxDifference(whole, tiled), 1.0 / 512,
                              "\(stock.name) seams between strips")
        }
    }

    func testFieldsRoadMatchesWholeFrame() throws {
        guard let gpu = HalideMetalFilmRenderer.shared else { throw XCTSkip("no Metal") }
        let width = 640, height = 3000
        let pixels = scene(width: width, height: height, peak: 9)
        let options = FotufilmEngine.Options()
        var physical = TestStocks.negative
        physical.name = "Continuous physical halation"
        physical.halationProfile = HalationProfile(
            roundTripOpticalDepth: [0.7, 1.0, 1.3],
            angularExponent: [0.8, 1.1, 1.5],
            diffuseShare: [0.08, 0.14, 0.22],
            diffuseSigmaMM: [0.018, 0.014, 0.010],
            bounceRetention: [0.18, 0.12, 0.08])
        setenv("FOTUFILM_NO_FIELDS", "1", 1)
        defer { unsetenv("FOTUFILM_NO_FIELDS") }
        for stock in TestStocks.all + [physical] {
            let whole = try XCTUnwrap(gpu.processLinearFloat(
                pixels, width: width, height: height, stock: stock,
                options: options, memoryBudget: 1 << 30))
            var classicStrips = 0
            _ = try XCTUnwrap(gpu.processLinearFloat(
                pixels, width: width, height: height, stock: stock,
                options: options, memoryBudget: 40 << 20,
                progress: { if case .developing(_, let c) = $0 { classicStrips = c } }))
            unsetenv("FOTUFILM_NO_FIELDS")
            setenv("FOTUFILM_FORCE_FIELDS", "1", 1)
            var fieldsStrips = 0
            let fielded = try XCTUnwrap(gpu.processLinearFloat(
                pixels, width: width, height: height, stock: stock,
                options: options, memoryBudget: 40 << 20,
                progress: { if case .developing(_, let c) = $0 { fieldsStrips = c } }))
            unsetenv("FOTUFILM_FORCE_FIELDS")
            setenv("FOTUFILM_NO_FIELDS", "1", 1)
            let invocation = FilmEngineInvocation(
                stock: stock, options: options, width: width, height: height)
            if invocation.halationSupport > 0 {
                XCTAssertGreaterThan(
                    fieldsStrips, classicStrips,
                    "\(stock.name) never took the fields road — its develop "
                    + "should add light strips to the classic count")
            }
            XCTAssertLessThan(maxDifference(whole, fielded), 1.0 / 512,
                              "\(stock.name) fields road strays from the whole frame")
        }
    }

    func testStillRendererRespondsToHDRExposure() throws {
        guard let gpu = HalideMetalFilmRenderer.shared else { throw XCTSkip("no Metal") }
        let side = 64
        var options = FotufilmEngine.Options()
        options.grainScale = 0

        func developedGreen(_ exposure: Float) throws -> Float {
            var pixels = [Float](repeating: 1, count: side * side * 4)
            for index in 0..<(side * side) {
                pixels[index * 4] = exposure
                pixels[index * 4 + 1] = exposure
                pixels[index * 4 + 2] = exposure
            }
            let print = try XCTUnwrap(gpu.processLinearFloat(
                pixels, width: side, height: side, stock: TestStocks.negative,
                options: options, memoryBudget: 96 << 20))
            return print[((side / 2) * side + side / 2) * 4 + 1]
        }

        let one = try developedGreen(1)
        let two = try developedGreen(2)
        let four = try developedGreen(4)
        XCTAssertGreaterThan(two, one + 0.01,
                             "the film did not react from 1× to 2× exposure")
        XCTAssertGreaterThan(four, two + 0.01,
                             "the film did not react from 2× to 4× exposure")
    }

    func testPeakEstimateCoversTheBuffersAnExportReallyHolds() {
        let width = 7008, height = 4672
        let stock = TestStocks.negative
        let options = FotufilmEngine.Options()
        let invocation = FilmEngineInvocation(
            stock: stock, options: options, width: width, height: height)
        let apron = invocation.spatialSupport
        XCTAssertGreaterThan(apron, 150, "halation should span hundreds of pixels here")

        let pixels = width * height
        let strip = min(height, 2 * apron + 1)
        let frames = 2 * MappedBuffer.residentBytes(pixels * 8)
        XCTAssertEqual(frames, 0, "a 33 MP frame buffer belongs on disk")
        let expected = frames
            + strip * width * (16 * 2 + HalideMetalFilmRenderer.developBytesPerPixel)
        let estimate = HalideMetalFilmRenderer.minimumPeakBytes(
            width: width, height: height, stock: stock, options: options)
        XCTAssertGreaterThanOrEqual(estimate, expected,
                                    "estimate misses buffers the export holds")

        XCTAssertLessThan(estimate, pixels * 16 + strip * width * 200,
                          "estimate implies a full float frame is still held")

        let small = 64
        XCTAssertEqual(MappedBuffer.residentBytes(small * small * 8),
                       small * small * 8,
                       "a preview-sized buffer has nowhere cheaper to live")

        XCTAssertTrue(HalideMetalFilmRenderer.canRender(
            width: width, height: height, stock: stock, options: options,
            budget: estimate))
        XCTAssertFalse(HalideMetalFilmRenderer.canRender(
            width: width, height: height, stock: stock, options: options,
            budget: estimate - 1))

        let available = HalideMetalFilmRenderer.availableBytes()
        XCTAssertFalse(HalideMetalFilmRenderer.canRender(
            width: width, height: height, stock: stock, options: options,
            budget: nil) && estimate > available * 4 / 5,
            "the gate would approve a render with no headroom left")
    }

    func testStripNeverOutgrowsItsBudget() {
        let width = 8064, height = 6048
        let perRow = HalideMetalFilmRenderer.stripBytesPerRow(width: width)
        for budgetRows in stride(from: 64, through: 4096, by: 64) {
            let budget = budgetRows * perRow
            for apron in stride(from: 1, through: budgetRows, by: 7) {
                let rows = HalideMetalFilmRenderer.stripRows(
                    width: width, height: height, apron: apron, budget: budget)
                let strip = min(height, rows + 2 * apron)
                XCTAssertGreaterThan(rows, 0, "a strip has to make progress")
                guard 2 * apron + 1 <= budgetRows else { continue }
                XCTAssertLessThanOrEqual(
                    strip * perRow, budget,
                    "a \(rows)-row strip with a \(apron)-row apron overruns a "
                    + "\(budgetRows)-row budget")
            }
        }
    }

    func testEveryStripPricesFullPrecisionApron() {
        let width = 7008
        XCTAssertEqual(
            HalideMetalFilmRenderer.apronBytesPerRow(
                width: width, exactMath: true),
            HalideMetalFilmRenderer.stripBytesPerRow(width: width),
            "float stills must not use a half-float apron estimate")

        let height = 4672
        let apron = 591
        let budget = 1 << 30
        let rows = HalideMetalFilmRenderer.stripRows(
            width: width, height: height, apron: apron,
            budget: budget, exactMath: true)
        let stripHeight = min(height, rows + 2 * apron)
        XCTAssertLessThanOrEqual(
            stripHeight * HalideMetalFilmRenderer.stripBytesPerRow(width: width),
            budget,
            "an accurate strip must fit the budget with its full-float apron")
    }

    func testAccurateTwoHundredMegapixelGateUsesExactApron() {
        let width = 16_320, height = 12_240
        XCTAssertEqual(width * height, 199_756_800)
        let stock = TestStocks.negative
        let options = FotufilmEngine.Options()
        let invocation = FilmEngineInvocation(
            stock: stock, options: options, width: width, height: height)
        XCTAssertGreaterThan(invocation.spatialSupport, 0)

        let fast = HalideMetalFilmRenderer.minimumPeakBytes(
            width: width, height: height, stock: stock, options: options)
        let accurate = HalideMetalFilmRenderer.minimumPeakBytes(
            width: width, height: height, stock: stock, options: options,
            exactMath: true)
        XCTAssertGreaterThanOrEqual(accurate, fast)
        XCTAssertTrue(HalideMetalFilmRenderer.canRender(
            width: width, height: height, stock: stock, options: options,
            budget: accurate, exactMath: true))
        XCTAssertFalse(HalideMetalFilmRenderer.canRender(
            width: width, height: height, stock: stock, options: options,
            budget: accurate - 1, exactMath: true))
    }

    func testStripIsTheWholeFrameWhenTheWholeFrameFits() {
        let width = 512, height = 512
        let perRow = HalideMetalFilmRenderer.stripBytesPerRow(width: width)
        XCTAssertEqual(
            HalideMetalFilmRenderer.stripRows(
                width: width, height: height, apron: 200,
                budget: height * perRow),
            height,
            "a frame that fits should not be cut up on account of its apron")
    }

    func testMappedFramesDevelopIdenticallyToPlainMemory() throws {
        guard let gpu = HalideMetalFilmRenderer.shared else { throw XCTSkip("no Metal") }
        let width = 1024, height = 4096
        var options = FotufilmEngine.Options()
        options.format = .super8
        let pixels = barredScene(width: width, height: height, peak: 6,
                                 period: 128)
        let expected = try XCTUnwrap(gpu.processLinearFloat(
            pixels, width: width, height: height, stock: TestStocks.negative,
            options: options, memoryBudget: 96 << 20))

        let source = try XCTUnwrap(MappedBuffer(byteCount: width * height * 16))
        let print = try XCTUnwrap(MappedBuffer(byteCount: width * height * 8))
        XCTAssertTrue(source.isMapped && print.isMapped,
                      "this test is only worth running on mapped buffers")
        let light = source.bound(to: Float.self)
        for index in 0..<(width * height * 4) { light[index] = pixels[index] }
        let printed = print.bound(to: UInt16.self)

        var strips = 0
        let ok = gpu.developStreaming(
            width: width, height: height, stock: TestStocks.negative,
            options: options, memoryBudget: 96 << 20,
            progress: { phase in
                if case .developing(_, let count) = phase { strips = count }
            },
            readRows: { rows, into in
                let start = rows.lowerBound * width * 4
                for index in 0..<(rows.count * width * 4) {
                    into[index] = light[start + index]
                }
            },
            writeRows: { rows, from in
                let start = rows.lowerBound * width * 4
                for index in 0..<(rows.count * width * 4) {
                    printed[start + index] = UInt16(
                        max(0, min(65535, from[index] * 65535)))
                }
                print.flush(byteOffset: rows.lowerBound * width * 8,
                            byteCount: rows.count * width * 8)
            })
        XCTAssertTrue(ok)
        XCTAssertGreaterThan(strips, 1, "the render did not actually tile")

        for index in stride(from: 0, to: width * height * 4, by: 37) {
            let reference = UInt16(max(0, min(65535, expected[index] * 65535)))
            XCTAssertEqual(printed[index], reference,
                           "sample \(index) differs through the mapping")
        }
    }

    func testDevelopRefusesRatherThanExceedItsBudget() throws {
        guard let gpu = HalideMetalFilmRenderer.shared else { throw XCTSkip("no Metal") }
        let width = 512, height = 512
        var options = FotufilmEngine.Options()
        options.format = .super8
        let pixels = [Float](repeating: 0.2, count: width * height * 4)
        XCTAssertNil(gpu.processLinearFloat(
            pixels, width: width, height: height, stock: TestStocks.negative,
            options: options, memoryBudget: 1 << 20),
            "a render that cannot fit its budget must fail, not proceed")
    }

    func testApronIsWideEnoughForHalationToBeInvisible() throws {
        guard let gpu = HalideMetalFilmRenderer.shared else { throw XCTSkip("no Metal") }
        // This canary measures the classic single-pass striping, where halation rides in the
        // apron. The fields path removes halation from the apron by construction — a starved
        // apron there no longer visibly hurts, which is its point, and its own parity test
        // (testFieldsRoadMatchesWholeFrame) holds it to the whole frame instead.
        setenv("FOTUFILM_NO_FIELDS", "1", 1)
        defer { unsetenv("FOTUFILM_NO_FIELDS") }
        let width = 256, height = 2048
        let pixels = barredScene(width: width, height: height, peak: 8,
                                 period: 128)
        var options = FotufilmEngine.Options()
        options.format = .super8
        options.grainScale = 0
        let whole = try XCTUnwrap(gpu.processLinearFloat(
            pixels, width: width, height: height, stock: TestStocks.negative,
            options: options, memoryBudget: 1 << 30))
        func error(apronScale: Double) throws -> Float {
            let tiled = try XCTUnwrap(gpu.processLinearFloat(
                pixels, width: width, height: height, stock: TestStocks.negative,
                options: options, memoryBudget: 21 << 20, apronScale: apronScale))
            return maxDifference(whole, tiled)
        }
        let shipped = try error(apronScale: 1)
        let starved = try error(apronScale: 0.15)
        XCTAssertLessThan(shipped, 1.0 / 4096,
                          "the shipped apron should make striping invisible")
        XCTAssertGreaterThan(starved, 1.0 / 256,
                             "a starved apron must visibly hurt; if it does "
                             + "not, this test has stopped measuring anything")
    }

    func testFloatScheduleAgreesWithEightBitOnDisplayReferredInput() throws {
        guard let gpu = HalideMetalFilmRenderer.shared else { throw XCTSkip("no Metal") }
        let size = 96
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        var bytes = [UInt8](repeating: 255, count: size * size * 4)
        var floats = [Float](repeating: 1, count: size * size * 4)
        for i in 0..<(size * size) {
            let level = UInt8(20 + (i % 200))
            for c in 0..<3 {
                bytes[i * 4 + c] = level
                let encoded = Float(level) / 255
                floats[i * 4 + c] = encoded <= 0.04045
                    ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
            }
        }
        let eight = try XCTUnwrap(gpu.processSRGB8(
            bytes, width: size, height: size, stock: TestStocks.negative, options: options))
        let float = try XCTUnwrap(gpu.processLinearFloat(
            floats, width: size, height: size, stock: TestStocks.negative, options: options))
        var worst = 0
        for i in 0..<(size * size) {
            for c in 0..<3 {
                let rolled = ColorScience.displayShoulder(float[i * 4 + c])
                let linear = min(max(rolled, 0), 1)
                let encoded = linear <= 0.0031308
                    ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
                worst = max(worst, abs(Int(bytes: eight[i * 4 + c]) - Int(encoded * 255 + 0.5)))
            }
        }
        XCTAssertLessThanOrEqual(worst, 2, "schedules disagree by \(worst)/255")
    }

    func testFloatBufferEntryAgreesWithEightBitOnDisplayReferredInput() throws {
        guard let gpu = HalideMetalFilmRenderer.shared else { throw XCTSkip("no Metal") }
        guard let metal = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let size = 96
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        var bytes = [UInt8](repeating: 255, count: size * size * 4)
        var floats = [Float](repeating: 1, count: size * size * 4)
        for i in 0..<(size * size) {
            let level = UInt8(20 + (i % 200))
            for c in 0..<3 {
                bytes[i * 4 + c] = level
                let encoded = Float(level) / 255
                floats[i * 4 + c] = encoded <= 0.04045
                    ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
            }
        }
        let eight = try XCTUnwrap(gpu.processSRGB8(
            bytes, width: size, height: size, stock: TestStocks.negative, options: options))
        let byteCount = size * size * 16
        guard let input = metal.makeBuffer(length: byteCount, options: .storageModeShared),
              let output = metal.makeBuffer(length: byteCount, options: .storageModeShared)
        else { throw XCTSkip("no shared buffers") }
        floats.withUnsafeBufferPointer { source in
            input.contents().copyMemory(from: source.baseAddress!, byteCount: byteCount)
        }
        XCTAssertTrue(gpu.processLinearFloat(
            input: input, output: output, width: size, height: size,
            stock: TestStocks.negative, options: options))
        let developed = output.contents().assumingMemoryBound(to: Float.self)
        var worst = 0
        for i in 0..<(size * size) {
            for c in 0..<3 {
                let rolled = ColorScience.displayShoulder(developed[i * 4 + c])
                let linear = min(max(rolled, 0), 1)
                let encoded = linear <= 0.0031308
                    ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
                worst = max(worst, abs(Int(bytes: eight[i * 4 + c]) - Int(encoded * 255 + 0.5)))
            }
        }
        XCTAssertLessThanOrEqual(worst, 2, "buffer float entry disagrees by \(worst)/255")
    }

    func testHighlightsAboveDisplayWhiteStillCarryInformation() throws {
        guard let gpu = HalideMetalFilmRenderer.shared else { throw XCTSkip("no Metal") }
        let width = 192, height = 192
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        // Twelve pixels outside the highlight is past halation's reach, so what
        // carries a bright highlight that far is the frame-wide veiling glare —
        // which this test needs turned on now that it is opt-in. The assertion
        // below has always been reading flare, whatever its message said.
        options.flareScale = 1
        let atWhite = try XCTUnwrap(gpu.processLinearFloat(
            scene(width: width, height: height, peak: 1),
            width: width, height: height, stock: TestStocks.negative, options: options))
        let farAbove = try XCTUnwrap(gpu.processLinearFloat(
            scene(width: width, height: height, peak: 20),
            width: width, height: height, stock: TestStocks.negative, options: options))
        XCTAssertGreaterThan(maxDifference(atWhite, farAbove), 0.01,
                             "scene-referred highlights were clipped away")

        let edge = height / 2 - height / 12 - 12
        var outside: Float = 0
        for x in 0..<width {
            let i = (edge * width + x) * 4
            outside = max(outside, abs(atWhite[i] - farAbove[i]))
        }
        XCTAssertGreaterThan(outside, 0.002,
                             "a highlight above diffuse white reached nothing outside itself")
    }

    func flatField(stops: Float, width: Int = 64, height: Int = 64) -> [Float] {
        let value = 0.18 * pow(2, stops)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            pixels[i * 4] = value
            pixels[i * 4 + 1] = value
            pixels[i * 4 + 2] = value
            pixels[i * 4 + 3] = 1
        }
        return pixels
    }

    func toneOptions(highlights: Float, shadows: Float,
                     exposureEV: Float = 0) -> FotufilmEngine.Options {
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        options.highlights = highlights
        options.shadows = shadows
        options.exposureEV = exposureEV
        return options
    }

    func testToneControlsLeaveMeteredMidGreyAlone() throws {
        guard let gpu = HalideMetalFilmRenderer.shared else { throw XCTSkip("no Metal") }
        let width = 64, height = 64
        let field = flatField(stops: 0, width: width, height: height)
        for stock in TestStocks.all {
            let neutral = try XCTUnwrap(gpu.processLinearFloat(
                field, width: width, height: height, stock: stock,
                options: toneOptions(highlights: 0, shadows: 0)))
            for (highlights, shadows) in [(Float(1), Float(0)), (-1, 0), (0, 1), (0, -1)] {
                let moved = try XCTUnwrap(gpu.processLinearFloat(
                    field, width: width, height: height, stock: stock,
                    options: toneOptions(highlights: highlights, shadows: shadows)))
                XCTAssertLessThan(
                    maxDifference(neutral, moved), 1e-4,
                    "\(stock.name): highlights \(highlights)/shadows \(shadows) moved mid-grey")
            }
        }
    }

    func testEachToneControlActsOnItsOwnEnd() throws {
        guard let gpu = HalideMetalFilmRenderer.shared else { throw XCTSkip("no Metal") }
        let width = 64, height = 64
        func mean(_ pixels: [Float]) -> Float {
            var total: Float = 0
            for i in stride(from: 0, to: pixels.count, by: 4) { total += pixels[i + 1] }
            return total / Float(pixels.count / 4)
        }
        for stops in [Float(-4), 4] {
            let field = flatField(stops: stops, width: width, height: height)
            let neutral = try XCTUnwrap(gpu.processLinearFloat(
                field, width: width, height: height, stock: TestStocks.negative,
                options: toneOptions(highlights: 0, shadows: 0)))
            let byHighlights = try XCTUnwrap(gpu.processLinearFloat(
                field, width: width, height: height, stock: TestStocks.negative,
                options: toneOptions(highlights: -1, shadows: 0)))
            let byShadows = try XCTUnwrap(gpu.processLinearFloat(
                field, width: width, height: height, stock: TestStocks.negative,
                options: toneOptions(highlights: 0, shadows: 1)))
            let base = mean(neutral)
            let fromHighlights = abs(mean(byHighlights) - base)
            let fromShadows = abs(mean(byShadows) - base)
            if stops > 0 {
                XCTAssertGreaterThan(fromHighlights, 0.01,
                                     "highlights did not reach +4 stops")
                XCTAssertLessThan(fromShadows, 1e-4,
                                  "shadows reached into the highlights")
            } else {
                XCTAssertGreaterThan(fromShadows, 0.01,
                                     "shadows did not reach -4 stops")
                XCTAssertLessThan(fromHighlights, 1e-4,
                                  "highlights reached into the shadows")
            }
        }
    }

    func testToneMaskFollowsExposure() throws {
        guard let gpu = HalideMetalFilmRenderer.shared else { throw XCTSkip("no Metal") }
        let width = 64, height = 64
        let field = flatField(stops: 0, width: width, height: height)
        let neutral = try XCTUnwrap(gpu.processLinearFloat(
            field, width: width, height: height, stock: TestStocks.negative,
            options: toneOptions(highlights: 0, shadows: 0, exposureEV: 2)))
        let recovered = try XCTUnwrap(gpu.processLinearFloat(
            field, width: width, height: height, stock: TestStocks.negative,
            options: toneOptions(highlights: -1, shadows: 0, exposureEV: 2)))
        XCTAssertGreaterThan(maxDifference(neutral, recovered), 0.01,
                             "the highlight mask ignored the exposure slider")
    }

    func testToneControlsPreserveOrdering() throws {
        guard let gpu = HalideMetalFilmRenderer.shared else { throw XCTSkip("no Metal") }
        let width = 32, height = 32
        let ladder = stride(from: Float(-7), through: 7, by: 0.5)
        for (highlights, shadows) in [(Float(1), Float(1)), (-1, -1), (1, -1), (-1, 1)] {
            var previous = -Float.greatestFiniteMagnitude
            for stops in ladder {
                let developed = try XCTUnwrap(gpu.processLinearFloat(
                    flatField(stops: stops, width: width, height: height),
                    width: width, height: height, stock: TestStocks.negative,
                    options: toneOptions(highlights: highlights, shadows: shadows)))
                let value = developed[(height / 2 * width + width / 2) * 4 + 1]
                XCTAssertGreaterThanOrEqual(
                    value, previous,
                    "highlights \(highlights)/shadows \(shadows) inverted at \(stops) stops")
                previous = value
            }
        }
    }
}

private extension Int {
    init(bytes value: UInt8) { self.init(value) }
}
#endif
