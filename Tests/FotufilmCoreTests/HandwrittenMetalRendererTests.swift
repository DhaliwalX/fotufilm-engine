#if canImport(Metal)
import XCTest
@testable import FotufilmCore
import FotufilmMetal
import Metal

final class HandwrittenMetalRendererTests: XCTestCase {
    func testPointwiseUniformColoursTrackHalideByteSchedule() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let handwritten = try XCTUnwrap(HandwrittenMetalFilmRenderer.shared)
        let oracle = try XCTUnwrap(HalideMetalFilmRenderer.shared)
        let width = 16
        let height = 16
        let count = width * height * 4
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        options.localTone = false
        let key = "pointwise-uniform-negative"
        let prepared = handwritten.prepare(
            key: key, stock: TestStocks.negative, options: options,
            frameWidth: width, frameHeight: height)
        XCTAssertTrue(prepared)
        guard prepared else { return }

        let colours: [SIMD3<UInt8>] = [
            SIMD3(0, 0, 0), SIMD3(32, 32, 32), SIMD3(128, 128, 128),
            SIMD3(255, 255, 255), SIMD3(220, 32, 18), SIMD3(24, 210, 70),
            SIMD3(18, 48, 230), SIMD3(196, 118, 35),
        ]
        var totalError = 0
        var compared = 0
        var maximumError = 0
        for (sampleIndex, colour) in colours.enumerated() {
            var input = [UInt8](repeating: 255, count: count)
            for offset in stride(from: 0, to: count, by: 4) {
                input[offset] = colour.x
                input[offset + 1] = colour.y
                input[offset + 2] = colour.z
            }
            let source = try XCTUnwrap(device.makeBuffer(
                bytes: input, length: count, options: .storageModeShared))
            let nativeOutput = try XCTUnwrap(device.makeBuffer(
                length: count, options: .storageModeShared))
            let oracleOutput = try XCTUnwrap(device.makeBuffer(
                length: count, options: .storageModeShared))
            let frame = UInt64(sampleIndex + 7)
            XCTAssertTrue(handwritten.processRGBA8(
                input: source, output: nativeOutput, width: width, height: height,
                key: key, frameIndex: frame))
            XCTAssertTrue(oracle.processRGBA8(
                input: source, output: oracleOutput, width: width, height: height,
                stock: TestStocks.negative, options: options, frameIndex: frame))
            let actual = nativeOutput.contents().assumingMemoryBound(to: UInt8.self)
            let expected = oracleOutput.contents().assumingMemoryBound(to: UInt8.self)
            for offset in stride(from: 0, to: count, by: 4) {
                for channel in 0..<3 {
                    let error = abs(Int(actual[offset + channel])
                                    - Int(expected[offset + channel]))
                    maximumError = max(maximumError, error)
                    totalError += error
                    compared += 1
                }
                XCTAssertEqual(actual[offset + 3], expected[offset + 3])
            }
        }
        XCTAssertLessThanOrEqual(maximumError, 3)
        XCTAssertLessThanOrEqual(
            Double(totalError) / Double(compared), 0.75)
    }

    func testPointwiseHDRUniformColoursTrackHalideRealtimeSchedule() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let handwritten = try XCTUnwrap(HandwrittenMetalFilmRenderer.shared)
        let oracle = try XCTUnwrap(HalideMetalFilmRenderer.shared)
        let width = 16
        let height = 16
        let values = width * height * 4
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        options.localTone = false
        options.sceneHeadroom = HLGSceneTransfer.headroom
        let key = "pointwise-hdr-negative"
        let prepared = handwritten.prepareLinearHDR(
            key: key, stock: TestStocks.negative, options: options,
            frameWidth: width, frameHeight: height)
        XCTAssertTrue(prepared)
        guard prepared else { return }

        let colours: [SIMD3<Float>] = [
            SIMD3(repeating: 0), SIMD3(repeating: 0.18), SIMD3(repeating: 1),
            SIMD3(repeating: 4), SIMD3(repeating: 16),
            SIMD3(2, 0.25, 0.04), SIMD3(0.08, 1.5, 0.32),
            SIMD3(0.12, 0.4, 6),
        ]
        var maximumError: Float = 0
        var totalError: Double = 0
        var compared = 0
        for (sampleIndex, colour) in colours.enumerated() {
            var floatInput = [Float](repeating: 1, count: values)
            var halfInput = [Float16](repeating: 1, count: values)
            for offset in stride(from: 0, to: values, by: 4) {
                for channel in 0..<3 {
                    floatInput[offset + channel] = colour[channel]
                    halfInput[offset + channel] = Float16(colour[channel])
                }
            }
            let halfBytes = values * MemoryLayout<Float16>.stride
            let sourceHalf = try halfInput.withUnsafeBytes { raw in
                try XCTUnwrap(device.makeBuffer(
                    bytes: raw.baseAddress!, length: halfBytes,
                    options: .storageModeShared))
            }
            let nativeOutput = try XCTUnwrap(device.makeBuffer(
                length: halfBytes, options: .storageModeShared))
            let floatBytes = values * MemoryLayout<Float>.stride
            let sourceFloat = try floatInput.withUnsafeBytes { raw in
                try XCTUnwrap(device.makeBuffer(
                    bytes: raw.baseAddress!, length: floatBytes,
                    options: .storageModeShared))
            }
            let oracleOutput = try XCTUnwrap(device.makeBuffer(
                length: floatBytes, options: .storageModeShared))
            let frame = UInt64(sampleIndex + 11)
            XCTAssertTrue(handwritten.processLinearHalf(
                input: sourceHalf, output: nativeOutput,
                width: width, height: height, key: key, frameIndex: frame))
            XCTAssertTrue(oracle.processLinearFloat(
                input: sourceFloat, output: oracleOutput,
                width: width, height: height, stock: TestStocks.negative,
                options: options, frameIndex: frame, realtime: true))
            let actual = nativeOutput.contents().assumingMemoryBound(to: Float16.self)
            let expected = oracleOutput.contents().assumingMemoryBound(to: Float.self)
            for offset in stride(from: 0, to: values, by: 4) {
                for channel in 0..<3 {
                    let error = abs(Float(actual[offset + channel])
                                    - expected[offset + channel])
                    maximumError = max(maximumError, error)
                    totalError += Double(error)
                    compared += 1
                }
                XCTAssertEqual(Float(actual[offset + 3]), expected[offset + 3])
            }
        }
        XCTAssertLessThanOrEqual(maximumError, 0.02)
        XCTAssertLessThanOrEqual(totalError / Double(compared), 0.003)
    }

    func testTemporalPrintSamplingConvergesToExactTetrahedronAndIsDeterministic() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try XCTUnwrap(HandwrittenMetalFilmRenderer.shared)
        let width = 16
        let height = 16
        let values = width * height * 4
        let bytes = values * MemoryLayout<Float16>.stride
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        options.localTone = false
        options.sceneHeadroom = HLGSceneTransfer.headroom
        let key = "pointwise-temporal-tetra"
        XCTAssertTrue(renderer.prepareLinearHDR(
            key: key, stock: TestStocks.negative, options: options,
            frameWidth: width, frameHeight: height))

        var inputValues = [Float16](repeating: 1, count: values)
        for offset in stride(from: 0, to: values, by: 4) {
            inputValues[offset] = 0.73
            inputValues[offset + 1] = 0.19
            inputValues[offset + 2] = 1.41
            inputValues[offset + 3] = 0.625
        }
        let input = try inputValues.withUnsafeBytes { raw in
            try XCTUnwrap(device.makeBuffer(
                bytes: raw.baseAddress!, length: bytes,
                options: .storageModeShared))
        }
        let exact = try XCTUnwrap(device.makeBuffer(
            length: bytes, options: .storageModeShared))
        let sampled = try XCTUnwrap(device.makeBuffer(
            length: bytes, options: .storageModeShared))
        XCTAssertTrue(renderer.processLinearHalf(
            input: input, output: exact, width: width, height: height,
            key: key, frameIndex: 0, temporalPrint: false))
        let exactPixels = exact.contents().assumingMemoryBound(to: Float16.self)
        var exactMean = SIMD3<Double>.zero
        for offset in stride(from: 0, to: values, by: 4) {
            exactMean += SIMD3(
                Double(exactPixels[offset]), Double(exactPixels[offset + 1]),
                Double(exactPixels[offset + 2]))
        }
        exactMean /= Double(width * height)

        var temporalMean = SIMD3<Double>.zero
        let frames = 64
        for frame in 0..<frames {
            XCTAssertTrue(renderer.processLinearHalf(
                input: input, output: sampled, width: width, height: height,
                key: key, frameIndex: UInt64(frame), temporalPrint: true))
            let pixels = sampled.contents().assumingMemoryBound(to: Float16.self)
            for offset in stride(from: 0, to: values, by: 4) {
                temporalMean += SIMD3(
                    Double(pixels[offset]), Double(pixels[offset + 1]),
                    Double(pixels[offset + 2]))
                XCTAssertEqual(Float(pixels[offset + 3]), 0.625)
            }
        }
        temporalMean /= Double(width * height * frames)
        for channel in 0..<3 {
            XCTAssertEqual(
                temporalMean[channel], exactMean[channel], accuracy: 0.002,
                "temporal tetra channel \(channel)")
        }

        let first = Array(UnsafeBufferPointer(
            start: sampled.contents().assumingMemoryBound(to: UInt16.self),
            count: values))
        XCTAssertTrue(renderer.processLinearHalf(
            input: input, output: sampled, width: width, height: height,
            key: key, frameIndex: UInt64(frames - 1), temporalPrint: true))
        let repeated = Array(UnsafeBufferPointer(
            start: sampled.contents().assumingMemoryBound(to: UInt16.self),
            count: values))
        XCTAssertEqual(repeated, first)
    }
}
#endif
