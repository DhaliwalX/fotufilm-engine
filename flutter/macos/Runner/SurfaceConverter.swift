import IOSurface
import Metal

/// Readies a frame the engine wrote for Flutter's compositor, in place on the GPU. The engine
/// writes Display P3 RGBA; Flutter's external textures are BGRA and its window is sRGB. One
/// compute pass per frame converts the colour and reorders the channels, so Flutter draws the
/// layer as it is.
final class SurfaceConverter {
  private let device: MTLDevice
  private let queue: MTLCommandQueue
  private let pipeline: MTLComputePipelineState

  init?() {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
          let library = try? device.makeLibrary(source: Self.source, options: nil),
          let function = library.makeFunction(name: "displayP3ToSRGB"),
          let pipeline = try? device.makeComputePipelineState(function: function) else { return nil }
    self.device = device
    self.queue = queue
    self.pipeline = pipeline
  }

  /// Converts `surface` (`width`×`height`, RGBA8 Display P3) to BGRA8 sRGB. Engine thread.
  func convert(_ surface: IOSurfaceRef, width: Int, height: Int) -> Bool {
    // Two views of the same memory: each thread reads its pixel, then writes it back.
    func view(_ usage: MTLTextureUsage) -> MTLTexture? {
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
      descriptor.usage = usage
      descriptor.storageMode = .shared
      return device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0)
    }
    guard let source = view(.shaderRead), let target = view(.shaderWrite),
          let commands = queue.makeCommandBuffer(),
          let encoder = commands.makeComputeCommandEncoder() else { return false }
    encoder.setComputePipelineState(pipeline)
    encoder.setTexture(source, index: 0)
    encoder.setTexture(target, index: 1)
    let group = MTLSize(width: 16, height: 16, depth: 1)
    encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                            threadsPerThreadgroup: group)
    encoder.endEncoding()
    commands.commit()
    commands.waitUntilCompleted()
    return commands.status == .completed
  }

  // The same conversion as shaders/display_p3_to_srgb.frag.
  private static let source = """
  #include <metal_stdlib>
  using namespace metal;

  static float3 decode(float3 c) {
    return select(pow((c + 0.055) / 1.055, float3(2.4)), c / 12.92, c <= 0.04045);
  }

  static float3 encode(float3 c) {
    return select(1.055 * pow(c, float3(1.0 / 2.4)) - 0.055, c * 12.92, c <= 0.0031308);
  }

  kernel void displayP3ToSRGB(texture2d<float, access::read> source [[texture(0)]],
                              texture2d<float, access::write> target [[texture(1)]],
                              uint2 at [[thread_position_in_grid]]) {
    if (at.x >= source.get_width() || at.y >= source.get_height()) return;
    float4 texel = source.read(at);
    float3 p3 = decode(texel.rgb);
    // Display P3 to linear sRGB (both D65).
    float3 srgb = float3(1.2249401 * p3.r - 0.2249404 * p3.g,
                         -0.0420569 * p3.r + 1.0420571 * p3.g,
                         -0.0196376 * p3.r - 0.0786361 * p3.g + 1.0982735 * p3.b);
    float3 out = encode(clamp(srgb, 0.0, 1.0));
    // The memory is read as BGRA: blue first.
    target.write(float4(out.b, out.g, out.r, texel.a), at);
  }
  """
}
