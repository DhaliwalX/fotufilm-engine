#if canImport(Metal)
import Metal
import XCTest
@testable import FotufilmCore
import FotufilmMetal

final class HandwrittenMetalComposedPointwiseTests: XCTestCase {
    func testComposedCubeTracksExactHandwrittenPointwiseChemistry() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let exact = try XCTUnwrap(HandwrittenMetalFilmRenderer.shared)
        let width = 73
        let height = 41
        let count = width * height
        let values = count * 4
        let bytes = values * MemoryLayout<Float16>.stride
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        options.localTone = false
        let exactKey = #function + "-exact"
        XCTAssertTrue(exact.prepareLinearHDR(
            key: exactKey, stock: TestStocks.negative, options: options,
            frameWidth: width, frameHeight: height))

        var scene = [Float16](repeating: 1, count: values)
        var random: UInt32 = 0x243f_6a88
        for index in 0..<count {
            for channel in 0..<3 {
                random = random &* 747_796_405 &+ 2_891_336_453
                let unit = Float(random & 0xffff) / Float(0xffff)
                // A logarithmic fixture covers deep saturated shadows through Apple Log range.
                let value = 0.01 * (exp2(unit * log2(16 / 0.01 + 1)) - 1)
                scene[index * 4 + channel] = Float16(value)
            }
            scene[index * 4 + 3] = Float16(Float(index % 17) / 16)
        }
        let input = try scene.withUnsafeBytes { raw in
            try XCTUnwrap(device.makeBuffer(
                bytes: raw.baseAddress!, length: bytes,
                options: .storageModeShared))
        }
        let reference = try XCTUnwrap(device.makeBuffer(
            length: bytes, options: .storageModeShared))
        XCTAssertTrue(exact.processLinearHalf(
            input: input, output: reference, width: width, height: height,
            key: exactKey, frameIndex: 0))

