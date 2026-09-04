#if canImport(Metal)
import XCTest
@testable import FotufilmCore
import FotufilmMetal
import Metal

final class HandwrittenMetalNativeEightBitIngestTests: XCTestCase {
    private enum CaptureRange: CaseIterable {
        case video
        case full

        var head: HandwrittenMetalSpectralHead.SDRCaptureRange {
            self == .video ? .video : .full
        }

        var measurement: HandwrittenMetalGlobalMeasurements.SDRCaptureRange {
            self == .video ? .video : .full
        }

        var renderer: HandwrittenMetalFullFrameRenderer.SDRCaptureRange {
            self == .video ? .video : .full
        }
    }

    private enum CaptureGamut: CaseIterable {
        case sRGB
        case displayP3

        var head: HandwrittenMetalSpectralHead.SDRCaptureGamut {
            self == .sRGB ? .sRGB : .displayP3
        }

        var measurement: HandwrittenMetalGlobalMeasurements.SDRCaptureGamut {
            self == .sRGB ? .sRGB : .displayP3
        }

        var renderer: HandwrittenMetalFullFrameRenderer.SDRCaptureGamut {
            self == .sRGB ? .sRGB : .displayP3
        }
    }

    private struct NativeFrame {
        let luma: MTLTexture
        let chroma: MTLTexture
        let lumaCodes: [UInt8]
        let chromaCode: SIMD2<UInt8>
    }

    func testNative420fAnd420vDecodeMatchesSceneLinearSpectralInputForBothGamuts() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let head = try XCTUnwrap(HandwrittenMetalSpectralHead(device: device))
        let width = 31
        let height = 9
        let invocation = FilmEngineInvocation(
            stock: TestStocks.negative, options: neutralOptions(),
            width: width, height: height)
        try head.prepareChecked(
            key: #function + "-native", invocation: invocation,
            mode: .encodedDisplayP3RGBA8,
            frameWidth: width, frameHeight: height)
        try head.prepareChecked(
            key: #function + "-linear", invocation: invocation,
            mode: .linearRec2020RGBA32Float,
            frameWidth: width, frameHeight: height)

