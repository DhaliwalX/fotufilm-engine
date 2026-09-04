import CoreVideo
import Foundation
import Metal

#if canImport(FotufilmImaging)
import FotufilmImaging
#endif

/// Writing a developed float print into a 10-bit HLG frame.
enum HLGRecording {
    private struct MetalState {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let pipeline: MTLComputePipelineState
        let textureCache: CVMetalTextureCache
        /// One texture cache and one queue for the process, and `CVMetalTextureCache` is nowhere
        /// documented thread-safe — while two paths reach them: the camera's frame queue and the
        /// editor's export task.
        let encoding = NSLock()
    }

    private static let metalState: MetalState? = {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        // Source, entry point, compile options and argument indices all come from the package,
        // where the parity test compiles and runs the same kernel against `HLGTransfer`.
        guard let library = try? device.makeLibrary(
                source: HLGRecordingKernel.source,
                options: HLGRecordingKernel.compileOptions),
              let function = library.makeFunction(
                name: HLGRecordingKernel.functionName),
              let pipeline = try? device.makeComputePipelineState(
                function: function) else { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device,
                                        nil, &cache) == kCVReturnSuccess,
              let cache else { return nil }
        return MetalState(device: device, queue: queue, pipeline: pipeline,
                          textureCache: cache)
    }()


    /// Converts one print and fills `destination`, which must be a
    /// `420YpCbCr10BiPlanarVideoRange` buffer of the same size.
    static func write(print buffer: MTLBuffer, width: Int, height: Int,
                      into destination: CVPixelBuffer) -> Bool {
        guard buffer.length >= width * height * 16 else { return false }
        guard writeOnGPU(print: buffer, width: width, height: height,
                         into: destination)
                || write(
                    print: UnsafePointer(
                        buffer.contents().assumingMemoryBound(to: Float.self)),
                    width: width, height: height, into: destination)
        else { return false }

        CVBufferSetAttachment(destination,
                              kCVImageBufferChromaLocationTopFieldKey,
                              kCVImageBufferChromaLocation_Center,
                              .shouldPropagate)
        return true
    }

    private static func writeOnGPU(
        print buffer: MTLBuffer, width: Int, height: Int,
        into destination: CVPixelBuffer
    ) -> Bool {
        guard width > 0, height > 0, width % 2 == 0, height % 2 == 0,
              let state = metalState,
              buffer.device.registryID == state.device.registryID,
              CVPixelBufferGetPixelFormatType(destination)
                == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(destination) == 2,
              CVPixelBufferGetWidthOfPlane(destination, 0) == width,
              CVPixelBufferGetHeightOfPlane(destination, 0) == height
        else { return false }

        state.encoding.lock()
        defer { state.encoding.unlock() }

        var lumaReference: CVMetalTexture?
        var chromaReference: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, state.textureCache, destination, nil,
                .r16Unorm, width, height, 0,
                &lumaReference) == kCVReturnSuccess,
              CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, state.textureCache, destination, nil,
                .rg16Unorm, width / 2, height / 2, 1,
                &chromaReference) == kCVReturnSuccess,
              let lumaReference, let chromaReference,
              let luma = CVMetalTextureGetTexture(lumaReference),
              let chroma = CVMetalTextureGetTexture(chromaReference),
              let commands = state.queue.makeCommandBuffer(),
              let encoder = commands.makeComputeCommandEncoder()
        else { return false }

        encoder.setComputePipelineState(state.pipeline)
        encoder.setBuffer(buffer, offset: 0,
                          index: HLGRecordingKernel.Argument.source)
        encoder.setTexture(luma, index: 0)
        encoder.setTexture(chroma, index: 1)
        var size = SIMD2<UInt32>(UInt32(width), UInt32(height))
        encoder.setBytes(&size, length: MemoryLayout<SIMD2<UInt32>>.size,
                         index: HLGRecordingKernel.Argument.size)
        var curve = HLGRecordingKernel.curve
        encoder.setBytes(&curve, length: MemoryLayout<SIMD4<Float>>.size,
                         index: HLGRecordingKernel.Argument.curve)
        var hlgTail = HLGRecordingKernel.tail
        encoder.setBytes(&hlgTail, length: MemoryLayout<SIMD2<Float>>.size,
                         index: HLGRecordingKernel.Argument.tail)
        encoder.dispatchThreads(
            MTLSize(width: width / 2, height: height / 2, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        withExtendedLifetime((lumaReference, chromaReference)) {}
        return commands.status == .completed
    }

    /// Pointer form used when a finished print has been resized for export.
    static func write(print source: UnsafePointer<Float>, width: Int, height: Int,
                      into destination: CVPixelBuffer) -> Bool {
        guard width > 0, height > 0, width % 2 == 0, height % 2 == 0,
              CVPixelBufferGetPixelFormatType(destination)
                == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(destination) == 2,
              CVPixelBufferGetWidthOfPlane(destination, 0) == width,
              CVPixelBufferGetHeightOfPlane(destination, 0) == height
        else { return false }

        CVPixelBufferLockBaseAddress(destination, [])
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(destination, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(destination, 1)
        else { return false }
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(destination, 0) / 2
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(destination, 1) / 2
        let luma = lumaBase.assumingMemoryBound(to: UInt16.self)
        let chroma = chromaBase.assumingMemoryBound(to: UInt16.self)

        let chromaRows = height / 2
        let workers = chromaRows >= 128 ? min(8, chromaRows) : 1
        let band = (chromaRows + workers - 1) / workers
        DispatchQueue.concurrentPerform(iterations: workers) { index in
            let start = index * band
            let end = min(chromaRows, start + band)
            guard start < end else { return }
            for chromaY in start..<end {
                let y = chromaY * 2
                let top = source.advanced(by: y * width * 4)
                let bottom = top.advanced(by: width * 4)
                let topLuma = luma.advanced(by: y * lumaStride)
                let bottomLuma = topLuma.advanced(by: lumaStride)
                let chromaRow = chroma.advanced(by: chromaY * chromaStride)
                for x in stride(from: 0, to: width, by: 2) {
                    let topPixel = top.advanced(by: x * 4)
                    let bottomPixel = bottom.advanced(by: x * 4)
                    let encoded = HLGTransfer.encode420(
                        topLeft: SIMD3(topPixel[0], topPixel[1], topPixel[2])
                            * max(topPixel[3], 1),
                        topRight: SIMD3(topPixel[4], topPixel[5], topPixel[6])
                            * max(topPixel[7], 1),
                        bottomLeft: SIMD3(
                            bottomPixel[0], bottomPixel[1], bottomPixel[2])
                            * max(bottomPixel[3], 1),
                        bottomRight: SIMD3(
                            bottomPixel[4], bottomPixel[5], bottomPixel[6])
                            * max(bottomPixel[7], 1))
                    topLuma[x] = code(encoded.luma.x * 876 + 64)
                    topLuma[x + 1] = code(encoded.luma.y * 876 + 64)
                    bottomLuma[x] = code(encoded.luma.z * 876 + 64)
                    bottomLuma[x + 1] = code(encoded.luma.w * 876 + 64)
                    chromaRow[x] = code(encoded.u * 896 + 512)
                    chromaRow[x + 1] = code(encoded.v * 896 + 512)
                }
            }
        }
        return true
    }


    private static func code(_ value: Float) -> UInt16 {
        UInt16(min(max(value.rounded(), 0), 1023)) << 6
    }
}
