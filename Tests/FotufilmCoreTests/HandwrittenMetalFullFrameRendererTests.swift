#if canImport(Metal)
import XCTest
@testable import FotufilmCore
import FotufilmMetal
import Metal

final class HandwrittenMetalFullFrameRendererTests: XCTestCase {
    private static let testFormat = FilmFormat(
        name: "Handwritten HDR full-frame test", frameHeightMM: 0.8)

    func testUniformSpatialHDRMasterStaysUniformAndIsOpaque() throws {
        let harness = try Harness(maximumInFlightFrames: 1)
        let width = 40
        let height = 24
        let input = try x420(
            device: harness.device, width: width, height: height,
            luma: { _, _ in 502 }, chroma: { _, _ in SIMD2(512, 512) })
        let output = try rgba16Texture(
            device: harness.device, width: width, height: height)
        let options = spatialOptions(grain: false)
        let invocation = FilmEngineInvocation(
            stock: TestStocks.negative, options: screen(options),
            width: width, height: height)
        let spatialMask = FilmEngineFeature.halation | FilmEngineFeature.couplers
            | FilmEngineFeature.couplerDiffusion | FilmEngineFeature.adjacency
        XCTAssertEqual(invocation.featureMask & spatialMask, spatialMask)
        XCTAssertTrue(harness.renderer.prepare(
            key: #function, stock: TestStocks.negative, options: options,
            frameWidth: width, frameHeight: height))

        try render(
            renderer: harness.renderer, queue: harness.queue,
            input: input, output: output, key: #function,
            transfer: .hlg, sceneScale: HLGSceneTransfer.headroom,
            frameIndex: 17)

        let values = readRGBA16(output)
        let first = Array(values[0..<4])
        for offset in stride(from: 0, to: values.count, by: 4) {
            XCTAssertEqual(Array(values[offset..<(offset + 3)]), Array(first[0..<3]))
            XCTAssertEqual(values[offset + 3], Float16(1))
        }
    }

    func testSeededHDRMasterIsDeterministicForFrameIndex() throws {
        let harness = try Harness(maximumInFlightFrames: 1)
        let width = 48
        let height = 30
        let input = try representativeX420(
            device: harness.device, width: width, height: height)
        let first = try rgba16Texture(
            device: harness.device, width: width, height: height)
        let repeated = try rgba16Texture(
            device: harness.device, width: width, height: height)
        let next = try rgba16Texture(
            device: harness.device, width: width, height: height)
        let options = spatialOptions(grain: true)
        let invocation = FilmEngineInvocation(
            stock: TestStocks.negative, options: screen(options),
            width: width, height: height)
        XCTAssertNotEqual(invocation.featureMask & FilmEngineFeature.grain, 0)
        XCTAssertTrue(harness.renderer.prepare(
            key: #function, stock: TestStocks.negative, options: options,
            frameWidth: width, frameHeight: height))

        try render(
            renderer: harness.renderer, queue: harness.queue,
            input: input, output: first, key: #function,
            transfer: .hlg, sceneScale: HLGSceneTransfer.headroom,
            frameIndex: 0x1234)
        try render(
            renderer: harness.renderer, queue: harness.queue,
            input: input, output: repeated, key: #function,
            transfer: .hlg, sceneScale: HLGSceneTransfer.headroom,
            frameIndex: 0x1234)
        try render(
            renderer: harness.renderer, queue: harness.queue,
            input: input, output: next, key: #function,
            transfer: .hlg, sceneScale: HLGSceneTransfer.headroom,
            frameIndex: 0x1235)

        let firstValues = readRGBA16(first)
        let repeatedValues = readRGBA16(repeated)
        let nextValues = readRGBA16(next)
        XCTAssertEqual(repeatedValues, firstValues)
        XCTAssertNotEqual(nextValues, firstValues)
        for offset in stride(from: 3, to: firstValues.count, by: 4) {
            XCTAssertEqual(firstValues[offset], Float16(1))
            XCTAssertEqual(repeatedValues[offset], Float16(1))
            XCTAssertEqual(nextValues[offset], Float16(1))
        }
    }

