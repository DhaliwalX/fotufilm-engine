import XCTest
@testable import FotufilmCore

final class CineonLogTests: XCTestCase {
    private let stops: [Float] = [-10, -4, -2, 0, 2, 4, 6]

    private func wedge() -> ImageBuffer {
        let width = stops.count * 8
        var image = ImageBuffer(width: width, height: 8)
        for y in 0..<8 { for x in 0..<width {
            // The first step is unexposed: the film base.
            let level = x < 8 ? 0 : 0.18 * pow(2, stops[x / 8])
            for c in 0..<3 { image.planes[c][y * width + x] = level }
        }}
        return image
    }

    private func options(_ paper: PrintPaper = .cineonLog) -> FotufilmEngine.Options {
        var value = FotufilmEngine.Options()
        value.paper = paper; value.grainScale = 0; value.halationScale = 0
        value.flareScale = 0; value.couplerScale = 0; value.localTone = false
        return value
    }

    private func stock(_ id: String) throws -> FilmStock {
        var film = try XCTUnwrap(FilmStock.named(id), id)
        film.emulsionDiffusionMM = [0, 0, 0]; film.emulsionDiffusionSecondaryMM = [0, 0, 0]
        film.adjacencyStrength = 0
        return film
    }

    /// Code values at the centre of each wedge step, per channel.
    private func codeValues(_ output: ImageBuffer) -> [SIMD3<Float>] {
        stops.indices.map { step in
            let i = 4 * output.width + step * 8 + 4
            return SIMD3(output.planes[0][i], output.planes[1][i], output.planes[2][i])
                * CineonLog.maximumCodeValue
        }
    }

    func testEncodingPlacesGreyAtTheLADAndStepsTwoThousandthsOfADensity() {
        XCTAssertEqual(CineonLog.signal(densityAboveGrey: 0) * 1023, 445, accuracy: 1e-4)
        XCTAssertEqual(CineonLog.signal(densityAboveGrey: 0.48) * 1023, 685, accuracy: 1e-3)
        XCTAssertEqual(CineonLog.signal(densityAboveGrey: -0.7) * 1023, 95, accuracy: 1e-3)
        XCTAssertEqual(CineonLog.densityAboveGrey(signal: CineonLog.signal(densityAboveGrey: 0.3)),
                       0.3, accuracy: 1e-6)
        XCTAssertEqual(CineonLog.codeValue(signal: 95.0 / 1023), 95)
        XCTAssertEqual(CineonLog.codeValue(signal: 2), 1023)
        XCTAssertEqual(CineonLog.codeValue(signal: -1), 0)
    }

