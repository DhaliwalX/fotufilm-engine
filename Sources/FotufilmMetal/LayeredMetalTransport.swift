import Foundation
import Metal
import FotufilmHalide
#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// The same positive pixel stencils as the reference renderer, executed on Metal without a
/// Halide JIT dependency. Scene preparation and development use the shipping AOT entry points.
public enum LayeredMetalTransport {
    public static func process(_ pixels: [Float], width: Int, height: Int, stock: FilmStock,
                               options: FotufilmEngine.Options, frameIndex: UInt64 = 0,
                               invocation: FilmEngineInvocation? = nil, pixelPitchMM: Double? = nil) throws -> [Float] {
        guard pixels.count == width * height * 4, let model = options.transportConstruction(for: stock),
              let convolution = Convolution.shared else { throw TransportError.backend("Metal transport unavailable") }
        var input = ImageBuffer(width: width, height: height)
        for c in 0..<3 { for i in 0..<input.pixelCount { input.planes[c][i] = pixels[4*i+c] } }
        let execution = TransportExecution(render: render,
            convolve: { try convolution.apply($0, stencil: $1) })
        let result = try LayeredTransportRenderer.process(image: input, stock: stock, options: options,
            model: model, frameIndex: frameIndex, execution: execution,
            invocation: invocation, pixelPitchMM: pixelPitchMM)
        var output = pixels
        for c in 0..<3 { for i in 0..<input.pixelCount { output[4*i+c] = result.planes[c][i] } }
        return output
    }

