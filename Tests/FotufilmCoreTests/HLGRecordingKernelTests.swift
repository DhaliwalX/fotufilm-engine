#if canImport(Metal)
import XCTest
import Metal
@testable import FotufilmImaging

final class HLGRecordingKernelTests: XCTestCase {
    private static let tolerance: Float = 1

    private struct Run {
        var luma: [Float]      // width * height, in 10-bit codes
        var chroma: [Float]    // (width/2) * (height/2) * 2, in 10-bit codes
        var preview: [Float]?  // width * height * 4, linear Display P3
    }

    private func runKernel(_ pixels: [Float], width: Int, height: Int,
                           half: Bool = false, preview: Bool = false) throws -> Run {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device")
        }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let library = try device.makeLibrary(
            source: half ? HLGRecordingKernel.halfSource
                         : HLGRecordingKernel.source,
                                             options: HLGRecordingKernel.compileOptions)
        let functionName: String
        if preview {
            functionName = half ? HLGRecordingKernel.halfRecordPreviewFunctionName
                                : HLGRecordingKernel.recordPreviewFunctionName
        } else {
            functionName = half ? HLGRecordingKernel.halfFunctionName
                                : HLGRecordingKernel.functionName
        }
        let function = try XCTUnwrap(library.makeFunction(name: functionName))
        let pipeline = try device.makeComputePipelineState(function: function)

        let source: MTLBuffer
        if half {
            let values = pixels.map(Float16.init)
            source = try XCTUnwrap(device.makeBuffer(
                bytes: values,
                length: values.count * MemoryLayout<Float16>.size,
                options: .storageModeShared))
        } else {
            source = try XCTUnwrap(device.makeBuffer(
                bytes: pixels,
                length: pixels.count * MemoryLayout<Float>.size,
                options: .storageModeShared))
        }

