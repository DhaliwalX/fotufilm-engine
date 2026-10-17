import CoreVideo
import FlutterMacOS
import Foundation

/// The editor's image layer on macOS, as the CEF host's (cef/src/platform/mac/image_presenter.mm):
/// the engine develops straight into IOSurface-backed pixel buffers this presenter lends
/// (`fotufilm_engine_set_presenter`), and Flutter draws them as external textures. Nothing is
/// encoded and nothing crosses to Dart but frame ids.
///
/// Layers are `preview`, `detail` and their `.original`s. A frame the same size and scope as the
/// one on show replaces it at once; any other waits for Dart to place it (`show`), so its new
/// geometry and its pixels reach the screen in the same frame.
final class EnginePresenter: NSObject {
  static let layers = ["preview", "preview.original", "detail", "detail.original"]

  private let registry: FlutterTextureRegistry
  private var textures: [String: (texture: LayerTexture, id: Int64)] = [:]
  private let lock = NSLock()
  private var nextFrame: UInt64 = 1
  private var frames: [UInt64: Frame] = [:]
  private var pools: [String: CVPixelBufferPool] = [:]
  private var callbacks = fotufilm_presenter()

  /// Converts each frame for the compositor on the GPU; without it, Dart's colour filter does.
  let converter = SurfaceConverter()

  private struct Frame {
    let layer: String
    let buffer: CVPixelBuffer
    let width: Int
    let height: Int
    let scope: String
  }

  init(registry: FlutterTextureRegistry) {
    self.registry = registry
    super.init()
  }

  var textureIDs: [String: Int64] { textures.mapValues(\.id) }

  /// Lends this presenter to the engine at `address` (the `fotufilm_engine *` Dart created).
  /// The layers' textures are registered here, once Flutter's engine runs; before, it has no
  /// registry to give ids from.
  func attach(engine address: Int) -> Bool {
    if textures.isEmpty {
      for layer in Self.layers {
        let texture = LayerTexture()
        textures[layer] = (texture, registry.register(texture))
      }
    }
    guard let library = dlopen(Bundle.main.privateFrameworksPath! + "/libfotufilm.dylib", RTLD_NOW),
          let symbol = dlsym(library, "fotufilm_engine_set_presenter"),
          let engine = OpaquePointer(bitPattern: address) else { return false }
    typealias SetPresenter = @convention(c) (OpaquePointer?, UnsafePointer<fotufilm_presenter>?) -> Void
    let setPresenter = unsafeBitCast(symbol, to: SetPresenter.self)
    callbacks.context = Unmanaged.passUnretained(self).toOpaque()
    // Flutter's layer is drawn in standard range.
    callbacks.headroom = { _ in 1 }
    callbacks.acquire = { context, width, height, format, surface in
      EnginePresenter.from(context).acquire(Int(width), Int(height), format, surface)
    }
    callbacks.present = { context, layer, surface, info in
      EnginePresenter.from(context).present(layer, surface, info)
    }
    callbacks.discard = { context, surface in
      EnginePresenter.from(context).discard(surface)
    }
    withUnsafePointer(to: &callbacks) { setPresenter(engine, $0) }
    return true
  }

  private static func from(_ context: UnsafeMutableRawPointer?) -> EnginePresenter {
    Unmanaged<EnginePresenter>.fromOpaque(context!).takeUnretainedValue()
  }

  // Engine thread.
  private func acquire(_ width: Int, _ height: Int, _ format: Int32,
                       _ surface: UnsafeMutablePointer<fotufilm_surface>?) -> Int32 {
    guard format == Int32(FOTUFILM_SURFACE_RGBA8_DISPLAY_P3), let surface,
          let pool = pool(width, height) else { return Int32(FOTUFILM_ERROR) }
    var made: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess,
          let buffer = made else { return Int32(FOTUFILM_ERROR) }
    CVPixelBufferLockBaseAddress(buffer, [])
    surface.pointee.width = UInt32(width)
    surface.pointee.height = UInt32(height)
    surface.pointee.format = format
    surface.pointee.pixels = CVPixelBufferGetBaseAddress(buffer)
    surface.pointee.row_bytes = CVPixelBufferGetBytesPerRow(buffer)
    surface.pointee.native = CVPixelBufferGetIOSurface(buffer).map {
      UnsafeMutableRawPointer(Unmanaged.passUnretained($0.takeUnretainedValue()).toOpaque())
    }
    surface.pointee.host = Unmanaged.passRetained(buffer).toOpaque()
    return Int32(FOTUFILM_OK)
  }

