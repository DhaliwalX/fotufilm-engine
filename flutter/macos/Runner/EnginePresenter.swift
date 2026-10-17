import CoreImage
import CoreVideo
import FlutterMacOS
import Foundation

/// The editor's image layer on macOS, as the CEF host's (cef/src/platform/mac/image_presenter.mm):
/// the engine develops straight into IOSurface-backed pixel buffers this presenter lends
/// (`fotufilm_engine_set_presenter`), and each layer's view draws them in Display P3, or in
/// extended range on a screen with EDR (PhotoLayer.swift). Nothing is encoded and nothing
/// crosses to Dart but frame ids.
///
/// Layers are `preview`, `detail` and their `.original`s. A frame the same size and scope as the
/// one on show replaces it at once; any other waits for Dart to place it (`show`), so its new
/// geometry and its pixels reach the screen in the same frame.
final class EnginePresenter: NSObject {
  static let layers = ["preview", "preview.original", "detail", "detail.original"]

  private let lock = NSLock()
  private var nextFrame: UInt64 = 1
  private var frames: [UInt64: Frame] = [:]
  private var pools: [String: CVPixelBufferPool] = [:]
  private var callbacks = fotufilm_presenter()
  private var attached = false

  /// The frame on show in each layer, and the views drawing each layer.
  private var shown: [String: Frame] = [:]
  private var views: [String: NSHashTable<PhotoLayerView>] = [:]
  let drawer = PhotoLayerDrawer()

  /// How far above SDR white the window's screen can show light; 1 without EDR. The engine reads
  /// it from its own thread.
  private var headroom: Float = 1
  /// Asks Dart to develop again when the screen's headroom changes.
  var onHeadroomChange: (() -> Void)?

  private struct Frame {
    let layer: String
    let buffer: CVPixelBuffer
    let width: Int
    let height: Int
    let scope: String
  }

