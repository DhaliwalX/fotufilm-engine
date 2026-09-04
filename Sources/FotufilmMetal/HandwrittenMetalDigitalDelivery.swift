#if canImport(Metal)
import Foundation
import Metal

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Downstream video delivery from the optical engine's single linear Display P3 HDR master.
///
/// This stage does not capture, develop, grade, or select an output medium. HDR applies the same
/// hue-preserving highlight shoulder, Display P3 → Rec.2020 matrix, inverse HLG OOTF, and HLG OETF
/// as `HLGTransfer`, then emits BT.2020 non-constant-luminance Y′CbCr. SDR is derived from that
/// same master: linear Display P3 → linear Rec.709, negative gamut clipping, the engine's
/// per-channel 0.9-knee SDR shoulder, BT.709 OETF, then BT.709 Y′CbCr. Both outputs use 10-bit
/// video-range codes in x420's left-justified `r16Unorm`/`rg16Unorm` planes.
public final class HandwrittenMetalDigitalDelivery {
    public enum Output: String, Sendable, CaseIterable {
        case hdrHLGRec2020
        case sdrRec709
    }

    public enum DeliveryError: Swift.Error, CustomStringConvertible {
        case pipelineUnavailable(String)
        case commandBufferAlreadyEnqueued
        case deviceMismatch
        case invalidMasterTexture
        case invalidLumaTexture
        case invalidChromaTexture
        case encoderUnavailable

        public var description: String {
            switch self {
            case let .pipelineUnavailable(reason):
                return "digital-delivery Metal pipeline unavailable: \(reason)"
            case .commandBufferAlreadyEnqueued:
                return "digital delivery requires a command buffer that has not been enqueued"
            case .deviceMismatch:
                return "digital-delivery textures and command buffer must use the renderer device"
            case .invalidMasterTexture:
                return "master must be an even-sized, nonempty rgba16Float 2D texture"
            case .invalidLumaTexture:
                return "luma must be an r16Unorm 2D texture matching the master dimensions"
            case .invalidChromaTexture:
                return "chroma must be an rg16Unorm 2D texture at half the master dimensions"
            case .encoderUnavailable:
                return "could not allocate the digital-delivery compute encoder"
            }
        }
    }

    private let device: MTLDevice
    private let hdrPipeline: MTLComputePipelineState
    private let sdrPipeline: MTLComputePipelineState

    public convenience init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = try? HandwrittenMetalDigitalDelivery(device: device)
        else { return nil }
        self.init(renderer: renderer)
    }

    private convenience init(renderer: HandwrittenMetalDigitalDelivery) {
        self.init(
            device: renderer.device,
            hdrPipeline: renderer.hdrPipeline,
            sdrPipeline: renderer.sdrPipeline)
    }

    public init(device: MTLDevice) throws {
        let options = MTLCompileOptions()
        // Delivery lands on integer video codes. Safe math keeps the CPU/GPU parity bound at the
        // quantizer instead of letting relaxed pow/log approximations move code boundaries.
        if #available(macOS 15.0, iOS 18.0, *) {
            options.mathMode = .safe
        } else {
            options.fastMathEnabled = false
        }

        do {
            let library = try HandwrittenMetalShaderLibrary.makeLibrary(
                device: device, shader: .digitalDelivery, options: options,
                preprocessorMacros: HandwrittenMetalShaderLibrary.digitalDeliveryMacros)
            guard let hdrFunction = library.makeFunction(
                    name: "fotufilm_deliver_hdr_hlg_x420"),
                  let sdrFunction = library.makeFunction(
                    name: "fotufilm_deliver_sdr_rec709_x420")
            else {
                throw DeliveryError.pipelineUnavailable("missing kernel function")
            }
            self.device = device
            hdrPipeline = try device.makeComputePipelineState(function: hdrFunction)
            sdrPipeline = try device.makeComputePipelineState(function: sdrFunction)
        } catch let error as DeliveryError {
            throw error
        } catch {
            throw DeliveryError.pipelineUnavailable(String(describing: error))
        }
    }

    private init(
        device: MTLDevice, hdrPipeline: MTLComputePipelineState,
        sdrPipeline: MTLComputePipelineState
    ) {
        self.device = device
        self.hdrPipeline = hdrPipeline
        self.sdrPipeline = sdrPipeline
    }

    /// Records one delivery transform into a caller-owned command buffer without committing it.
    /// One GPU invocation consumes each 2×2 master block and writes its four luma samples and one
    /// averaged chroma pair directly to the destination planes.
    public func encode(
        master: MTLTexture, luma: MTLTexture, chroma: MTLTexture,
        output: Output,
        sdrShoulderKnee: Float = FilmSDRDelivery.standardShoulderKnee,
        commandBuffer: MTLCommandBuffer
    ) throws {
        guard commandBuffer.status == .notEnqueued else {
            throw DeliveryError.commandBufferAlreadyEnqueued
        }
        guard commandBuffer.commandQueue.device.registryID == device.registryID,
              master.device.registryID == device.registryID,
              luma.device.registryID == device.registryID,
              chroma.device.registryID == device.registryID
        else { throw DeliveryError.deviceMismatch }
        guard master.textureType == .type2D, master.pixelFormat == .rgba16Float,
              master.width > 0, master.height > 0,
              master.width.isMultiple(of: 2), master.height.isMultiple(of: 2)
        else { throw DeliveryError.invalidMasterTexture }
        guard luma.textureType == .type2D, luma.pixelFormat == .r16Unorm,
              luma.width == master.width, luma.height == master.height
        else { throw DeliveryError.invalidLumaTexture }
        guard chroma.textureType == .type2D, chroma.pixelFormat == .rg16Unorm,
              chroma.width == master.width / 2, chroma.height == master.height / 2
        else { throw DeliveryError.invalidChromaTexture }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw DeliveryError.encoderUnavailable
        }

        let pipeline = output == .hdrHLGRec2020 ? hdrPipeline : sdrPipeline
        encoder.label = output == .hdrHLGRec2020
            ? "Fotufilm linear HDR master → x420 HLG Rec.2020"
            : "Fotufilm linear HDR master → x420 SDR Rec.709"
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(master, index: 0)
        encoder.setTexture(luma, index: 1)
        encoder.setTexture(chroma, index: 2)
        var shoulderKnee = sdrShoulderKnee
        encoder.setBytes(&shoulderKnee, length: MemoryLayout<Float>.stride,
                         index: 0)
        let groupWidth = min(pipeline.threadExecutionWidth, 16)
        let groupHeight = max(1, min(
            8, pipeline.maxTotalThreadsPerThreadgroup / max(groupWidth, 1)))
        encoder.dispatchThreads(
            MTLSize(width: master.width / 2, height: master.height / 2, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: groupWidth, height: groupHeight, depth: 1))
        encoder.endEncoding()
    }

}
#endif
