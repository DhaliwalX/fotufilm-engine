import XCTest
@testable import FotufilmCore
@testable import FotufilmStockMatch

final class StockRankingTests: XCTestCase {

    private func scene(width: Int, height: Int) -> [Float] {
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let u = Float(x) / Float(max(width - 1, 1))
                let v = Float(y) / Float(max(height - 1, 1))
                let checker: Float = ((x / 2) + (y / 2)) % 2 == 0 ? 1.12 : 0.89
                var level = exp2(-9 + 12 * (u + v) / 2) * checker
                if u > 0.94, v > 0.94 { level = 40 }
                if u < 0.05, v < 0.05 { level = 0 }
                let index = (y * width + x) * 4
                pixels[index] = level * (0.6 + 0.8 * u)
                pixels[index + 1] = level
                pixels[index + 2] = level * (0.6 + 0.8 * v)
                pixels[index + 3] = 1
            }
        }
        return pixels
    }

    private func coverage(width: Int, height: Int) -> [Float] {
        (0..<(width * height)).map { index in
            let x = Float(index % width) / Float(max(width - 1, 1))
            let y = Float(index / width) / Float(max(height - 1, 1))
            let distance = ((x - 0.5) * (x - 0.5) + (y - 0.5) * (y - 0.5))
                .squareRoot()
            return max(0, min(1, (0.42 - distance) / 0.12))
        }
    }

    private struct Reference {
        var spread: Float
        var texture: Float
        var structureWhole: Float
        var structureSubject: Float
        var chromaWhole: Float
        var chromaSubject: Float
        var clippedHigh: Float
    }

    private func reference(_ pixels: [Float], width: Int, height: Int,
                           subject: [Float]?) -> Reference {
        let count = width * height
        let luma = ColorScience.luminanceWeights
        var logLuminance = [Float](repeating: 0, count: count)
        var chroma = [Float](repeating: 0, count: count)
        var high = 0
        for index in 0..<count {
            let base = index * 4
            let red = max(pixels[base], 0)
            let green = max(pixels[base + 1], 0)
            let blue = max(pixels[base + 2], 0)
            let luminance = luma.0 * red + luma.1 * green + luma.2 * blue
            logLuminance[index] = log2(max(luminance, 1e-5))
            let peak = max(red, max(green, blue))
            let dip = min(red, min(green, blue))
            chroma[index] = peak > 0 ? (peak - dip) / peak : 0
            if luminance >= 1 { high += 1 }
        }

        let sorted = logLuminance.sorted()
        func percentile(_ q: Float) -> Float {
            sorted[min(sorted.count - 1,
                       max(0, Int(q * Float(sorted.count - 1))))]
        }
        let spread = max(0, percentile(0.99) - percentile(0.01))

        func gradient(_ weights: [Float]?) -> Float {
            var sum = 0.0, total = 0.0
            for y in 0..<height {
                for x in 0..<width {
                    let index = y * width + x
                    let weight = Double(weights?[index] ?? 1)
                    guard weight > 0 else { continue }
                    let here = logLuminance[index]
                    if x + 1 < width {
                        sum += weight * Double(abs(here - logLuminance[index + 1]))
                        total += weight
                    }
                    if y + 1 < height {
                        sum += weight * Double(abs(here - logLuminance[index + width]))
                        total += weight
                    }
                }
            }
            return total > 0 ? Float(sum / total) : 0
        }

        func mean(_ values: [Float], _ weights: [Float]?) -> Float {
            guard let weights else {
                return values.reduce(0, +) / Float(values.count)
            }
            var sum = 0.0, total = 0.0
            for index in values.indices {
                sum += Double(values[index]) * Double(weights[index])
                total += Double(weights[index])
            }
            return total > 0 ? Float(sum / total) : 0
        }

        let texture = gradient(nil)
        return Reference(
            spread: spread, texture: texture,
            structureWhole: spread > 1e-3 ? texture / spread : 0,
            structureSubject: spread > 1e-3 ? gradient(subject) / spread : 0,
            chromaWhole: mean(chroma, nil),
            chromaSubject: mean(chroma, subject),
            clippedHigh: Float(high) / Float(count))
    }

    func testTheFusedPassAgreesWithTheSlowWay() {
        let width = 120, height = 160
        let pixels = scene(width: width, height: height)
        let mask = coverage(width: width, height: height)
        let expected = reference(pixels, width: width, height: height,
                                 subject: mask)

        let workspace = Workspace(width: width)
        let measured = pixels.withUnsafeBufferPointer { source in
            mask.withUnsafeBufferPointer { weights in
                measurePicture(ScenePlane(pixels: source.baseAddress!),
                        width: width, height: height,
                        subject: weights.baseAddress, workspace: workspace)
            }
        }

        XCTAssertEqual(measured.contrastSpread, expected.spread, accuracy: 0.02,
                       "the histogram percentiles drifted from the sorted ones")
        XCTAssertEqual(measured.texture, expected.texture,
                       accuracy: expected.texture * 1e-4)
        XCTAssertEqual(measured.chromaWhole, expected.chromaWhole,
                       accuracy: expected.chromaWhole * 1e-4)
        XCTAssertEqual(measured.chromaSubject, expected.chromaSubject,
                       accuracy: expected.chromaSubject * 1e-4)
        XCTAssertEqual(measured.clippedHigh, expected.clippedHigh, accuracy: 0)
        XCTAssertEqual(measured.structureWhole, expected.structureWhole,
                       accuracy: expected.structureWhole * 5e-3)
        XCTAssertEqual(measured.structureSubject, expected.structureSubject,
                       accuracy: expected.structureSubject * 5e-3)
    }

    func testWithoutAMaskBothReadingsAreTheWholeFrame() {
        let width = 64, height = 48
        let pixels = scene(width: width, height: height)
        let workspace = Workspace(width: width)
        let measured = pixels.withUnsafeBufferPointer { source in
            measurePicture(ScenePlane(pixels: source.baseAddress!),
                    width: width, height: height,
                    subject: nil, workspace: workspace)
        }
        XCTAssertEqual(measured.structureSubject, measured.structureWhole)
        XCTAssertEqual(measured.chromaSubject, measured.chromaWhole)
    }

    func testAPrintReadsBackInTheSameLightAsTheScene() {
        let width = 256, height = 8
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        var linear = [Float](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            let code = UInt8(index % 256)
            let v = Float(code) / 255
            let light = v <= 0.04045 ? v / 12.92
                : pow((v + 0.055) / 1.055, 2.4)
            for channel in 0..<3 {
                bytes[index * 4 + channel] = code
                linear[index * 4 + channel] = light
            }
            bytes[index * 4 + 3] = 255
            linear[index * 4 + 3] = 1
        }

        let workspace = Workspace(width: width)
        let fromBytes = bytes.withUnsafeBufferPointer { source in
            measurePicture(PrintPlane(bytes: source.baseAddress!,
                               table: workspace.decode),
                    width: width, height: height, subject: nil,
                    workspace: workspace)
        }
        let fromFloats = linear.withUnsafeBufferPointer { source in
            measurePicture(ScenePlane(pixels: source.baseAddress!),
                    width: width, height: height, subject: nil,
                    workspace: workspace)
        }
        XCTAssertEqual(fromBytes.contrastSpread, fromFloats.contrastSpread,
                       accuracy: 0.02)
        XCTAssertEqual(fromBytes.texture, fromFloats.texture,
                       accuracy: fromFloats.texture * 1e-4)
    }

    func testAFilmThatCannotBeDevelopedIsSimplyNotRanked() {
        let width = 32, height = 32
        let pixels = scene(width: width, height: height)
        guard let reading = pixels.withUnsafeBufferPointer({ source in
            StockRanking.read(linearRGBA: source.baseAddress!,
                              width: width, height: height)
        }) else { return XCTFail("the scene did not read") }

        let films = TestStocks.all.enumerated().map {
            StockRanking.Film(id: "film-\($0.offset)", name: "Film \($0.offset)",
                              stock: $0.element)
        }
        let ranking = StockRanking.rank(scene: reading, films: films) { _, _, _, _ in
            false
        }
        XCTAssertTrue(ranking.ordered.isEmpty)
        XCTAssertNil(ranking.best)
        XCTAssertEqual(ranking.summary, "no eligible film")
    }

    func testCancellationStopsTheLoopWhereItIsAsked() {
        let width = 32, height = 32
        let pixels = scene(width: width, height: height)
        guard let reading = pixels.withUnsafeBufferPointer({ source in
            StockRanking.read(linearRGBA: source.baseAddress!,
                              width: width, height: height)
        }) else { return XCTFail("the scene did not read") }

        let films = (0..<8).map {
            StockRanking.Film(id: "film-\($0)", name: "Film \($0)",
                              stock: TestStocks.negative)
        }
        var developed = 0
        let ranking = StockRanking.rank(
            scene: reading, films: films,
            isCancelled: { developed >= 3 }
        ) { _, bytes, _, _ in
            developed += 1
            for index in bytes.indices { bytes[index] = UInt8(index % 251) }
            return true
        }
        XCTAssertEqual(developed, 3)
        XCTAssertEqual(ranking.ordered.count, 3)
    }
}