  override init() {
    super.init()
    updateHeadroom()
    for name in [NSWindow.didChangeScreenNotification,
                 NSApplication.didChangeScreenParametersNotification] {
      NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
                                             name: name, object: nil)
    }
  }

  /// The potential headroom of the editor's screen, which the system grants once a layer asks
  /// for EDR, as the CEF host reads it (host_window.mm `screenChanged`).
  @discardableResult
  private func updateHeadroom() -> Bool {
    let screen = NSApp.mainWindow?.screen ?? NSApp.windows.first?.screen ?? NSScreen.main
    let value = Float(max(1, screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1))
    lock.lock()
    defer { lock.unlock() }
    if value == headroom { return false }
    headroom = value
    return true
  }

  @objc private func screenChanged() {
    if updateHeadroom() { onHeadroomChange?() }
  }

  /// A view for `layer`, drawing its frame on show at once.
  func makeView(layer: String) -> NSView {
    guard let drawer else { return NSView() }
    let view = PhotoLayerView(layer: layer, drawer: drawer)
    lock.lock()
    // A table read through `default:` is not stored by calling a method on it.
    let table = views[layer] ?? .weakObjects()
    table.add(view)
    views[layer] = table
    let frame = shown[layer]
    lock.unlock()
    view.show(frame?.buffer)
    return view
  }

  /// Lends this presenter to the engine at `address` (the `fotufilm_engine *` Dart created).
  func attach(engine address: Int) -> Bool {
    if attached { return true }
    // The window is on its screen by now.
    updateHeadroom()
    guard drawer != nil, let library = dlopen(Bundle.main.privateFrameworksPath! + "/libfotufilm.dylib", RTLD_NOW),
          let symbol = dlsym(library, "fotufilm_engine_set_presenter"),
          let engine = OpaquePointer(bitPattern: address) else { return false }
    typealias SetPresenter = @convention(c) (OpaquePointer?, UnsafePointer<fotufilm_presenter>?) -> Void
    let setPresenter = unsafeBitCast(symbol, to: SetPresenter.self)
    callbacks.context = Unmanaged.passUnretained(self).toOpaque()
    callbacks.headroom = { context in
      let presenter = EnginePresenter.from(context)
      presenter.lock.lock()
      defer { presenter.lock.unlock() }
      return presenter.headroom
    }
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
    attached = true
    return true
  }

  private static func from(_ context: UnsafeMutableRawPointer?) -> EnginePresenter {
    Unmanaged<EnginePresenter>.fromOpaque(context!).takeUnretainedValue()
  }

  // Engine thread.
  private func acquire(_ width: Int, _ height: Int, _ format: Int32,
                       _ surface: UnsafeMutablePointer<fotufilm_surface>?) -> Int32 {
    let deep = format == Int32(FOTUFILM_SURFACE_RGBA16F_EXTENDED_LINEAR_P3)
    guard deep || format == Int32(FOTUFILM_SURFACE_RGBA8_DISPLAY_P3), let surface,
          let pool = pool(width, height, deep: deep) else { return Int32(FOTUFILM_ERROR) }
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
    let current = shown[layer]
    lock.unlock()
    if let current, current.width == frame.width, current.height == frame.height,
       current.scope == scope {
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
    lock.lock()
    shown[layer] = nil
    lock.unlock()
    draw(layer, nil)
  }

  private func show(_ frame: Frame) {
    lock.lock()
    shown[frame.layer] = frame
    lock.unlock()
    draw(frame.layer, frame.buffer)
  }

  private func draw(_ layer: String, _ buffer: CVPixelBuffer?) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { self.draw(layer, buffer) }
      return
    }
    lock.lock()
    let drawing = views[layer]?.allObjects ?? []
    lock.unlock()
    for view in drawing { view.show(buffer) }
  }

  /// For the development driver: each view's place in the window (points from the top left),
  /// how its layer draws, and the frame it shows written to `<dir>/<layer>.png`.
  func describe(writingTo dir: String?) -> [[String: Any]] {
    lock.lock()
    let all = views.flatMap { name, table in table.allObjects.map { (name, $0) } }
    let frames = shown
    lock.unlock()
    return all.map { name, view in
      var entry = view.describe()
      if let frame = frames[name] {
        entry["frame"] = [frame.width, frame.height]
        if let dir { Self.write(frame.buffer, to: "\(dir)/\(name).png") }
      }
      return entry
    }
  }

  private static func write(_ buffer: CVPixelBuffer, to path: String) {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let deep = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_64RGBAHalf
    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
    guard let base = CVPixelBufferGetBaseAddress(buffer),
          let space = CGColorSpace(name: deep ? CGColorSpace.extendedLinearDisplayP3 : CGColorSpace.displayP3),
          let provider = CGDataProvider(data: Data(bytes: base, count: CVPixelBufferGetBytesPerRow(buffer) * height) as CFData)
    else { return }
    let info: CGBitmapInfo = deep
      ? [CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), .floatComponents, .byteOrder16Little]
      : CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    guard let image = CGImage(width: width, height: height, bitsPerComponent: deep ? 16 : 8,
                              bitsPerPixel: deep ? 64 : 32, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                              space: space, bitmapInfo: info, provider: provider, decode: nil,
                              shouldInterpolate: false, intent: .defaultIntent) else { return }
    try? CIContext().writePNGRepresentation(of: CIImage(cgImage: image), to: URL(fileURLWithPath: path),
                                            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!)
  }

  private func pool(_ width: Int, _ height: Int, deep: Bool) -> CVPixelBufferPool? {
    let key = "\(width)x\(height)\(deep ? "h" : "")"
    lock.lock()
    defer { lock.unlock() }
    if let pool = pools[key] { return pool }
    // The engine writes RGBA bytes, which the views read as RGBA whatever the buffer calls them;
    // an extended-range frame is RGBA half floats.
    let attributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String:
        deep ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_32BGRA,
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

/// The presenter's channel: `attach` {engine} → {layers}, `show` {frame} → size, `clear`; it
/// calls `headroomChanged` when the screen's headroom does. The layers' views are the platform
/// view "fotufilm/photo-layer".
enum PresenterChannel {
  static func register(with controller: FlutterViewController) {
    let presenter = EnginePresenter()
    let channel = FlutterMethodChannel(name: "fotufilm/presenter",
                                       binaryMessenger: controller.engine.binaryMessenger)
    presenter.onHeadroomChange = { channel.invokeMethod("headroomChanged", arguments: nil) }
    controller.registrar(forPlugin: "FotufilmPhotoLayer")
      .register(PhotoLayerFactory(presenter: presenter), withId: "fotufilm/photo-layer")
    channel.setMethodCallHandler { call, result in
      let arguments = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "attach":
        let address = (arguments["engine"] as? NSNumber)?.intValue ?? 0
        result(presenter.attach(engine: address) ? ["layers": EnginePresenter.layers] : nil)
      case "show":
        let frame = (arguments["frame"] as? NSNumber)?.uint64Value ?? 0
        result(presenter.show(frame: frame))
      case "clear":
        presenter.clear(layer: arguments["layer"] as? String ?? "")
        result(nil)
      case "describe":
        result(presenter.describe(writingTo: arguments["dir"] as? String))
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
