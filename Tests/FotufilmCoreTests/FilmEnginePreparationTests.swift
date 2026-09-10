import XCTest
@testable import FotufilmCore

final class FilmEnginePreparationTests: XCTestCase {
    func testCheckedInvocationReturnsUnavailableDevelopmentError() {
        let stock = TestStocks.negative
        var options = FotufilmEngine.Options()
        options.developmentEV = 1
        XCTAssertThrowsError(try FilmEngineInvocation(
            validating: stock, options: options, width: 16, height: 12)) { error in
                XCTAssertEqual(error as? FilmDevelopmentError,
                               .unavailable(stock: stock.name, requestedStops: 1))
            }
    }

    func testCheckedInvocationReturnsUnmeasuredAndMalformedConditionErrors() {
        var stock = TestStocks.negative
        stock.developmentProfile = FilmDevelopmentProfile(
            developer: "Synthetic test developer", temperatureC: 20,
            agitation: "Test", source: "Synthetic regression fixture", sourcePage: 1,
            conditions: [FilmDevelopmentCondition(
                stops: 1, label: "+1", timeMinutes: 10, curves: [])])
        var options = FotufilmEngine.Options()
        options.developmentEV = 2
        XCTAssertThrowsError(try FilmEngineInvocation(
            validating: stock, options: options, width: 16, height: 12)) { error in
                XCTAssertEqual(error as? FilmDevelopmentError,
                               .unmeasuredCondition(stock: stock.name, requestedStops: 2,
                                                    availableStops: [1]))
            }
        options.developmentEV = 1
        XCTAssertThrowsError(try FilmEngineInvocation(
            validating: stock, options: options, width: 16, height: 12)) { error in
                guard case FilmDevelopmentError.invalidProfile = error else {
                    return XCTFail("unexpected development error: \(error)")
                }
            }
    }

    func testCheckedPlanarRenderReturnsDevelopmentError() {
        let stock = TestStocks.negative
        var options = FotufilmEngine.Options()
        options.developmentEV = 1
        XCTAssertThrowsError(try FotufilmEngine(stock: stock, options: options)
            .processChecked(linearRGB: ImageBuffer(width: 4, height: 4, fill: 0.18))) { error in
                XCTAssertEqual(error as? FilmDevelopmentError,
                               .unavailable(stock: stock.name, requestedStops: 1))
            }
    }

    func testCheckedSpansReturnDevelopmentErrors() {
        let stock = TestStocks.negative
        var options = FotufilmEngine.Options()
        options.developmentEV = 1
        let engine = FotufilmEngine(stock: stock, options: options)
        let input = ImageBuffer(width: 4, height: 4, fill: 0.18)
        for render in [engine.developNegativeChecked(linearRGB:),
                       engine.printPositiveChecked(negativeDensity:)] {
            XCTAssertThrowsError(try render(input)) { error in
                XCTAssertEqual(error as? FilmDevelopmentError,
                               .unavailable(stock: stock.name, requestedStops: 1))
                XCTAssertTrue(error.localizedDescription.contains("invalid development request:"))
                XCTAssertFalse(error.localizedDescription.contains("Install Halide"))
            }
        }
    }

    #if os(macOS)
    func testUncheckedEntryPointsReportDevelopmentFailures() throws {
        let probeKey = "FOTUFILM_DEVELOPMENT_FAILURE_PROBE"
        if let entryPoint = ProcessInfo.processInfo.environment[probeKey] {
            var options = FotufilmEngine.Options()
            options.developmentEV = 1
            let engine = FotufilmEngine(stock: TestStocks.negative, options: options)
            let image = ImageBuffer(width: 4, height: 4, fill: 0.18)
            switch entryPoint {
            case "process": _ = engine.process(linearRGB: image)
            case "develop": _ = engine.developNegative(linearRGB: image)
            case "print": _ = engine.printPositive(negativeDensity: image)
            default: XCTFail("unknown failure probe")
            }
            return XCTFail("unchecked entry point unexpectedly returned")
        }
        for entryPoint in ["process", "develop", "print"] {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["-XCTest",
                "FotufilmCoreTests.FilmEnginePreparationTests/testUncheckedEntryPointsReportDevelopmentFailures",
                Bundle(for: Self.self).bundlePath]
            var environment = ProcessInfo.processInfo.environment
            environment[probeKey] = entryPoint
            environment["SWIFT_BACKTRACE"] = "enable=no"
            child.environment = environment
            let pipe = Pipe()
            child.standardOutput = pipe
            child.standardError = pipe
            try child.run()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            child.waitUntilExit()
            XCTAssertNotEqual(child.terminationStatus, 0, entryPoint)
            XCTAssertTrue(output.contains("invalid development request:"), output)
            XCTAssertTrue(output.contains("no measured push/pull response"), output)
            XCTAssertFalse(output.contains("Install Halide"), output)
        }
    }
    #endif

    func testInvalidDevelopmentErrorsCanDescribeNonFiniteAndLargeValues() {
        for stops: Float in [.infinity, -.infinity, .nan, .greatestFiniteMagnitude] {
            var options = FotufilmEngine.Options()
            options.developmentEV = stops
            XCTAssertThrowsError(try FilmEngineInvocation(
                validating: TestStocks.negative, options: options, width: 4, height: 4)) { error in
                    XCTAssertTrue(String(describing: error).contains("no measured push/pull"))
                }
        }
    }

    func testCheckedRenderAppliesMeasuredDevelopmentExactlyOnce() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable, "Halide unavailable")
        var stock = TestStocks.negative
        var pushedCurves = stock.curves
        for index in pushedCurves.indices { pushedCurves[index].gamma *= 1.2 }
        stock.developmentProfile = FilmDevelopmentProfile(
            developer: "Synthetic test developer", temperatureC: 20,
            agitation: "Test", source: "Synthetic regression fixture", sourcePage: 1,
            conditions: [FilmDevelopmentCondition(
                stops: 1, label: "+1", timeMinutes: 10, curves: pushedCurves)])
        var options = FotufilmEngine.Options()
        options.developmentEV = 1
        options.grainScale = 0
        options.expiredYears = 3
        let image = ImageBuffer(width: 8, height: 8, fill: 0.18)
        let actual = try FotufilmEngine(stock: stock, options: options).processChecked(linearRGB: image)
        var explicit = stock
        explicit.curves = pushedCurves
        options.developmentEV = 0
        let expected = FotufilmEngine(stock: explicit, options: options).process(linearRGB: image)
        XCTAssertEqual(actual.planes, expected.planes)
    }

    func testCheckedPlanarRenderPreservesEmptyImageBehavior() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable, "Halide unavailable")
        let output = try FotufilmEngine(stock: TestStocks.negative)
            .processChecked(linearRGB: ImageBuffer(width: 0, height: 0))
        XCTAssertEqual(output.pixelCount, 0)
        XCTAssertEqual(output.planes, [[], [], []])
    }
}
