#if canImport(Metal)
import Metal
import XCTest
@testable import FotufilmCore
@testable import FotufilmMetal

final class HandwrittenMetalStillDeliveryTests: XCTestCase {
    private struct Harness {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let delivery: HandwrittenMetalStillDelivery

        init() throws {
            guard let device = MTLCreateSystemDefaultDevice() else {
                throw XCTSkip("no Metal device")
            }
            self.device = device
            queue = try XCTUnwrap(device.makeCommandQueue())
            delivery = try HandwrittenMetalStillDelivery(device: device)
        }
    }

    private func texture(
        _ device: MTLDevice, format: MTLPixelFormat,
        width: Int, height: Int, usage: MTLTextureUsage
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = usage
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private func run(
        _ pixels: [SIMD4<Float>], output: HandwrittenMetalStillDelivery.Output,
        sdrShoulderKnee: Float = FilmSDRDelivery.standardShoulderKnee,
        harness: Harness? = nil
    ) throws -> [SIMD4<Float>] {
        let harness = try harness ?? Harness()
        let width = pixels.count
        let master = try texture(
            harness.device, format: .rgba16Float, width: width, height: 1,
            usage: .shaderRead)
        let stored = pixels.flatMap {
            [Float16($0.x), Float16($0.y), Float16($0.z), Float16($0.w)]
        }
        stored.withUnsafeBytes { bytes in
            master.replace(
                region: MTLRegionMake2D(0, 0, width, 1), mipmapLevel: 0,
                withBytes: bytes.baseAddress!, bytesPerRow: width * 8)
        }
        let delivered = try texture(
            harness.device, format: .rgba16Float, width: width, height: 1,
            usage: [.shaderRead, .shaderWrite])
        let commands = try XCTUnwrap(harness.queue.makeCommandBuffer())
        try harness.delivery.encode(
            master: master, output: delivered, as: output,
            sdrShoulderKnee: sdrShoulderKnee,
            commandBuffer: commands)
        commands.commit()
        commands.waitUntilCompleted()
        XCTAssertEqual(commands.status, .completed,
                       commands.error?.localizedDescription ?? "")

        var words = [UInt16](repeating: 0, count: width * 4)
        words.withUnsafeMutableBytes { bytes in
            delivered.getBytes(
                bytes.baseAddress!, bytesPerRow: width * 8,
                from: MTLRegionMake2D(0, 0, width, 1), mipmapLevel: 0)
        }
        var result: [SIMD4<Float>] = []
        result.reserveCapacity(width)
        for index in stride(from: 0, to: words.count, by: 4) {
            result.append(SIMD4(
                Float(Float16(bitPattern: words[index])),
                Float(Float16(bitPattern: words[index + 1])),
                Float(Float16(bitPattern: words[index + 2])),
                Float(Float16(bitPattern: words[index + 3]))))
        }
        return result
    }

    private func reference(
        _ pixels: [SIMD4<Float>], output: HandwrittenMetalStillDelivery.Output
    ) -> [SIMD4<Float>] {
        let source = pixels.flatMap { pixel in
            [Float(Float16(pixel.x)), Float(Float16(pixel.y)),
             Float(Float16(pixel.z)), Float(Float16(pixel.w))]
        }
        var converted = [Float](repeating: 0, count: source.count)
        source.withUnsafeBufferPointer { source in
            converted.withUnsafeMutableBufferPointer { destination in
                let converter: FilmOutputConversion = output == .hdrHLGRec2020
                    ? .rec2020HLG : .rec709SDR
                DevelopedPrintOutput.convert(
                    source, from: 0, count: source.count,
                    into: destination, using: converter)
            }
        }
        var result: [SIMD4<Float>] = []
        result.reserveCapacity(pixels.count)
        for index in stride(from: 0, to: converted.count, by: 4) {
            result.append(SIMD4(
                Float(Float16(converted[index])),
                Float(Float16(converted[index + 1])),
                Float(Float16(converted[index + 2])),
                Float(Float16(converted[index + 3]))))
        }
        return result
    }

    func testRGBDeliveriesMatchPortablePerPixelConverters() throws {
        let pixels = [
            SIMD4<Float>(0, 0, 0, 1),
            SIMD4<Float>(repeating: 0.18),
            SIMD4<Float>(1, 1, 1, 1),
            SIMD4<Float>(4.9, 4.9, 4.9, 1),
            SIMD4<Float>(1, 0, 0, 1),
            SIMD4<Float>(0, 1, 0, 1),
            SIMD4<Float>(0, 0, 1, 1),
            SIMD4<Float>(2.4, 0.3, 0.02, 1),
            SIMD4<Float>(0.08, 0.08, 0.08, 2.25),
        ]
        let harness = try Harness()
        for delivery in HandwrittenMetalStillDelivery.Output.allCases {
            let actual = try run(pixels, output: delivery, harness: harness)
            let expected = reference(pixels, output: delivery)
            XCTAssertEqual(actual.count, expected.count)
            for index in actual.indices {
                for channel in 0..<4 {
                    XCTAssertEqual(
                        actual[index][channel], expected[index][channel],
                        accuracy: 0.002,
                        "\(delivery) pixel \(index), channel \(channel)")
                }
            }
        }
    }

    func testDeliveryIsDeterministic() throws {
        let pixels = [
            SIMD4<Float>(0.13, 0.42, 0.91, 1),
            SIMD4<Float>(3.2, 0.7, 0.19, 1.4),
        ]
        let harness = try Harness()
        for delivery in HandwrittenMetalStillDelivery.Output.allCases {
            XCTAssertEqual(
                try run(pixels, output: delivery, harness: harness),
                try run(pixels, output: delivery, harness: harness))
        }
    }

    func testReversalKneeUsesLongerSDRHighlightRollOff() throws {
        let pixels = [SIMD4<Float>(1, 1, 1, 1), SIMD4<Float>(2, 2, 2, 1)]
        let standard = try run(pixels, output: .sdrRec709)
        let reversal = try run(
            pixels, output: .sdrRec709,
            sdrShoulderKnee: FilmSDRDelivery.reversalShoulderKnee)
        XCTAssertLessThan(reversal[0].x, standard[0].x)
        XCTAssertGreaterThan(reversal[1].x - reversal[0].x,
                             standard[1].x - standard[0].x)
    }

    func testEightBitMasterIsRejected() throws {
        let harness = try Harness()
        let master = try texture(
            harness.device, format: .bgra8Unorm, width: 2, height: 2,
            usage: .shaderRead)
        let output = try texture(
            harness.device, format: .rgba16Float, width: 2, height: 2,
            usage: [.shaderRead, .shaderWrite])
        let commands = try XCTUnwrap(harness.queue.makeCommandBuffer())
        XCTAssertThrowsError(try harness.delivery.encode(
            master: master, output: output, as: .hdrHLGRec2020,
            commandBuffer: commands)) { error in
            guard case HandwrittenMetalStillDelivery.DeliveryError.invalidMasterTexture = error
            else { return XCTFail("unexpected error: \(error)") }
        }
    }
}
#endif
