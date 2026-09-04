#if canImport(Metal)
import XCTest
@testable import FotufilmCore
import FotufilmMetal
import Metal

final class HandwrittenMetalFrameEndpointsTests: XCTestCase {
    private static let device = MTLCreateSystemDefaultDevice()
    private static let endpoints = device.flatMap(HandwrittenMetalFrameEndpoints.init(device:))
    private static let queue = device?.makeCommandQueue()

    func testSDRAndHDRHeadsTrackIndependentSpectralRecovery() throws {
        let device = try XCTUnwrap(Self.device)
        let endpoints = try XCTUnwrap(Self.endpoints)
        let queue = try XCTUnwrap(Self.queue)
        let width = 8
        let height = 1
        var options = neutralOptions()
        let invocation = FilmEngineInvocation(
            stock: TestStocks.negative, options: options,
            width: width, height: height)

        let encoded: [SIMD4<UInt8>] = [
            SIMD4(0, 0, 0, 255), SIMD4(32, 32, 32, 255),
            SIMD4(255, 255, 255, 255), SIMD4(220, 32, 18, 255),
            SIMD4(24, 210, 70, 255), SIMD4(18, 48, 230, 255),
            SIMD4(96, 40, 12, 128), SIMD4(0, 0, 0, 0),
        ]
        let sdrBytes = encoded.flatMap { [$0.x, $0.y, $0.z, $0.w] }
        let sdrInput = try buffer(device: device, values: sdrBytes)
        let sdrRecord = try texture(
            device: device, format: .rgba16Float, width: width, height: height,
            usage: [.shaderRead, .shaderWrite])
        XCTAssertTrue(endpoints.prepare(
            key: "endpoint-head-sdr", invocation: invocation,
            mode: .encodedDisplayP3RGBA8,
            frameWidth: width, frameHeight: height))
        let sdrCommand = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(endpoints.encodeHead(
            input: sdrInput, recordExposure: sdrRecord,
            key: "endpoint-head-sdr", commandBuffer: sdrCommand))
        XCTAssertEqual(sdrCommand.status, .notEnqueued)
        sdrCommand.commit()
        sdrCommand.waitUntilCompleted()
        XCTAssertEqual(sdrCommand.status, .completed)
        let actualSDR = readHalfTexture(sdrRecord)
        for index in 0..<width {
            let pixel = encoded[index]
            let denominator = pixel.w > 0 && pixel.w < 255 ? Float(pixel.w) : 255
            let p3 = SIMD3(
                canonicalDecode(Float(pixel.x) / denominator),
                canonicalDecode(Float(pixel.y) / denominator),
                canonicalDecode(Float(pixel.z) / denominator))
            let expected = expectedExposure(
                scene: ColorScience.linearDisplayP3ToRec2020(p3),
                invocation: invocation)
            for channel in 0..<4 {
                XCTAssertEqual(
                    Float(actualSDR[index * 4 + channel]), expected[channel],
                    accuracy: max(0.002, abs(expected[channel]) * 0.0015),
                    "SDR sample \(index), record \(channel)")
            }
        }

        options.sceneHeadroom = 1
        let hdrInvocation = FilmEngineInvocation(
            stock: TestStocks.negative, options: options,
            width: width, height: height)
        let hdrColours: [SIMD4<Float>] = [
            SIMD4(0, 0, 0, 0), SIMD4(0.18, 0.18, 0.18, 0.25),
            SIMD4(1, 1, 1, 0.5), SIMD4(16, 16, 16, 1),
            SIMD4(2, 0.25, 0.04, 0.75), SIMD4(0.08, 1.5, 0.32, 1),
            SIMD4(0.12, 0.4, 6, 0.125), SIMD4(-0.1, 0.5, 0.3, 1),
        ]
        let hdrHalf = hdrColours.flatMap {
            [Float16($0.x), Float16($0.y), Float16($0.z), Float16($0.w)]
        }
        let hdrInput = try buffer(device: device, values: hdrHalf)
        let hdrRecord = try texture(
            device: device, format: .rgba32Float, width: width, height: height,
            usage: [.shaderRead, .shaderWrite])
        XCTAssertTrue(endpoints.prepare(
            key: "endpoint-head-hdr", invocation: hdrInvocation,
            mode: .linearRec2020RGBA16Float,
            frameWidth: width, frameHeight: height))
        let hdrCommand = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(endpoints.encodeHead(
            input: hdrInput, recordExposure: hdrRecord,
            key: "endpoint-head-hdr", commandBuffer: hdrCommand))
        hdrCommand.commit()
        hdrCommand.waitUntilCompleted()
        XCTAssertEqual(hdrCommand.status, .completed)
        let actualHDR = readFloatTexture(hdrRecord)
        for index in 0..<width {
            let base = index * 4
            let scene = SIMD3(
                Float(hdrHalf[base]), Float(hdrHalf[base + 1]),
                Float(hdrHalf[base + 2]))
            let expected = expectedExposure(scene: scene, invocation: hdrInvocation)
            for channel in 0..<4 {
                XCTAssertEqual(
                    actualHDR[base + channel], expected[channel],
                    accuracy: max(2e-5, abs(expected[channel]) * 3e-5),
                    "HDR sample \(index), record \(channel)")
            }
        }
    }