        for range in CaptureRange.allCases {
            for gamut in CaptureGamut.allCases {
                let native = try makeNativeFrame(
                    device: device, width: width, height: height,
                    range: range, gamut: gamut)
                let linear = decodedScene(
                    native, range: range, gamut: gamut)
                let linearInput = try buffer(device: device, values: linear)
                let nativeOutput = try rgba16Texture(
                    device: device, width: width, height: height)
                let linearOutput = try rgba16Texture(
                    device: device, width: width, height: height)
                let inputGain: Float = 0.913

                let nativeCommand = try XCTUnwrap(queue.makeCommandBuffer())
                XCTAssertTrue(head.encodeCapturedSDR(
                    luma: native.luma, chroma: native.chroma,
                    recordExposure: nativeOutput, key: #function + "-native",
                    range: range.head, gamut: gamut.head,
                    inputGain: inputGain, commandBuffer: nativeCommand))
                nativeCommand.commit()
                nativeCommand.waitUntilCompleted()
                XCTAssertEqual(
                    nativeCommand.status, .completed,
                    "\(range)/\(gamut): \(String(describing: nativeCommand.error))")

                let linearCommand = try XCTUnwrap(queue.makeCommandBuffer())
                XCTAssertTrue(head.encode(
                    input: linearInput, recordExposure: linearOutput,
                    key: #function + "-linear", inputGain: inputGain,
                    commandBuffer: linearCommand))
                linearCommand.commit()
                linearCommand.waitUntilCompleted()
                XCTAssertEqual(
                    linearCommand.status, .completed,
                    "\(range)/\(gamut): \(String(describing: linearCommand.error))")

                assertHalfParity(
                    readRGBA16(nativeOutput), readRGBA16(linearOutput),
                    maximum: 0.02, mean: 0.0008,
                    context: "\(range)/\(gamut) native decode")
            }
        }
    }

    func testNative420fAnd420vToneSolveMatchesTheDecodedScene() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let measurements = try XCTUnwrap(
            HandwrittenMetalGlobalMeasurements(device: device))
        let width = 127
        let height = 71
        var options = neutralOptions()
        options.localTone = true
        options.highlights = 0.51
        options.shadows = -0.34
        let invocation = FilmEngineInvocation(
            stock: TestStocks.negative, options: options,
            width: width, height: height)
        let inputGain: Float = 0.927

        for range in CaptureRange.allCases {
            for gamut in CaptureGamut.allCases {
                let native = try makeNativeFrame(
                    device: device, width: width, height: height,
                    range: range, gamut: gamut)
                let linearInput = try buffer(
                    device: device,
                    values: decodedScene(native, range: range, gamut: gamut))
                let nativeResources = try measurements.makeResources(
                    invocation: invocation, mode: .encodedDisplayP3RGBA8,
                    frameWidth: width, frameHeight: height)
                let linearResources = try measurements.makeResources(
                    invocation: invocation, mode: .linearRec2020RGBA32Float,
                    frameWidth: width, frameHeight: height)
                let nativeGrid = try XCTUnwrap(nativeResources.toneGrid)
                let linearGrid = try XCTUnwrap(linearResources.toneGrid)
                let nativeValues = try readPrivateFloats(
                    queue: queue, source: nativeGrid.buffer,
                    count: 2 * nativeGrid.cellCount
                ) { command in
                    measurements.encodeToneBase(
                        luma: native.luma, chroma: native.chroma,
                        range: range.measurement, gamut: gamut.measurement,
                        inputGain: inputGain, resources: nativeResources,
                        commandBuffer: command)
                }
                let linearValues = try readPrivateFloats(
                    queue: queue, source: linearGrid.buffer,
                    count: 2 * linearGrid.cellCount
                ) { command in
                    measurements.encodeToneBase(
                        input: linearInput, inputGain: inputGain,
                        resources: linearResources, commandBuffer: command)
                }
                assertFloatParity(
                    nativeValues, linearValues, maximum: 3e-4,
                    context: "\(range)/\(gamut) tone solve")
            }
        }
    }

    func testNativeEightBitInputMatchesSceneLinearThroughTheFullSpatialGraph() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let renderer = try XCTUnwrap(HandwrittenMetalFullFrameRenderer(
            device: device, maximumInFlightFrames: 1,
            spatialOptimizationVariant: .perceptualMultires))
        let width = 32
        let height = 20
        var stock = TestStocks.negative
        stock.flare = max(stock.flare, 0.12)
        var options = neutralOptions()
        options.format = FilmFormat(
            name: "Native eight-bit full-graph parity", frameHeightMM: 0.8)
        options.localTone = true
        options.highlights = 0.36
        options.shadows = -0.21
        options.flareScale = 1
        options.halationScale = 1
        options.couplerScale = 1
        XCTAssertTrue(renderer.prepare(
            key: #function, stock: stock, options: options,
            frameWidth: width, frameHeight: height))

        for range in CaptureRange.allCases {
            for gamut in CaptureGamut.allCases {
                let native = try makeNativeFrame(
                    device: device, width: width, height: height,
                    range: range, gamut: gamut)
                let linearInput = try buffer(
                    device: device,
                    values: decodedScene(native, range: range, gamut: gamut))
                let nativeOutput = try rgba16Texture(
                    device: device, width: width, height: height)
                let linearOutput = try rgba16Texture(
                    device: device, width: width, height: height)
                let inputGain: Float = 0.947
                let frameIndex: UInt64 = 0x820

                let nativeCommand = try XCTUnwrap(queue.makeCommandBuffer())
                XCTAssertTrue(renderer.encodeCapturedSDR(
                    luma: native.luma, chroma: native.chroma,
                    output: nativeOutput, width: width, height: height,
                    key: #function, range: range.renderer,
                    gamut: gamut.renderer, inputGain: inputGain,
                    frameIndex: frameIndex, commandBuffer: nativeCommand))
                nativeCommand.commit()
                nativeCommand.waitUntilCompleted()
                XCTAssertEqual(
                    nativeCommand.status, .completed,
                    "\(range)/\(gamut): \(String(describing: nativeCommand.error))")

                let linearCommand = try XCTUnwrap(queue.makeCommandBuffer())
                XCTAssertTrue(renderer.encodeSceneLinearRec2020RGBAFloat(
                    sceneLinearRec2020RGBAFloat: linearInput,
                    output: linearOutput, width: width, height: height,
                    key: #function, inputGain: inputGain,
                    frameIndex: frameIndex, commandBuffer: linearCommand))
                linearCommand.commit()
                linearCommand.waitUntilCompleted()
                XCTAssertEqual(
                    linearCommand.status, .completed,
                    "\(range)/\(gamut): \(String(describing: linearCommand.error))")

                assertHalfParity(
                    readRGBA16(nativeOutput), readRGBA16(linearOutput),
                    maximum: 0.03, mean: 0.001,
                    context: "\(range)/\(gamut) full graph")
            }
        }
    }

    func testNoFilmPassThroughPublishesTheNativeSceneAsLinearDisplayP3() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let passThrough = try XCTUnwrap(
            HandwrittenMetalCameraPassThrough(device: device))
        let width = 32
        let height = 18

        for range in CaptureRange.allCases {
            for gamut in CaptureGamut.allCases {
                let native = try makeNativeFrame(
                    device: device, width: width, height: height,
                    range: range, gamut: gamut)
                let output = try rgba16Texture(
                    device: device, width: width, height: height)
                let command = try XCTUnwrap(queue.makeCommandBuffer())
                XCTAssertTrue(passThrough.encodeCapturedSDR(
                    luma: native.luma, chroma: native.chroma, output: output,
                    width: width, height: height, range: range.head,
                    gamut: gamut.head, commandBuffer: command))
                command.commit()
                command.waitUntilCompleted()
                XCTAssertEqual(command.status, .completed,
                               "\(String(describing: command.error))")

                let scene = decodedScene(native, range: range, gamut: gamut)
                var expected: [Float16] = []
                expected.reserveCapacity(scene.count)
                for offset in stride(from: 0, to: scene.count, by: 4) {
                    let p3 = ColorScience.linearRec2020ToDisplayP3(SIMD3(
                        scene[offset], scene[offset + 1], scene[offset + 2]))
                    expected.append(contentsOf: [
                        Float16(p3.x), Float16(p3.y), Float16(p3.z), 1,
                    ])
                }
                assertHalfParity(
                    readRGBA16(output), expected,
                    maximum: 0.002, mean: 0.0002,
                    context: "\(range)/\(gamut) no-film pass-through")
            }
        }
    }

    func testNoFilmPassThroughPreservesDeepHLGSceneLight() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let passThrough = try XCTUnwrap(
            HandwrittenMetalCameraPassThrough(device: device))
        let width = 16
        let height = 8
        let lumaCode: UInt16 = 512
        let neutralCode: UInt16 = 512
        let luma = try inputTexture(
            device: device, format: .r16Unorm,
            width: width, height: height)
        let chroma = try inputTexture(
            device: device, format: .rg16Unorm,
            width: width / 2, height: height / 2)
        writeWords(
            [UInt16](repeating: lumaCode << 6, count: width * height),
            into: luma, components: 1)
        writeWords(
            [UInt16](repeating: neutralCode << 6,
                     count: width * height / 2),
            into: chroma, components: 2)
        let output = try rgba16Texture(
            device: device, width: width, height: height)
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(passThrough.encodeCapturedHDR(
            luma: luma, chroma: chroma, output: output,
            width: width, height: height, transfer: .hlg,
            sceneScale: HLGSceneTransfer.headroom,
            commandBuffer: command))
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed,
                       "\(String(describing: command.error))")

        let signal = (Float(lumaCode) - 64) / 876
        let open = signal <= 0.5
            ? signal * signal / 3
            : (exp((signal - 0.55991073) / 0.17883277) + 0.28466892) / 12
        let expected = open * HLGSceneTransfer.headroom
        let result = readRGBA16(output).map(Float.init)
        for offset in stride(from: 0, to: result.count, by: 4) {
            XCTAssertEqual(result[offset], expected, accuracy: 0.002)
            XCTAssertEqual(result[offset + 1], expected, accuracy: 0.002)
            XCTAssertEqual(result[offset + 2], expected, accuracy: 0.002)
            XCTAssertEqual(result[offset + 3], 1, accuracy: 0.0001)
        }
    }

    private func neutralOptions() -> FotufilmEngine.Options {
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        options.flareScale = 0
        options.halationScale = 0
        options.couplerScale = 0
        options.localTone = false
        options.sceneHeadroom = 1
        return options
    }

    private func makeNativeFrame(
        device: MTLDevice, width: Int, height: Int,
        range: CaptureRange, gamut: CaptureGamut
    ) throws -> NativeFrame {
        let bounds = range == .video ? (16, 235) : (0, 255)
        let span = bounds.1 - bounds.0 + 1
        let seed = gamut == .sRGB ? 17 : 53
        var lumaCodes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                lumaCodes[y * width + x] = UInt8(
                    bounds.0 + (x * 37 + y * 61 + seed) % span)
            }
        }
        let chromaCode: SIMD2<UInt8>
        switch (range, gamut) {
        case (.video, .sRGB): chromaCode = SIMD2(184, 88)
        case (.video, .displayP3): chromaCode = SIMD2(72, 196)
        case (.full, .sRGB): chromaCode = SIMD2(200, 56)
        case (.full, .displayP3): chromaCode = SIMD2(40, 216)
        }
        let chromaWidth = (width + 1) / 2
        let chromaHeight = (height + 1) / 2
        let chromaCodes = (0..<(chromaWidth * chromaHeight)).flatMap { _ in
            [chromaCode.x, chromaCode.y]
        }
        let luma = try inputTexture(
            device: device, format: .r8Unorm,
            width: width, height: height)
        let chroma = try inputTexture(
            device: device, format: .rg8Unorm,
            width: chromaWidth, height: chromaHeight)
        writeBytes(lumaCodes, into: luma, components: 1)
        writeBytes(chromaCodes, into: chroma, components: 2)
        return NativeFrame(
            luma: luma, chroma: chroma,
            lumaCodes: lumaCodes, chromaCode: chromaCode)
    }

    /// CPU spelling of the Metal include, including its half-float 256-sample transfer table.
    private func decodedScene(
        _ frame: NativeFrame, range: CaptureRange, gamut: CaptureGamut
    ) -> [Float] {
        let fullRange = range == .full
        let u = (Float(frame.chromaCode.x) - 128) / (fullRange ? 255 : 224)
        let v = (Float(frame.chromaCode.y) - 128) / (fullRange ? 255 : 224)
        return frame.lumaCodes.flatMap { code -> [Float] in
            let y = fullRange
                ? Float(code) / 255
                : (Float(code) - 16) / 219
            let signal = SIMD3<Float>(
                y + 1.5748 * v,
                y - 0.187324 * u - 0.468124 * v,
                y + 1.8556 * u)
            let linear = SIMD3(
                decodeTable(signal.x), decodeTable(signal.y),
                decodeTable(signal.z))
            let mapped = gamut == .sRGB
                ? ColorScience.linearSRGBToRec2020(linear)
                : ColorScience.linearDisplayP3ToRec2020(linear)
            return [max(mapped.x, 0), max(mapped.y, 0), max(mapped.z, 0), 1]
        }
    }

    private func decodeTable(_ signal: Float) -> Float {
        let clamped = min(max(signal, 0), 1)
        let q = clamped * 255
        let lower = min(Int(q), 255)
        let upper = min(lower + 1, 255)
        let low = Float(Float16(ColorScience.srgbToLinear(Float(lower) / 255)))
        let high = Float(Float16(ColorScience.srgbToLinear(Float(upper) / 255)))
        return low + (high - low) * (q - Float(lower))
    }

    private func inputTexture(
        device: MTLDevice, format: MTLPixelFormat,
        width: Int, height: Int
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private func rgba16Texture(
        device: MTLDevice, width: Int, height: Int
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height,
            mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private func writeBytes(
        _ values: [UInt8], into texture: MTLTexture, components: Int
    ) {
        values.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0, withBytes: bytes.baseAddress!,
                bytesPerRow: texture.width * components)
        }
    }

    private func writeWords(
        _ values: [UInt16], into texture: MTLTexture, components: Int
    ) {
        values.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0, withBytes: bytes.baseAddress!,
                bytesPerRow: texture.width * components
                    * MemoryLayout<UInt16>.stride)
        }
    }

    private func buffer<T>(device: MTLDevice, values: [T]) throws -> MTLBuffer {
        try values.withUnsafeBytes { bytes in
            try XCTUnwrap(device.makeBuffer(
                bytes: bytes.baseAddress!, length: bytes.count,
                options: .storageModeShared))
        }
    }

    private func readRGBA16(_ texture: MTLTexture) -> [Float16] {
        var values = [Float16](
            repeating: 0, count: texture.width * texture.height * 4)
        values.withUnsafeMutableBytes { bytes in
            texture.getBytes(
                bytes.baseAddress!,
                bytesPerRow: texture.width * 4 * MemoryLayout<Float16>.stride,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0)
        }
        return values
    }

    private func readPrivateFloats(
        queue: MTLCommandQueue, source: MTLBuffer, count: Int,
        encode: (MTLCommandBuffer) -> Bool
    ) throws -> [Float] {
        let length = count * MemoryLayout<Float>.stride
        let destination = try XCTUnwrap(queue.device.makeBuffer(
            length: length, options: .storageModeShared))
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(encode(command))
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(
            from: source, sourceOffset: 0,
            to: destination, destinationOffset: 0, size: length)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(
            command.status, .completed, "\(String(describing: command.error))")
        return Array(UnsafeBufferPointer(
            start: destination.contents().assumingMemoryBound(to: Float.self),
            count: count))
    }

    private func assertHalfParity(
        _ actual: [Float16], _ expected: [Float16],
        maximum: Float, mean: Float, context: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        assertFloatParity(
            actual.map(Float.init), expected.map(Float.init),
            maximum: maximum, mean: mean, context: context,
            file: file, line: line)
    }

    private func assertFloatParity(
        _ actual: [Float], _ expected: [Float],
        maximum: Float, mean: Float = .greatestFiniteMagnitude,
        context: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        var largest: Float = 0
        var total: Double = 0
        for index in actual.indices {
            let error = abs(actual[index] - expected[index])
            largest = max(largest, error)
            total += Double(error)
        }
        let average = Float(total / Double(max(actual.count, 1)))
        XCTAssertLessThanOrEqual(
            largest, maximum, "\(context): max=\(largest), mean=\(average)",
            file: file, line: line)
        XCTAssertLessThanOrEqual(
            average, mean, "\(context): max=\(largest), mean=\(average)",
            file: file, line: line)
    }
}
#endif
