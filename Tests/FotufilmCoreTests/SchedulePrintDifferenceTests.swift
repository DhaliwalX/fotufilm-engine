#if canImport(Metal)
import XCTest
@testable import FotufilmCore
@testable import FotufilmImaging
import FotufilmMetal
import Metal

final class SchedulePrintDifferenceTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "Halide engine required")
    }

    private static let side = 128

    private enum Region: String, CaseIterable {
        case neutral = "neutral ramp"
        case saturated = "saturated patches"
        case skin = "skin tones"
        case bright = "bright blocks"
    }

    private static func referenceChart(headroom: Float)
        -> (pixels: [Float], regions: [Region]) {
        var pixels = [Float](repeating: 0, count: side * side * 4)
        var regions = [Region](repeating: .neutral, count: side * side)
        let saturated: [(UInt16, UInt16, UInt16)] = [
            (60000, 3000, 3000), (3000, 60000, 3000), (3000, 3000, 60000),
            (3000, 55000, 55000), (55000, 3000, 55000), (55000, 55000, 3000),
            (26000, 6000, 6000), (6000, 26000, 6000),
        ]
        let skin: [(UInt16, UInt16, UInt16)] = [
            (58000, 44000, 38000), (48000, 33000, 27000),
            (34000, 21000, 16000), (20000, 12000, 9000),
            (52000, 38000, 30000), (40000, 26000, 20000),
            (28000, 17000, 13000), (14000, 8000, 6000),
        ]
        let bright: [(UInt16, UInt16, UInt16)] = [
            (65535, 65535, 65535), (58000, 58000, 58000),
            (65535, 62000, 52000), (52000, 62000, 65535),
            (65535, 30000, 12000), (12000, 65535, 30000),
            (30000, 12000, 65535), (46000, 46000, 46000),
        ]
        let band = side / 4
        let cell = side / 8
        for y in 0..<side {
            for x in 0..<side {
                let index = y * side + x
                let column = min(7, x / cell)
                let region: Region
                let code: (UInt16, UInt16, UInt16)
                switch y / band {
                case 0:
                    region = .neutral
                    let step = UInt16(min(65535, (x * 65535) / (side - 1)))
                    code = (step, step, step)
                case 1:
                    region = .saturated
                    code = saturated[column]
                case 2:
                    region = .skin
                    code = skin[column]
                default:
                    region = .bright
                    code = bright[column]
                }
                regions[index] = region
                pixels[index * 4] = Float(code.0) / 65535 * headroom
                pixels[index * 4 + 1] = Float(code.1) / 65535 * headroom
                pixels[index * 4 + 2] = Float(code.2) / 65535 * headroom
                pixels[index * 4 + 3] = 1
            }
        }
        return (pixels, regions)
    }

    private static func print8(_ linear: Float) -> Double {
        Double((PrintEncoding.encode(ColorScience.displayShoulder(linear)) * 255)
            .rounded())
    }

    private static func opponent(_ r: Double, _ g: Double, _ b: Double)
        -> (luma: Double, cb: Double, cr: Double) {
        let (wr, wg, wb) = ColorScience.luminanceWeights
        let luma = Double(wr) * r + Double(wg) * g + Double(wb) * b
        return (luma, b - luma, r - luma)
    }

    private struct Spread {
        var mean = 0.0
        var worst = 0.0
        private var total = 0.0
        private var count = 0
        mutating func add(_ value: Double) {
            total += value
            count += 1
            worst = max(worst, value)
        }
        mutating func finish() { mean = count > 0 ? total / Double(count) : 0 }
    }

    func testScheduleDifferenceInTheDeliveredPrint() throws {
        let gpu = try XCTUnwrap(HalideMetalFilmRenderer.shared,
                               "Halide Metal unavailable")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let side = Self.side
        let bytes = side * side * 16
        let input = try XCTUnwrap(device.makeBuffer(length: bytes,
                                                   options: .storageModeShared))
        let referenceOut = try XCTUnwrap(
            device.makeBuffer(length: bytes, options: .storageModeShared))
        let realtimeOut = try XCTUnwrap(
            device.makeBuffer(length: bytes, options: .storageModeShared))

        var options = FotufilmEngine.Options()
        options.grainScale = 0

        for headroom: Float in [1.0, 3.0] {
            let chart = Self.referenceChart(headroom: headroom)
            for stock in [TestStocks.negative, TestStocks.reversal] {
                chart.pixels.withUnsafeBufferPointer {
                    input.contents().copyMemory(
                        from: $0.baseAddress!,
                        byteCount: side * side * 16)
                }
                XCTAssertTrue(
                    gpu.processLinearFloat(
                        input: input, output: referenceOut,
                        width: side, height: side,
                        stock: stock, options: options),
                    "\(stock.name): reference schedule failed")
                XCTAssertTrue(
                    gpu.processLinearFloat(
                        input: input, output: realtimeOut,
                        width: side, height: side,
                        stock: stock, options: options, realtime: true),
                    "\(stock.name): realtime schedule failed")

                let a = referenceOut.contents()
                    .assumingMemoryBound(to: Float.self)
                let b = realtimeOut.contents()
                    .assumingMemoryBound(to: Float.self)
                var luma: [Region: Spread] = [:]
                var chroma: [Region: Spread] = [:]
                var allLuma = Spread(), allChroma = Spread()
                var perChannel = Spread()
                var darkest = 255.0, brightest = 0.0
                for region in Region.allCases {
                    luma[region] = Spread()
                    chroma[region] = Spread()
                }
                for index in 0..<(side * side) {
                    let ref = (Self.print8(a[index * 4]),
                               Self.print8(a[index * 4 + 1]),
                               Self.print8(a[index * 4 + 2]))
                    let live = (Self.print8(b[index * 4]),
                                Self.print8(b[index * 4 + 1]),
                                Self.print8(b[index * 4 + 2]))
                    perChannel.add(abs(ref.0 - live.0))
                    perChannel.add(abs(ref.1 - live.1))
                    perChannel.add(abs(ref.2 - live.2))
                    darkest = min(darkest, ref.0, ref.1, ref.2)
                    brightest = max(brightest, ref.0, ref.1, ref.2)
                    let reference = Self.opponent(ref.0, ref.1, ref.2)
                    let realtime = Self.opponent(live.0, live.1, live.2)
                    let dLuma = abs(reference.luma - realtime.luma)
                    let dChroma = (pow(reference.cb - realtime.cb, 2)
                                   + pow(reference.cr - realtime.cr, 2))
                        .squareRoot()
                    let region = chart.regions[index]
                    luma[region]?.add(dLuma)
                    chroma[region]?.add(dChroma)
                    allLuma.add(dLuma)
                    allChroma.add(dChroma)
                }
                allLuma.finish()
                allChroma.finish()
                perChannel.finish()

                let label = "\(stock.name) headroom \(headroom)"
                print(String(
                    format: "SCHEDULE %@ | luma mean %.2f worst %.2f "
                        + "| chroma mean %.2f worst %.2f | channel mean %.3f "
                        + "worst %.0f | print spans %.0f-%.0f  (8-bit codes)",
                    label, allLuma.mean, allLuma.worst,
                    allChroma.mean, allChroma.worst,
                    perChannel.mean, perChannel.worst, darkest, brightest))

                XCTAssertLessThan(
                    darkest, Self.printMustReachBelow,
                    "\(label): the developed print never gets darker than "
                    + "\(darkest), so this is not a developed chart and the "
                    + "agreement below measures nothing")
                XCTAssertGreaterThan(
                    brightest, Self.printMustReachAbove,
                    "\(label): the developed print never gets brighter than "
                    + "\(brightest), so this is not a developed chart and the "
                    + "agreement below measures nothing")
                for region in Region.allCases {
                    var regionLuma = luma[region]!, regionChroma = chroma[region]!
                    regionLuma.finish()
                    regionChroma.finish()
                    print(String(
                        format: "  %-18@ luma mean %.2f worst %.2f "
                            + "| chroma mean %.2f worst %.2f",
                        region.rawValue, regionLuma.mean, regionLuma.worst,
                        regionChroma.mean, regionChroma.worst))
                    if region == .neutral {
                        XCTAssertLessThan(
                            regionChroma.worst, Self.neutralChromaCeiling,
                            "\(label): the schedules disagree about the colour "
                            + "of a neutral by \(regionChroma.worst) codes, "
                            + "which is a cast rather than an exposure "
                            + "difference")
                    }
                }

                XCTAssertLessThan(
                    perChannel.worst, Self.channelWorstCeiling,
                    "\(label): a delivered channel differs by "
                    + "\(perChannel.worst) codes between the two schedules")
                XCTAssertLessThan(
                    allLuma.mean, Self.lumaMeanCeiling,
                    "\(label): mean luma difference \(allLuma.mean) codes")
                XCTAssertLessThan(
                    allLuma.worst, Self.lumaWorstCeiling,
                    "\(label): worst luma difference \(allLuma.worst) codes")
                XCTAssertLessThan(
                    allChroma.mean, Self.chromaMeanCeiling,
                    "\(label): mean chroma difference \(allChroma.mean) codes")
                XCTAssertLessThan(
                    allChroma.worst, Self.chromaWorstCeiling,
                    "\(label): worst chroma difference \(allChroma.worst) codes")
            }
        }
    }

    private static let channelWorstCeiling = 3.0  // measured 1
    private static let lumaMeanCeiling = 0.25  // measured 0.05
    private static let lumaWorstCeiling = 2.5  // measured 0.77
    private static let chromaMeanCeiling = 0.30  // measured 0.09
    private static let chromaWorstCeiling = 2.5  // measured 0.98
    private static let neutralChromaCeiling = 2.0  // measured 0.98

    // What the developed chart has to look like for the numbers above to be about anything.
    private static let printMustReachBelow = 48.0
    private static let printMustReachAbove = 200.0
}
#endif
