#if canImport(Metal)
import XCTest
import Metal
@testable import FotufilmCore
@testable import FotufilmMetal

final class SampledMetalCurveTests: XCTestCase {
    func testSpatialResponseBakerMatchesCoreAcrossFiniteHalfExposures() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let library = try HandwrittenMetalShaderLibrary.makeLibrary(
            device: device, shader: .spatial, options: MTLCompileOptions())
        let kernel = try XCTUnwrap(library.makeFunction(name: "fotufilm_spatial_bake_half_response"))
        let pipeline = try device.makeComputePipelineState(function: kernel)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rg32Float, width: 256, height: 256, mipmapped: false)
        descriptor.textureType = .type2DArray
        descriptor.arrayLength = 4
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        let table = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let curveDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: 2048, height: 4, mipmapped: false)
        curveDescriptor.storageMode = .shared
        let curves = try XCTUnwrap(device.makeTexture(descriptor: curveDescriptor))
        let zero = [Float](repeating: 0, count: 2048 * 4)
        zero.withUnsafeBytes { curves.replace(region: MTLRegionMake2D(0, 0, 2048, 4),
            mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 2048 * 4) }
        for id in ["gold200", "trix400", "provia100f", "kodachrome25"] {
            let stock = try XCTUnwrap(FilmStock.named(id))
            let invocation = FilmEngineInvocation(stock: stock, options: .init(), width: 16, height: 16)
            let configuration = invocation.configuration
            let buffer = try XCTUnwrap(device.makeBuffer(bytes: configuration,
                length: configuration.count * 4, options: .storageModeShared))
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(curves, index: 0)
            encoder.setTexture(table, index: 1)
            encoder.setBuffer(buffer, offset: 0, index: 0)
            encoder.dispatchThreads(MTLSize(width: 256, height: 256, depth: 4),
                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed, "\(String(describing: command.error))")
            var values = [Float](repeating: 0, count: 65536 * 2)
            for channel in 0..<3 {
                values.withUnsafeMutableBytes { table.getBytes($0.baseAddress!, bytesPerRow: 256 * 8,
                    bytesPerImage: 65536 * 8, from: MTLRegionMake2D(0, 0, 256, 256),
                    mipmapLevel: 0, slice: channel) }
                let curve = stock.curves[channel]
                var worst: Float = 0
                for bits in 0..<65536 {
                    let x = Float(Float16(bitPattern: UInt16(bits)))
                    guard x.isFinite else { continue }
                    let expected = (curve.density(logExposure: x) - curve.dMin)
                        / (curve.dMax - curve.dMin)
                    XCTAssertTrue(values[bits * 2].isFinite, id)
                    worst = max(worst, abs(values[bits * 2] - expected))
                }
                XCTAssertLessThanOrEqual(worst, 2e-6, "\(id), channel \(channel)")
            }
        }
    }
}
#endif
