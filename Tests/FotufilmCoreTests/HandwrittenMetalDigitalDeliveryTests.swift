#if canImport(Metal)
import Foundation
import Metal
import XCTest
@testable import FotufilmCore
@testable import FotufilmImaging
@testable import FotufilmMetal

final class HandwrittenMetalDigitalDeliveryTests: XCTestCase {
    private struct Planes: Equatable {
        let luma: [Float]
        let chroma: [Float]
    }

    private struct Harness {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let delivery: HandwrittenMetalDigitalDelivery

        init() throws {
            guard let device = MTLCreateSystemDefaultDevice() else {
                throw XCTSkip("no Metal device")
            }
            self.device = device
            queue = try XCTUnwrap(device.makeCommandQueue())
            delivery = try HandwrittenMetalDigitalDelivery(device: device)
        }
    }

    private static let codeTolerance: Float = 2

    private func texture(
        device: MTLDevice, format: MTLPixelFormat, width: Int, height: Int,
        usage: MTLTextureUsage
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = usage
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private func run(
        _ pixels: [SIMD4<Float>], width: Int, height: Int,
        output: HandwrittenMetalDigitalDelivery.Output,
        sdrShoulderKnee: Float = FilmSDRDelivery.standardShoulderKnee,
        harness: Harness? = nil
    ) throws -> Planes {
        let harness = try harness ?? Harness()
        XCTAssertEqual(pixels.count, width * height)
        let master = try texture(
            device: harness.device, format: .rgba16Float,
            width: width, height: height, usage: .shaderRead)
        let stored = pixels.flatMap { pixel in
            [Float16(pixel.x), Float16(pixel.y), Float16(pixel.z), Float16(pixel.w)]
        }
        stored.withUnsafeBytes { bytes in
            master.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: bytes.baseAddress!, bytesPerRow: width * 8)
        }
        let luma = try texture(
            device: harness.device, format: .r16Unorm,
            width: width, height: height, usage: [.shaderRead, .shaderWrite])
        let chroma = try texture(
            device: harness.device, format: .rg16Unorm,
            width: width / 2, height: height / 2, usage: [.shaderRead, .shaderWrite])
        let commands = try XCTUnwrap(harness.queue.makeCommandBuffer())
        try harness.delivery.encode(
            master: master, luma: luma, chroma: chroma,
            output: output, sdrShoulderKnee: sdrShoulderKnee,
            commandBuffer: commands)
        commands.commit()
        commands.waitUntilCompleted()
        XCTAssertEqual(commands.status, .completed, commands.error?.localizedDescription ?? "")

        var lumaWords = [UInt16](repeating: 0, count: width * height)
        lumaWords.withUnsafeMutableBytes { bytes in
            luma.getBytes(
                bytes.baseAddress!, bytesPerRow: width * 2,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        var chromaWords = [UInt16](
            repeating: 0, count: width / 2 * height / 2 * 2)
        chromaWords.withUnsafeMutableBytes { bytes in
            chroma.getBytes(
                bytes.baseAddress!, bytesPerRow: width / 2 * 4,
                from: MTLRegionMake2D(0, 0, width / 2, height / 2),
                mipmapLevel: 0)
        }
        return Planes(
            luma: lumaWords.map { Float($0) / 64 },
            chroma: chromaWords.map { Float($0) / 64 })
    }

    private func halfRounded(_ pixel: SIMD4<Float>) -> SIMD4<Float> {
        SIMD4(
            Float(Float16(pixel.x)), Float(Float16(pixel.y)),
            Float(Float16(pixel.z)), Float(Float16(pixel.w)))
    }

    private func reference(
        _ pixels: [SIMD4<Float>], width: Int, height: Int,
        output: HandwrittenMetalDigitalDelivery.Output
    ) -> Planes {
        func light(_ x: Int, _ y: Int) -> SIMD3<Float> {
            let pixel = halfRounded(pixels[y * width + x])
            return SIMD3(pixel.x, pixel.y, pixel.z) * max(pixel.w, 1)
        }
        func encodeSDR(_ value: SIMD3<Float>) -> (y: Float, u: Float, v: Float) {
            let transformed = ColorScience.linearDisplayP3ToSRGB(value)
            let mapped = SIMD3<Float>(
                ColorScience.displayShoulder(max(transformed.x, 0)),
                ColorScience.displayShoulder(max(transformed.y, 0)),
                ColorScience.displayShoulder(max(transformed.z, 0)))
            func oetf(_ linear: Float) -> Float {
                let bounded = min(max(linear, 0), 1)
                return bounded < 0.018
                    ? 4.5 * bounded
                    : 1.099 * pow(bounded, 0.45) - 0.099
            }
            let signal = SIMD3(oetf(mapped.x), oetf(mapped.y), oetf(mapped.z))
            let y = 0.2126 * signal.x + 0.7152 * signal.y + 0.0722 * signal.z
            return (y, (signal.z - y) / 1.8556, (signal.x - y) / 1.5748)
        }
        func encoded(_ value: SIMD3<Float>) -> (y: Float, u: Float, v: Float) {
            switch output {
            case .hdrHLGRec2020:
                return HLGTransfer.encode(r: value.x, g: value.y, b: value.z)
            case .sdrRec709:
                return encodeSDR(value)
            }
        }
        func lumaCode(_ value: Float) -> Float {
            floor(min(max(value, 0), 1) * 876 + 64.5)
        }
        func chromaCode(_ value: Float) -> Float {
            floor(min(max(value, -0.5), 0.5) * 896 + 512.5)
        }

        var luma = [Float](repeating: 0, count: width * height)
        var chroma = [Float](repeating: 0, count: width / 2 * height / 2 * 2)
        for blockY in 0..<(height / 2) {
            for blockX in 0..<(width / 2) {
                let x = blockX * 2
                let y = blockY * 2
                let a = encoded(light(x, y))
                let b = encoded(light(x + 1, y))
                let c = encoded(light(x, y + 1))
                let d = encoded(light(x + 1, y + 1))
                luma[y * width + x] = lumaCode(a.y)
                luma[y * width + x + 1] = lumaCode(b.y)
                luma[(y + 1) * width + x] = lumaCode(c.y)
                luma[(y + 1) * width + x + 1] = lumaCode(d.y)
                let chromaIndex = (blockY * (width / 2) + blockX) * 2
                chroma[chromaIndex] = chromaCode((a.u + b.u + c.u + d.u) * 0.25)
                chroma[chromaIndex + 1] = chromaCode(
                    (a.v + b.v + c.v + d.v) * 0.25)
            }
        }
        return Planes(luma: luma, chroma: chroma)
    }

    private func blockFrame(_ colours: [SIMD4<Float>])
        -> (pixels: [SIMD4<Float>], width: Int, height: Int) {
        let blocksPerRow = 4
        let width = blocksPerRow * 2
        let blockRows = (colours.count + blocksPerRow - 1) / blocksPerRow
        let height = blockRows * 2
        var pixels = [SIMD4<Float>](
            repeating: SIMD4(0, 0, 0, 1), count: width * height)
        for (index, colour) in colours.enumerated() {
            let blockX = index % blocksPerRow
            let blockY = index / blocksPerRow
            for dy in 0..<2 {
                for dx in 0..<2 {
                    pixels[(blockY * 2 + dy) * width + blockX * 2 + dx] = colour
                }
            }
        }
        return (pixels, width, height)
    }

    private func assertParity(
        _ actual: Planes, _ expected: Planes,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let lumaError = zip(actual.luma, expected.luma).reduce(Float.zero) {
            max($0, abs($1.0 - $1.1))
        }
        let chromaError = zip(actual.chroma, expected.chroma).reduce(Float.zero) {
            max($0, abs($1.0 - $1.1))
        }
        XCTAssertLessThanOrEqual(
            lumaError, Self.codeTolerance,
            "luma differs by \(lumaError) 10-bit codes", file: file, line: line)
        XCTAssertLessThanOrEqual(
            chromaError, Self.codeTolerance,
            "chroma differs by \(chromaError) 10-bit codes", file: file, line: line)
    }

    func testHDRIsTheExistingHLGTransferAtTheX420Quantizer() throws {
        let frame = blockFrame([
            SIMD4(0, 0, 0, 1), SIMD4(repeating: 0.18),
            SIMD4(1, 1, 1, 1), SIMD4(4.9, 4.9, 4.9, 1),
            SIMD4(1, 0, 0, 1), SIMD4(0, 1, 0, 1), SIMD4(0, 0, 1, 1),
            SIMD4(2.2, 0.4, 0.07, 1), SIMD4(0.1, 0.1, 0.1, 2),
        ])
        let gpu = try run(
            frame.pixels, width: frame.width, height: frame.height,
            output: .hdrHLGRec2020)
        let cpu = reference(
            frame.pixels, width: frame.width, height: frame.height,
            output: .hdrHLGRec2020)
        assertParity(gpu, cpu)
    }

    func testSDRMatchesTheDocumentedHDRMasterToRec709Reference() throws {
        let frame = blockFrame([
            SIMD4(0, 0, 0, 1), SIMD4(repeating: 0.18),
            SIMD4(1, 1, 1, 1), SIMD4(8, 8, 8, 1),
            SIMD4(1, 0, 0, 1), SIMD4(0, 1, 0, 1), SIMD4(0, 0, 1, 1),
            SIMD4(2.4, 0.3, 0.02, 1), SIMD4(0.08, 0.08, 0.08, 2.25),
        ])
        let gpu = try run(
            frame.pixels, width: frame.width, height: frame.height,
            output: .sdrRec709)
        let cpu = reference(
            frame.pixels, width: frame.width, height: frame.height,
            output: .sdrRec709)
        assertParity(gpu, cpu)
    }

    func testBlackNeutralAndDiffuseWhiteKeepLegalNeutralCodes() throws {
        let frame = blockFrame([
            SIMD4(0, 0, 0, 1), SIMD4(0.18, 0.18, 0.18, 1),
            SIMD4(1, 1, 1, 1),
        ])
        for output in HandwrittenMetalDigitalDelivery.Output.allCases {
            let encoded = try run(
                frame.pixels, width: frame.width, height: frame.height,
                output: output)
            XCTAssertEqual(encoded.luma[0], 64, accuracy: Self.codeTolerance)
            for block in 0..<3 {
                XCTAssertEqual(
                    encoded.chroma[block * 2], 512, accuracy: Self.codeTolerance,
                    "\(output) neutral Cb at block \(block)")
                XCTAssertEqual(
                    encoded.chroma[block * 2 + 1], 512, accuracy: Self.codeTolerance,
                    "\(output) neutral Cr at block \(block)")
            }
            XCTAssertGreaterThan(encoded.luma[2], encoded.luma[0])
            XCTAssertGreaterThan(encoded.luma[4], encoded.luma[2])
            XCTAssertGreaterThanOrEqual(encoded.luma.min() ?? 0, 64)
            XCTAssertLessThanOrEqual(encoded.luma.max() ?? 1024, 940)
        }
    }

    func testHighlightsRollWithoutChangingTheHDRMaster() throws {
        let frame = blockFrame([
            SIMD4(1, 1, 1, 1), SIMD4(2, 2, 2, 1), SIMD4(20, 20, 20, 1),
        ])
        for output in HandwrittenMetalDigitalDelivery.Output.allCases {
            let encoded = try run(
                frame.pixels, width: frame.width, height: frame.height,
                output: output)
            let white = encoded.luma[0]
            let highlight = encoded.luma[2]
            let farHighlight = encoded.luma[4]
            XCTAssertGreaterThan(highlight, white, "\(output) clipped at diffuse white")
            XCTAssertGreaterThan(
                farHighlight, highlight, "\(output) shoulder became a hard clip")
            XCTAssertLessThanOrEqual(farHighlight, 940)
        }
    }

    func testDisplayP3GamutProbesUseEachDeliveryGamut() throws {
        let frame = blockFrame([
            SIMD4(1, 0, 0, 1), SIMD4(0, 1, 0, 1), SIMD4(0, 0, 1, 1),
            SIMD4(1, 0.2, 0.8, 1),
        ])
        for output in HandwrittenMetalDigitalDelivery.Output.allCases {
            let gpu = try run(
                frame.pixels, width: frame.width, height: frame.height,
                output: output)
            let cpu = reference(
                frame.pixels, width: frame.width, height: frame.height,
                output: output)
            assertParity(gpu, cpu)
            XCTAssertTrue(gpu.chroma.contains { abs($0 - 512) > 32 },
                          "\(output) collapsed saturated P3 probes to neutral")
        }
    }

    func testDeliveryIsDeterministic() throws {
        let frame = blockFrame([
            SIMD4(0.13, 0.42, 0.91, 1), SIMD4(3.2, 0.7, 0.19, 1),
            SIMD4(0.01, 0.03, 0.08, 1), SIMD4(1.4, 1.1, 0.6, 1),
        ])
        let harness = try Harness()
        for output in HandwrittenMetalDigitalDelivery.Output.allCases {
            let first = try run(
                frame.pixels, width: frame.width, height: frame.height,
                output: output, harness: harness)
            let second = try run(
                frame.pixels, width: frame.width, height: frame.height,
                output: output, harness: harness)
            XCTAssertEqual(first, second, "\(output) changed between identical encodes")
        }
    }

    func testReversalKneeLowersSDRHighlightPlacement() throws {
        let pixels = [SIMD4<Float>](repeating: SIMD4(1, 1, 1, 1), count: 4)
        let standard = try run(
            pixels, width: 2, height: 2, output: .sdrRec709)
        let reversal = try run(
            pixels, width: 2, height: 2, output: .sdrRec709,
            sdrShoulderKnee: FilmSDRDelivery.reversalShoulderKnee)
        XCTAssertLessThan(reversal.luma[0], standard.luma[0])
    }

    func testEightBitAndMalformedSurfacesAreRejected() throws {
        let harness = try Harness()
        let invalidMaster = try texture(
            device: harness.device, format: .bgra8Unorm,
            width: 4, height: 4, usage: .shaderRead)
        let luma = try texture(
            device: harness.device, format: .r16Unorm,
            width: 4, height: 4, usage: .shaderWrite)
        let chroma = try texture(
            device: harness.device, format: .rg16Unorm,
            width: 2, height: 2, usage: .shaderWrite)
        let commands = try XCTUnwrap(harness.queue.makeCommandBuffer())
        XCTAssertThrowsError(try harness.delivery.encode(
            master: invalidMaster, luma: luma, chroma: chroma,
            output: .hdrHLGRec2020, commandBuffer: commands)) { error in
            guard case HandwrittenMetalDigitalDelivery.DeliveryError.invalidMasterTexture = error
            else { return XCTFail("unexpected error: \(error)") }
        }
    }
}
#endif
