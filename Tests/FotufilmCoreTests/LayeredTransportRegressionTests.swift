import XCTest
#if canImport(Metal)
import Metal
#endif
#if canImport(Accelerate)
import Accelerate
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

    #if canImport(Accelerate)
    func testFFTPositiveImpulse() throws {
        let kernel = try TransportRadialKernel(radiusMM: [0.005, 0.015, 0.035], mass: [0.4, 0.35, 0.25])
        var image = ImageBuffer(width: 65, height: 65)
        for c in 0..<3 { image.planes[c][32 * 65 + 32] = 1 }
        let result = try LayeredTransportFFT.convolve(image: image, kernel: kernel, pixelPitchMM: 0.004)
        let values = result.planes[0]
        XCTAssertGreaterThanOrEqual(values.min()!, 0)
        XCTAssertEqual(values.reduce(0, +), 1, accuracy: 0.00002)
        if TransportBackend.cpu.isAvailable {
            let reference = try LayeredTransportRenderer.convolve(image, stencil: kernel.stencil(pixelPitchMM: 0.004))
            XCTAssertLessThan(zip(values, reference.planes[0]).map { abs($0-$1) }.max()!, 0.000002)
        }
    }

    func testFFTBlackHighlightPipeline() throws {
        guard TransportBackend.cpu.isAvailable else { throw XCTSkip("Halide unavailable") }
        var stock = TestStocks.negative; stock.adjacencyStrength = 0
        var options = TransportFixtures.quiet
        options.layeredTransport = TransportFixtures.stack
        var image = ImageBuffer(width: 25, height: 19)
        image.planes[0][120] = 50
        image.planes[1][120] = 2
        image.planes[2][120] = 1
        let cpu = try FotufilmEngine(stock: stock, options: options).processChecked(linearRGB: image)
        options.transportBackend = .fft
        let fft = try FotufilmEngine(stock: stock, options: options).processChecked(linearRGB: image)
        for c in 0..<3 {
            XCTAssertLessThan(zip(cpu.planes[c], fft.planes[c]).map { abs($0-$1) }.max()!, 0.00005)
        }
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

    #if canImport(Accelerate)
    func testFFTHDRHighlightDoesNotLeakIntoDistantShadows() throws {
        let kernel = try TransportRadialKernel(radiusMM: [0.008], mass: [1])
        var image = ImageBuffer(width: 129, height: 97, fill: 0.00001)
        image.planes[0][48*129+64] = 10000
        let output = try LayeredTransportFFT.convolve(image: image, kernel: kernel, pixelPitchMM: 0.008)
        var maximumShadowError: Float = 0
        for y in 0..<97 { for x in 0..<129 where abs(x-64) > 8 || abs(y-48) > 8 {
            maximumShadowError = max(maximumShadowError, abs(output.planes[0][y*129+x] - 0.00001))
        } }
        XCTAssertLessThan(maximumShadowError, 1e-8)
    }

    func testFFTPlanSurvivesCacheGrowthAndIsReleasedAfterUse() throws {
        let cache = FFTSetupCache()
        var small: FFTPlan? = try cache.setup(forLog2N: 6)
        weak var lifetime = small
        let larger = try cache.setup(forLog2N: 14)
        XCTAssertNotNil(lifetime)
        XCTAssertEqual(larger.log2N, 14)
        var real = [Double](repeating: 1, count: 64*64)
        var imag = [Double](repeating: 0, count: 64*64)
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPDoubleSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                small!.transform(&split, width: 6, height: 6, direction: FFTDirection(FFT_FORWARD))
            }
        }
        XCTAssertEqual(real[0], 4096, accuracy: 0.001)
        XCTAssertTrue(real.dropFirst().allSatisfy { abs($0) < 0.00001 })
        small = nil
        XCTAssertNil(lifetime)
    }

    func testFFTMultiscaleMatchesSpatialAtEdgesAndAcrossSizes() throws {
        guard TransportBackend.cpu.isAvailable else { throw XCTSkip("Halide unavailable") }
        let kernel = try TransportRadialKernel(radiusMM: [0.001, 0.09, 0.22, 0.44], mass: [0.1, 0.2, 0.3, 0.4])
        let bands = try kernel.stencils(pixelPitchMM: 0.004)
        XCTAssertGreaterThan(bands.count, 2)
        for (w, h) in [(37, 29), (11, 9), (129, 65), (37, 29)] {
            var image = ImageBuffer(width: w, height: h)
            for c in 0..<3 { for i in 0..<w*h { image.planes[c][i] = Float((i*17+c*23)%101)/100 } }
            image.planes[0][0] = 20; image.planes[1][w*h-1] = 10
            var cpu = ImageBuffer(width: w, height: h, fill: 0.125)
            var fft = cpu
            try LayeredTransportRenderer.accumulate(component: image, bands: bands, into: &cpu)
            try LayeredTransportFFT.convolve(component: image, kernel: kernel, pixelPitchMM: 0.004, into: &fft)
            for c in 0..<3 {
                XCTAssertLessThan(zip(cpu.planes[c],fft.planes[c]).map { abs($0-$1) }.max()!, 0.00005)
            }
        }
    }
    #endif
}