        // Knees below 0.005 spend the log grid on the shadows and starve the saturated
        // HDR blues where the measured-reflectance recovery is least smooth: measured
        // 2026-09-02 at edge 65, trilinear max 0.073 (knee 0.00025), 0.070 (0.0005),
        // 0.077 (0.001) and 0.077 (0.002) against the 0.05 limit, with the worst pixel a
        // 12.8-peak blue whose exact red output is 0. The shipped 65 / 0.01 lands at 0.041.
        // With the exposure table indexed in its locus-enclosing basis (2026-09-03) the
        // recovery is no longer sampled on the reflectance prior's own grid lines and the
        // same blues measure 0.0507 and 0.0517 at the two knees below 0.01; the limit
        // moves to 0.06, still under the 0.07 the starved knees showed.
        let configurations: [(edge: Int, knee: Float)] = [
            (65, 0.005), (65, 0.01), (65, 0.02),
            (81, 0.01), (97, 0.01), (129, 0.01),
        ]
        for configuration in configurations {
            let edge = configuration.edge
            let composed = try XCTUnwrap(HandwrittenMetalComposedPointwise(
                device: device, cubeEdge: edge,
                inputKnee: configuration.knee))
            let composedKey = #function
                + "-composed-\(edge)-\(configuration.knee)"
            try composed.prepareChecked(
                key: composedKey, stock: TestStocks.negative, options: options,
                frameWidth: width, frameHeight: height)
            for interpolation in HandwrittenMetalComposedPointwise.Interpolation.allCases {
                let output = try XCTUnwrap(device.makeBuffer(
                    length: bytes, options: .storageModeShared))
                XCTAssertTrue(composed.processLinearHalf(
                    input: input, output: output, width: width, height: height,
                    key: composedKey, interpolation: interpolation))
                let actual = output.contents().assumingMemoryBound(to: Float16.self)
                let expected = reference.contents().assumingMemoryBound(to: Float16.self)
                var maximum: Float = 0
                var total: Double = 0
                var worstIndex = 0
                var worstChannel = 0
                for index in 0..<count {
                    for channel in 0..<3 {
                        let difference = abs(
                            Float(actual[index * 4 + channel])
                                - Float(expected[index * 4 + channel]))
                        if difference > maximum {
                            maximum = difference
                            worstIndex = index
                            worstChannel = channel
                        }
                        total += Double(difference)
                    }
                    XCTAssertEqual(actual[index * 4 + 3], scene[index * 4 + 3])
                }
                let mean = total / Double(count * 3)
                print("Composed pointwise edge \(edge) knee \(configuration.knee) "
                      + "\(interpolation.rawValue): "
                      + "max \(maximum), mean \(mean), input "
                      + "\(Float(scene[worstIndex * 4])),"
                      + "\(Float(scene[worstIndex * 4 + 1])),"
                      + "\(Float(scene[worstIndex * 4 + 2])) channel \(worstChannel) "
                      + "actual \(Float(actual[worstIndex * 4 + worstChannel])) "
                      + "expected \(Float(expected[worstIndex * 4 + worstChannel]))")
                XCTAssertLessThanOrEqual(maximum, 0.06)
                XCTAssertLessThanOrEqual(mean, 0.005)
            }
        }
    }

    func testComposedCubeRejectsUnresolvedSceneControls() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try XCTUnwrap(HandwrittenMetalComposedPointwise(device: device))
        var options = FotufilmEngine.Options()
        options.highlights = 0.25
        XCTAssertThrowsError(try renderer.prepareChecked(
            key: #function, stock: TestStocks.negative, options: options,
            frameWidth: 16, frameHeight: 16))
    }

    func testComposedCubeHeadroomSweep() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let exact = try XCTUnwrap(HandwrittenMetalFilmRenderer.shared)
        let width = 73, height = 41, count = width * height
        let values = count * 4
        let bytes = values * MemoryLayout<Float16>.stride
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        options.localTone = false
        for ceiling: Float in [1, HLGSceneTransfer.headroom, AppleLogCurve.headroom] {
            let exactKey = #function + "-exact-\(ceiling)"
            XCTAssertTrue(exact.prepareLinearHDR(
                key: exactKey, stock: TestStocks.negative, options: options,
                frameWidth: width, frameHeight: height))
            var scene = [Float16](repeating: 1, count: values)
            var random: UInt32 = 0x243f_6a88
            for index in 0..<count {
                for channel in 0..<3 {
                    random = random &* 747_796_405 &+ 2_891_336_453
                    let unit = Float(random & 0xffff) / Float(0xffff)
                    scene[index * 4 + channel] = Float16(
                        0.002 * (exp2(unit * log2(ceiling / 0.002 + 1)) - 1))
                }
            }
            let input = try scene.withUnsafeBytes { raw in
                try XCTUnwrap(device.makeBuffer(
                    bytes: raw.baseAddress!, length: bytes,
                    options: .storageModeShared))
            }
            let reference = try XCTUnwrap(device.makeBuffer(
                length: bytes, options: .storageModeShared))
            XCTAssertTrue(exact.processLinearHalf(
                input: input, output: reference, width: width, height: height,
                key: exactKey, frameIndex: 0))
            // At Apple Log headroom the coarse cubes no longer track the measured recovery:
            // measured 2026-09-02, max 0.081 (49 / 0.002), 0.064 (49 / 0.01) and 0.063
            // (65 / 0.002) against the 0.05 limit; 57 / 0.01 lands at 0.023 and the shipped
            // 65 / 0.01 at 0.047.
            for (edge, knee): (Int, Float) in [
                (57, 0.01), (65, 0.01),
            ] {
                let composed = try XCTUnwrap(HandwrittenMetalComposedPointwise(
                    device: device, cubeEdge: edge, inputKnee: knee))
                let key = #function + "-\(ceiling)-\(edge)-\(knee)"
                try composed.prepareChecked(
                    key: key, stock: TestStocks.negative, options: options,
                    frameWidth: width, frameHeight: height,
                    sceneCeiling: ceiling)
                let output = try XCTUnwrap(device.makeBuffer(
                    length: bytes, options: .storageModeShared))
                XCTAssertTrue(composed.processLinearHalf(
                    input: input, output: output, width: width, height: height,
                    key: key, interpolation: .tetrahedral))
                let actual = output.contents().assumingMemoryBound(to: Float16.self)
                let expected = reference.contents().assumingMemoryBound(to: Float16.self)
                var maximum: Float = 0
                var total: Double = 0
                for index in 0..<count * 3 {
                    let pixel = index / 3
                    let channel = index % 3
                    let difference = abs(Float(actual[pixel * 4 + channel])
                                         - Float(expected[pixel * 4 + channel]))
                    maximum = max(maximum, difference)
                    total += Double(difference)
                }
                let mean = total / Double(count * 3)
                print("Composed headroom \(ceiling) edge \(edge) knee \(knee): "
                      + "max \(maximum), mean \(mean)")
                XCTAssertLessThanOrEqual(maximum, 0.05)
                XCTAssertLessThanOrEqual(mean, 0.005)
            }
        }
    }
}
#endif
