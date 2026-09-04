#if canImport(Metal)
import Foundation
import Metal

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// A one-dispatch scene-linear form of the exact hand-written pointwise chemistry.
///
/// Preparation evaluates the existing spectral/film/print executor at the nodes of a logarithmic
/// scene cube. Per-frame execution then performs only one deterministic hardware-filtered lookup.
/// The cube is an acceleration structure, not a different look: it is rebuilt for every edit and
/// retains the same scene-referred input and linear Display-P3 Digital Reference output contracts.
public final class HandwrittenMetalComposedPointwise {
    struct Binding {
        let cube: MTLTexture
        let inputKnee: Float
        let shaperScale: Float
    }

    public enum Interpolation: String, Sendable, CaseIterable {
        case trilinear
        case tetrahedral
    }

    public enum PreparationError: Swift.Error, CustomStringConvertible {
        case invalidDimensions
        case unsupportedSceneAdjustment
        case pointwisePreparation
        case allocationFailed
        case cubeBakeFailed

        public var description: String {
            switch self {
            case .invalidDimensions:
                return "frame dimensions and scene ceiling must be positive"
            case .unsupportedSceneAdjustment:
                return "the composed cube currently requires scene adjustments to be resolved before its input"
            case .pointwisePreparation:
                return "the exact hand-written pointwise executor could not prepare the cube"
            case .allocationFailed:
                return "unable to allocate the composed scene cube"
            case .cubeBakeFailed:
                return "the exact hand-written pointwise executor could not bake the cube"
            }
        }
    }

    private struct Parameters {
        var width: UInt32
        var height: UInt32
        var inputKnee: Float
        var shaperScale: Float
    }

    private struct Prepared {
        let cube: MTLTexture
        let frameWidth: Int
        let frameHeight: Int
        let sceneCeiling: Float
        let inputKnee: Float
        let shaperScale: Float
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pointwise: HandwrittenMetalFilmRenderer
    private let trilinearPipeline: MTLComputePipelineState
    private let tetrahedralPipeline: MTLComputePipelineState
    private let cubeEdge: Int
    private let inputKnee: Float
    private let lock = NSLock()
    private var prepared: [String: Prepared] = [:]

    public convenience init?(cubeEdge: Int = 65, inputKnee: Float = 0.01) {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.init(device: device, cubeEdge: cubeEdge, inputKnee: inputKnee)
    }

    public init?(
        device: MTLDevice, cubeEdge: Int = 65, inputKnee: Float = 0.01
    ) {
        guard cubeEdge >= 17, cubeEdge <= 129,
              inputKnee.isFinite, inputKnee > 0 else { return nil }
        guard let queue = device.makeCommandQueue(),
              let pointwise = HandwrittenMetalFilmRenderer()
        else { return nil }
        do {
            let options = MTLCompileOptions()
            options.fastMathEnabled = true
            let library = try HandwrittenMetalShaderLibrary.makeLibrary(
                device: device, shader: .composedPointwise, options: options)
            guard let trilinear = library.makeFunction(
                    name: "fotufilm_handwritten_composed_pointwise_trilinear"),
                  let tetrahedral = library.makeFunction(
                    name: "fotufilm_handwritten_composed_pointwise_tetrahedral")
            else { return nil }
            trilinearPipeline = try device.makeComputePipelineState(function: trilinear)
            tetrahedralPipeline = try device.makeComputePipelineState(function: tetrahedral)
        } catch {
            print("HandwrittenMetalComposedPointwise: Metal library failed (\(error))")
            return nil
        }
        self.device = device
        self.queue = queue
        self.pointwise = pointwise
        self.cubeEdge = cubeEdge
        self.inputKnee = inputKnee
    }

