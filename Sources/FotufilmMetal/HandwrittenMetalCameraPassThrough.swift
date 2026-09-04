#if canImport(Metal)
import Foundation
import Metal

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Decodes the native camera planes into the same extended-linear Display P3 master the
/// viewfinder consumes when no film is loaded. This is a capture endpoint, not a preview graph:
/// recording and display share the caller-owned RGBA16F result.
public final class HandwrittenMetalCameraPassThrough {
    public typealias HDRCaptureTransfer = HandwrittenMetalSpectralHead.HDRCaptureTransfer
    public typealias SDRCaptureRange = HandwrittenMetalSpectralHead.SDRCaptureRange
    public typealias SDRCaptureGamut = HandwrittenMetalSpectralHead.SDRCaptureGamut

    static let decodeSamples = 256

    private struct Parameters {
        var extentAndSource: SIMD4<UInt32>
        var scaleAndChroma: SIMD4<Float>
    }

    private let device: MTLDevice
    private let sdrPipeline: MTLComputePipelineState
    private let hdrPipeline: MTLComputePipelineState
    private let decode: MTLTexture

    public convenience init?() {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.init(device: device)
    }

    public init?(device: MTLDevice) {
        let options = MTLCompileOptions()
        if #available(macOS 15.0, iOS 18.0, *) {
            options.mathMode = .fast
        } else {
            options.fastMathEnabled = true
        }
        do {
            let library = try HandwrittenMetalShaderLibrary.makeLibrary(
                device: device, shader: .cameraPassThrough, options: options,
                preprocessorMacros: [
                    "FOTUFILM_CAMERA_DECODE_SAMPLES": NSNumber(
                        value: Self.decodeSamples),
                ])
            guard let sdr = library.makeFunction(
                    name: "fotufilm_camera_passthrough_nv12"),
                  let hdr = library.makeFunction(
                    name: "fotufilm_camera_passthrough_x420"),
                  let decode = Self.makeDecodeTexture(device: device)
            else { return nil }
            sdrPipeline = try device.makeComputePipelineState(function: sdr)
            hdrPipeline = try device.makeComputePipelineState(function: hdr)
            self.decode = decode
        } catch {
            print("HandwrittenMetalCameraPassThrough: Metal library failed (\(error))")
            return nil
        }
        self.device = device
    }

    @discardableResult
    public func encodeCapturedSDR(
        luma: MTLTexture, chroma: MTLTexture, output: MTLTexture,
        width: Int, height: Int, range: SDRCaptureRange,
        gamut: SDRCaptureGamut, chromaOffset: SIMD2<Float> = .zero,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        encode(
            luma: luma, chroma: chroma, output: output,
            width: width, height: height,
            sourceA: range.rawValue, sourceB: gamut.rawValue,
            scale: 1, chromaOffset: chromaOffset,
            pipeline: sdrPipeline, bindsDecode: true,
            commandBuffer: commandBuffer)
    }

    @discardableResult
    public func encodeCapturedHDR(
        luma: MTLTexture, chroma: MTLTexture, output: MTLTexture,
        width: Int, height: Int, transfer: HDRCaptureTransfer,
        sceneScale: Float, chromaOffset: SIMD2<Float> = .zero,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        guard sceneScale.isFinite, sceneScale >= 0 else { return false }
        return encode(
            luma: luma, chroma: chroma, output: output,
            width: width, height: height,
            sourceA: transfer.rawValue, sourceB: 0,
            scale: sceneScale, chromaOffset: chromaOffset,
            pipeline: hdrPipeline, bindsDecode: false,
            commandBuffer: commandBuffer)
    }

    private func encode(
        luma: MTLTexture, chroma: MTLTexture, output: MTLTexture,
        width: Int, height: Int, sourceA: UInt32, sourceB: UInt32,
        scale: Float, chromaOffset: SIMD2<Float>,
        pipeline: MTLComputePipelineState, bindsDecode: Bool,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        guard width > 0, height > 0,
              width <= Int(UInt32.max), height <= Int(UInt32.max),
              chromaOffset.x.isFinite, chromaOffset.y.isFinite,
              commandBuffer.status == .notEnqueued,
              commandBuffer.commandQueue.device.registryID == device.registryID,
              validPlanes(luma: luma, chroma: chroma,
                          width: width, height: height),
              validOutput(output, width: width, height: height),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return false }
        var parameters = Parameters(
            extentAndSource: SIMD4(
                UInt32(width), UInt32(height), sourceA, sourceB),
            scaleAndChroma: SIMD4(
                scale, chromaOffset.x, chromaOffset.y, 0))
        encoder.label = "Fotufilm native camera pass-through"
        encoder.setComputePipelineState(pipeline)
        encoder.setBytes(
            &parameters, length: MemoryLayout<Parameters>.stride, index: 0)
        encoder.setTexture(luma, index: 0)
        encoder.setTexture(chroma, index: 1)
        if bindsDecode { encoder.setTexture(decode, index: 2) }
        encoder.setTexture(output, index: 3)
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        commandBuffer.addCompletedHandler { [self, luma, chroma, output] _ in
            withExtendedLifetime((self, luma, chroma, output)) {}
        }
        return true
    }

    private func validPlanes(
        luma: MTLTexture, chroma: MTLTexture, width: Int, height: Int
    ) -> Bool {
        luma.device.registryID == device.registryID
            && chroma.device.registryID == device.registryID
            && luma.textureType == .type2D && chroma.textureType == .type2D
            && luma.width == width && luma.height == height
            && chroma.width == width / 2 && chroma.height == height / 2
            && luma.usage.contains(.shaderRead)
            && chroma.usage.contains(.shaderRead)
    }

    private func validOutput(_ output: MTLTexture, width: Int, height: Int) -> Bool {
        output.device.registryID == device.registryID
            && output.textureType == .type2D
            && output.pixelFormat == .rgba16Float
            && output.width == width && output.height == height
            && output.usage.contains(.shaderWrite)
    }

    private static func makeDecodeTexture(device: MTLDevice) -> MTLTexture? {
        var values = [Float16](repeating: 0, count: decodeSamples)
        for index in values.indices {
            values[index] = Float16(ColorScience.srgbToLinear(
                Float(index) / Float(decodeSamples - 1)))
        }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type1D
        descriptor.pixelFormat = .r16Float
        descriptor.width = values.count
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        values.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake1D(0, values.count), mipmapLevel: 0,
                withBytes: bytes.baseAddress!, bytesPerRow: bytes.count)
        }
        return texture
    }
}
#endif