    private static func render(_ image: ImageBuffer, _ supplied: FilmEngineInvocation,
                               _ lightOnly: Bool) throws -> ImageBuffer {
        var invocation = supplied
        invocation.featureMask |= FilmEngineFeature.floatIO
        var input = Array(repeating: Float(1), count: image.pixelCount * 4)
        for c in 0..<3 { for i in 0..<image.pixelCount { input[4*i+c] = image.planes[c][i] } }
        if invocation.featureMask & FilmEngineFeature.flare != 0 {
            input.withUnsafeBufferPointer {
                invocation.flareMean = invocation.measuredAreaWeightedFlareMean(
                    linearRGBA: $0.baseAddress!, width: image.width, height: image.height)
            }
        }
        var output = input
        let status = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                invocation.configuration.withUnsafeBufferPointer { config in
                    invocation.withSpectralPointers { exposure, film, paper in
                        fotufilm_halide_metal_process_linear_float(source.baseAddress, destination.baseAddress,
                            Int32(image.width), Int32(image.height), 0, 0, config.baseAddress,
                            exposure, film, paper, Int32(invocation.spectral.exposure.dimension),
                            invocation.spectralCacheID, invocation.featureMask, invocation.seed)
                    }
                }
            }
        }
        guard status == 0 else { throw TransportError.backend("Metal transport stage failed (\(status))") }
        var result = image
        for c in 0..<3 { for i in 0..<image.pixelCount { result.planes[c][i] = output[4*i+c] } }
        return result
    }

    private final class Convolution {
        static let shared = try? Convolution()
        let device: MTLDevice
        let queue: MTLCommandQueue
        let pipelines: [MTLComputePipelineState]

        init() throws {
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
                throw TransportError.backend("Metal device unavailable")
            }
            self.device = device; self.queue = queue
            let options = MTLCompileOptions(); options.fastMathEnabled = false
            let library = try device.makeLibrary(source: Self.source, options: options)
            pipelines = try ["transport_down", "transport_blur", "transport_up"].map {
                guard let function = library.makeFunction(name: $0) else { throw TransportError.backend("missing Metal transport kernel") }
                return try device.makeComputePipelineState(function: function)
            }
        }

        func apply(_ image: ImageBuffer, stencil: TransportStencil) throws -> ImageBuffer {
            let w = image.width, h = image.height, scale = stencil.stride
            let gw = (w+scale-1)/scale, gh = (h+scale-1)/scale
            let source = image.planes.flatMap { $0 }
            guard let input = device.makeBuffer(bytes: source, length: source.count*4, options: .storageModeShared),
                  let weights = device.makeBuffer(bytes: stencil.weights, length: stencil.weights.count*4, options: .storageModeShared),
                  let down = device.makeBuffer(length: gw*gh*3*4, options: .storageModePrivate),
                  let blurred = device.makeBuffer(length: gw*gh*3*4, options: .storageModePrivate),
                  let output = device.makeBuffer(length: source.count*4, options: .storageModeShared),
                  let command = queue.makeCommandBuffer() else { throw TransportError.backend("Metal transport allocation failed") }
            var dimensions = [UInt32(w), UInt32(h), UInt32(gw), UInt32(gh), UInt32(scale), UInt32(stencil.radius)]
            for pass in 0..<3 {
                guard let encoder = command.makeComputeCommandEncoder() else { throw TransportError.backend("Metal transport encoder failed") }
                encoder.setComputePipelineState(pipelines[pass])
                encoder.setBuffer(pass == 0 ? input : (pass == 1 ? down : blurred), offset: 0, index: 0)
                encoder.setBuffer(pass == 0 ? down : (pass == 1 ? blurred : output), offset: 0, index: 1)
                encoder.setBuffer(weights, offset: 0, index: 2)
                encoder.setBytes(&dimensions, length: 6*4, index: 3)
                let count = pass == 2 ? w*h*3 : gw*gh*3
                encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: min(256, pipelines[pass].maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
                encoder.endEncoding()
            }
            command.commit(); command.waitUntilCompleted()
            guard command.status == .completed else { throw TransportError.backend(command.error?.localizedDescription ?? "Metal transport failed") }
            let values = output.contents().assumingMemoryBound(to: Float.self)
            return ImageBuffer(width: w, height: h, planes: (0..<3).map {
                Array(UnsafeBufferPointer(start: values+$0*w*h, count: w*h))
            })
        }

        static let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct D { uint w,h,gw,gh,s,r; };
        kernel void transport_down(device const float* a [[buffer(0)]], device float* b [[buffer(1)]],
            device const float* k [[buffer(2)]], constant D& d [[buffer(3)]], uint i [[thread_position_in_grid]]) {
            if(i>=d.gw*d.gh*3)return; uint c=i/(d.gw*d.gh), x=i%d.gw, y=(i/d.gw)%d.gh;
            float sum=0; for(uint yy=0;yy<d.s;++yy)for(uint xx=0;xx<d.s;++xx)
                sum+=a[c*d.w*d.h+min(y*d.s+yy,d.h-1)*d.w+min(x*d.s+xx,d.w-1)];
            b[i]=sum/float(d.s*d.s);
        }
        kernel void transport_blur(device const float* a [[buffer(0)]], device float* b [[buffer(1)]],
            device const float* k [[buffer(2)]], constant D& d [[buffer(3)]], uint i [[thread_position_in_grid]]) {
            if(i>=d.gw*d.gh*3)return; int c=i/(d.gw*d.gh), x=i%d.gw, y=(i/d.gw)%d.gh, r=d.r;
            float sum=0; for(int yy=-r;yy<=r;++yy)for(int xx=-r;xx<=r;++xx){
                float weight=k[(yy+r)*(2*r+1)+xx+r];
                sum+=weight*a[c*d.gw*d.gh+clamp(y+yy,0,int(d.gh)-1)*d.gw+clamp(x+xx,0,int(d.gw)-1)];
            } b[i]=sum;
        }
        kernel void transport_up(device const float* a [[buffer(0)]], device float* b [[buffer(1)]],
            device const float* k [[buffer(2)]], constant D& d [[buffer(3)]], uint i [[thread_position_in_grid]]) {
            if(i>=d.w*d.h*3)return; uint c=i/(d.w*d.h), x=i%d.w, y=(i/d.w)%d.h;
            float px=(float(x)+.5f)/float(d.s)-.5f, py=(float(y)+.5f)/float(d.s)-.5f;
            int ix=int(floor(px)), iy=int(floor(py)); float fx=px-floor(px), fy=py-floor(py);
            uint x0=clamp(ix,0,int(d.gw)-1), x1=clamp(ix+1,0,int(d.gw)-1);
            uint y0=clamp(iy,0,int(d.gh)-1), y1=clamp(iy+1,0,int(d.gh)-1), o=c*d.gw*d.gh;
            b[i]=(1-fx)*((1-fy)*a[o+y0*d.gw+x0]+fy*a[o+y1*d.gw+x0])
                +fx*((1-fy)*a[o+y0*d.gw+x1]+fy*a[o+y1*d.gw+x1]);
        }
        """
    }
}