    /// Prepares a cube for input whose scene adjustments have already been resolved. The initial
    /// implementation rejects active white-balance/tone/chroma controls so an unresolved control
    /// cannot be silently baked with the wrong per-pixel tone base.
    public func prepareChecked(
        key: String, stock: FilmStock, options: FotufilmEngine.Options,
        frameWidth: Int, frameHeight: Int, sceneCeiling: Float = 16
    ) throws {
        guard frameWidth > 0, frameHeight > 0,
              frameWidth <= Int(UInt32.max), frameHeight <= Int(UInt32.max),
              sceneCeiling.isFinite, sceneCeiling > 0
        else { throw PreparationError.invalidDimensions }
        let invocation = FilmEngineInvocation(
            stock: stock, options: options,
            width: frameWidth, height: frameHeight)
        let adjust = FilmEngineInvocation.sceneAdjustOffset
        let balance = FilmEngineInvocation.whiteBalanceOffset
        guard !invocation.localToneActive,
              invocation.configuration[adjust] == 0,
              invocation.configuration[adjust + 1] == 0,
              invocation.configuration[adjust + 2] == 1,
              invocation.configuration[adjust + 3] == 0,
              invocation.configuration[balance] == 1,
              invocation.configuration[balance + 1] == 1,
              invocation.configuration[balance + 2] == 1
        else { throw PreparationError.unsupportedSceneAdjustment }

        let cubeKey = "\(key)#composed-pointwise-cube"
        guard pointwise.prepareLinearHDR(
            key: cubeKey, stock: stock, options: options,
            frameWidth: cubeEdge, frameHeight: cubeEdge * cubeEdge)
        else { throw PreparationError.pointwisePreparation }

        let values = cubeEdge * cubeEdge * cubeEdge * 4
        let byteCount = values * MemoryLayout<Float16>.stride
        guard let input = device.makeBuffer(
                length: byteCount, options: .storageModeShared),
              let output = device.makeBuffer(
                length: byteCount, options: .storageModeShared)
        else { throw PreparationError.allocationFailed }
        let logCeiling = log2(sceneCeiling / inputKnee + 1)
        let samples = input.contents().assumingMemoryBound(to: Float16.self)
        for blue in 0..<cubeEdge {
            for green in 0..<cubeEdge {
                for red in 0..<cubeEdge {
                    let offset = ((blue * cubeEdge + green) * cubeEdge + red) * 4
                    samples[offset] = Float16(inputKnee * (
                        exp2(Float(red) / Float(cubeEdge - 1) * logCeiling) - 1))
                    samples[offset + 1] = Float16(inputKnee * (
                        exp2(Float(green) / Float(cubeEdge - 1) * logCeiling) - 1))
                    samples[offset + 2] = Float16(inputKnee * (
                        exp2(Float(blue) / Float(cubeEdge - 1) * logCeiling) - 1))
                    samples[offset + 3] = 1
                }
            }
        }
        guard pointwise.processLinearHalf(
            input: input, output: output,
            width: cubeEdge, height: cubeEdge * cubeEdge,
            key: cubeKey, frameIndex: 0)
        else { throw PreparationError.cubeBakeFailed }
        guard let cube = Self.makeCube(
            device: device, buffer: output, edge: cubeEdge)
        else { throw PreparationError.allocationFailed }

        let value = Prepared(
            cube: cube, frameWidth: frameWidth, frameHeight: frameHeight,
            sceneCeiling: sceneCeiling, inputKnee: inputKnee,
            shaperScale: Float(cubeEdge - 1) / logCeiling)
        lock.lock()
        prepared[key] = value
        lock.unlock()
        pointwise.removeAll()
    }

    @discardableResult
    public func prepare(
        key: String, stock: FilmStock, options: FotufilmEngine.Options,
        frameWidth: Int, frameHeight: Int, sceneCeiling: Float = 16
    ) -> Bool {
        do {
            try prepareChecked(
                key: key, stock: stock, options: options,
                frameWidth: frameWidth, frameHeight: frameHeight,
                sceneCeiling: sceneCeiling)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public func encodeLinearHalf(
        input: MTLBuffer, output: MTLBuffer,
        width: Int, height: Int, key: String,
        interpolation: Interpolation = .trilinear,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        let byteCount = width * height * 4 * MemoryLayout<Float16>.stride
        guard width > 0, height > 0,
              input.device.registryID == device.registryID,
              output.device.registryID == device.registryID,
              input.length >= byteCount, output.length >= byteCount,
              commandBuffer.status == .notEnqueued,
              commandBuffer.commandQueue.device.registryID == device.registryID
        else { return false }
        lock.lock()
        let state = prepared[key]
        lock.unlock()
        guard let state, state.frameWidth == width, state.frameHeight == height,
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return false }

        var parameters = Parameters(
            width: UInt32(width), height: UInt32(height),
            inputKnee: state.inputKnee, shaperScale: state.shaperScale)
        encoder.setComputePipelineState(
            interpolation == .trilinear ? trilinearPipeline : tetrahedralPipeline)
        encoder.setBuffer(input, offset: 0, index: 0)
        encoder.setBuffer(output, offset: 0, index: 1)
        encoder.setTexture(state.cube, index: 0)
        encoder.setBytes(
            &parameters, length: MemoryLayout<Parameters>.stride, index: 2)
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 32, height: 2, depth: 1))
        encoder.endEncoding()
        commandBuffer.addCompletedHandler { [self, input, output, state] _ in
            withExtendedLifetime((self, input, output, state)) {}
        }
        return true
    }

    @discardableResult
    public func processLinearHalf(
        input: MTLBuffer, output: MTLBuffer,
        width: Int, height: Int, key: String,
        interpolation: Interpolation = .trilinear
    ) -> Bool {
        guard let commandBuffer = queue.makeCommandBuffer(),
              encodeLinearHalf(
                input: input, output: output, width: width, height: height,
                key: key, interpolation: interpolation,
                commandBuffer: commandBuffer)
        else { return false }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.status == .completed
    }

    public func removeAll() {
        lock.lock()
        prepared.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    func binding(forKey key: String) -> Binding? {
        lock.lock()
        defer { lock.unlock() }
        guard let state = prepared[key] else { return nil }
        return Binding(
            cube: state.cube, inputKnee: state.inputKnee,
            shaperScale: state.shaperScale)
    }

    private static func makeCube(
        device: MTLDevice, buffer: MTLBuffer, edge: Int
    ) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba16Float
        descriptor.width = edge
        descriptor.height = edge
        descriptor.depth = edge
        descriptor.mipmapLevelCount = 1
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let cube = device.makeTexture(descriptor: descriptor) else { return nil }
        cube.replace(
            region: MTLRegionMake3D(0, 0, 0, edge, edge, edge),
            mipmapLevel: 0, slice: 0, withBytes: buffer.contents(),
            bytesPerRow: edge * 4 * MemoryLayout<Float16>.stride,
            bytesPerImage: edge * edge * 4 * MemoryLayout<Float16>.stride)
        return cube
    }
}
#endif