    func testDPXCarriesTenBitPrintingDensityBigEndian() throws {
        let width = 3, height = 2
        let signals: [Float] = [95, 470, 685, 0, 1023, 2000, 512, 100, 900, 300, 301, 302,
                                1, 2, 3, 1022, 1021, 1020]
            .map { $0 / 1023 }
        let rgba: [Float] = stride(from: 0, to: signals.count, by: 3).flatMap { i -> [Float] in
            [signals[i], signals[i + 1], signals[i + 2], 1]
        }
        let data = rgba.withUnsafeBufferPointer {
            CineonDPX.encode(signals: $0, width: width, height: height,
                             film: .init(frameRate: 24, format: "Super 35", stock: "Vision3 250D"))
        }
        let bytes = [UInt8](data)
        func u32(_ offset: Int) -> UInt32 {
            bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }
        func u16(_ offset: Int) -> UInt16 { UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]) }
        XCTAssertEqual(bytes.count, 2048 + width * height * 4)
        XCTAssertEqual(Array(bytes[0..<4]), Array("SDPX".utf8))
        XCTAssertEqual(u32(4), 2048)
        XCTAssertEqual(Array(bytes[8..<12]), Array("V2.0".utf8))
        XCTAssertEqual(u32(16), UInt32(bytes.count))
        XCTAssertEqual(u32(24) + u32(28), 2048)
        XCTAssertEqual(u16(770), 1)
        XCTAssertEqual(u32(772), UInt32(width))
        XCTAssertEqual(u32(776), UInt32(height))
        XCTAssertEqual(bytes[800], 50, "RGB")
        XCTAssertEqual(bytes[801], 1, "printing density transfer")
        XCTAssertEqual(bytes[802], 1, "printing density colorimetry")
        XCTAssertEqual(bytes[803], 10)
        XCTAssertEqual(u16(804), 1, "filled method A")
        XCTAssertEqual(u32(808), 2048)
        XCTAssertEqual(Float(bitPattern: u32(1724)), 24)
        XCTAssertEqual(String(decoding: bytes[1680..<1688], as: UTF8.self), "Super 35")
        let expected: [UInt32] = [95, 470, 685, 0, 1023, 1023, 512, 100, 900, 300, 301, 302,
                                  1, 2, 3, 1022, 1021, 1020]
        for pixel in 0..<(width * height) {
            let word = u32(2048 + pixel * 4)
            XCTAssertEqual(word & 0x3, 0)
            XCTAssertEqual([word >> 22, (word >> 12) & 0x3FF, (word >> 2) & 0x3FF],
                           Array(expected[pixel * 3..<pixel * 3 + 3]), "pixel \(pixel)")
        }
    }

    func testMediumIsAnUnsharpenedScanOfferedToNegativesOnly() throws {
        XCTAssertEqual(PrintPaper.allCases.last, .cineonLog, "append-only: hosts persist indices")
        XCTAssertEqual(PrintPaper(rawValue: "cineon-log"), .cineonLog)
        let medium = PrintPaper.cineonLog
        XCTAssertTrue(medium.isScan)
        XCTAssertTrue(medium.deliversCodeValues)
        XCTAssertFalse(medium.acceptsPrintCorrection)
        XCTAssertFalse(medium.showsHDR)
        XCTAssertEqual(medium.scanSharpening, 0)
        XCTAssertNil(medium.printStock)
        XCTAssertEqual(medium.sensitivity(bands: .paper), SpectralGrid.telecineSensitivity)
        let negative = try stock("vision250d")
        XCTAssertTrue(PrintPaper.choices(for: negative).contains(.cineonLog))
        XCTAssertTrue(PrintPaper.stripChoices(for: negative, gauge: .super35).contains(.cineonLog))
        let slide = try stock("provia100f")
        XCTAssertFalse(PrintPaper.choices(for: slide).contains(.cineonLog))
        XCTAssertEqual(PrintPaper.cineonLog.resolved(for: slide), .screen)
    }

    func testWedgeIsNeutralAtTheLADAndClimbsAtTheFilmsPrintingContrast() throws {
        for id in ["vision250d", "vision500t", "portra400", "gold200", "hp5plus400"] {
            let output = try FotufilmEngine(stock: stock(id), options: options())
                .processChecked(linearRGB: wedge())
            let codes = codeValues(output)
            for c in 0..<3 {
                // A normally exposed mid grey is the laboratory aim density the scanner was set
                // up on: code value 445 in every record, so it reads as grey.
                XCTAssertEqual(codes[3][c], 445, accuracy: 1, "\(id) channel \(c) grey")
                // Unexposed, the film is at its base, the scan's floor, near the convention's 95.
                XCTAssertLessThan(codes[0][c], codes[1][c], "\(id) channel \(c) base")
                XCTAssertEqual(codes[0][c], 95, accuracy: 90, "\(id) channel \(c) base")
                for step in 1..<codes.count {
                    XCTAssertGreaterThan(codes[step][c], codes[step - 1][c],
                                         "\(id) channel \(c) step \(stops[step])")
                }
                // About 0.6 gamma: 0.18 D a stop, 90 code values. Allow the records' spread.
                let perStop = (codes[5][c] - codes[3][c]) / 4
                XCTAssertGreaterThan(perStop, 55, "\(id) channel \(c)")
                XCTAssertLessThan(perStop, 125, "\(id) channel \(c)")
            }
        }
    }

    func testEachStepIsItsPrintingDensityAboveMidGrey() throws {
        let film = try stock("vision250d")
        let output = try FotufilmEngine(stock: film, options: options())
            .processChecked(linearRGB: wedge())
        let codes = codeValues(output)
        // The same read the output table makes, done directly: RP 180 bands under a flat lamp.
        let bands = PrintPaper.cineonLog.sensitivity(bands: .paper)
        func energy(_ density: [Float]) -> SIMD3<Float> {
            SpectralRuntime.paperExposure(density: density, stock: film,
                                          lamp: SpectralGrid.equalEnergy,
                                          paperSensitivity: bands)
        }
        func exposed(stops: Float) -> SIMD3<Float> {
            energy((0..<3).map {
                film.developedDensity(layer: $0, logExposure: stops * log10(2))
            })
        }
        let grey = exposed(stops: 0)
        // The base, and two stops over: each is its printing density relative to mid grey.
        for (step, read) in [(0, energy(film.curves.map(\.dMin))), (4, exposed(stops: 2))] {
            for c in 0..<3 {
                let density = log10(grey[c] / read[c])
                XCTAssertEqual(codes[step][c], 445 + density / 0.002, accuracy: 6,
                               "step \(step) channel \(c)")
            }
        }
    }

    func testStillDeliveryLeavesCodeValuesAsTheyAre() throws {
        let film = try stock("vision250d")
        let still = FilmOutputTransform.still(options(), stock: film)
        XCTAssertEqual(still, .cineonLog)
        XCTAssertNil(still.shoulderKnee)
        XCTAssertEqual(still.transfer, .linear)
        let printed = options(.vision2383)
        XCTAssertEqual(FilmOutputTransform.still(printed, stock: film),
                       .displayP3(shoulderKnee: printed.sdrShoulderKnee(for: film)))
        let signals: [Float] = [95 / 1023, 0.5, 685 / 1023, 1, 1.2, 0.3, 0, 0.7]
        var out = [Float](repeating: -1, count: signals.count)
        signals.withUnsafeBufferPointer { source in
            out.withUnsafeMutableBufferPointer { destination in
                AnyFilmOutputConverter.still(options(), stock: film)
                    .convert(source, from: 0, count: signals.count, into: destination)
            }
        }
        XCTAssertEqual(Array(out[0..<3]), Array(signals[0..<3]))
        XCTAssertEqual(Array(out[4..<7]), Array(signals[4..<7]))
    }

    func testTimingKeysAndGradeCannotMoveTheCodeValues() throws {
        let film = try stock("vision500t")
        let plain = try FotufilmEngine(stock: film, options: options())
            .processChecked(linearRGB: wedge())
        var adjusted = options()
        adjusted.grade = ColorGrade(shadows: .init(balanceX: 0.5, level: 0.4),
                                    midtones: .init(balanceY: -0.3, level: -0.2),
                                    highlights: .init(balanceX: -0.4, level: 0.5))
        adjusted.printFinish = PrintFinish(gains: SIMD3(1.2, 1, 0.9), highlights: 0.5,
                                           shadows: -0.5, saturation: 0.3, vibrance: 0.2)
        adjusted.printCorrection = 1
        adjusted.screenCMY = SIMD3(0.5, -0.5, 0.3)
        let moved = try FotufilmEngine(stock: film, options: adjusted)
            .processChecked(linearRGB: wedge())
        for c in 0..<3 { XCTAssertEqual(moved.planes[c], plain.planes[c], "channel \(c)") }
    }

}

