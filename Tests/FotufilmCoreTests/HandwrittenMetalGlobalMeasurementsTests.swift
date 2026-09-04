#if canImport(Metal)
import XCTest
@testable import FotufilmCore
import FotufilmMetal
import Metal

final class HandwrittenMetalGlobalMeasurementsTests: XCTestCase {
    private static let device = MTLCreateSystemDefaultDevice()
    private static let measurements = device.flatMap(
        HandwrittenMetalGlobalMeasurements.init(device:))
    private static let queue = device?.makeCommandQueue()

    func testSDRToneGridMatchesCPUAndResourceReuseIsDeterministic() throws {
        let device = try XCTUnwrap(Self.device)
        let measurements = try XCTUnwrap(Self.measurements)
        let queue = try XCTUnwrap(Self.queue)
        let width = 131
        let height = 73
        let invocation = toneInvocation(width: width, height: height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let alphas: [UInt8] = [0, 37, 128, 219, 255]
        for y in 0..<height {
            for x in 0..<width {
                let base = (y * width + x) * 4
                let alpha = alphas[(x + 3 * y) % alphas.count]
                bytes[base + 3] = alpha
                if alpha > 0 && alpha < 255 {
                    bytes[base] = UInt8((x * 17 + y * 7) % (Int(alpha) + 1))
                    bytes[base + 1] = UInt8((x * 5 + y * 19) % (Int(alpha) + 1))
                    bytes[base + 2] = UInt8((x * 23 + y * 3) % (Int(alpha) + 1))
                } else {
                    bytes[base] = UInt8((x * 17 + y * 7) & 255)
                    bytes[base + 1] = UInt8((x * 5 + y * 19) & 255)
                    bytes[base + 2] = UInt8((x * 23 + y * 3) & 255)
                }
            }
        }
        let input = try buffer(device: device, values: bytes)
        let resources = try measurements.makeResources(
            invocation: invocation, mode: .encodedDisplayP3RGBA8,
            frameWidth: width, frameHeight: height)
        let grid = try XCTUnwrap(resources.toneGrid)
        XCTAssertEqual(grid.buffer.storageMode, .private)

        var reference = invocation.toneBaseMeasurement()
        bytes.withUnsafeBufferPointer {
            reference.add(encodedDisplayP3RGBA: $0.baseAddress!, rows: 0..<height)
        }
        let expected = reference.solvedCoefficients()
        let first = try readPrivateFloats(
            queue: queue, source: grid.buffer, count: 2 * grid.cellCount
        ) { command in
            measurements.encodeToneBase(
                input: input, resources: resources, commandBuffer: command)
        }
        XCTAssertEqual(grid.width, reference.gridWidth)
        XCTAssertEqual(grid.height, reference.gridHeight)
        assertGrid(first, expected: expected, cells: grid.cellCount, accuracy: 7e-4)

        let repeated = try readPrivateFloats(
            queue: queue, source: grid.buffer, count: 2 * grid.cellCount
        ) { command in
            measurements.encodeToneBase(
                input: input, resources: resources, commandBuffer: command)
        }
        XCTAssertEqual(first.map(\.bitPattern), repeated.map(\.bitPattern))
    }

    func testHDRToneGridMatchesCPUReferenceAfterHalfQuantization() throws {
        let device = try XCTUnwrap(Self.device)
        let measurements = try XCTUnwrap(Self.measurements)
        let queue = try XCTUnwrap(Self.queue)
        let width = 79
        let height = 113
        let invocation = toneInvocation(width: width, height: height)
        var half = [Float16](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let base = (y * width + x) * 4
                let ramp = exp2(Float(x) / 15 - 3) * (0.7 + Float(y) / 90)
                half[base] = Float16(ramp * (Float((x + y) % 9) / 10 - 0.12))
                half[base + 1] = Float16(ramp)
                half[base + 2] = Float16(ramp * (0.25 + Float(y % 13) / 8))
                half[base + 3] = Float16(Float((x + 2 * y) % 11) / 10)
            }
        }
        let input = try buffer(device: device, values: half)
        let resources = try measurements.makeResources(
            invocation: invocation, mode: .linearRec2020RGBA16Float,
            frameWidth: width, frameHeight: height)
        let grid = try XCTUnwrap(resources.toneGrid)
        let quantized = half.map(Float.init)
        var reference = invocation.toneBaseMeasurement()
        quantized.withUnsafeBufferPointer {
            reference.add(linearRGBA: $0.baseAddress!, rows: 0..<height)
        }
        let expected = reference.solvedCoefficients()
        let actual = try readPrivateFloats(
            queue: queue, source: grid.buffer, count: 2 * grid.cellCount
        ) { command in
            measurements.encodeToneBase(
                input: input, resources: resources, commandBuffer: command)
        }
        assertGrid(actual, expected: expected, cells: grid.cellCount, accuracy: 7e-4)
    }

