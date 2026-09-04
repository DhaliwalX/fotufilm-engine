#if canImport(Metal)
import XCTest
@testable import FotufilmCore
import FotufilmMetal
import Metal

final class HandwrittenMetalCompositeTailTests: XCTestCase {
    private static let device = MTLCreateSystemDefaultDevice()
    private static let tail = device.flatMap(HandwrittenMetalCompositeTail.init(device:))
    private static let baselineTail = device.flatMap {
        HandwrittenMetalCompositeTail(device: $0, lookupLayout: .baseline3D)
    }
    private static let composedTetrahedralTail = device.flatMap {
        HandwrittenMetalCompositeTail(
            device: $0, lookupLayout: .composed129WarpedTetrahedral)
    }
    private static let composedTrilinearTail = device.flatMap {
        HandwrittenMetalCompositeTail(
            device: $0, lookupLayout: .composed129WarpedTrilinear)
    }
    private static let endpoints = device.flatMap(HandwrittenMetalFrameEndpoints.init(device:))
    private static let queue = device?.makeCommandQueue()

    func testDenseAndRandomSDRCompositeTracksFactorizedTailPerceptually() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "Halide reference engine required")
        for (stock, options, name) in parityCases() {
            let result = try compareSDR(stock: stock, options: options, name: name)
            XCTAssertLessThanOrEqual(
                result.maximumCodeError, 3,
                "\(name): max code error \(result.maximumCodeError), mean \(result.meanCodeError)")
            XCTAssertLessThanOrEqual(
                result.meanCodeError, 0.35,
                "\(name): max code error \(result.maximumCodeError), mean \(result.meanCodeError)")
            // CIE76 is intentionally conservative here. A maximum below two and a sub-quarter
            // mean are below a just-noticeable difference for the patch set as displayed.
            XCTAssertLessThanOrEqual(
                result.maximumDeltaE, 2.0,
                "\(name): max dE76 \(result.maximumDeltaE), mean \(result.meanDeltaE)")
            XCTAssertLessThanOrEqual(
                result.meanDeltaE, 0.25,
                "\(name): max dE76 \(result.maximumDeltaE), mean \(result.meanDeltaE)")
        }
    }

    func testAdversarialNearBlackTracksCanonicalForOrientedAndBaselineLayouts() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "Halide reference engine required")
        let baseline = try XCTUnwrap(Self.baselineTail)
        let cases: [(HandwrittenMetalCompositeTail?, String)] = [
            (nil, "oriented"),
            (baseline, "baseline"),
        ]
        for (tail, name) in cases {
            let result = try compareSDR(
                stock: TestStocks.negative, options: neutralOptions(),
                name: "near-black-\(name)", sampleSet: .nearBlack,
                tailOverride: tail)
            XCTAssertLessThanOrEqual(
                result.maximumCodeError, 3,
                "\(name): max code error \(result.maximumCodeError), mean \(result.meanCodeError)")
            XCTAssertLessThanOrEqual(
                result.meanCodeError, 0.35,
                "\(name): max code error \(result.maximumCodeError), mean \(result.meanCodeError)")
            XCTAssertLessThanOrEqual(
                result.maximumDeltaE, 2.0,
                "\(name): max dE76 \(result.maximumDeltaE), mean \(result.meanDeltaE)")
            XCTAssertLessThanOrEqual(
                result.meanDeltaE, 0.25,
                "\(name): max dE76 \(result.maximumDeltaE), mean \(result.meanDeltaE)")
        }
    }

    func testWarpedComposedLayoutsTrackCanonicalHDRMasterAndMonotonicity() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "Halide reference engine required")
        let cases = [
            (try XCTUnwrap(Self.composedTetrahedralTail), "composed-tetrahedral"),
            (try XCTUnwrap(Self.composedTrilinearTail), "composed-trilinear"),
        ]
        for (tail, name) in cases {
            var broadResults = [HDRMetrics]()
            for (stock, options, variant) in parityCases() {
                let result = try compareHDR(
                    stock: stock, options: options,
                    name: "\(name)-\(variant)", tailOverride: tail)
                broadResults.append(result)
            }
            let nearBlack = try compareHDR(
                stock: TestStocks.negative, options: neutralOptions(),
                name: "\(name)-near-black", sampleSet: .nearBlack,
                tailOverride: tail)
            for result in broadResults + [nearBlack] {
                XCTAssertLessThanOrEqual(result.maximumLinearError, 0.02)
                XCTAssertLessThanOrEqual(result.meanLinearError, 0.002)
                XCTAssertLessThanOrEqual(result.maximumDeltaE, 2.0)
                XCTAssertLessThanOrEqual(result.meanDeltaE, 0.25)
            }
            XCTAssertTrue(broadResults.contains(where: \.sawHighlightAboveOne))
        }
    }

    func testWarpedComposedLayoutsRejectSeparateSDROpticalTail() throws {
        let tails = [
            try XCTUnwrap(Self.composedTetrahedralTail),
            try XCTUnwrap(Self.composedTrilinearTail),
        ]
        let count = 4
        let invocation = FilmEngineInvocation(
            stock: TestStocks.negative, options: neutralOptions(),
            width: count, height: 1)
        for (index, tail) in tails.enumerated() {
            XCTAssertThrowsError(try tail.prepareChecked(
                key: "composed-sdr-rejected-\(index)", invocation: invocation,
                mode: .encodedDisplayP3RGBA8, frameWidth: count, frameHeight: 1
            )) { error in
                guard let error = error as? HandwrittenMetalCompositeTail.PreparationError,
                      case .unsupportedOutputMode = error
                else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
        }
    }

    func testDenseAndRandomHDRCompositeTracksFactorizedTailWithoutHighlightClamp()
        throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "Halide reference engine required")
        let device = try XCTUnwrap(Self.device)
        let tail = try XCTUnwrap(Self.tail)
        let endpoints = try XCTUnwrap(Self.endpoints)
        let queue = try XCTUnwrap(Self.queue)
        var options = neutralOptions()
        options.grade = ColorGrade(
            shadows: .init(balanceX: 0.2, balanceY: 0.1, level: 0.1),
            midtones: .init(balanceX: -0.1, balanceY: 0.15, level: 0.2),
            highlights: .init(balanceX: 0.1, balanceY: -0.1, level: 0.25))
        options.gradeSpace = .encoded
        let sampleCount = Self.sampleCount
        let invocation = FilmEngineInvocation(
            stock: TestStocks.negative, options: options,
            width: sampleCount, height: 1)
        let densityHalf = densitySamples(invocation: invocation)
        let densityFloat = densityHalf.map(Float.init)
        let compositeDensity = try texture(
            device: device, format: .rgba16Float,
            width: sampleCount, values: densityHalf)
        let referenceDensity = try texture(
            device: device, format: .rgba32Float,
            width: sampleCount, values: densityFloat)
        var original = [Float16](repeating: 0, count: sampleCount * 4)
        for index in 0..<sampleCount {
            original[index * 4] = Float16(Float(index % 7) / 6)
            original[index * 4 + 1] = Float16(Float(index % 11) / 10)
            original[index * 4 + 2] = Float16(Float(index % 13) / 12)
            original[index * 4 + 3] = Float16(Float(index % 17) / 16)
        }
        let input = try buffer(device: device, values: original)
        let byteCount = original.count * MemoryLayout<Float16>.stride
        let expectedBuffer = try XCTUnwrap(device.makeBuffer(
            length: byteCount, options: .storageModeShared))
        let actualBuffer = try XCTUnwrap(device.makeBuffer(
            length: byteCount, options: .storageModeShared))
        let repeatedBuffer = try XCTUnwrap(device.makeBuffer(
            length: byteCount, options: .storageModeShared))
        let referenceKey = "composite-hdr-factorized"
        let compositeKey = "composite-hdr-baked"
        XCTAssertTrue(endpoints.prepare(
            key: referenceKey, invocation: invocation,
            mode: .linearRec2020RGBA16Float,
            frameWidth: sampleCount, frameHeight: 1))
        XCTAssertTrue(tail.prepare(
            key: compositeKey, invocation: invocation,
            mode: .linearRec2020RGBA16Float,
            frameWidth: sampleCount, frameHeight: 1))

        let frameIndex: UInt64 = 37
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(endpoints.encodeTail(
            developedDensity: referenceDensity, originalInput: input,
            output: expectedBuffer, key: referenceKey, frameIndex: frameIndex,
            commandBuffer: command))
        XCTAssertTrue(tail.encodeTail(
            developedDensity: compositeDensity, originalInput: input,
            output: actualBuffer, key: compositeKey, frameIndex: frameIndex,
            commandBuffer: command))
        XCTAssertEqual(command.status, .notEnqueued)
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)

        let repeatedCommand = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(tail.encodeTail(
            developedDensity: compositeDensity, originalInput: input,
            output: repeatedBuffer, key: compositeKey, frameIndex: frameIndex,
            commandBuffer: repeatedCommand))
        repeatedCommand.commit()
        repeatedCommand.waitUntilCompleted()
        XCTAssertEqual(repeatedCommand.status, .completed)

        let expected = expectedBuffer.contents().assumingMemoryBound(to: Float16.self)
        let actual = actualBuffer.contents().assumingMemoryBound(to: Float16.self)
        let repeated = repeatedBuffer.contents().assumingMemoryBound(to: UInt16.self)
        var maximumLinearError: Float = 0
        var totalLinearError: Double = 0
        var maximumDeltaE = 0.0
        var totalDeltaE = 0.0
        var sawHighlightAboveOne = false
        for index in 0..<sampleCount {
            let base = index * 4
            var wantedRGB = SIMD3<Float>.zero
            var actualRGB = SIMD3<Float>.zero
            for channel in 0..<3 {
                let wanted = Float(expected[base + channel])
                let got = Float(actual[base + channel])
                XCTAssertTrue(got.isFinite)
                let error = abs(got - wanted)
                maximumLinearError = max(maximumLinearError, error)
                totalLinearError += Double(error)
                wantedRGB[channel] = wanted
                actualRGB[channel] = got
                sawHighlightAboveOne = sawHighlightAboveOne || got > 1
            }
            let delta = displayDeltaE(wantedRGB, actualRGB)
            maximumDeltaE = max(maximumDeltaE, delta)
            totalDeltaE += delta
            XCTAssertEqual(actual[base + 3], original[base + 3])
            for channel in 0..<4 {
                XCTAssertEqual(
                    repeated[base + channel],
                    actualBuffer.contents().assumingMemoryBound(to: UInt16.self)[base + channel],
                    "HDR output must be bit-deterministic")
            }
        }
        let meanLinearError = totalLinearError / Double(sampleCount * 3)
        let meanDeltaE = totalDeltaE / Double(sampleCount)
        XCTAssertTrue(sawHighlightAboveOne, "HDR tail unexpectedly clipped display-linear light")
        XCTAssertLessThanOrEqual(
            maximumLinearError, 0.02,
            "max linear error \(maximumLinearError), mean \(meanLinearError)")
        XCTAssertLessThanOrEqual(
            meanLinearError, 0.002,
            "max linear error \(maximumLinearError), mean \(meanLinearError)")
        XCTAssertLessThanOrEqual(
            maximumDeltaE, 2.0,
            "max display-referred dE76 \(maximumDeltaE), mean \(meanDeltaE)")
        XCTAssertLessThanOrEqual(
            meanDeltaE, 0.25,
            "max display-referred dE76 \(maximumDeltaE), mean \(meanDeltaE)")
    }

    func testBaselineHDRTextureOutputMatchesBufferAndPreservesDensityAlpha() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "Halide reference engine required")
        let device = try XCTUnwrap(Self.device)
        let tail = try XCTUnwrap(Self.baselineTail)
        let queue = try XCTUnwrap(Self.queue)
        let width = 9
        let height = 3
        let count = width * height
        let invocation = FilmEngineInvocation(
            stock: TestStocks.negative, options: neutralOptions(),
            width: width, height: height)
        var density = Array(densitySamples(invocation: invocation).prefix(count * 4))
        var original = [Float16](repeating: 0, count: count * 4)
        for index in 0..<count {
            let base = index * 4
            density[base + 3] = Float16(Float((index * 7) % 17) / 16)
            original[base] = Float16(Float(index % 5) / 4)
            original[base + 1] = Float16(Float(index % 7) / 6)
            original[base + 2] = Float16(Float(index % 11) / 10)
            original[base + 3] = density[base + 3]
        }
        let densityTexture = try texture(
            device: device, format: .rgba16Float,
            width: width, height: height, values: density)
        let input = try buffer(device: device, values: original)
        let bufferOutput = try XCTUnwrap(device.makeBuffer(
            length: count * 4 * MemoryLayout<Float16>.stride,
            options: .storageModeShared))
        let zero = [Float16](repeating: 0, count: count * 4)
        let textureOutput = try texture(
            device: device, format: .rgba16Float,
            width: width, height: height, values: zero,
            usage: [.shaderRead, .shaderWrite])
        let repeatedOutput = try texture(
            device: device, format: .rgba16Float,
            width: width, height: height, values: zero,
            usage: [.shaderRead, .shaderWrite])
        let key = "composite-hdr-texture-baseline"
        XCTAssertTrue(tail.prepare(
            key: key, invocation: invocation,
            mode: .linearRec2020RGBA16Float,
            frameWidth: width, frameHeight: height))

        let frameIndex: UInt64 = 83
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(tail.encodeTail(
            developedDensity: densityTexture, originalInput: input,
            output: bufferOutput, key: key, frameIndex: frameIndex,
            commandBuffer: command))
        XCTAssertTrue(tail.encodeTail(
            developedDensity: densityTexture, output: textureOutput,
            key: key, frameIndex: frameIndex, commandBuffer: command))
        XCTAssertEqual(command.status, .notEnqueued)
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)

        let repeatedCommand = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(tail.encodeTail(
            developedDensity: densityTexture, output: repeatedOutput,
            key: key, frameIndex: frameIndex, commandBuffer: repeatedCommand))
        repeatedCommand.commit()
        repeatedCommand.waitUntilCompleted()
        XCTAssertEqual(repeatedCommand.status, .completed)

        let expected = bufferOutput.contents().assumingMemoryBound(to: UInt16.self)
        let actual = readRGBA16(textureOutput)
        let repeated = readRGBA16(repeatedOutput)
        for index in 0..<count {
            let base = index * 4
            for channel in 0..<4 {
                XCTAssertEqual(
                    actual[base + channel].bitPattern, expected[base + channel],
                    "texture and buffer HDR outputs differ at pixel \(index), channel \(channel)")
                XCTAssertEqual(
                    repeated[base + channel].bitPattern,
                    actual[base + channel].bitPattern,
                    "HDR texture output must be bit-deterministic")
            }
            XCTAssertEqual(
                actual[base + 3].bitPattern, density[base + 3].bitPattern,
                "HDR texture alpha must come from developed density")
        }
        XCTAssertEqual(actual[3], 0)
        XCTAssertEqual(actual[12 * 4 + 3], 1)
    }

    private static let denseEdge = 11
    private static let randomSamples = 1_024
    private static let sampleCount = denseEdge * denseEdge * denseEdge + randomSamples
    private static let nearBlackDenseEdge = 17
    private static let nearBlackRandomSamples = 2_048
    private static let nearBlackSampleCount = nearBlackDenseEdge * nearBlackDenseEdge
        * nearBlackDenseEdge + nearBlackRandomSamples + 7

    private enum SampleSet {
        case broad
        case nearBlack
    }

    private struct SDRMetrics {
        let maximumCodeError: Int
        let meanCodeError: Double
        let maximumDeltaE: Double
        let meanDeltaE: Double
    }

    private struct HDRMetrics {
        let maximumLinearError: Float
        let meanLinearError: Double
        let maximumDeltaE: Double
        let meanDeltaE: Double
        let sawHighlightAboveOne: Bool
    }

    private func compareSDR(
        stock: FilmStock, options: FotufilmEngine.Options, name: String,
        sampleSet: SampleSet = .broad,
        tailOverride: HandwrittenMetalCompositeTail? = nil
    ) throws -> SDRMetrics {
        let device = try XCTUnwrap(Self.device)
        let tail = try XCTUnwrap(tailOverride ?? Self.tail)
        let endpoints = try XCTUnwrap(Self.endpoints)
        let queue = try XCTUnwrap(Self.queue)
        let count = sampleSet == .broad
            ? Self.sampleCount : Self.nearBlackSampleCount
        let invocation = FilmEngineInvocation(
            stock: stock, options: options, width: count, height: 1)
        let density = sampleSet == .broad
            ? densitySamples(invocation: invocation)
            : nearBlackDensitySamples()
        XCTAssertEqual(density.count, count * 4)
        let densityTexture = try texture(
            device: device, format: .rgba16Float, width: count, values: density)
        var original = [UInt8](repeating: 0, count: count * 4)
        for index in 0..<count {
            original[index * 4] = UInt8(truncatingIfNeeded: index &* 29)
            original[index * 4 + 1] = UInt8(truncatingIfNeeded: index &* 71)
            original[index * 4 + 2] = UInt8(truncatingIfNeeded: index &* 113)
            original[index * 4 + 3] = UInt8(truncatingIfNeeded: index &* 47)
        }
        let input = try buffer(device: device, values: original)
        let expectedBuffer = try XCTUnwrap(device.makeBuffer(
            length: original.count, options: .storageModeShared))
        let actualBuffer = try XCTUnwrap(device.makeBuffer(
            length: original.count, options: .storageModeShared))
        let repeatedBuffer = try XCTUnwrap(device.makeBuffer(
            length: original.count, options: .storageModeShared))
        let referenceKey = "composite-sdr-factorized-\(name)"
        let compositeKey = "composite-sdr-baked-\(name)"
        XCTAssertTrue(endpoints.prepare(
            key: referenceKey, invocation: invocation,
            mode: .encodedDisplayP3RGBA8, frameWidth: count, frameHeight: 1))
        XCTAssertTrue(tail.prepare(
            key: compositeKey, invocation: invocation,
            mode: .encodedDisplayP3RGBA8, frameWidth: count, frameHeight: 1))

        let frameIndex: UInt64 = 23
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(endpoints.encodeTail(
            developedDensity: densityTexture, originalInput: input,
            output: expectedBuffer, key: referenceKey, frameIndex: frameIndex,
            commandBuffer: command))
        XCTAssertTrue(tail.encodeTail(
            developedDensity: densityTexture, originalInput: input,
            output: actualBuffer, key: compositeKey, frameIndex: frameIndex,
            commandBuffer: command))
        XCTAssertEqual(command.status, .notEnqueued)
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)

        let repeatedCommand = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(tail.encodeTail(
            developedDensity: densityTexture, originalInput: input,
            output: repeatedBuffer, key: compositeKey, frameIndex: frameIndex,
            commandBuffer: repeatedCommand))
        repeatedCommand.commit()
        repeatedCommand.waitUntilCompleted()
        XCTAssertEqual(repeatedCommand.status, .completed)

        let expected = expectedBuffer.contents().assumingMemoryBound(to: UInt8.self)
        let actual = actualBuffer.contents().assumingMemoryBound(to: UInt8.self)
        let repeated = repeatedBuffer.contents().assumingMemoryBound(to: UInt8.self)
        var maximumCodeError = 0
        var totalCodeError = 0
        var maximumDeltaE = 0.0
        var totalDeltaE = 0.0
        for index in 0..<count {
            let base = index * 4
            for channel in 0..<3 {
                let error = abs(Int(actual[base + channel]) - Int(expected[base + channel]))
                maximumCodeError = max(maximumCodeError, error)
                totalCodeError += error
            }
            let delta = displayDeltaE(
                SIMD3(expected[base], expected[base + 1], expected[base + 2]),
                SIMD3(actual[base], actual[base + 1], actual[base + 2]))
            maximumDeltaE = max(maximumDeltaE, delta)
            totalDeltaE += delta
            XCTAssertEqual(actual[base + 3], original[base + 3])
            for channel in 0..<4 {
                XCTAssertEqual(repeated[base + channel], actual[base + channel],
                               "SDR output must be bit-deterministic")
            }
        }
        return SDRMetrics(
            maximumCodeError: maximumCodeError,
            meanCodeError: Double(totalCodeError) / Double(count * 3),
            maximumDeltaE: maximumDeltaE,
            meanDeltaE: totalDeltaE / Double(count))
    }

    private func compareHDR(
        stock: FilmStock, options: FotufilmEngine.Options, name: String,
        sampleSet: SampleSet = .broad,
        tailOverride: HandwrittenMetalCompositeTail? = nil
    ) throws -> HDRMetrics {
        let device = try XCTUnwrap(Self.device)
        let tail = try XCTUnwrap(tailOverride ?? Self.tail)
        let endpoints = try XCTUnwrap(Self.endpoints)
        let queue = try XCTUnwrap(Self.queue)
        let count = sampleSet == .broad
            ? Self.sampleCount : Self.nearBlackSampleCount
        let invocation = FilmEngineInvocation(
            stock: stock, options: options, width: count, height: 1)
        let densityHalf = sampleSet == .broad
            ? densitySamples(invocation: invocation)
            : nearBlackDensitySamples()
        XCTAssertEqual(densityHalf.count, count * 4)
        let densityFloat = densityHalf.map(Float.init)
        let compositeDensity = try texture(
            device: device, format: .rgba16Float, width: count,
            values: densityHalf)
        let referenceDensity = try texture(
            device: device, format: .rgba32Float, width: count,
            values: densityFloat)
        var original = [Float16](repeating: 0, count: count * 4)
        for index in 0..<count {
            original[index * 4] = Float16(Float(index % 7) / 6)
            original[index * 4 + 1] = Float16(Float(index % 11) / 10)
            original[index * 4 + 2] = Float16(Float(index % 13) / 12)
            original[index * 4 + 3] = Float16(Float(index % 17) / 16)
        }
        let input = try buffer(device: device, values: original)
        let byteCount = original.count * MemoryLayout<Float16>.stride
        let expectedBuffer = try XCTUnwrap(device.makeBuffer(
            length: byteCount, options: .storageModeShared))
        let actualBuffer = try XCTUnwrap(device.makeBuffer(
            length: byteCount, options: .storageModeShared))
        let repeatedBuffer = try XCTUnwrap(device.makeBuffer(
            length: byteCount, options: .storageModeShared))
        let referenceKey = "composed-hdr-reference-\(name)"
        let compositeKey = "composed-hdr-candidate-\(name)"
        XCTAssertTrue(endpoints.prepare(
            key: referenceKey, invocation: invocation,
            mode: .linearRec2020RGBA16Float,
            frameWidth: count, frameHeight: 1))
        XCTAssertTrue(tail.prepare(
            key: compositeKey, invocation: invocation,
            mode: .linearRec2020RGBA16Float,
            frameWidth: count, frameHeight: 1))

        let frameIndex: UInt64 = 59
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(endpoints.encodeTail(
            developedDensity: referenceDensity, originalInput: input,
            output: expectedBuffer, key: referenceKey, frameIndex: frameIndex,
            commandBuffer: command))
        XCTAssertTrue(tail.encodeTail(
            developedDensity: compositeDensity, originalInput: input,
            output: actualBuffer, key: compositeKey, frameIndex: frameIndex,
            commandBuffer: command))
        XCTAssertEqual(command.status, .notEnqueued)
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)

        let repeatedCommand = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(tail.encodeTail(
            developedDensity: compositeDensity, originalInput: input,
            output: repeatedBuffer, key: compositeKey, frameIndex: frameIndex,
            commandBuffer: repeatedCommand))
        repeatedCommand.commit()
        repeatedCommand.waitUntilCompleted()
        XCTAssertEqual(repeatedCommand.status, .completed)

        let expected = expectedBuffer.contents().assumingMemoryBound(to: Float16.self)
        let actual = actualBuffer.contents().assumingMemoryBound(to: Float16.self)
        let repeated = repeatedBuffer.contents().assumingMemoryBound(to: UInt16.self)
        let actualBits = actualBuffer.contents().assumingMemoryBound(to: UInt16.self)
        var maximumLinearError: Float = 0
        var totalLinearError: Double = 0
        var maximumDeltaE = 0.0
        var totalDeltaE = 0.0
        var sawHighlightAboveOne = false
        for index in 0..<count {
            let base = index * 4
            var wantedRGB = SIMD3<Float>.zero
            var actualRGB = SIMD3<Float>.zero
            for channel in 0..<3 {
                let wanted = Float(expected[base + channel])
                let got = Float(actual[base + channel])
                XCTAssertTrue(got.isFinite)
                let error = abs(got - wanted)
                maximumLinearError = max(maximumLinearError, error)
                totalLinearError += Double(error)
                wantedRGB[channel] = wanted
                actualRGB[channel] = got
                sawHighlightAboveOne = sawHighlightAboveOne || got > 1
            }
            let delta = displayDeltaE(wantedRGB, actualRGB)
            maximumDeltaE = max(maximumDeltaE, delta)
            totalDeltaE += delta
            XCTAssertEqual(actual[base + 3], original[base + 3])
            for channel in 0..<4 {
                XCTAssertEqual(repeated[base + channel], actualBits[base + channel],
                               "HDR output must be bit-deterministic")
            }
        }
        if sampleSet == .broad {
            assertPreservesCanonicalMonotonicSteps(expected: expected, actual: actual)
        }
        return HDRMetrics(
            maximumLinearError: maximumLinearError,
            meanLinearError: totalLinearError / Double(count * 3),
            maximumDeltaE: maximumDeltaE,
            meanDeltaE: totalDeltaE / Double(count),
            sawHighlightAboveOne: sawHighlightAboveOne)
    }

    private func assertPreservesCanonicalMonotonicSteps(
        expected: UnsafePointer<Float16>, actual: UnsafePointer<Float16>
    ) {
        let edge = Self.denseEdge
        let strides = [1, edge, edge * edge]
        var checkedSteps = 0
        for axis in 0..<3 {
            for blue in 0..<edge {
                for green in 0..<edge {
                    for red in 0..<edge {
                        let coordinate = [red, green, blue]
                        guard coordinate[axis] + 1 < edge else { continue }
                        let first = (blue * edge + green) * edge + red
                        let second = first + strides[axis]
                        for channel in 0..<3 {
                            let expectedDelta = Float(expected[second * 4 + channel])
                                - Float(expected[first * 4 + channel])
                            // Flat and sub-code steps are dominated by half quantization. Larger
                            // canonical steps must not acquire a visible opposite-slope segment.
                            guard abs(expectedDelta) >= 0.01 else { continue }
                            let actualDelta = Float(actual[second * 4 + channel])
                                - Float(actual[first * 4 + channel])
                            if expectedDelta > 0 {
                                XCTAssertGreaterThanOrEqual(actualDelta, -0.002)
                            } else {
                                XCTAssertLessThanOrEqual(actualDelta, 0.002)
                            }
                            checkedSteps += 1
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(checkedSteps, 100)
    }

    private func neutralOptions() -> FotufilmEngine.Options {
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        options.flareScale = 0
        options.localTone = false
        options.sceneHeadroom = 1
        return options
    }

    private func testGrade() -> ColorGrade {
        ColorGrade(
            shadows: .init(balanceX: 0.2, balanceY: 0.1, level: 0.1),
            midtones: .init(balanceX: -0.1, balanceY: 0.15, level: 0.2),
            highlights: .init(balanceX: 0.1, balanceY: -0.1, level: 0.25))
    }

    private func parityCases() -> [(FilmStock, FotufilmEngine.Options, String)] {
        var linearGrade = neutralOptions()
        linearGrade.grade = testGrade()
        linearGrade.gradeSpace = .linear
        var encodedGrade = neutralOptions()
        encodedGrade.grade = testGrade()
        encodedGrade.gradeSpace = .encoded
        return [
            (TestStocks.negative, neutralOptions(), "negative"),
            (TestStocks.reversal, neutralOptions(), "reversal"),
            (TestStocks.monochrome, neutralOptions(), "monochrome"),
            (TestStocks.negative, linearGrade, "linear-grade"),
            (TestStocks.negative, encodedGrade, "encoded-grade"),
        ]
    }

    private func densitySamples(invocation: FilmEngineInvocation) -> [Float16] {
        let minima = SIMD3<Float>(
            invocation.configuration[0], invocation.configuration[6],
            invocation.configuration[12])
        var ranges = SIMD3<Float>.zero
        for channel in 0..<3 {
            let primary = channel * 6
            let secondary = FilmEngineInvocation.curveSecondaryOffset + channel * 5
            ranges[channel] = invocation.configuration[primary + 1]
                * (invocation.configuration[primary + 4]
                   - invocation.configuration[primary + 2])
                + invocation.configuration[secondary]
                * (invocation.configuration[secondary + 3]
                   - invocation.configuration[secondary + 1])
        }
        var samples = [Float16]()
        samples.reserveCapacity(Self.sampleCount * 4)
        for blue in 0..<Self.denseEdge {
            for green in 0..<Self.denseEdge {
                for red in 0..<Self.denseEdge {
                    let unit = SIMD3(
                        Float(red) / Float(Self.denseEdge - 1),
                        Float(green) / Float(Self.denseEdge - 1),
                        Float(blue) / Float(Self.denseEdge - 1))
                    appendDensity(minima + unit * ranges, to: &samples)
                }
            }
        }
        var state: UInt32 = 0xC001_C0DE
        for _ in 0..<Self.randomSamples {
            func randomUnit() -> Float {
                state = state &* 1_664_525 &+ 1_013_904_223
                // Exercise canonical endpoint clamping slightly beyond the nominal curve domain.
                return -0.05 + 1.1 * Float(state >> 8) / Float(0x00FF_FFFF)
            }
            let unit = SIMD3(randomUnit(), randomUnit(), randomUnit())
            appendDensity(minima + unit * ranges, to: &samples)
        }
        return samples
    }

    private func nearBlackDensitySamples() -> [Float16] {
        // This is the 65-grid cell that exposed the original composed-cube defect. The canonical
        // paper LUT changes by roughly thirty red codes inside it, so a dense cell sweep plus
        // random and one-ULP probes guards against regression without relying on one lucky point.
        let low = SIMD3<Float>(0.757, 3.174, 3.336)
        let high = SIMD3<Float>(0.782, 3.2, 3.363)
        var samples = [Float16]()
        samples.reserveCapacity(Self.nearBlackSampleCount * 4)
        for blue in 0..<Self.nearBlackDenseEdge {
            for green in 0..<Self.nearBlackDenseEdge {
                for red in 0..<Self.nearBlackDenseEdge {
                    let fraction = SIMD3<Float>(
                        Float(red) / Float(Self.nearBlackDenseEdge - 1),
                        Float(green) / Float(Self.nearBlackDenseEdge - 1),
                        Float(blue) / Float(Self.nearBlackDenseEdge - 1))
                    appendDensity(low + fraction * (high - low), to: &samples)
                }
            }
        }
        var state: UInt32 = 0x51A7_0B1A
        for _ in 0..<Self.nearBlackRandomSamples {
            func randomUnit() -> Float {
                state = state &* 1_664_525 &+ 1_013_904_223
                return Float(state >> 8) / Float(0x00FF_FFFF)
            }
            let fraction = SIMD3<Float>(randomUnit(), randomUnit(), randomUnit())
            appendDensity(low + fraction * (high - low), to: &samples)
        }
        let center = SIMD3<Float16>(0.7666, 3.197, 3.346)
        appendDensity(SIMD3<Float>(center), to: &samples)
        for channel in 0..<3 {
            var below = center
            below[channel] = below[channel].nextDown
            appendDensity(SIMD3<Float>(below), to: &samples)
            var above = center
            above[channel] = above[channel].nextUp
            appendDensity(SIMD3<Float>(above), to: &samples)
        }
        return samples
    }

    private func appendDensity(_ value: SIMD3<Float>, to samples: inout [Float16]) {
        samples.append(Float16(value.x))
        samples.append(Float16(value.y))
        samples.append(Float16(value.z))
        samples.append(1)
    }

    private func buffer<T>(device: MTLDevice, values: [T]) throws -> MTLBuffer {
        try values.withUnsafeBytes { bytes in
            try XCTUnwrap(device.makeBuffer(
                bytes: bytes.baseAddress!, length: bytes.count,
                options: .storageModeShared))
        }
    }

    private func texture<T>(
        device: MTLDevice, format: MTLPixelFormat, width: Int,
        height: Int = 1, values: [T], usage: MTLTextureUsage = .shaderRead
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = usage
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        values.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: bytes.baseAddress!, bytesPerRow: bytes.count / height)
        }
        return texture
    }

    private func readRGBA16(_ texture: MTLTexture) -> [Float16] {
        var result = [Float16](
            repeating: 0, count: texture.width * texture.height * 4)
        result.withUnsafeMutableBytes { bytes in
            texture.getBytes(
                bytes.baseAddress!,
                bytesPerRow: texture.width * 4 * MemoryLayout<Float16>.stride,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0)
        }
        return result
    }

    private func displayDeltaE(_ lhs: SIMD3<UInt8>, _ rhs: SIMD3<UInt8>) -> Double {
        let first = cieLab(SIMD3(
            ColorScience.srgbToLinear(Float(lhs.x) / 255),
            ColorScience.srgbToLinear(Float(lhs.y) / 255),
            ColorScience.srgbToLinear(Float(lhs.z) / 255)))
        let second = cieLab(SIMD3(
            ColorScience.srgbToLinear(Float(rhs.x) / 255),
            ColorScience.srgbToLinear(Float(rhs.y) / 255),
            ColorScience.srgbToLinear(Float(rhs.z) / 255)))
        return euclideanDistance(first, second)
    }

    private func displayDeltaE(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>) -> Double {
        func displayed(_ value: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(
                min(max(ColorScience.displayShoulder(value.x), 0), 1),
                min(max(ColorScience.displayShoulder(value.y), 0), 1),
                min(max(ColorScience.displayShoulder(value.z), 0), 1))
        }
        let first = cieLab(displayed(lhs))
        let second = cieLab(displayed(rhs))
        return euclideanDistance(first, second)
    }

    private func euclideanDistance(
        _ lhs: SIMD3<Double>, _ rhs: SIMD3<Double>
    ) -> Double {
        let difference = lhs - rhs
        return sqrt(difference.x * difference.x
                    + difference.y * difference.y
                    + difference.z * difference.z)
    }

    /// Display-P3/D65 linear light to CIE Lab. Delta-E 76 is used as a conservative acceptance
    /// instrument; this test does not claim it is a model of HDR appearance above display white.
    private func cieLab(_ p3: SIMD3<Float>) -> SIMD3<Double> {
        let red = Double(p3.x), green = Double(p3.y), blue = Double(p3.z)
        let x = (0.4865709486482162 * red + 0.2656676931690931 * green
                 + 0.1982172852343625 * blue) / 0.95047
        let y = 0.2289745640697488 * red + 0.6917385218365064 * green
            + 0.0792869140937450 * blue
        let z = (0.0451133818589026 * green + 1.043944368900976 * blue) / 1.08883
        let epsilon = 216.0 / 24_389.0
        let kappa = 24_389.0 / 27.0
        func f(_ value: Double) -> Double {
            value > epsilon ? pow(value, 1.0 / 3.0) : (kappa * value + 16) / 116
        }
        let fx = f(x), fy = f(y), fz = f(z)
        return SIMD3(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }
}
#endif