  // Engine thread.
  private func present(_ layerName: UnsafePointer<CChar>?, _ surface: UnsafePointer<fotufilm_surface>?,
                       _ info: UnsafePointer<CChar>?) -> UInt64 {
    guard let layerName, let surface, let host = surface.pointee.host else { return 0 }
    let buffer = Unmanaged<CVPixelBuffer>.fromOpaque(host).takeRetainedValue()
    CVPixelBufferUnlockBaseAddress(buffer, [])
    if let converter, let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() {
      _ = converter.convert(surface, width: CVPixelBufferGetWidth(buffer),
                            height: CVPixelBufferGetHeight(buffer))
    }
    let layer = String(cString: layerName)
    var scope = ""
    if let info, let object = try? JSONSerialization.jsonObject(
        with: Data(bytes: info, count: strlen(info))) as? [String: Any] {
      scope = object["scope"] as? String ?? ""
    }
    let frame = Frame(layer: layer, buffer: buffer, width: Int(surface.pointee.width),
                      height: Int(surface.pointee.height), scope: scope)
    lock.lock()
    let id = nextFrame
    nextFrame += 1
    frames[id] = frame
    // Keep the newest few of each layer for Dart to place; older ones go back to the pool.
    let stale = frames.filter { $0.value.layer == layer }.keys.sorted().dropLast(3)
    for key in stale { frames[key] = nil }
    let shown = textures[layer]?.texture.frame
    lock.unlock()
    if let shown, shown.width == frame.width, shown.height == frame.height, shown.scope == scope {
      show(frame)
    }
    return id
  }

  private func discard(_ surface: UnsafePointer<fotufilm_surface>?) {
    guard let host = surface?.pointee.host else { return }
    let buffer = Unmanaged<CVPixelBuffer>.fromOpaque(host).takeRetainedValue()
    CVPixelBufferUnlockBaseAddress(buffer, [])
  }

  /// Puts a presented frame on its layer; Dart calls this once it has laid the frame out.
  func show(frame id: UInt64) -> [String: Int]? {
    lock.lock()
    let frame = frames[id]
    lock.unlock()
    guard let frame else { return nil }
    show(frame)
    return ["width": frame.width, "height": frame.height]
  }

  /// Takes a layer off the screen (another photograph is shown).
  func clear(layer: String) {
    guard let entry = textures[layer] else { return }
    entry.texture.set(nil)
    DispatchQueue.main.async { self.registry.textureFrameAvailable(entry.id) }
  }

  private func show(_ frame: Frame) {
    guard let entry = textures[frame.layer] else { return }
    entry.texture.set(LayerTexture.Shown(buffer: frame.buffer, width: frame.width,
                                         height: frame.height, scope: frame.scope))
    if Thread.isMainThread {
      registry.textureFrameAvailable(entry.id)
    } else {
      DispatchQueue.main.async { self.registry.textureFrameAvailable(entry.id) }
    }
  }

  private func pool(_ width: Int, _ height: Int) -> CVPixelBufferPool? {
    let key = "\(width)x\(height)"
    lock.lock()
    defer { lock.unlock() }
    if let pool = pools[key] { return pool }
    // The engine writes RGBA; Flutter's external textures read BGRA. The converter reorders
    // the channels as it converts Display P3 for the window.
    let attributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
      kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    var pool: CVPixelBufferPool?
    CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary,
                            attributes as CFDictionary, &pool)
    // A resized viewer leaves sizes it no longer asks for.
    if pools.count > 6 { pools.removeAll() }
    pools[key] = pool
    return pool
  }
}

/// One layer's picture for Flutter's compositor.
final class LayerTexture: NSObject, FlutterTexture {
  struct Shown {
    let buffer: CVPixelBuffer
    let width: Int
    let height: Int
    let scope: String
  }

  private let lock = NSLock()
  private var shown: Shown?

  var frame: Shown? {
    lock.lock()
    defer { lock.unlock() }
    return shown
  }

  func set(_ next: Shown?) {
    lock.lock()
    shown = next
    lock.unlock()
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    lock.lock()
    defer { lock.unlock() }
    return shown.map { Unmanaged.passRetained($0.buffer) }
  }
}

/// The presenter's channel: `attach` {engine} → texture ids, `show` {frame} → size, `clear`.
enum PresenterChannel {
  static func register(with controller: FlutterViewController) {
    let presenter = EnginePresenter(registry: controller.engine)
    let channel = FlutterMethodChannel(name: "fotufilm/presenter",
                                       binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler { call, result in
      let arguments = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "attach":
        let address = (arguments["engine"] as? NSNumber)?.intValue ?? 0
        result(presenter.attach(engine: address)
          ? ["textures": presenter.textureIDs,
             "convertsColour": presenter.converter != nil,
             "swapRedBlue": presenter.converter == nil] : nil)
      case "show":
        let frame = (arguments["frame"] as? NSNumber)?.uint64Value ?? 0
        result(presenter.show(frame: frame))
      case "clear":
        presenter.clear(layer: arguments["layer"] as? String ?? "")
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
