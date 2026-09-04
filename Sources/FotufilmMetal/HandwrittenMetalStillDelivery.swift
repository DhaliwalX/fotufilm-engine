#if canImport(Metal)
import Foundation
import Metal

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Zero-readback RGB delivery from the optical engine's single RGBA16F HDR master.
///
/// The output remains 16-bit half float until ImageIO quantizes and packs it as 10-bit HEIF.
/// HDR and SDR use the exact same transfer source as x420 video delivery.
public final class HandwrittenMetalStillDelivery {
    public enum Output: String, Sendable, CaseIterable {
        case hdrHLGRec2020
        case sdrRec709
    }

    public enum DeliveryError: Swift.Error, CustomStringConvertible {
        case pipelineUnavailable(String)
        case commandBufferAlreadyEnqueued
        case deviceMismatch
        case invalidMasterTexture
        case invalidOutputTexture
        case encoderUnavailable

        public var description: String {
            switch self {
            case let .pipelineUnavailable(reason):
                return "still-delivery Metal pipeline unavailable: \(reason)"
            case .commandBufferAlreadyEnqueued:
                return "still delivery requires a command buffer that has not been enqueued"
            case .deviceMismatch:
                return "still-delivery textures and command buffer must use one device"
            case .invalidMasterTexture:
                return "master must be a nonempty shader-readable rgba16Float 2D texture"
            case .invalidOutputTexture:
                return "output must be a same-size shader-writable rgba16Float 2D texture"
            case .encoderUnavailable:
                return "could not allocate the still-delivery compute encoder"
            }
        }
    }

    private let device: MTLDevice
    private let hdrPipeline: MTLComputePipelineState
    private let sdrPipeline: MTLComputePipelineState

    public init(device: MTLDevice) throws {
        let options = MTLCompileOptions()
        if #available(macOS 15.0, iOS 18.0, *) {
            options.mathMode = .safe
        } else {
            options.fastMathEnabled = false
        }
        do {
            let library = try HandwrittenMetalShaderLibrary.makeLibrary(
                device: device, shader: .stillDelivery, options: options,
                preprocessorMacros: HandwrittenMetalShaderLibrary.digitalDeliveryMacros)
            guard let hdr = library.makeFunction(
                    name: "fotufilm_deliver_hdr_hlg_rgb"),
                  let sdr = library.makeFunction(
                    name: "fotufilm_deliver_sdr_rec709_rgb")
            else { throw DeliveryError.pipelineUnavailable("missing kernel function") }
            self.device = device
            hdrPipeline = try device.makeComputePipelineState(function: hdr)
            sdrPipeline = try device.makeComputePipelineState(function: sdr)
        } catch let error as DeliveryError {
            throw error
        } catch {
            throw DeliveryError.pipelineUnavailable(String(describing: error))
        }
    }

    /// Records the selected downstream encoding into `commandBuffer`; it does not commit or wait.
    public func encode(
        master: MTLTexture, output: MTLTexture, as delivery: Output,
        sdrShoulderKnee: Float = FilmSDRDelivery.standardShoulderKnee,
        commandBuffer: MTLCommandBuffer
    ) throws {
        guard commandBuffer.status == .notEnqueued else {
            throw DeliveryError.commandBufferAlreadyEnqueued
        }
        guard commandBuffer.commandQueue.device.registryID == device.registryID,
              master.device.registryID == device.registryID,
              output.device.registryID == device.registryID
        else { throw DeliveryError.deviceMismatch }
        guard master.textureType == .type2D,
              master.pixelFormat == .rgba16Float,
              master.width > 0, master.height > 0,
              master.usage.contains(.shaderRead)
        else { throw DeliveryError.invalidMasterTexture }
        guard output.textureType == .type2D,
              output.pixelFormat == .rgba16Float,
              output.width == master.width, output.height == master.height,
              output.usage.contains(.shaderWrite)
        else { throw DeliveryError.invalidOutputTexture }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw DeliveryError.encoderUnavailable
        }
        let pipeline = delivery == .hdrHLGRec2020 ? hdrPipeline : sdrPipeline
        encoder.label = delivery == .hdrHLGRec2020
            ? "Fotufilm HDR master → HLG Rec.2020 RGB still"
            : "Fotufilm HDR master → SDR Rec.709 RGB still"
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(master, index: 0)
        encoder.setTexture(output, index: 1)
        var shoulderKnee = sdrShoulderKnee
        encoder.setBytes(&shoulderKnee, length: MemoryLayout<Float>.stride,
                         index: 0)
        let width = min(pipeline.threadExecutionWidth, 16)
        let height = max(1, min(
            8, pipeline.maxTotalThreadsPerThreadgroup / max(width, 1)))
        encoder.dispatchThreads(
            MTLSize(width: master.width, height: master.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
        encoder.endEncoding()
    }
}
#endif
