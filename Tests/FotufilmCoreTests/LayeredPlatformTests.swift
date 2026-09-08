#if canImport(Metal)
import XCTest
import Metal
@testable import FotufilmCore
import FotufilmMetal

final class LayeredPlatformTests: XCTestCase {
    func testExportBrowserReferenceWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["FOTUFILM_WASM_REFERENCE_OUTPUT"] else { return }
        let parts = (ProcessInfo.processInfo.environment["FOTUFILM_WASM_PACK_SIZE"] ?? "160x90").split(separator: "x").compactMap { Int($0) }
        let w = parts[0], h = parts[1]
        var source = ImageBuffer(width: w, height: h)
        for y in 0..<h { for x in 0..<w {
            let rgb: SIMD3<Float> = x > w/2 ? SIMD3(repeating: 1) : SIMD3(20/255, 15/255, 10/255)
            let scene = ColorScience.linearSRGBToRec2020(SIMD3(
                ColorScience.srgbToLinear(rgb.x), ColorScience.srgbToLinear(rgb.y), ColorScience.srgbToLinear(rgb.z)))
            for c in 0..<3 { source.planes[c][y*w+x] = scene[c] }
        } }
        var references: [String: [Float]] = [:]
        for id in FilmStock.allPresetIDs {
            let stock = try XCTUnwrap(FilmStock.named(id))
            var options = FotufilmEngine.Options()
            options.format = FilmFormat.native(forStockID: id)
            options.localTone = false; options.grainScale = 0; options.halationModel = .layered
            references[id] = try FotufilmEngine(stock: stock, options: options)
                .processChecked(linearRGB: source).planes.flatMap { $0 }
        }
        try JSONEncoder().encode(references).write(to: URL(fileURLWithPath: path))
    }

    func testCameraGraphRunsLayeredTransportInCallerCommandBuffer() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try XCTUnwrap(HandwrittenMetalFullFrameRenderer(device: device, maximumInFlightFrames: 1))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let w = 40, h = 30
        var pixels = [Float](repeating: 0.02, count: w*h*4)
        for i in 0..<w*h { pixels[4*i+3] = 1 }
        for c in 0..<3 { pixels[(15*w+20)*4+c] = 16 }
        let input = try XCTUnwrap(device.makeBuffer(bytes: pixels, length: pixels.count*4, options: .storageModeShared))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.shaderRead, .shaderWrite]
        let output = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var options = TransportFixtures.quiet
        options.localTone = false; options.halationModel = .layered; options.paper = .screen
        try renderer.prepareChecked(key: "layered", stock: TestStocks.negative, options: options, frameWidth: w, frameHeight: h)
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(renderer.encodeSceneLinearRec2020RGBAFloat(sceneLinearRec2020RGBAFloat: input,
            output: output, width: w, height: h, key: "layered", commandBuffer: commands))
        XCTAssertEqual(commands.status, .notEnqueued)
        commands.commit(); commands.waitUntilCompleted()
        XCTAssertEqual(commands.status, .completed, commands.error?.localizedDescription ?? "")
        var actual = [Float16](repeating: 0, count: pixels.count)
        actual.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: w*8,
            from: MTLRegionMake2D(0,0,w,h), mipmapLevel: 0) }
        let reference = try LayeredMetalTransport.process(pixels, width: w, height: h, stock: TestStocks.negative, options: options)
        var maximum: Float = 0
        for i in 0..<w*h { for c in 0..<3 { maximum = max(maximum, abs(Float(actual[4*i+c])-reference[4*i+c])) } }
        XCTAssertLessThan(maximum, 0.005)
        XCTAssertTrue(actual.allSatisfy(\.isFinite))
    }

    func testRegionReadsTheTransportedWholeFrame() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try XCTUnwrap(HalideMetalFilmRenderer.shared)
        let w = 33, h = 25
        var pixels = [Float](repeating: 0.03, count: w*h*4)
        for i in 0..<w*h { pixels[i*4+3] = 1 }
        pixels[(12*w+16)*4] = 50
        var options = TransportFixtures.quiet
        options.halationModel = .layered
        let input = try XCTUnwrap(device.makeBuffer(bytes: pixels, length: pixels.count*4, options: .storageModeShared))
        let context = try XCTUnwrap(renderer.makeLinearFloatFrameContext(input: input, width: w, height: h, stock: TestStocks.negative, options: options))
        let result = try XCTUnwrap(device.makeBuffer(length: 9*7*16, options: .storageModeShared))
        XCTAssertTrue(renderer.processLinearFloatRegion(input: input, output: result, regionWidth: 9,
            regionHeight: 7, originX: 10, originY: 8, context: context))
        let whole = try LayeredMetalTransport.process(pixels, width: w, height: h, stock: TestStocks.negative, options: options)
        let actual = result.contents().assumingMemoryBound(to: Float.self)
        for y in 0..<7 { for x in 0..<9 { for c in 0..<4 {
            XCTAssertEqual(actual[(y*9+x)*4+c], whole[((y+8)*w+x+10)*4+c], accuracy: 0.00001)
        } } }
    }

    func testModelSelectionAndNativeMetalAgreeWithReference() throws {
        let renderer = try XCTUnwrap(HalideMetalFilmRenderer.shared)
        var options = TransportFixtures.quiet
        options.localTone = false; options.halationModel = .layered
        let w = 65, h = 49
        var pixels = [Float](repeating: 0.02, count: w*h*4)
        for i in 0..<w*h { pixels[4*i+3] = 0.7 }
        for c in 0..<3 { pixels[(24*w+32)*4+c] = 80 }
        let output = try XCTUnwrap(renderer.processLinearFloat(pixels, width: w, height: h,
            stock: TestStocks.negative, options: options))
        let source = ImageBuffer(width: w, height: h, planes: (0..<3).map { c in
            (0..<w*h).map { pixels[4*$0+c] }
        })
        let reference = try FotufilmEngine(stock: TestStocks.negative, options: options).processChecked(linearRGB: source)
        var error: Float = 0
        for c in 0..<3 { for i in 0..<w*h { error = max(error, abs(reference.planes[c][i]-output[4*i+c])) } }
        XCTAssertLessThan(error, 0.0002)
        XCTAssertEqual(output[3], 0.7)
        options.halationModel = .legacy
        let legacy = try XCTUnwrap(renderer.processLinearFloat(pixels, width: w, height: h,
            stock: TestStocks.negative, options: options))
        XCTAssertGreaterThan(zip(output,legacy).map { abs($0-$1) }.max() ?? 0, 0.001)
    }
}
#endif
