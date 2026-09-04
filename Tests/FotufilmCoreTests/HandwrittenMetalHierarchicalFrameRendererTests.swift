#if canImport(Metal)
import Metal
import XCTest
@testable import FotufilmCore
import FotufilmMetal

final class HandwrittenMetalHierarchicalFrameRendererTests: XCTestCase {
    func testSDRSpatialResidualTracksNativeResolutionHandwrittenGraph() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let exact = try XCTUnwrap(HandwrittenMetalFullFrameRenderer(
            device: device, maximumInFlightFrames: 1,
            spatialOptimizationVariant: .exactSpecialized))
        let hierarchical = try XCTUnwrap(HandwrittenMetalHierarchicalFrameRenderer(
            device: device, maximumInFlightFrames: 1,
            cubeEdge: 65, cubeInputKnee: 0.01))
        let width = 1_920, height = 1_080
        let luma = try makeTexture(
            device: device, format: .r8Unorm, width: width, height: height)
        let chroma = try makeTexture(
            device: device, format: .rg8Unorm,
            width: width / 2, height: height / 2)
        stageCameraFixture(luma: luma, chroma: chroma)
        let exactOutput = try makeOutput(device: device, width: width, height: height)
        let hierarchicalOutput = try makeOutput(
            device: device, width: width, height: height)

        var options = FotufilmEngine.Options()
        options.paper = .screen
        options.grainScale = 0
        options.localTone = false
        let stock = TestStocks.negative
        let exactKey = #function + "-exact"
        let hierarchicalKey = #function + "-hierarchical"
        try exact.prepareChecked(
            key: exactKey, stock: stock, options: options,
            frameWidth: width, frameHeight: height)
        try hierarchical.prepareChecked(
            key: hierarchicalKey, stock: stock, options: options,
            frameWidth: width, frameHeight: height, sceneCeiling: 1)

        let exactCommands = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(exact.encodeCapturedSDR(
            luma: luma, chroma: chroma, output: exactOutput,
            width: width, height: height, key: exactKey,
            range: .full, gamut: .sRGB,
            frameIndex: 17, commandBuffer: exactCommands))
        exactCommands.commit()
        exactCommands.waitUntilCompleted()
        XCTAssertEqual(exactCommands.status, .completed)

        let hierarchicalCommands = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(hierarchical.encodeCapturedSDR(
            luma: luma, chroma: chroma, output: hierarchicalOutput,
            width: width, height: height, key: hierarchicalKey,
            range: .full, gamut: .sRGB,
            frameIndex: 17, commandBuffer: hierarchicalCommands))
        hierarchicalCommands.commit()
        hierarchicalCommands.waitUntilCompleted()
        XCTAssertEqual(hierarchicalCommands.status, .completed)

        var maximum: Float = 0
        var total: Double = 0
        let count = width * height
        var expected = [Float16](repeating: 0, count: count * 4)
        var actual = [Float16](repeating: 0, count: count * 4)
        expected.withUnsafeMutableBytes { bytes in
            exactOutput.getBytes(
                bytes.baseAddress!, bytesPerRow: width * 4 * MemoryLayout<Float16>.stride,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        actual.withUnsafeMutableBytes { bytes in
            hierarchicalOutput.getBytes(
                bytes.baseAddress!, bytesPerRow: width * 4 * MemoryLayout<Float16>.stride,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        for pixel in 0..<count {
            for channel in 0..<3 {
                let difference = abs(Float(actual[pixel * 4 + channel])
                                     - Float(expected[pixel * 4 + channel]))
                maximum = max(maximum, difference)
                total += Double(difference)
            }
        }
        let mean = total / Double(count * 3)
        print("Hierarchical SDR residual: max \(maximum), mean \(mean)")
        // The composed cube and its caller must use the same Rec.2020 coordinates. Applying the
        // exposure-domain seam a second time raises this fixture to about 0.060 max / 0.007 mean.
        XCTAssertLessThanOrEqual(maximum, 0.03)
        XCTAssertLessThanOrEqual(mean, 0.005)
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

    private func makeOutput(
        device: MTLDevice, width: Int, height: Int
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height,
            mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private func stageCameraFixture(luma: MTLTexture, chroma: MTLTexture) {
        var y = [UInt8](repeating: 0, count: luma.width * luma.height)
        for row in 0..<luma.height {
            for column in 0..<luma.width {
                let checker = ((column / 3) ^ (row / 3)) & 1
                y[row * luma.width + column] = UInt8(
                    min(255, max(0, (column * 191 / max(luma.width - 1, 1))
                                   + (checker == 0 ? 24 : 64))))
            }
        }
        var c = [UInt8](repeating: 128, count: chroma.width * chroma.height * 2)
        for row in 0..<chroma.height {
            for column in 0..<chroma.width {
                let offset = (row * chroma.width + column) * 2
                c[offset] = UInt8(48 + column * 160 / max(chroma.width - 1, 1))
                c[offset + 1] = UInt8(208 - row * 160 / max(chroma.height - 1, 1))
            }
        }
        y.withUnsafeBytes { bytes in
            luma.replace(
                region: MTLRegionMake2D(0, 0, luma.width, luma.height),
                mipmapLevel: 0, withBytes: bytes.baseAddress!,
                bytesPerRow: luma.width)
        }
        c.withUnsafeBytes { bytes in
            chroma.replace(
                region: MTLRegionMake2D(0, 0, chroma.width, chroma.height),
                mipmapLevel: 0, withBytes: bytes.baseAddress!,
                bytesPerRow: chroma.width * 2)
        }
    }
}
#endif