        func texture(_ format: MTLPixelFormat, _ w: Int, _ h: Int) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: w, height: h, mipmapped: false)
            descriptor.usage = [.shaderWrite, .shaderRead]
            descriptor.storageMode = .shared
            return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        }
        // The planes a `420YpCbCr10BiPlanarVideoRange` buffer hands the recorder.
        let luma = try texture(.r16Unorm, width, height)
        let chroma = try texture(.rg16Unorm, width / 2, height / 2)
        let previewTexture = preview
            ? try texture(.rgba16Float, width, height) : nil

        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commands.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(source, offset: 0,
                          index: HLGRecordingKernel.Argument.source)
        encoder.setTexture(luma, index: 0)
        encoder.setTexture(chroma, index: 1)
        if let previewTexture {
            encoder.setTexture(previewTexture, index: 2)
            var origin = SIMD2<UInt32>.zero
            encoder.setBytes(
                &origin, length: MemoryLayout<SIMD2<UInt32>>.size,
                index: HLGRecordingKernel.Argument.previewOrigin)
        }
        var size = SIMD2<UInt32>(UInt32(width), UInt32(height))
        encoder.setBytes(&size, length: MemoryLayout<SIMD2<UInt32>>.size,
                         index: HLGRecordingKernel.Argument.size)
        var curve = HLGRecordingKernel.curve
        encoder.setBytes(&curve, length: MemoryLayout<SIMD4<Float>>.size,
                         index: HLGRecordingKernel.Argument.curve)
        var tail = HLGRecordingKernel.tail
        encoder.setBytes(&tail, length: MemoryLayout<SIMD2<Float>>.size,
                         index: HLGRecordingKernel.Argument.tail)
        encoder.dispatchThreads(
            MTLSize(width: width / 2, height: height / 2, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 8, height: 4, depth: 1))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        XCTAssertEqual(commands.status, .completed)

        var lumaWords = [UInt16](repeating: 0, count: width * height)
        lumaWords.withUnsafeMutableBytes { raw in
            luma.getBytes(raw.baseAddress!, bytesPerRow: width * 2,
                          from: MTLRegionMake2D(0, 0, width, height),
                          mipmapLevel: 0)
        }
        var chromaWords = [UInt16](repeating: 0, count: width / 2 * height / 2 * 2)
        chromaWords.withUnsafeMutableBytes { raw in
            chroma.getBytes(raw.baseAddress!, bytesPerRow: width / 2 * 4,
                            from: MTLRegionMake2D(0, 0, width / 2, height / 2),
                            mipmapLevel: 0)
        }
        // The kernel stores a 10-bit code left-justified into 16 bits, as the plane does.
        var previewValues: [Float]?
        if let previewTexture {
            var halfValues = [Float16](repeating: 0, count: width * height * 4)
            halfValues.withUnsafeMutableBytes { raw in
                previewTexture.getBytes(
                    raw.baseAddress!, bytesPerRow: width * 8,
                    from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
            previewValues = halfValues.map(Float.init)
        }
        return Run(luma: lumaWords.map { Float($0) / 64 },
                   chroma: chromaWords.map { Float($0) / 64 },
                   preview: previewValues)
    }

    private func reference(_ pixels: [Float], width: Int, height: Int) -> Run {
        func light(_ x: Int, _ y: Int) -> SIMD3<Float> {
            let i = (y * width + x) * 4
            let gain = max(pixels[i + 3], 1)
            return SIMD3(pixels[i], pixels[i + 1], pixels[i + 2]) * gain
        }
        var luma = [Float](repeating: 0, count: width * height)
        var chroma = [Float](repeating: 0, count: width / 2 * height / 2 * 2)
        for blockY in 0..<(height / 2) {
            for blockX in 0..<(width / 2) {
                let x = blockX * 2, y = blockY * 2
                let encoded = HLGTransfer.encode420(
                    topLeft: light(x, y), topRight: light(x + 1, y),
                    bottomLeft: light(x, y + 1),
                    bottomRight: light(x + 1, y + 1))
                func code(_ value: Float) -> Float {
                    min(max(value.rounded(), 0), 1023)
                }
                luma[y * width + x] = code(encoded.luma.x * 876 + 64)
                luma[y * width + x + 1] = code(encoded.luma.y * 876 + 64)
                luma[(y + 1) * width + x] = code(encoded.luma.z * 876 + 64)
                luma[(y + 1) * width + x + 1] = code(encoded.luma.w * 876 + 64)
                chroma[(blockY * (width / 2) + blockX) * 2] =
                    code(encoded.u * 896 + 512)
                chroma[(blockY * (width / 2) + blockX) * 2 + 1] =
                    code(encoded.v * 896 + 512)
            }
        }
        return Run(luma: luma, chroma: chroma)
    }

    private func probeFrame() -> (pixels: [Float], width: Int, height: Int) {
        let ceiling = PrintEncoding.hdrDisplayCeiling
        var colours: [SIMD3<Float>] = []
        for step in 0...15 {
            let v = Float(step) / 15 * ceiling
            colours.append(SIMD3(v, v, v))
            colours.append(SIMD3(v, 0, 0))
            colours.append(SIMD3(0, v, 0))
            colours.append(SIMD3(0, 0, v))
            colours.append(SIMD3(v, v * 0.35, v * 0.08))
            colours.append(SIMD3(v * 0.08, v, v * 0.35))
            colours.append(SIMD3(v * 0.35, v * 0.08, v))
            colours.append(SIMD3(v, v * 0.9, 0))
        }
        // Laid out so every colour gets a whole 2x2 block to itself, which is the unit the
        // kernel and `encode420` both work in — a colour split across a block would be
        // averaged into its neighbour and the comparison would nothing useful.
        let width = 16
        let blocksPerRow = width / 2
        while colours.count % blocksPerRow != 0 { colours.append(.zero) }
        let rows = colours.count / blocksPerRow * 2
        var pixels = [Float](repeating: 0, count: width * rows * 4)
        for (index, colour) in colours.enumerated() {
            let blockX = index % blocksPerRow, blockY = index / blocksPerRow
            for dy in 0..<2 {
                for dx in 0..<2 {
                    let x = blockX * 2 + dx, y = blockY * 2 + dy
                    let i = (y * width + x) * 4
                    pixels[i] = colour.x
                    pixels[i + 1] = colour.y
                    pixels[i + 2] = colour.z
                    pixels[i + 3] = 1
                }
            }
        }
        return (pixels, width, rows)
    }

    func testTheKernelIsTheTransferItIsASpellingOf() throws {
        let (pixels, width, height) = probeFrame()
        let gpu = try runKernel(pixels, width: width, height: height)
        let cpu = reference(pixels, width: width, height: height)

        var worstLuma: Float = 0, worstLumaAt = 0
        for i in 0..<cpu.luma.count {
            let delta = abs(gpu.luma[i] - cpu.luma[i])
            if delta > worstLuma { worstLuma = delta; worstLumaAt = i }
        }
        var worstChroma: Float = 0
        for i in 0..<cpu.chroma.count {
            worstChroma = max(worstChroma, abs(gpu.chroma[i] - cpu.chroma[i]))
        }
        let pixel = worstLumaAt
        XCTAssertLessThanOrEqual(
            worstLuma, Self.tolerance,
            """
            kernel and `HLGTransfer` disagree by \(worstLuma) 10-bit luma codes at pixel \
            \(pixel), linear (\(pixels[pixel * 4]), \(pixels[pixel * 4 + 1]), \
            \(pixels[pixel * 4 + 2]))
            """)
        XCTAssertLessThanOrEqual(
            worstChroma, Self.tolerance,
            "kernel and `HLGTransfer` disagree by \(worstChroma) 10-bit chroma codes")
    }

    func testHalfFloatInputStaysWithinTwoTenBitCodes() throws {
        let (pixels, width, height) = probeFrame()
        let gpu = try runKernel(pixels, width: width, height: height, half: true)
        let cpu = reference(pixels, width: width, height: height)
        let worstLuma = zip(gpu.luma, cpu.luma).reduce(Float.zero) {
            max($0, abs($1.0 - $1.1))
        }
        let worstChroma = zip(gpu.chroma, cpu.chroma).reduce(Float.zero) {
            max($0, abs($1.0 - $1.1))
        }
        XCTAssertLessThanOrEqual(worstLuma, 2)
        XCTAssertLessThanOrEqual(worstChroma, 2)
    }

    func testTheKernelReadsTheFourthChannelAsAGain() throws {
        let base: SIMD3<Float> = SIMD3(0.30, 0.18, 0.09)
        var pixels: [Float] = []
        // Row pair 1: the light halved, with a gain of two on top.
        for _ in 0..<2 {
            for _ in 0..<2 { pixels += [base.x, base.y, base.z, 2] }
        }
        // Row pair 2: twice that light, with no gain.
        for _ in 0..<2 {
            for _ in 0..<2 { pixels += [base.x * 2, base.y * 2, base.z * 2, 1] }
        }
        // Row pair 3: the doubled light again, with a fourth channel below one, which is
        // coverage and must not darken it.
        for _ in 0..<2 {
            for _ in 0..<2 { pixels += [base.x * 2, base.y * 2, base.z * 2, 0.25] }
        }
        let gpu = try runKernel(pixels, width: 2, height: 6)

        XCTAssertEqual(gpu.luma[0], gpu.luma[4], accuracy: Self.tolerance,
                       "the kernel ignored a fourth-channel gain of two")
        XCTAssertEqual(gpu.luma[8], gpu.luma[4], accuracy: Self.tolerance,
                       "a fourth channel below one changed the recorded light")
        XCTAssertEqual(gpu.chroma[0], gpu.chroma[2], accuracy: Self.tolerance,
                       "the gain moved chroma off the light it should have matched")
    }

    func testThePreviewIsDecodedFromTheWrittenMain10Block() throws {
        let (pixels, width, height) = probeFrame()
        let gpu = try runKernel(pixels, width: width, height: height,
                                half: true, preview: true)
        let preview = try XCTUnwrap(gpu.preview)
        let matrix = HLGTransfer.rec2020ToDisplayP3
        for y in 0..<height {
            for x in 0..<width {
                let block = (y / 2) * (width / 2) + x / 2
                let open = HLGTransfer.decode(
                    luma: gpu.luma[y * width + x],
                    cb: gpu.chroma[block * 2], cr: gpu.chroma[block * 2 + 1])
                let optical = HLGTransfer.openToOptical(
                    r: open.0, g: open.1, b: open.2)
                let expected = SIMD3<Float>(
                    max(matrix[0] * optical.r + matrix[1] * optical.g
                        + matrix[2] * optical.b, 0),
                    max(matrix[3] * optical.r + matrix[4] * optical.g
                        + matrix[5] * optical.b, 0),
                    max(matrix[6] * optical.r + matrix[7] * optical.g
                        + matrix[8] * optical.b, 0))
                let offset = (y * width + x) * 4
                for channel in 0..<3 {
                    XCTAssertEqual(preview[offset + channel], expected[channel],
                                   accuracy: 0.003)
                }
                XCTAssertEqual(preview[offset + 3], 1, accuracy: 0.001)
            }
        }
    }
}
#endif
