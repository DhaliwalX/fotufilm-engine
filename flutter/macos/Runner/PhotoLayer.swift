import CoreVideo
import FlutterMacOS
import Metal
import QuartzCore

/// One of the presenter's layers on screen, as the CEF host's compositor draws the photograph
/// (cef/src/platform/mac/compositor.mm): its own Metal layer, placed by Flutter as a platform
/// view, so the picture keeps the engine's Display P3 and, on a screen with EDR, the light above
/// SDR white that an extended-range frame carries. Flutter's own window is sRGB and standard range.
/// It takes no clicks: the editor's gestures over the photograph stay Flutter's.
final class PhotoLayerView: NSView {
  let layerName: String
  private let metal = CAMetalLayer()
  private let drawer: PhotoLayerDrawer

  init(layer: String, drawer: PhotoLayerDrawer) {
    layerName = layer
    self.drawer = drawer
    super.init(frame: .zero)
    metal.device = drawer.device
    metal.framebufferOnly = true
    metal.isOpaque = false
    // The drawable is the frame's own size; the layer scales it to the view, as Flutter's
    // texture was scaled.
    metal.contentsGravity = .resize
    metal.magnificationFilter = .linear
    metal.minificationFilter = .linear
    metal.presentsWithTransaction = true
    metal.isHidden = true
    wantsLayer = true
  }

  required init?(coder: NSCoder) { nil }

  override func makeBackingLayer() -> CALayer { metal }

  override var wantsUpdateLayer: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  /// Draws `buffer`, or hides the layer for nil. Main thread.
  func show(_ buffer: CVPixelBuffer?) {
    guard let buffer else {
      metal.isHidden = true
      return
    }
    if drawer.draw(buffer, into: metal) { metal.isHidden = false }
  }

  /// For the development driver.
  func describe() -> [String: Any] {
    let place = window.map { window -> [Double] in
      let rect = convert(bounds, to: nil)
      let top = (window.contentView?.bounds.height ?? 0) - rect.maxY
      return [rect.minX, top, rect.width, rect.height].map(Double.init)
    } ?? []
    return [
      "layer": layerName,
      "hidden": metal.isHidden || isHiddenOrHasHiddenAncestor,
      "rect": place,
      "drawable": [Double(metal.drawableSize.width), Double(metal.drawableSize.height)],
      "format": metal.pixelFormat == .rgba16Float ? "rgba16Float" : metal.pixelFormat == .bgra8Unorm ? "bgra8Unorm" : "\(metal.pixelFormat.rawValue)",
      "colorspace": (metal.colorspace?.name as String?) ?? "none",
      "edr": metal.wantsExtendedDynamicRangeContent,
      "headroom": Double(window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1),
    ]
  }
}

/// Copies a frame the engine wrote into a layer's drawable, choosing the drawable's format and
/// colour space by the frame's: 8-bit Display P3, or half-float extended-linear Display P3 with
/// EDR.
final class PhotoLayerDrawer {
  let device: MTLDevice
  private let queue: MTLCommandQueue
  private let standard: MTLRenderPipelineState
  private let extended: MTLRenderPipelineState
  private let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)
  private let extendedLinearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)

  init?() {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
          let library = try? device.makeLibrary(source: Self.source, options: nil),
          let vertex = library.makeFunction(name: "frame_vertex"),
          let fragment = library.makeFunction(name: "frame_fragment") else { return nil }
    func pipeline(_ format: MTLPixelFormat) -> MTLRenderPipelineState? {
      let descriptor = MTLRenderPipelineDescriptor()
      descriptor.vertexFunction = vertex
      descriptor.fragmentFunction = fragment
      descriptor.colorAttachments[0].pixelFormat = format
      return try? device.makeRenderPipelineState(descriptor: descriptor)
    }
    guard let standard = pipeline(.bgra8Unorm), let extended = pipeline(.rgba16Float) else {
      return nil
    }
    self.device = device
    self.queue = queue
    self.standard = standard
    self.extended = extended
  }

  /// Main thread: the drawable is presented with the transaction that places the view.
  func draw(_ buffer: CVPixelBuffer, into layer: CAMetalLayer) -> Bool {
    guard let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else {
      return false
    }
    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
    let deep = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_64RGBAHalf
    let format: MTLPixelFormat = deep ? .rgba16Float : .bgra8Unorm
    if layer.pixelFormat != format || layer.colorspace == nil {
      layer.pixelFormat = format
      layer.colorspace = deep ? extendedLinearP3 : displayP3
      layer.wantsExtendedDynamicRangeContent = deep
    }
    layer.drawableSize = CGSize(width: width, height: height)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: deep ? .rgba16Float : .rgba8Unorm, width: width, height: height,
      mipmapped: false)
    descriptor.usage = .shaderRead
    descriptor.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0),
          let drawable = layer.nextDrawable(), let commands = queue.makeCommandBuffer() else {
      return false
    }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = drawable.texture
    pass.colorAttachments[0].loadAction = .dontCare
    pass.colorAttachments[0].storeAction = .store
    guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return false }
    encoder.setRenderPipelineState(deep ? extended : standard)
    encoder.setFragmentTexture(texture, index: 0)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()
    commands.commit()
    commands.waitUntilScheduled()
    drawable.present()
    return true
  }

  // One triangle over the drawable; each pixel reads its own texel, the two being one size.
  private static let source = """
  #include <metal_stdlib>
  using namespace metal;

  struct Position { float4 at [[position]]; };

  vertex Position frame_vertex(uint index [[vertex_id]]) {
    float2 corner = float2((index << 1) & 2, index & 2);
    return Position { float4(corner * 2.0 - 1.0, 0.0, 1.0) };
  }

  fragment float4 frame_fragment(Position in [[stage_in]], texture2d<float> frame [[texture(0)]]) {
    return frame.read(uint2(in.at.xy));
  }
  """
}

/// Makes the layers' views for Flutter's `AppKitView` ("fotufilm/photo-layer", {layer}).
final class PhotoLayerFactory: NSObject, FlutterPlatformViewFactory {
  private let presenter: EnginePresenter

  init(presenter: EnginePresenter) {
    self.presenter = presenter
  }

  func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
    let layer = (args as? [String: Any])?["layer"] as? String ?? "preview"
    return presenter.makeView(layer: layer)
  }

  func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol)? {
    FlutterStandardMessageCodec.sharedInstance()
  }
}
