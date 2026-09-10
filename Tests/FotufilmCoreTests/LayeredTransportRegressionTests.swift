import XCTest
#if canImport(Metal)
import Metal
#endif
@testable import FotufilmCore
#if canImport(Metal)
import FotufilmMetal
#endif

final class LayeredTransportRegressionTests: XCTestCase {
    #if canImport(Metal)
    func testCameraMultiscaleParity() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try XCTUnwrap(HandwrittenMetalFullFrameRenderer(device: device, maximumInFlightFrames: 1))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let w = 129, h = 97
        var pixels = [Float](repeating: 0.0001, count: w*h*4)
        for i in 0..<w*h { pixels[4*i+3] = 1 }
        for y in 44...52 { for x in 60...68 { for c in 0..<3 { pixels[(y*w+x)*4+c] = 80 } } }
        let input = try XCTUnwrap(device.makeBuffer(bytes: pixels, length: pixels.count*4, options: .storageModeShared))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.shaderRead, .shaderWrite]
        let output = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var options = TransportFixtures.quiet
        options.localTone = false; options.paper = .screen; options.frameCoverage = 0.05
        var model = TransportFixtures.mirror
        model.coreSigmaMM = [0.1, 0.1, 0.1]
        options.layeredTransport = model; options.halationScale = 0
        let plan = try LayeredTransportRenderer.renderPlan(stock: TestStocks.negative, options: options, width: w, height: h)
        try renderer.prepareChecked(key: "pr57", stock: TestStocks.negative, options: options, frameWidth: w, frameHeight: h)
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(renderer.encodeSceneLinearRec2020RGBAFloat(sceneLinearRec2020RGBAFloat: input,
            output: output, width: w, height: h, key: "pr57", commandBuffer: commands))
        commands.commit(); commands.waitUntilCompleted()
        XCTAssertEqual(commands.status, .completed)
        var actual = [Float16](repeating: 0, count: pixels.count)
        actual.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: w*8,
            from: MTLRegionMake2D(0,0,w,h), mipmapLevel: 0) }
        let reference = try LayeredMetalTransport.process(pixels, width: w, height: h, stock: TestStocks.negative, options: options)
        var maximum: Float = 0
        for i in 0..<w*h { for c in 0..<3 { maximum = max(maximum, abs(Float(actual[4*i+c])-reference[4*i+c])) } }
        XCTAssertTrue(plan.components.flatMap(\.bands).contains { $0.stencil.stride > 1 })
        XCTAssertLessThan(maximum, 0.005)
    }

    #endif

    func testMetalRepeatedOddBandAccumulation() throws {
        guard TransportBackend.metal.isAvailable else { throw XCTSkip("Metal unavailable") }
        let kernel = try TransportRadialKernel(radiusMM: [0.01], mass: [1])
        let stencil = try kernel.stencil(pixelPitchMM: 0.008)
        let bands = (0..<3).map { _ in TransportWeightedStencil(weight: 1.0 / 3, stencil: stencil) }
        let image = ImageBuffer(width: 37, height: 29, fill: 0.5)
        for _ in 0..<3 {
            var output = ImageBuffer(width: 37, height: 29, fill: 0.2)
            try LayeredTransportRenderer.accumulate(component: image, bands: bands, into: &output, backend: .metal)
            XCTAssertEqual(output.planes[0][0], 0.7, accuracy: 1e-5)
        }
    }

    func testAccumulationRejectsShortExposurePlanesAndInvalidBandWeights() throws {
        let kernel = try TransportRadialKernel(radiusMM: [0.01], mass: [1])
        let stencil = try kernel.stencil(pixelPitchMM: 0.008)
        let component = ImageBuffer(width: 5, height: 3, fill: 0.5)
        let band = TransportWeightedStencil(weight: 1, stencil: stencil)
        for length in [0, 1, 14] {
            var output = ImageBuffer(width: 5, height: 3)
            output.planes[1] = Array(repeating: 0, count: length)
            XCTAssertThrowsError(try LayeredTransportRenderer.accumulate(component: component, bands: [band], into: &output))
        }
        for weight: Float in [-1, .nan, .infinity] {
            var output = ImageBuffer(width: 5, height: 3)
            XCTAssertThrowsError(try LayeredTransportRenderer.accumulate(component: component,
                bands: [.init(weight: weight, stencil: stencil)], into: &output))
        }
    }

    func testMultiscaleAccumulationMatchesSequentialAcrossSizeChanges() throws {
        guard TransportBackend.cpu.isAvailable else { throw XCTSkip("Halide unavailable") }
        let kernel = try TransportRadialKernel(radiusMM: [0.001, 0.09, 0.22, 0.44], mass: [0.1, 0.2, 0.3, 0.4])
        let bands = try kernel.stencils(pixelPitchMM: 0.004)
        XCTAssertGreaterThan(bands.count, 2)
        XCTAssertTrue(bands.contains { $0.stencil.stride > 1 })
        for (w, h) in [(37, 29), (11, 9), (129, 65), (37, 29)] {
            var image = ImageBuffer(width: w, height: h)
            for c in 0..<3 { for i in 0..<w*h { image.planes[c][i] = Float((i*17+c*23)%101)/100 } }
            image.planes[0][0] = 20; image.planes[1][w*h-1] = 10
            var reference = ImageBuffer(width: w, height: h, fill: 0.125)
            for band in bands {
                let filtered = try LayeredTransportRenderer.convolve(image, stencil: band.stencil)
                for c in 0..<3 { for i in 0..<w*h {
                    reference.planes[c][i] += band.weight * filtered.planes[c][i]
                } }
            }
            for backend in [TransportBackend.cpu, .metal] where backend.isAvailable {
                var output = ImageBuffer(width: w, height: h, fill: 0.125)
                try LayeredTransportRenderer.accumulate(component: image, bands: bands, into: &output, backend: backend)
                for c in 0..<3 {
                    XCTAssertLessThan(zip(reference.planes[c], output.planes[c]).map { abs($0-$1) }.max()!, 0.00005,
                                      "\(backend), \(w)x\(h), channel \(c)")
                }
            }
        }
    }

}