    func testEncodeUsesCallerCommandBuffersAndBoundsEveryInFlightResource() throws {
        let harness = try Harness(maximumInFlightFrames: 2)
        let width = 32
        let height = 20
        let input = try representativeX420(
            device: harness.device, width: width, height: height)
        let sentinel = [Float16](repeating: -3, count: width * height * 4)
        let outputs = try (0..<3).map { _ in
            try rgba16Texture(
                device: harness.device, width: width, height: height,
                values: sentinel)
        }
        var stock = TestStocks.negative
        stock.flare = 0.2
        var options = spatialOptions(grain: false)
        options.highlights = 0.35
        options.shadows = -0.2
        options.localTone = true
        options.flareScale = 1
        XCTAssertTrue(harness.renderer.prepare(
            key: #function, stock: stock, options: options,
            frameWidth: width, frameHeight: height))

        let first = try XCTUnwrap(harness.queue.makeCommandBuffer())
        let second = try XCTUnwrap(harness.queue.makeCommandBuffer())
        let third = try XCTUnwrap(harness.queue.makeCommandBuffer())
        XCTAssertTrue(harness.renderer.encodeCapturedHDR(
            luma: input.luma, chroma: input.chroma, output: outputs[0],
            width: width, height: height, key: #function,
            transfer: .hlg, sceneScale: HLGSceneTransfer.headroom,
            frameIndex: 4, commandBuffer: first))
        XCTAssertTrue(harness.renderer.encodeCapturedHDR(
            luma: input.luma, chroma: input.chroma, output: outputs[1],
            width: width, height: height, key: #function,
            transfer: .hlg, sceneScale: HLGSceneTransfer.headroom,
            frameIndex: 5, commandBuffer: second))
        XCTAssertEqual(first.status, .notEnqueued)
        XCTAssertEqual(second.status, .notEnqueued)
        XCTAssertEqual(readRGBA16(outputs[0]), sentinel)
        XCTAssertFalse(harness.renderer.encodeCapturedHDR(
            luma: input.luma, chroma: input.chroma, output: outputs[2],
            width: width, height: height, key: #function,
            transfer: .hlg, sceneScale: HLGSceneTransfer.headroom,
            frameIndex: 6, commandBuffer: third),
            "a third frame must not share either leased measurement/intermediate slot")
        XCTAssertEqual(third.status, .notEnqueued)

        first.commit()
        second.commit()
        first.waitUntilCompleted()
        second.waitUntilCompleted()
        XCTAssertEqual(first.status, .completed, "\(String(describing: first.error))")
        XCTAssertEqual(second.status, .completed, "\(String(describing: second.error))")
        XCTAssertNotEqual(readRGBA16(outputs[0]), sentinel)

        let afterCompletion = try XCTUnwrap(harness.queue.makeCommandBuffer())
        XCTAssertTrue(harness.renderer.encodeCapturedHDR(
            luma: input.luma, chroma: input.chroma, output: outputs[2],
            width: width, height: height, key: #function,
            transfer: .hlg, sceneScale: HLGSceneTransfer.headroom,
            frameIndex: 6, commandBuffer: afterCompletion))
        XCTAssertEqual(afterCompletion.status, .notEnqueued)
        afterCompletion.commit()
        afterCompletion.waitUntilCompleted()
        XCTAssertEqual(
            afterCompletion.status, .completed,
            "\(String(describing: afterCompletion.error))")
    }

