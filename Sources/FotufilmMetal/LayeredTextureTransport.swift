#if canImport(Metal)
import Foundation
import Metal
#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Camera transport stays in the caller's command buffer. Spectral components stream through a
/// half exposure texture; convolution and positive accumulation use Float32 textures.
final class LayeredTextureTransport {
    let head: HandwrittenMetalSpectralHead
    let tail: FilmEngineInvocation
    private let device: MTLDevice
    private let plan: TransportRenderPlan
    private let kernels: [MTLComputePipelineState]
    private let weights: [[MTLBuffer]]
    private let lens: HandwrittenMetalSpatialExecutor?
    private let lensInvocation: FilmEngineInvocation

    init(device: MTLDevice, stock: FilmStock, options: FotufilmEngine.Options,
         invocation: FilmEngineInvocation, width: Int, height: Int) throws {
        self.device = device
        var exportOptions = options; exportOptions.localTone = false
        plan = try LayeredTransportRenderer.renderPlan(stock: stock, options: exportOptions,
                                                       width: width, height: height)
        guard let head = HandwrittenMetalSpectralHead(device: device) else {
            throw TransportError.backend("camera spectral head unavailable")
        }
        self.head = head
        var tail = invocation
        tail.clearTransportOptics(keepLens: false)
        tail.featureMask &= ~(FilmEngineFeature.flare | FilmEngineFeature.diffusion
            | FilmEngineFeature.mtf | FilmEngineFeature.mtfLuma | FilmEngineFeature.halation
            | FilmEngineFeature.annularHalation)
        self.tail = tail
        var lensInvocation = invocation
        lensInvocation.clearTransportOptics(keepLens: true)
        lensInvocation.featureMask &= FilmEngineFeature.flare | FilmEngineFeature.diffusion
        self.lensInvocation = lensInvocation
        if lensInvocation.featureMask != 0 {
            guard let lens = HandwrittenMetalSpatialExecutor(device: device,
                maximumInFlightFrames: plan.components.count * 2, optimizationVariant: .automatic) else {
                throw TransportError.backend("camera lens executor unavailable")
            }
            try lens.prepareChecked(key: "lens", stock: stock, options: options.withoutLayeredTransport,
                frameWidth: width, frameHeight: height, invocation: lensInvocation)
            self.lens = lens
        } else { lens = nil }
        for (k, component) in plan.components.enumerated() {
            var part = invocation
            part.setTransportExposure(SpectralLUT(dimension: 33, values: component.exposure))
            for (suffix, mode) in [("sdr", HandwrittenMetalSpectralHead.InputMode.encodedDisplayP3RGBA8),
                                    ("hdr", .linearRec2020RGBA16Float), ("float", .linearRec2020RGBA32Float)] {
                try head.prepareChecked(key: "\(k)-\(suffix)", invocation: part, mode: mode,
                    frameWidth: width, frameHeight: height, toneGrid: invocation.localToneActive ? .gpu : nil)
            }
        }
        weights = try plan.components.map { component in
            try component.bands.map { band in
                guard let buffer = device.makeBuffer(bytes: band.stencil.weights,
                    length: band.stencil.weights.count * 4, options: .storageModeShared) else {
                    throw TransportError.backend("camera transport weights allocation failed")
                }
                return buffer
            }
        }
        let compile = MTLCompileOptions(); compile.fastMathEnabled = false
        let library = try device.makeLibrary(source: Self.source, options: compile)
        kernels = try ["clear_sum", "down", "blur", "accumulate", "finish"].map { name in
            guard let function = library.makeFunction(name: name) else { throw TransportError.backend(name) }
            return try device.makeComputePipelineState(function: function)
        }
    }