    func testFactorizedSDRTailTracksCanonicalNegativeReversalMonoGradeAndDenseRamp()
        throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "Halide reference engine required")
        var neutral = neutralOptions()
        try assertSDRTail(stock: TestStocks.negative, options: neutral,
                          key: "endpoint-tail-negative")
        try assertSDRTail(stock: TestStocks.reversal, options: neutral,
                          key: "endpoint-tail-reversal")
        try assertSDRTail(stock: TestStocks.monochrome, options: neutral,
                          key: "endpoint-tail-monochrome")

        neutral.grade = ColorGrade(
            shadows: .init(balanceX: 0.3, balanceY: -0.2, level: 0.25),
            midtones: .init(balanceX: -0.15, balanceY: 0.2, level: 0.3),
            highlights: .init(balanceX: 0.2, balanceY: 0.1, level: 0.2))
        neutral.gradeSpace = .encoded
        try assertSDRTail(stock: TestStocks.negative, options: neutral,
                          key: "endpoint-tail-encoded-grade")
    }

    func testFactorizedHDRTailTracksCanonicalPrintAndPreservesAlpha() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "Halide reference engine required")
        let device = try XCTUnwrap(Self.device)
        let endpoints = try XCTUnwrap(Self.endpoints)
        let queue = try XCTUnwrap(Self.queue)
        let width = 96
        let height = 1
        var options = neutralOptions()
        options.grade = ColorGrade(
            shadows: .init(balanceX: 0.2, balanceY: 0.1, level: 0.1),
            midtones: .init(balanceX: -0.1, balanceY: 0.15, level: 0.2),
            highlights: .init(balanceX: 0.1, balanceY: -0.1, level: 0.25))
        options.gradeSpace = .encoded
        let invocation = FilmEngineInvocation(
            stock: TestStocks.negative, options: options,
            width: width, height: height)
        let density = denseDensity(invocation: invocation, width: width)
        let densityTexture = try texture(
            device: device, format: .rgba32Float, width: width, height: height,
            usage: .shaderRead)
        writeFloatTexture(density.interleaved, into: densityTexture)
        let alpha: [Float16] = (0..<width).flatMap { index -> [Float16] in
            let value = Float16(Float(index % 11) / 10)
            return [0, 0, 0, value]
        }
        let original = try buffer(device: device, values: alpha)
        let output = try XCTUnwrap(device.makeBuffer(
            length: width * 4 * MemoryLayout<Float16>.stride,
            options: .storageModeShared))
        XCTAssertTrue(endpoints.prepare(
            key: "endpoint-tail-hdr", invocation: invocation,
            mode: .linearRec2020RGBA16Float,
            frameWidth: width, frameHeight: height))
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(endpoints.encodeTail(
            developedDensity: densityTexture, originalInput: original,
            output: output, key: "endpoint-tail-hdr", commandBuffer: command))
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)

        let expected = FotufilmEngine(stock: TestStocks.negative, options: options)
            .printPositive(negativeDensity: density.image)
        let actual = output.contents().assumingMemoryBound(to: Float16.self)
        for index in 0..<width {
            for channel in 0..<3 {
                let wanted = max(expected.planes[channel][index], 0)
                XCTAssertEqual(
                    Float(actual[index * 4 + channel]), wanted,
                    accuracy: max(0.002, abs(wanted) * 0.002),
                    "HDR ramp \(index), channel \(channel)")
            }
            XCTAssertEqual(actual[index * 4 + 3], alpha[index * 4 + 3])
        }
    }

    func testActiveGlobalMeasurementsAreRequiredAndAccepted() throws {
        let endpoints = try XCTUnwrap(Self.endpoints)
        let width = 12
        let height = 8
        var options = FotufilmEngine.Options()
        options.highlights = 0.25
        options.localTone = true
        options.flareScale = 1
        var measured = FilmEngineInvocation(
            stock: TestStocks.negative, options: options,
            width: width, height: height)
        XCTAssertTrue(measured.localToneActive)
        XCTAssertNotEqual(measured.featureMask & FilmEngineFeature.flare, 0)
        XCTAssertFalse(endpoints.prepare(
            key: "endpoint-missing-measurement", invocation: measured,
            mode: .linearRec2020RGBA16Float,
            frameWidth: width, frameHeight: height))

        let red = [Float](repeating: 0.18, count: width * height)
        let green = [Float](repeating: 0.20, count: width * height)
        let blue = [Float](repeating: 0.16, count: width * height)
        red.withUnsafeBufferPointer { r in
            green.withUnsafeBufferPointer { g in
                blue.withUnsafeBufferPointer { b in
                    measured.measureToneBase(
                        planarR: r.baseAddress!, g: g.baseAddress!, b: b.baseAddress!,
                        width: width, height: height)
                }
            }
        }
        measured.flareMean = SIMD3(0.5, 0.6, 0.7)
        let resources = HandwrittenMetalFrameEndpoints.MeasurementResources(
            measuredInvocation: measured)
        XCTAssertTrue(endpoints.prepare(
            key: "endpoint-measured", invocation: measured,
            mode: .linearRec2020RGBA16Float,
            frameWidth: width, frameHeight: height,
            measurements: resources))
        XCTAssertEqual(endpoints.preparedFlareMean(forKey: "endpoint-measured"),
                       SIMD3(0.5, 0.6, 0.7))
    }

    private func assertSDRTail(
        stock: FilmStock, options: FotufilmEngine.Options, key: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let device = try XCTUnwrap(Self.device, file: file, line: line)
        let endpoints = try XCTUnwrap(Self.endpoints, file: file, line: line)
        let queue = try XCTUnwrap(Self.queue, file: file, line: line)
        let width = 192
        let height = 1
        let invocation = FilmEngineInvocation(
            stock: stock, options: options, width: width, height: height)
        let generated = denseDensity(invocation: invocation, width: width)
        // The SDR spatial seam is RGBA16F. Quantize before both roads so this test measures only
        // the endpoint rather than assigning its required storage conversion to one side.
        let half = generated.interleaved.map(Float16.init)
        let quantized = half.map(Float.init)
        let densityTexture = try texture(
            device: device, format: .rgba16Float, width: width, height: height,
            usage: .shaderRead)
        writeHalfTexture(half, into: densityTexture)
        var planes = [[Float](repeating: 0, count: width),
                      [Float](repeating: 0, count: width),
                      [Float](repeating: 0, count: width)]
        for index in 0..<width {
            for channel in 0..<3 { planes[channel][index] = quantized[index * 4 + channel] }
        }
        let densityImage = ImageBuffer(width: width, height: height, planes: planes)
        var original = [UInt8](repeating: 0, count: width * 4)
        let alphas: [UInt8] = [0, 37, 128, 254, 255]
        for index in 0..<width { original[index * 4 + 3] = alphas[index % alphas.count] }
        let input = try buffer(device: device, values: original)
        let output = try XCTUnwrap(device.makeBuffer(
            length: original.count, options: .storageModeShared), file: file, line: line)
        XCTAssertTrue(endpoints.prepare(
            key: key, invocation: invocation, mode: .encodedDisplayP3RGBA8,
            frameWidth: width, frameHeight: height), file: file, line: line)
        let command = try XCTUnwrap(queue.makeCommandBuffer(), file: file, line: line)
        XCTAssertTrue(endpoints.encodeTail(
            developedDensity: densityTexture, originalInput: input,
            output: output, key: key, commandBuffer: command), file: file, line: line)
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, file: file, line: line)

        let printed = FotufilmEngine(stock: stock, options: options)
            .printPositive(negativeDensity: densityImage)
        let actual = output.contents().assumingMemoryBound(to: UInt8.self)
        var maximumError = 0
        var totalError = 0
        let shoulderKnee = FilmSDRDelivery.shoulderKnee(
            isReversal: stock.isReversal)
        for index in 0..<width {
            for channel in 0..<3 {
                let linear = min(max(ColorScience.displayShoulder(
                    printed.planes[channel][index], knee: shoulderKnee), 0), 1)
                let encoded = canonicalEncode(linear)
                let noise = triangularDither(
                    index: UInt32(index), channel: UInt32(channel),
                    seed: invocation.seed)
                let expected = Int(min(max(floor(encoded * 255 + 0.5 + noise), 0), 255))
                let error = abs(Int(actual[index * 4 + channel]) - expected)
                maximumError = max(maximumError, error)
                totalError += error
            }
            XCTAssertEqual(actual[index * 4 + 3], original[index * 4 + 3],
                           file: file, line: line)
        }
        XCTAssertLessThanOrEqual(maximumError, 2, file: file, line: line)
        XCTAssertLessThanOrEqual(Double(totalError) / Double(width * 3), 0.18,
                                 file: file, line: line)
    }

    private func neutralOptions() -> FotufilmEngine.Options {
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        options.flareScale = 0
        options.localTone = false
        options.sceneHeadroom = 1
        return options
    }

    private func denseDensity(
        invocation: FilmEngineInvocation, width: Int
    ) -> (image: ImageBuffer, interleaved: [Float]) {
        var planes = [[Float](repeating: 0, count: width),
                      [Float](repeating: 0, count: width),
                      [Float](repeating: 0, count: width)]
        var interleaved = [Float](repeating: 1, count: width * 4)
        for channel in 0..<3 {
            let base = channel * 6
            let secondary = FilmEngineInvocation.curveSecondaryOffset + channel * 5
            let minimum = invocation.configuration[base]
            let range = invocation.configuration[base + 1]
                    * (invocation.configuration[base + 4]
                       - invocation.configuration[base + 2])
                + invocation.configuration[secondary]
                    * (invocation.configuration[secondary + 3]
                       - invocation.configuration[secondary + 1])
            for index in 0..<width {
                let phase = Float((index * (channel * 41 + 73)) % width)
                    / Float(width - 1)
                let value = minimum + range * phase
                planes[channel][index] = value
                interleaved[index * 4 + channel] = value
            }
        }
        return (ImageBuffer(width: width, height: 1, planes: planes), interleaved)
    }

    private func expectedExposure(
        scene: SIMD3<Float>, invocation: FilmEngineInvocation
    ) -> SIMD4<Float> {
        let weights = ColorScience.luminanceWeights
        // The shaders step into the exposure table's locus-enclosing basis and walk toward
        // the luminance axis there; luminance itself is read on the Rec.2020 components.
        var physical = ColorScience.linearRec2020ToExposureDomain(scene)
        if physical.x < 0 || physical.y < 0 || physical.z < 0 {
            let luminance = weights.0 * scene.x + weights.1 * scene.y
                + weights.2 * scene.z
            if luminance > 0 {
                let tx = physical.x < 0 ? luminance / (luminance - physical.x) : 1
                let ty = physical.y < 0 ? luminance / (luminance - physical.y) : 1
                let tz = physical.z < 0 ? luminance / (luminance - physical.z) : 1
                let scale = min(tx, min(ty, tz))
                physical = SIMD3(repeating: luminance)
                    + scale * (physical - SIMD3(repeating: luminance))
            } else {
                physical = .zero
            }
        }
        physical = SIMD3(
            max(physical.x, 0), max(physical.y, 0), max(physical.z, 0))
        let radiance = max(physical.x, max(physical.y, physical.z))
        guard radiance > 0 else { return .zero }
        let sampled = sampleRGBA(
            invocation.spectral.exposure, at: physical / radiance)
        let scaled = sampled * (radiance
            * invocation.configuration[FilmEngineInvocation.exposureGainOffset] / 0.18)
        return SIMD4(
            max(scaled.x, 0), max(scaled.y, 0),
            max(scaled.z, 0), max(scaled.w, 0))
    }

    private func sampleRGBA(_ table: SpectralLUT, at point: SIMD3<Float>) -> SIMD4<Float> {
        let edge = table.dimension
        let q = SIMD3(
            min(max(point.x, 0), 1), min(max(point.y, 0), 1),
            min(max(point.z, 0), 1)) * Float(edge - 1)
        let low = SIMD3(
            min(Int(q.x), edge - 2), min(Int(q.y), edge - 2),
            min(Int(q.z), edge - 2))
        let f = q - SIMD3(Float(low.x), Float(low.y), Float(low.z))
        func load(_ step: SIMD3<Int>) -> SIMD4<Float> {
            let x = low.x + step.x, y = low.y + step.y, z = low.z + step.z
            let offset = ((z * edge + y) * edge + x) * 4
            return SIMD4(
                table.values[offset], table.values[offset + 1],
                table.values[offset + 2], table.values[offset + 3])
        }
        let c000 = load(.zero), c111 = load(SIMD3(repeating: 1))
        if f.x >= f.y {
            if f.y >= f.z {
                let c100 = load(SIMD3(1, 0, 0)), c110 = load(SIMD3(1, 1, 0))
                return c000 + f.x * (c100 - c000) + f.y * (c110 - c100)
                    + f.z * (c111 - c110)
            } else if f.x >= f.z {
                let c100 = load(SIMD3(1, 0, 0)), c101 = load(SIMD3(1, 0, 1))
                return c000 + f.x * (c100 - c000) + f.z * (c101 - c100)
                    + f.y * (c111 - c101)
            }
            let c001 = load(SIMD3(0, 0, 1)), c101 = load(SIMD3(1, 0, 1))
            return c000 + f.z * (c001 - c000) + f.x * (c101 - c001)
                + f.y * (c111 - c101)
        } else if f.x >= f.z {
            let c010 = load(SIMD3(0, 1, 0)), c110 = load(SIMD3(1, 1, 0))
            return c000 + f.y * (c010 - c000) + f.x * (c110 - c010)
                + f.z * (c111 - c110)
        } else if f.y >= f.z {
            let c010 = load(SIMD3(0, 1, 0)), c011 = load(SIMD3(0, 1, 1))
            return c000 + f.y * (c010 - c000) + f.z * (c011 - c010)
                + f.x * (c111 - c011)
        }
        let c001 = load(SIMD3(0, 0, 1)), c011 = load(SIMD3(0, 1, 1))
        return c000 + f.z * (c001 - c000) + f.y * (c011 - c001)
            + f.x * (c111 - c011)
    }

    private func canonicalDecode(_ encoded: Float) -> Float {
        sampleTransfer(position: min(max(encoded, 0), 1)) { root in
            ColorScience.srgbToLinear(root)
        }
    }

    private func canonicalEncode(_ linear: Float) -> Float {
        sampleTransfer(position: sqrt(min(max(linear, 0), 1))) { root in
            ColorScience.linearToSrgb(root * root)
        }
    }

    private func sampleTransfer(
        position: Float, value: (Float) -> Float
    ) -> Float {
        let samples = 1_024
        let q = position * Float(samples - 1)
        let index = min(Int(q), samples - 2)
        let low = value(Float(index) / Float(samples - 1))
        let high = value(Float(index + 1) / Float(samples - 1))
        return low + (q - Float(index)) * (high - low)
    }

    private func triangularDither(index: UInt32, channel: UInt32, seed: UInt32) -> Float {
        let hash1 = pcg(index ^ pcg(channel &+ seed &* 0x9E3779B9))
        let hash2 = pcg(hash1)
        let scale: Float = 1 / 16_777_216
        let first = Float(hash1 >> 8) * scale
        let second = Float(hash2 >> 8) * scale
        return first + second - 1
    }

    private func pcg(_ value: UInt32) -> UInt32 {
        let state = value &* 747_796_405 &+ 2_891_336_453
        let word = ((state >> ((state >> 28) + 4)) ^ state) &* 277_803_737
        return (word >> 22) ^ word
    }

    private func buffer<T>(device: MTLDevice, values: [T]) throws -> MTLBuffer {
        try values.withUnsafeBytes { bytes in
            try XCTUnwrap(device.makeBuffer(
                bytes: bytes.baseAddress!, length: bytes.count,
                options: .storageModeShared))
        }
    }

    private func texture(
        device: MTLDevice, format: MTLPixelFormat,
        width: Int, height: Int, usage: MTLTextureUsage
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = usage
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private func writeHalfTexture(_ values: [Float16], into texture: MTLTexture) {
        values.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0, withBytes: bytes.baseAddress!,
                bytesPerRow: texture.width * 4 * MemoryLayout<Float16>.stride)
        }
    }

    private func writeFloatTexture(_ values: [Float], into texture: MTLTexture) {
        values.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0, withBytes: bytes.baseAddress!,
                bytesPerRow: texture.width * 4 * MemoryLayout<Float>.stride)
        }
    }

    private func readHalfTexture(_ texture: MTLTexture) -> [Float16] {
        var values = [Float16](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(
            &values, bytesPerRow: texture.width * 4 * MemoryLayout<Float16>.stride,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0)
        return values
    }

    private func readFloatTexture(_ texture: MTLTexture) -> [Float] {
        var values = [Float](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(
            &values, bytesPerRow: texture.width * 4 * MemoryLayout<Float>.stride,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0)
        return values
    }
}
#endif