#if canImport(Metal) && canImport(CoreGraphics)
import Metal
import FotufilmMetal

extension CineonLogTests {
    func testCodeValuesAgreeOnCPUAndMetal() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable, "Halide engine required")
        let gpu = try XCTUnwrap(HalideMetalFilmRenderer.shared)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let side = 16, count = side * side
        let colours = [Float(-8), -4, -2, 0, 2, 4, 6].map { SIMD3<Float>(repeating: 0.18 * exp2($0)) }
            + [SIMD3(0.6, 0.03, 0.02), SIMD3(0.03, 0.6, 0.06), SIMD3(0.02, 0.08, 0.6),
               SIMD3(0.6, 0.5, 0.02), SIMD3(0.05, 0.4, 0.4)]
        let bytes = count * 4 * MemoryLayout<Float>.stride
        let input = try XCTUnwrap(device.makeBuffer(length: bytes, options: .storageModeShared))
        let output = try XCTUnwrap(device.makeBuffer(length: bytes, options: .storageModeShared))
        for id in ["vision250d", "vision500t", "portra400", "hp5plus400"] {
            var film = try XCTUnwrap(FilmStock.named(id))
            film.flare = 0
            var worst: Float = 0
            for colour in colours {
                var scene = ImageBuffer(width: side, height: side)
                let rgba = input.contents().assumingMemoryBound(to: Float.self)
                for i in 0..<count {
                    for channel in 0..<3 {
                        scene.planes[channel][i] = colour[channel]
                        rgba[i * 4 + channel] = colour[channel]
                    }
                    rgba[i * 4 + 3] = 1
                }
                let cpu = FotufilmEngine(stock: film, options: options()).process(linearRGB: scene)
                XCTAssertTrue(gpu.processLinearFloat(input: input, output: output,
                    width: side, height: side, stock: film, options: options()))
                let metal = output.contents().assumingMemoryBound(to: Float.self)
                for i in 0..<count {
                    for channel in 0..<3 {
                        worst = max(worst, abs(max(cpu.planes[channel][i], 0)
                                               - metal[i * 4 + channel]))
                    }
                }
            }
            // A tenth of a 10-bit code value.
            XCTAssertLessThan(worst * CineonLog.maximumCodeValue, 0.1, "\(id)")
        }
    }
}
#endif