    func encode(output: MTLTexture, suffix: String,
                measurements: HandwrittenMetalGlobalMeasurements,
                flareResources: HandwrittenMetalGlobalMeasurements.Resources?,
                commandBuffer: MTLCommandBuffer,
                expose: (HandwrittenMetalSpectralHead, String, MTLTexture) -> Bool) -> Bool {
        let w = output.width, h = output.height
        func texture(_ width: Int, _ height: Int, half: Bool = false) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: half ? .rgba16Float : .rgba32Float,
                width: width, height: height, mipmapped: false)
            d.storageMode = .private; d.usage = [.shaderRead, .shaderWrite]
            return device.makeTexture(descriptor: d)
        }
        let minimumStride = plan.components.flatMap(\.bands).map { $0.stencil.stride }.min() ?? 1
        guard let component = texture(w, h, half: true), let sum = texture(w, h),
              let reduced = texture((w + minimumStride - 1) / minimumStride, (h + minimumStride - 1) / minimumStride),
              let blurred = texture((w + minimumStride - 1) / minimumStride, (h + minimumStride - 1) / minimumStride),
              let lensed = lens == nil ? component : texture(w, h, half: true) else { return false }
        func dispatch(_ index: Int, _ textures: [MTLTexture], width: Int, height: Int,
                      dimensions: [UInt32] = [], weight: Float = 0, buffer: MTLBuffer? = nil) -> Bool {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
            encoder.setComputePipelineState(kernels[index])
            for (i, t) in textures.enumerated() { encoder.setTexture(t, index: i) }
            if let buffer { encoder.setBuffer(buffer, offset: 0, index: 0) }
            if !dimensions.isEmpty { dimensions.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 1) } }
            var weight = weight; encoder.setBytes(&weight, length: 4, index: 2)
            encoder.dispatchThreads(.init(width: width, height: height, depth: 1),
                threadsPerThreadgroup: .init(width: 16, height: 8, depth: 1))
            encoder.endEncoding(); return true
        }
        guard dispatch(0, [sum], width: w, height: h) else { return false }
        for (k, part) in plan.components.enumerated() {
            guard expose(head, "\(k)-\(suffix)", component) else { return false }
            if let lens {
                var mean: HandwrittenMetalGlobalMeasurements.FlareMean?
                if lensInvocation.featureMask & FilmEngineFeature.flare != 0 {
                    guard let resources = flareResources, let value = resources.flareMean,
                          measurements.encodeFlareMean(recordExposure: component, resources: resources,
                                                       commandBuffer: commandBuffer) else { return false }
                    mean = value
                }
                guard lens.encodeOpticalExposure(recordExposure: component, output: lensed,
                    key: "lens", flareMean: mean, commandBuffer: commandBuffer) else { return false }
            }
            for (b, band) in part.bands.enumerated() {
                let stride = band.stencil.stride, radius = band.stencil.radius
                let gw = (w + stride - 1) / stride, gh = (h + stride - 1) / stride
                let dimensions = [UInt32(stride), UInt32(radius), UInt32(gw), UInt32(gh)]
                guard dispatch(1, [lensed, reduced], width: gw, height: gh, dimensions: dimensions),
                      dispatch(2, [reduced, blurred], width: gw, height: gh, dimensions: dimensions, buffer: weights[k][b]),
                      dispatch(3, [blurred, sum], width: w, height: h, dimensions: dimensions, weight: band.weight)
                else { return false }
            }
        }
        guard dispatch(4, [sum, output], width: w, height: h) else { return false }
        commandBuffer.addCompletedHandler { [self] _ in withExtendedLifetime(self) {} }
        return true
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void clear_sum(texture2d<float,access::write> dst [[texture(0)]], uint2 p [[thread_position_in_grid]]) {
      if(p.x<dst.get_width()&&p.y<dst.get_height()) dst.write(float4(0),p);
    }
    kernel void down(texture2d<float,access::read> src [[texture(0)]], texture2d<float,access::write> dst [[texture(1)]],
      constant uint4 &d [[buffer(1)]], uint2 p [[thread_position_in_grid]]) {
      if(p.x>=dst.get_width()||p.y>=dst.get_height()) return;
      float4 sum=0; uint2 edge=uint2(src.get_width()-1,src.get_height()-1);
      for(uint y=0;y<d.x;y++) for(uint x=0;x<d.x;x++) sum+=src.read(min(p*d.x+uint2(x,y),edge));
      dst.write(sum/float(d.x*d.x),p);
    }
    kernel void blur(texture2d<float,access::read> src [[texture(0)]], texture2d<float,access::write> dst [[texture(1)]],
      device const float *weights [[buffer(0)]], constant uint4 &d [[buffer(1)]], uint2 p [[thread_position_in_grid]]) {
      if(p.x>=dst.get_width()||p.y>=dst.get_height()) return;
      float4 sum=0; int r=int(d.y); int2 edge=int2(d.zw)-1;
      for(int y=-r;y<=r;y++) for(int x=-r;x<=r;x++) sum+=weights[(y+r)*(2*r+1)+x+r]*src.read(uint2(clamp(int2(p)+int2(x,y),int2(0),edge)));
      dst.write(sum,p);
    }
    kernel void accumulate(texture2d<float,access::read> src [[texture(0)]], texture2d<float,access::read_write> dst [[texture(1)]],
      constant uint4 &d [[buffer(1)]], constant float &weight [[buffer(2)]], uint2 p [[thread_position_in_grid]]) {
      if(p.x>=dst.get_width()||p.y>=dst.get_height()) return;
      float2 q=(float2(p)+0.5f)/float(d.x)-0.5f; int2 a=int2(floor(q)); float2 f=q-floor(q);
      int2 edge=int2(d.zw)-1;
      float4 v=mix(mix(src.read(uint2(clamp(a,int2(0),edge))),src.read(uint2(clamp(a+int2(1,0),int2(0),edge))),f.x),
        mix(src.read(uint2(clamp(a+int2(0,1),int2(0),edge))),src.read(uint2(clamp(a+1,int2(0),edge))),f.x),f.y);
      dst.write(dst.read(p)+weight*v,p);
    }
    kernel void finish(texture2d<float,access::read> src [[texture(0)]], texture2d<float,access::write> dst [[texture(1)]], uint2 p [[thread_position_in_grid]]) {
      if(p.x<dst.get_width()&&p.y<dst.get_height()) dst.write(float4(src.read(p).rgb,1),p);
    }
    """
}
#endif