    func testForcedScreenAppleLogToneAndFlareMatchExplicitComponentGraph() throws {
        let harness = try Harness(maximumInFlightFrames: 1)
        let width = 35
        let height = 21
        let input = try representativeX420(
            device: harness.device, width: width, height: height)
        let actual = try rgba16Texture(
            device: harness.device, width: width, height: height)
        let expected = try rgba16Texture(
            device: harness.device, width: width, height: height)
        var stock = TestStocks.negative
        stock.flare = 0.2
        var requested = spatialOptions(grain: false)
        requested.paper = .projection
        requested.highlights = 0.42
        requested.shadows = -0.18
        requested.localTone = true
        requested.flareScale = 1
        let explicitScreen = screen(requested)
        let invocation = FilmEngineInvocation(
            stock: stock, options: explicitScreen,
            width: width, height: height)
        XCTAssertEqual(explicitScreen.paper(for: stock), .screen)
        XCTAssertTrue(invocation.localToneActive)
        XCTAssertNotEqual(invocation.featureMask & FilmEngineFeature.flare, 0)
        XCTAssertTrue(harness.renderer.prepare(
            key: #function, stock: stock, options: requested,
            frameWidth: width, frameHeight: height))

        let measurements = try XCTUnwrap(
            HandwrittenMetalGlobalMeasurements(device: harness.device))
        let head = try XCTUnwrap(HandwrittenMetalSpectralHead(device: harness.device))
        let spatial = try XCTUnwrap(HandwrittenMetalSpatialExecutor(
            device: harness.device, maximumInFlightFrames: 1,
            optimizationVariant: .perceptualMultires))
        let tail = try XCTUnwrap(HandwrittenMetalCompositeTail(
            device: harness.device, lookupLayout: .baseline3D))
        let componentKey = #function + "-components"
        try head.prepareChecked(
            key: componentKey, invocation: invocation,
            mode: .linearRec2020RGBA16Float,
            frameWidth: width, frameHeight: height, toneGrid: .gpu)
        try spatial.prepareChecked(
            key: componentKey, stock: stock, options: explicitScreen,
            frameWidth: width, frameHeight: height)
        try tail.prepareChecked(
            key: componentKey, invocation: invocation,
            mode: .linearRec2020RGBA16Float,
            frameWidth: width, frameHeight: height)
        let toneResources = try measurements.makeResources(
            invocation: invocation, mode: .linearRec2020RGBA16Float,
            frameWidth: width, frameHeight: height)
        let flareResources = try measurements.makeResources(
            invocation: invocation, mode: .encodedDisplayP3RGBA8,
            frameWidth: width, frameHeight: height)
        let toneGrid = try XCTUnwrap(toneResources.toneGrid)
        let flareMean = try XCTUnwrap(flareResources.flareMean)
        let record = try rgba16Texture(
            device: harness.device, width: width, height: height)
        let density = try rgba16Texture(
            device: harness.device, width: width, height: height)
        let frameIndex: UInt64 = 0x1020_3040
        let command = try XCTUnwrap(harness.queue.makeCommandBuffer())

        XCTAssertTrue(measurements.encodeToneBase(
            luma: input.luma, chroma: input.chroma, transfer: .appleLog,
            sceneScale: AppleLogCurve.sceneScale,
            chromaOffset: SIMD2(0.125, -0.125), inputGain: 0.94,
            resources: toneResources, commandBuffer: command))
        XCTAssertTrue(head.encodeCapturedHDR(
            luma: input.luma, chroma: input.chroma,
            recordExposure: record, key: componentKey,
            transfer: .appleLog, sceneScale: AppleLogCurve.sceneScale,
            chromaOffset: SIMD2(0.125, -0.125), inputGain: 0.94,
            gpuToneGrid: toneGrid, commandBuffer: command))
        XCTAssertTrue(measurements.encodeFlareMean(
            recordExposure: record, resources: flareResources,
            commandBuffer: command))
        XCTAssertTrue(spatial.encodeDevelopedDensity(
            recordExposure: record, densityOutput: density,
            key: componentKey, frameIndex: frameIndex,
            flareMean: flareMean, commandBuffer: command))
        XCTAssertTrue(tail.encodeTail(
            developedDensity: density, output: expected,
            key: componentKey, frameIndex: frameIndex,
            commandBuffer: command))
        XCTAssertTrue(harness.renderer.encodeCapturedHDR(
            luma: input.luma, chroma: input.chroma, output: actual,
            width: width, height: height, key: #function,
            transfer: .appleLog, sceneScale: AppleLogCurve.sceneScale,
            chromaOffset: SIMD2(0.125, -0.125), inputGain: 0.94,
            frameIndex: frameIndex, commandBuffer: command))
        XCTAssertEqual(command.status, .notEnqueued)
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, "\(String(describing: command.error))")