    func testFloat32HDRToneGridMatchesUnquantizedCPUReference() throws {
        let device = try XCTUnwrap(Self.device)
        let measurements = try XCTUnwrap(Self.measurements)
        let queue = try XCTUnwrap(Self.queue)
        let width = 83
        let height = 57
        let invocation = toneInvocation(width: width, height: height)
        var values = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let base = (y * width + x) * 4
                let detail = Float((x * 37 + y * 19) % 997) * 0.000_000_37
                let ramp = exp2(Float(x) / 14 - 3) * (0.65 + Float(y) / 77)
                values[base] = ramp * (0.07 + Float((x + y) % 11) / 12) + detail
                values[base + 1] = ramp + 0.5 * detail
                values[base + 2] = ramp * (0.2 + Float(y % 17) / 9) + 0.25 * detail
                values[base + 3] = Float((x + 2 * y) % 13) / 12
            }
        }
        let input = try buffer(device: device, values: values)
        let resources = try measurements.makeResources(
            invocation: invocation, mode: .linearRec2020RGBA32Float,
            frameWidth: width, frameHeight: height)
        let grid = try XCTUnwrap(resources.toneGrid)
        let inputGain: Float = 0.913
        var gained = values
        for offset in stride(from: 0, to: gained.count, by: 4) {
            gained[offset] *= inputGain
            gained[offset + 1] *= inputGain
            gained[offset + 2] *= inputGain
        }
        var reference = invocation.toneBaseMeasurement()
        gained.withUnsafeBufferPointer {
            reference.add(linearRGBA: $0.baseAddress!, rows: 0..<height)
        }
        let expected = reference.solvedCoefficients()
        let actual = try readPrivateFloats(
            queue: queue, source: grid.buffer, count: 2 * grid.cellCount
        ) { command in
            measurements.encodeToneBase(
                input: input, inputGain: inputGain,
                resources: resources, commandBuffer: command)
        }
        assertGrid(actual, expected: expected, cells: grid.cellCount, accuracy: 7e-4)

        let halfValues = values.map(Float16.init)
        let shortInput = try buffer(device: device, values: halfValues)
        let rejected = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertFalse(measurements.encodeToneBase(
            input: shortInput, resources: resources,
            commandBuffer: rejected))
        XCTAssertEqual(rejected.status, .notEnqueued)
    }

    func testX420HLGAndAppleLogToneSolveMatchesDecodedLinearHalf() throws {
        let device = try XCTUnwrap(Self.device)
        let measurements = try XCTUnwrap(Self.measurements)
        let queue = try XCTUnwrap(Self.queue)
        let width = 127
        let height = 71
        let invocation = toneInvocation(width: width, height: height)
        let lumaCodes: [UInt16] = [
            64, 78, 96, 128, 176, 240, 320, 400,
            480, 560, 640, 720, 800, 864, 912, 940,
        ]
        var lumaWords = [UInt16](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                lumaWords[y * width + x] = lumaCodes[(x + 3 * y) % lumaCodes.count] << 6
            }
        }
        let chromaCode = SIMD2<UInt16>(574, 438)
        let chromaWidth = (width + 1) / 2
        let chromaHeight = (height + 1) / 2
        let chromaWords: [UInt16] = (0..<(chromaWidth * chromaHeight)).flatMap { _ in
            [chromaCode.x << 6, chromaCode.y << 6]
        }
        let luma = try makeTexture(
            device: device, format: .r16Unorm, width: width, height: height)
        let chroma = try makeTexture(
            device: device, format: .rg16Unorm,
            width: chromaWidth, height: chromaHeight)
        writeWords(lumaWords, into: luma, components: 1)
        writeWords(chromaWords, into: chroma, components: 2)

        for transfer in [
            HandwrittenMetalGlobalMeasurements.HDRCaptureTransfer.hlg,
            .appleLog,
        ] {
            let sceneScale: Float = transfer == .hlg
                ? HLGSceneTransfer.headroom : AppleLogCurve.sceneScale
            let inputGain: Float = 0.91
            var decoded = [Float16](repeating: 1, count: width * height * 4)
            let u = (Float(chromaCode.x) - 512) / 896
            let v = (Float(chromaCode.y) - 512) / 896
            for index in 0..<(width * height) {
                let y = (Float(lumaWords[index] >> 6) - 64) / 876
                let signal = SIMD3(
                    y + 1.4746 * v,
                    y - 0.164553 * u - 0.571353 * v,
                    y + 1.8814 * u)
                let scene = SIMD3<Float>(
                    captureSceneLight(signal.x, transfer: transfer),
                    captureSceneLight(signal.y, transfer: transfer),
                    captureSceneLight(signal.z, transfer: transfer))
                let working = scene * (sceneScale * inputGain)
                let base = index * 4
                decoded[base] = Float16(max(working.x, 0))
                decoded[base + 1] = Float16(max(working.y, 0))
                decoded[base + 2] = Float16(max(working.z, 0))
            }
            let decodedBuffer = try buffer(device: device, values: decoded)
            let textureResources = try measurements.makeResources(
                invocation: invocation, mode: .linearRec2020RGBA16Float,
                frameWidth: width, frameHeight: height)
            let decodedResources = try measurements.makeResources(
                invocation: invocation, mode: .linearRec2020RGBA16Float,
                frameWidth: width, frameHeight: height)
            let textureGrid = try XCTUnwrap(textureResources.toneGrid)
            let decodedGrid = try XCTUnwrap(decodedResources.toneGrid)
            let textureResult = try readPrivateFloats(
                queue: queue, source: textureGrid.buffer,
                count: 2 * textureGrid.cellCount
            ) { command in
                measurements.encodeToneBase(
                    luma: luma, chroma: chroma, transfer: transfer,
                    sceneScale: sceneScale, inputGain: inputGain,
                    resources: textureResources, commandBuffer: command)
            }
            let decodedResult = try readPrivateFloats(
                queue: queue, source: decodedGrid.buffer,
                count: 2 * decodedGrid.cellCount
            ) { command in
                measurements.encodeToneBase(
                    input: decodedBuffer, resources: decodedResources,
                    commandBuffer: command)
            }
            assertValues(
                textureResult, decodedResult, accuracy: 5e-4,
                context: "\(transfer) x420 versus decoded Rec.2020 half")
        }
    }

    func testFlareMeanUsesEveryPixelAndIsDeterministicAcrossReuse() throws {
        let device = try XCTUnwrap(Self.device)
        let measurements = try XCTUnwrap(Self.measurements)
        let queue = try XCTUnwrap(Self.queue)
        let width = 67
        let height = 35
        let invocation = flareInvocation(width: width, height: height)
        let resources = try measurements.makeResources(
            invocation: invocation, mode: .encodedDisplayP3RGBA8,
            frameWidth: width, frameHeight: height)
        let result = try XCTUnwrap(resources.flareMean)
        XCTAssertEqual(result.buffer.storageMode, .private)
        XCTAssertEqual(result.width, width)
        XCTAssertEqual(result.height, height)
        XCTAssertEqual(result.byteCount, MemoryLayout<SIMD4<Float>>.stride)
        XCTAssertTrue(result.isCompatible(
            with: device, frameWidth: width, frameHeight: height))
        XCTAssertFalse(result.isCompatible(
            with: device, frameWidth: width + 1, frameHeight: height))
        let texture = try makeTexture(
            device: device, format: .rgba16Float, width: width, height: height)
        var pixels = [Float16](repeating: 0, count: width * height * 4)
        var expected = SIMD3<Double>.zero
        for y in 0..<height {
            for x in 0..<width {
                let base = (y * width + x) * 4
                pixels[base] = Float16(Float((x * 3 + y) % 29) / 11)
                pixels[base + 1] = Float16(Float((x + y * 5) % 31) / 13)
                pixels[base + 2] = Float16(Float((x * 7 + y * 2) % 37) / 17)
                pixels[base + 3] = Float16(Float((x + y) % 5) / 4)
                expected += SIMD3(
                    Double(pixels[base]), Double(pixels[base + 1]),
                    Double(pixels[base + 2]))
            }
        }
        expected /= Double(width * height)
        writeHalfTexture(pixels, into: texture)

        let first = try readPrivateFloats(
            queue: queue, source: result.buffer, count: 4
        ) { command in
            measurements.encodeFlareMean(
                recordExposure: texture, resources: resources, commandBuffer: command)
        }
        for channel in 0..<3 {
            XCTAssertEqual(Double(first[channel]), expected[channel], accuracy: 3e-6,
                           "flare channel \(channel)")
        }
        XCTAssertEqual(first[3], 1)

        let repeated = try readPrivateFloats(
            queue: queue, source: result.buffer, count: 4
        ) { command in
            measurements.encodeFlareMean(
                recordExposure: texture, resources: resources, commandBuffer: command)
        }
        XCTAssertEqual(first.map(\.bitPattern), repeated.map(\.bitPattern))
    }

    func testHDRFlareReadsFloatRecordExposureWithoutQuantizing() throws {
        let device = try XCTUnwrap(Self.device)
        let measurements = try XCTUnwrap(Self.measurements)
        let queue = try XCTUnwrap(Self.queue)
        let width = 19
        let height = 23
        let invocation = flareInvocation(width: width, height: height)
        let resources = try measurements.makeResources(
            invocation: invocation, mode: .linearRec2020RGBA16Float,
            frameWidth: width, frameHeight: height)
        let result = try XCTUnwrap(resources.flareMean)
        let texture = try makeTexture(
            device: device, format: .rgba32Float, width: width, height: height)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        var expected = SIMD3<Double>.zero
        for index in 0..<(width * height) {
            let base = index * 4
            pixels[base] = Float(index % 17) * 0.03125 + 0.000_123
            pixels[base + 1] = Float(index % 23) * 0.0625 + 0.000_257
            pixels[base + 2] = Float(index % 31) * 0.125 + 0.000_509
            pixels[base + 3] = 1
            expected += SIMD3(
                Double(pixels[base]), Double(pixels[base + 1]),
                Double(pixels[base + 2]))
        }
        expected /= Double(width * height)
        writeFloatTexture(pixels, into: texture)
        let actual = try readPrivateFloats(
            queue: queue, source: result.buffer, count: 4
        ) { command in
            measurements.encodeFlareMean(
                recordExposure: texture, resources: resources, commandBuffer: command)
        }
        for channel in 0..<3 {
            XCTAssertEqual(Double(actual[channel]), expected[channel], accuracy: 3e-6,
                           "HDR flare channel \(channel)")
        }
    }

    func testInactiveResourcesEncodeAsNoOpWithNoInputs() throws {
        let measurements = try XCTUnwrap(Self.measurements)
        let queue = try XCTUnwrap(Self.queue)
        let width = 17
        let height = 9
        var stock = TestStocks.negative
        stock.flare = 0
        var options = FotufilmEngine.Options()
        options.flareScale = 0
        options.localTone = false
        let invocation = FilmEngineInvocation(
            stock: stock, options: options, width: width, height: height)
        XCTAssertEqual(invocation.featureMask & FilmEngineFeature.flare, 0)
        let resources = try measurements.makeResources(
            invocation: invocation, mode: .encodedDisplayP3RGBA8,
            frameWidth: width, frameHeight: height)
        XCTAssertTrue(resources.isInactive)
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(measurements.encodeToneBase(
            input: nil, resources: resources, commandBuffer: command))
        XCTAssertTrue(measurements.encodeToneBase(
            luma: nil, chroma: nil, transfer: .hlg,
            sceneScale: HLGSceneTransfer.headroom,
            resources: resources, commandBuffer: command))
        XCTAssertTrue(measurements.encodeFlareMean(
            recordExposure: nil, resources: resources, commandBuffer: command))
        XCTAssertEqual(command.status, .notEnqueued)
    }

    private func toneInvocation(width: Int, height: Int) -> FilmEngineInvocation {
        var stock = TestStocks.negative
        stock.flare = 0
        var options = FotufilmEngine.Options()
        options.localTone = true
        options.highlights = 0.63
        options.shadows = -0.41
        options.exposureEV = 0.37
        options.whiteBalance = .init(kelvin: 4_800, tint: 11)
        options.flareScale = 0
        return FilmEngineInvocation(
            stock: stock, options: options, width: width, height: height)
    }

    private func flareInvocation(width: Int, height: Int) -> FilmEngineInvocation {
        var stock = TestStocks.negative
        stock.flare = max(stock.flare, 0.01)
        var options = FotufilmEngine.Options()
        options.localTone = false
        options.flareScale = 1
        return FilmEngineInvocation(
            stock: stock, options: options, width: width, height: height)
    }

    private func assertGrid(
        _ actual: [Float], expected: (a: [Float], b: [Float]),
        cells: Int, accuracy: Float,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, 2 * cells, file: file, line: line)
        XCTAssertEqual(expected.a.count, cells, file: file, line: line)
        for index in 0..<cells {
            XCTAssertEqual(actual[index], expected.a[index], accuracy: accuracy,
                           "tone A[\(index)]", file: file, line: line)
            XCTAssertEqual(actual[cells + index], expected.b[index], accuracy: accuracy,
                           "tone B[\(index)]", file: file, line: line)
        }
    }

    private func assertValues(
        _ actual: [Float], _ expected: [Float], accuracy: Float,
        context: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        var maximum: Float = 0
        var total: Double = 0
        for index in actual.indices {
            let error = abs(actual[index] - expected[index])
            maximum = max(maximum, error)
            total += Double(error)
        }
        let mean = Float(total / Double(max(actual.count, 1)))
        XCTAssertLessThanOrEqual(
            maximum, accuracy, "\(context): max=\(maximum), mean=\(mean)",
            file: file, line: line)
    }

    private func captureSceneLight(
        _ signal: Float,
        transfer: HandwrittenMetalGlobalMeasurements.HDRCaptureTransfer
    ) -> Float {
        let clamped = min(max(signal, 0), 1)
        switch transfer {
        case .hlg: return HLGSceneTransfer.sceneLight(clamped)
        case .appleLog: return AppleLogCurve.linear(clamped)
        }
    }

    private func buffer<T>(device: MTLDevice, values: [T]) throws -> MTLBuffer {
        try values.withUnsafeBytes { raw in
            try XCTUnwrap(device.makeBuffer(
                bytes: raw.baseAddress!, length: raw.count,
                options: .storageModeShared))
        }
    }

    private func makeTexture(
        device: MTLDevice, format: MTLPixelFormat, width: Int, height: Int
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private func writeHalfTexture(_ values: [Float16], into texture: MTLTexture) {
        values.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0, withBytes: raw.baseAddress!,
                bytesPerRow: texture.width * 4 * MemoryLayout<Float16>.stride)
        }
    }

    private func writeBytes(
        _ values: [UInt8], into texture: MTLTexture, components: Int
    ) {
        values.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0, withBytes: raw.baseAddress!,
                bytesPerRow: texture.width * components)
        }
    }

    private func writeWords(
        _ values: [UInt16], into texture: MTLTexture, components: Int
    ) {
        values.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0, withBytes: raw.baseAddress!,
                bytesPerRow: texture.width * components * MemoryLayout<UInt16>.stride)
        }
    }

    private func writeFloatTexture(_ values: [Float], into texture: MTLTexture) {
        values.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0, withBytes: raw.baseAddress!,
                bytesPerRow: texture.width * 4 * MemoryLayout<Float>.stride)
        }
    }

    private func readPrivateFloats(
        queue: MTLCommandQueue, source: MTLBuffer, count: Int,
        encode: (MTLCommandBuffer) -> Bool
    ) throws -> [Float] {
        let length = count * MemoryLayout<Float>.stride
        let output = try XCTUnwrap(queue.device.makeBuffer(
            length: length, options: .storageModeShared))
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(encode(command))
        XCTAssertEqual(command.status, .notEnqueued)
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(
            from: source, sourceOffset: 0,
            to: output, destinationOffset: 0, size: length)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, "\(String(describing: command.error))")
        return Array(UnsafeBufferPointer(
            start: output.contents().assumingMemoryBound(to: Float.self), count: count))
    }
}
#endif
