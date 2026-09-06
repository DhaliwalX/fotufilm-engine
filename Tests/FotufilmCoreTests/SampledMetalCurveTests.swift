#if canImport(Metal)
import XCTest
import Metal
@testable import FotufilmCore
@testable import FotufilmMetal

final class SampledMetalCurveTests: XCTestCase {
    func testAcceleratedLookupPassesThroughEveryRuntimeKnot() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let executor = try XCTUnwrap(HandwrittenMetalSpatialExecutor(device: device))
        let options = MTLCompileOptions()
        options.preprocessorMacros = HandwrittenMetalShaderLibrary.sharedConfigurationMacros
        let source = try HandwrittenMetalShaderLibrary.assembledSource(for: .spatial) + """

        kernel void test_sampled_knots(
            const device float2 *input [[buffer(0)]],
            const device float *configuration [[buffer(1)]],
            device float *output [[buffer(2)]],
            texture2d<float, access::read> curves [[texture(0)]],
            uint index [[thread_position_in_grid]]) {
            output[index] = sample_film_curve(configuration, curves, input[index].x,
                                              uint(input[index].y));
        }
        """
        let library = try device.makeLibrary(source: source, options: options)
        let function = try library.makeFunction(
            name: "test_sampled_knots", constantValues: MTLFunctionConstantValues())
        let pipeline = try device.makeComputePipelineState(function: function)
        var specialized: [Int: MTLComputePipelineState] = [:]
        var fixtures: [(String, FilmStock)] = try FilmStock.presetIDs.sorted().map {
            ($0, try XCTUnwrap(FilmStock.named($0)))
        }
        var mixed = try XCTUnwrap(FilmStock.named("gold200"))
        mixed.curves[1].sampled = nil
        fixtures.append(("mixed analytic and sampled", mixed))
        var shifted = try XCTUnwrap(FilmStock.named("gold200"))
        for channel in 0..<3 {
            let original = try XCTUnwrap(shifted.curves[channel].sampled)
            shifted.curves[channel].sampled = try SampledCharacteristicCurve(
                logExposure: original.logExposure.map { $0 + 16 }, density: original.density)
        }
        fixtures.append(("outside cache domain", shifted))
        var checked = 0
        for (id, stock) in fixtures {
            let configuration = FilmEngineInvocation(
                stock: stock, options: .init(), width: 16, height: 16).configuration
            var input: [SIMD2<Float>] = [], expected: [Float] = []
            var exact: [Bool] = []
            for channel in 0..<3 {
                let base = FilmEngineInvocation.sampledCurvesOffset
                    + channel * FilmEngineInvocation.sampledCurveStride
                for knot in 0..<Int(configuration[base]) {
                    input.append(SIMD2(configuration[base + 1 + knot * 3], Float(channel)))
                    expected.append(configuration[base + 2 + knot * 3])
                    exact.append(true)
                    let x = configuration[base + 1 + knot * 3]
                    var probes = [x.nextDown, x.nextUp]
                    if knot + 1 < Int(configuration[base]) {
                        let next = configuration[base + 1 + (knot + 1) * 3]
                        probes += [0.125, 0.5, 0.875].map { x + (next - x) * $0 }
                    }
                    for probe in probes {
                        input.append(SIMD2(probe, Float(channel)))
                        expected.append(try XCTUnwrap(FilmEngineInvocation.sampledFilmDensity(
                            configuration: configuration, channel: channel, logExposure: probe)))
                        exact.append(false)
                    }
                }
            }
            guard !input.isEmpty else { continue }
            let curves = try XCTUnwrap(executor.makeCurveTexture(configuration: configuration))
            let inputBuffer = try XCTUnwrap(device.makeBuffer(bytes: input,
                length: input.count * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared))
            let configurationBuffer = try XCTUnwrap(device.makeBuffer(bytes: configuration,
                length: configuration.count * 4, options: .storageModeShared))
            let output = try XCTUnwrap(device.makeBuffer(length: expected.count * 4,
                                                       options: .storageModeShared))
            let mode = HandwrittenMetalSpatialExecutor.curveMode(configuration)
            if specialized[mode] == nil {
                let constants = MTLFunctionConstantValues()
                var value = UInt32(mode)
                constants.setConstantValue(&value, type: .uint, index: 20)
                specialized[mode] = try device.makeComputePipelineState(function:
                    library.makeFunction(name: "test_sampled_knots", constantValues: constants))
            }
            for variant in [pipeline, try XCTUnwrap(specialized[mode])] {
                let command = try XCTUnwrap(queue.makeCommandBuffer())
                let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
                encoder.setComputePipelineState(variant)
                encoder.setBuffer(inputBuffer, offset: 0, index: 0)
                encoder.setBuffer(configurationBuffer, offset: 0, index: 1)
                encoder.setBuffer(output, offset: 0, index: 2)
                encoder.setTexture(curves, index: 0)
                encoder.dispatchThreads(MTLSize(width: expected.count, height: 1, depth: 1),
                                        threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
                encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
                XCTAssertEqual(command.status, .completed)
                let actual = output.contents().assumingMemoryBound(to: Float.self)
                let mismatches = expected.indices.filter {
                    !actual[$0].isFinite || (exact[$0]
                        ? actual[$0] != expected[$0] : abs(actual[$0] - expected[$0]) > 2e-6)
                }
                XCTAssertTrue(mismatches.isEmpty, "\(id): \(mismatches.prefix(3).map { (input[$0], actual[$0], expected[$0], exact[$0]) })")
            }
            checked += exact.filter { $0 }.count
        }
        XCTAssertGreaterThan(checked, 40_000)
    }

    func testSpatialResponseBakerMatchesCoreAcrossFiniteHalfExposures() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let library = try HandwrittenMetalShaderLibrary.makeLibrary(
            device: device, shader: .spatial, options: MTLCompileOptions())
        let kernel = try library.makeFunction(
            name: "fotufilm_spatial_bake_half_response", constantValues: MTLFunctionConstantValues())
        let pipeline = try device.makeComputePipelineState(function: kernel)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rg32Float, width: 256, height: 256, mipmapped: false)
        descriptor.textureType = .type2DArray
        descriptor.arrayLength = 4
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        let table = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let executor = try XCTUnwrap(HandwrittenMetalSpatialExecutor(device: device))
        let ids = FilmStock.presetIDs.sorted().filter {
            FilmStock.named($0)?.curves.contains(where: { $0.sampled != nil }) == true
        }
        XCTAssertFalse(ids.isEmpty)
        for id in ids {
            let stock = try XCTUnwrap(FilmStock.named(id))
            let invocation = FilmEngineInvocation(stock: stock, options: .init(), width: 16, height: 16)
            let configuration = invocation.configuration
            let curves = try XCTUnwrap(executor.makeCurveTexture(configuration: configuration))
            XCTAssertEqual(curves.height, 10)
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