        XCTAssertEqual(
            readRGBA16(actual), readRGBA16(expected),
            "the orchestrator must be the exact composition of its prepared HDR components")
    }

    func testFloat32StillToneAndFlareMatchExplicitComponentGraph() throws {
        let harness = try Harness(maximumInFlightFrames: 1)
        let width = 37
        let height = 23
        let sourceValues = representativeSceneLinearFloat(
            width: width, height: height)
        let input = try buffer(device: harness.device, values: sourceValues)
        let actual = try rgba16Texture(
            device: harness.device, width: width, height: height)
        let expected = try rgba16Texture(
            device: harness.device, width: width, height: height)
        var stock = TestStocks.negative
        stock.flare = 0.2
        var requested = spatialOptions(grain: false)
        requested.paper = .photoSoft
        requested.highlights = 0.38
        requested.shadows = -0.22
        requested.localTone = true
        requested.flareScale = 1
        let explicitScreen = screen(requested)
        let invocation = FilmEngineInvocation(
            stock: stock, options: explicitScreen,
            width: width, height: height)
        XCTAssertTrue(harness.renderer.prepare(
            key: #function, stock: stock, options: requested,
            frameWidth: width, frameHeight: height))

        let measurements = try XCTUnwrap(
            HandwrittenMetalGlobalMeasurements(device: harness.device))
        let head = try XCTUnwrap(HandwrittenMetalSpectralHead(device: harness.device))
        let spatial = try XCTUnwrap(HandwrittenMetalSpatialExecutor(
            device: harness.device, maximumInFlightFrames: 1,
            optimizationVariant: .perceptualMultires))
        let tail = try XCTUnwrap(HandwrittenMetalCompositeTail(
            device: harness.device, lookupLayout: .baseline3D))
        let componentKey = #function + "-components"
        try head.prepareChecked(
            key: componentKey, invocation: invocation,
            mode: .linearRec2020RGBA32Float,
            frameWidth: width, frameHeight: height, toneGrid: .gpu)
        try spatial.prepareChecked(
            key: componentKey, stock: stock, options: explicitScreen,
            frameWidth: width, frameHeight: height)
        try tail.prepareChecked(
            key: componentKey, invocation: invocation,
            mode: .linearRec2020RGBA16Float,
            frameWidth: width, frameHeight: height)
        let toneResources = try measurements.makeResources(
            invocation: invocation, mode: .linearRec2020RGBA32Float,
            frameWidth: width, frameHeight: height)
        let flareResources = try measurements.makeResources(
            invocation: invocation, mode: .encodedDisplayP3RGBA8,
            frameWidth: width, frameHeight: height)
        let toneGrid = try XCTUnwrap(toneResources.toneGrid)
        let flareMean = try XCTUnwrap(flareResources.flareMean)
        let record = try rgba16Texture(
            device: harness.device, width: width, height: height)
        let density = try rgba16Texture(
            device: harness.device, width: width, height: height)
        let frameIndex: UInt64 = 0x5060_7080
        let command = try XCTUnwrap(harness.queue.makeCommandBuffer())

        XCTAssertTrue(measurements.encodeToneBase(
            input: input, inputGain: 0.91, resources: toneResources,
            commandBuffer: command))
        XCTAssertTrue(head.encode(
            input: input, recordExposure: record, key: componentKey,
            inputGain: 0.91, gpuToneGrid: toneGrid,
            commandBuffer: command))
        XCTAssertTrue(measurements.encodeFlareMean(
            recordExposure: record, resources: flareResources,
            commandBuffer: command))
        XCTAssertTrue(spatial.encodeDevelopedDensity(
            recordExposure: record, densityOutput: density,
            key: componentKey, frameIndex: frameIndex,
            flareMean: flareMean, commandBuffer: command))
        XCTAssertTrue(tail.encodeTail(
            developedDensity: density, output: expected,
            key: componentKey, frameIndex: frameIndex,
            commandBuffer: command))
        XCTAssertTrue(harness.renderer.encodeSceneLinearRec2020RGBAFloat(
            sceneLinearRec2020RGBAFloat: input, output: actual,
            width: width, height: height, key: #function,
            inputGain: 0.91, frameIndex: frameIndex,
            commandBuffer: command))
        XCTAssertEqual(command.status, .notEnqueued)
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, "\(String(describing: command.error))")
        XCTAssertEqual(
            readRGBA16(actual), readRGBA16(expected),
            "the Float32 still entry must exactly compose the selected HDR components")
    }

    func testRejectsUnsupportedPreparationAndMalformedHDRTextures() throws {
        let harness = try Harness(maximumInFlightFrames: 1)
        var invalidStage = spatialOptions(grain: false)
        invalidStage.stage = .negative
        XCTAssertThrowsError(try harness.renderer.prepareChecked(
            key: #function + "-stage", stock: TestStocks.negative,
            options: invalidStage, frameWidth: 16, frameHeight: 12)) { error in
                guard case HandwrittenMetalFullFrameRenderer.PreparationError
                    .unsupportedPipelineStage = error else {
                    return XCTFail("unexpected stage error: \(error)")
                }
            }
        XCTAssertThrowsError(try harness.renderer.prepareChecked(
            key: #function + "-size", stock: TestStocks.negative,
            options: spatialOptions(grain: false),
            frameWidth: 0, frameHeight: 12))

        let width = 16
        let height = 12
        let key = #function + "-valid"
        XCTAssertTrue(harness.renderer.prepare(
            key: key, stock: TestStocks.negative,
            options: spatialOptions(grain: false),
            frameWidth: width, frameHeight: height))
        let input = try representativeX420(
            device: harness.device, width: width, height: height)
        let wrongOutput = try texture(
            device: harness.device, format: .bgra8Unorm,
            width: width, height: height,
            usage: [.shaderRead, .shaderWrite])
        let command = try XCTUnwrap(harness.queue.makeCommandBuffer())
        XCTAssertFalse(harness.renderer.encodeCapturedHDR(
            luma: input.luma, chroma: input.chroma, output: wrongOutput,
            width: width, height: height, key: key,
            transfer: .hlg, sceneScale: HLGSceneTransfer.headroom,
            commandBuffer: command))
        XCTAssertEqual(command.status, .notEnqueued)

        let output = try rgba16Texture(
            device: harness.device, width: width, height: height)
        XCTAssertFalse(harness.renderer.encodeCapturedHDR(
            luma: input.luma, chroma: input.chroma, output: output,
            width: width, height: height, key: key,
            transfer: .hlg, sceneScale: .nan,
            commandBuffer: command))
        XCTAssertFalse(harness.renderer.encodeCapturedHDR(
            luma: input.luma, chroma: input.chroma, output: output,
            width: width + 1, height: height, key: key,
            transfer: .hlg, sceneScale: HLGSceneTransfer.headroom,
            commandBuffer: command))

        let shortStill = try buffer(
            device: harness.device,
            values: [Float16](repeating: 0, count: width * height * 4))
        XCTAssertFalse(harness.renderer.encodeSceneLinearRec2020RGBAFloat(
            sceneLinearRec2020RGBAFloat: shortStill, output: output,
            width: width, height: height, key: key,
            commandBuffer: command),
            "the Float32 seam must reject an equally-sized RGBA16F allocation")
        let floatStill = try buffer(
            device: harness.device,
            values: representativeSceneLinearFloat(width: width, height: height))
        XCTAssertFalse(harness.renderer.encodeSceneLinearRec2020RGBAFloat(
            sceneLinearRec2020RGBAFloat: floatStill, output: wrongOutput,
            width: width, height: height, key: key,
            commandBuffer: command))
        XCTAssertFalse(harness.renderer.encodeSceneLinearRec2020RGBAFloat(
            sceneLinearRec2020RGBAFloat: floatStill, output: output,
            width: width, height: height, key: key, inputGain: .nan,
            commandBuffer: command))
        XCTAssertEqual(command.status, .notEnqueued)
    }

    func testFloat32StillResourcesOutliveInputAndRendererCleanup() throws {
        let harness = try Harness(maximumInFlightFrames: 1)
        let width = 22
        let height = 15
        var stock = TestStocks.negative
        stock.flare = 0.15
        var options = spatialOptions(grain: false)
        options.highlights = 0.25
        options.localTone = true
        options.flareScale = 1
        XCTAssertTrue(harness.renderer.prepare(
            key: #function, stock: stock, options: options,
            frameWidth: width, frameHeight: height))
        var input: MTLBuffer? = try buffer(
            device: harness.device,
            values: representativeSceneLinearFloat(width: width, height: height))
        let output = try rgba16Texture(
            device: harness.device, width: width, height: height)
        let command = try XCTUnwrap(harness.queue.makeCommandBuffer())
        XCTAssertTrue(harness.renderer.encodeSceneLinearRec2020RGBAFloat(
            sceneLinearRec2020RGBAFloat: try XCTUnwrap(input), output: output,
            width: width, height: height, key: #function,
            inputGain: 0.97, frameIndex: 42,
            commandBuffer: command))
        XCTAssertEqual(command.status, .notEnqueued)

        input = nil
        harness.renderer.removeAll()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, "\(String(describing: command.error))")
        let result = readRGBA16(output).map(Float.init)
        XCTAssertTrue(result.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(result.max() ?? 0, 0)
    }

    func testRemoveAllInvalidatesKeysButDoesNotBreakEncodedWork() throws {
        let harness = try Harness(maximumInFlightFrames: 1)
        let width = 20
        let height = 14
        let input = try representativeX420(
            device: harness.device, width: width, height: height)
        let output = try rgba16Texture(
            device: harness.device, width: width, height: height)
        XCTAssertTrue(harness.renderer.prepare(
            key: #function, stock: TestStocks.negative,
            options: spatialOptions(grain: false),
            frameWidth: width, frameHeight: height))
        let encoded = try XCTUnwrap(harness.queue.makeCommandBuffer())
        XCTAssertTrue(harness.renderer.encodeCapturedHDR(
            luma: input.luma, chroma: input.chroma, output: output,
            width: width, height: height, key: #function,
            transfer: .hlg, sceneScale: HLGSceneTransfer.headroom,
            commandBuffer: encoded))

        harness.renderer.removeAll()
        let rejected = try XCTUnwrap(harness.queue.makeCommandBuffer())
        XCTAssertFalse(harness.renderer.encodeCapturedHDR(
            luma: input.luma, chroma: input.chroma, output: output,
            width: width, height: height, key: #function,
            transfer: .hlg, sceneScale: HLGSceneTransfer.headroom,
            commandBuffer: rejected))
        XCTAssertEqual(rejected.status, .notEnqueued)

        encoded.commit()
        encoded.waitUntilCompleted()
        XCTAssertEqual(encoded.status, .completed, "\(String(describing: encoded.error))")
        XCTAssertTrue(readRGBA16(output).map(Float.init).allSatisfy(\.isFinite))
    }

    private struct Harness {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let renderer: HandwrittenMetalFullFrameRenderer

        init(maximumInFlightFrames: Int) throws {
            device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
            queue = try XCTUnwrap(device.makeCommandQueue())
            renderer = try XCTUnwrap(HandwrittenMetalFullFrameRenderer(
                device: device, maximumInFlightFrames: maximumInFlightFrames,
                spatialOptimizationVariant: .perceptualMultires))
        }
    }

    private struct X420 {
        let luma: MTLTexture
        let chroma: MTLTexture
    }

    private func spatialOptions(grain: Bool) -> FotufilmEngine.Options {
        var options = FotufilmEngine.Options()
        options.localTone = false
        options.flareScale = 0
        options.grainScale = grain ? 1 : 0
        options.format = Self.testFormat
        return options
    }

    private func screen(_ source: FotufilmEngine.Options) -> FotufilmEngine.Options {
        var result = source
        result.paper = .screen
        return result
    }

    private func representativeSceneLinearFloat(
        width: Int, height: Int
    ) -> [Float] {
        var result = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let checker: Float = ((x / 5 + y / 4) & 1) == 0 ? 0.028_713 : 2.417_31
                let detail = Float((x * 37 + y * 61) % 997) * 0.000_000_43
                result[offset] = checker * (0.67 + Float(x % 13) / 17) + detail
                result[offset + 1] = checker * (0.54 + Float(y % 11) / 15) + 0.5 * detail
                result[offset + 2] = checker
                    * (0.41 + Float((x + y) % 17) / 21) + 0.25 * detail
                result[offset + 3] = 1
            }
        }
        return result
    }

    private func representativeX420(
        device: MTLDevice, width: Int, height: Int
    ) throws -> X420 {
        let lumaCodes: [UInt16] = [
            64, 78, 96, 128, 176, 240, 320, 400,
            480, 560, 640, 720, 800, 864, 912, 940,
        ]
        return try x420(
            device: device, width: width, height: height,
            luma: { x, y in lumaCodes[(x + 3 * y) % lumaCodes.count] },
            chroma: { x, y in
                let u = UInt16(384 + (x * 37 + y * 19) % 256)
                let v = UInt16(384 + (x * 17 + y * 43) % 256)
                return SIMD2(u, v)
            })
    }

    private func x420(
        device: MTLDevice, width: Int, height: Int,
        luma: (Int, Int) -> UInt16,
        chroma: (Int, Int) -> SIMD2<UInt16>
    ) throws -> X420 {
        let lumaTexture = try texture(
            device: device, format: .r16Unorm,
            width: width, height: height, usage: .shaderRead)
        let chromaWidth = (width + 1) / 2
        let chromaHeight = (height + 1) / 2
        let chromaTexture = try texture(
            device: device, format: .rg16Unorm,
            width: chromaWidth, height: chromaHeight, usage: .shaderRead)
        var lumaWords = [UInt16](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                lumaWords[y * width + x] = luma(x, y) << 6
            }
        }
        var chromaWords = [UInt16](
            repeating: 0, count: chromaWidth * chromaHeight * 2)
        for y in 0..<chromaHeight {
            for x in 0..<chromaWidth {
                let value = chroma(x, y)
                let offset = (y * chromaWidth + x) * 2
                chromaWords[offset] = value.x << 6
                chromaWords[offset + 1] = value.y << 6
            }
        }
        writeWords(lumaWords, into: lumaTexture, components: 1)
        writeWords(chromaWords, into: chromaTexture, components: 2)
        return X420(luma: lumaTexture, chroma: chromaTexture)
    }

    private func texture(
        device: MTLDevice, format: MTLPixelFormat,
        width: Int, height: Int, usage: MTLTextureUsage
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height,
            mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = usage
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private func buffer<T>(device: MTLDevice, values: [T]) throws -> MTLBuffer {
        try values.withUnsafeBytes { bytes in
            try XCTUnwrap(device.makeBuffer(
                bytes: bytes.baseAddress!, length: bytes.count,
                options: .storageModeShared))
        }
    }

    private func rgba16Texture(
        device: MTLDevice, width: Int, height: Int,
        values: [Float16]? = nil
    ) throws -> MTLTexture {
        let texture = try texture(
            device: device, format: .rgba16Float,
            width: width, height: height,
            usage: [.shaderRead, .shaderWrite])
        if let values {
            values.withUnsafeBytes { bytes in
                texture.replace(
                    region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0, withBytes: bytes.baseAddress!,
                    bytesPerRow: width * 4 * MemoryLayout<Float16>.stride)
            }
        }
        return texture
    }

    private func writeWords(
        _ values: [UInt16], into texture: MTLTexture, components: Int
    ) {
        values.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0, withBytes: bytes.baseAddress!,
                bytesPerRow: texture.width * components * MemoryLayout<UInt16>.stride)
        }
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

    private func render(
        renderer: HandwrittenMetalFullFrameRenderer,
        queue: MTLCommandQueue, input: X420, output: MTLTexture,
        key: String, transfer: HandwrittenMetalFullFrameRenderer.HDRCaptureTransfer,
        sceneScale: Float, frameIndex: UInt64
    ) throws {
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(renderer.encodeCapturedHDR(
            luma: input.luma, chroma: input.chroma, output: output,
            width: output.width, height: output.height, key: key,
            transfer: transfer, sceneScale: sceneScale,
            frameIndex: frameIndex, commandBuffer: command))
        XCTAssertEqual(command.status, .notEnqueued)
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, "\(String(describing: command.error))")
    }
}
#endif
