import Foundation
import CFotufilmHost
#if canImport(FotufilmImaging)
import FotufilmImaging
#endif

// The C interface in `fotufilm.h`. Handles are retained Swift objects; strings handed out are
// malloc'd so a C caller frees them with `fotufilm_free`. The Swift names are prefixed so a
// Swift client importing both modules sees each function once, from the header.

private func duplicate(_ string: String) -> UnsafeMutablePointer<CChar>? { strdup(string) }

private func report(_ error: Error, into out: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) {
    out?.pointee = duplicate(String(describing: error))
}

private func engine(_ handle: OpaquePointer?) -> HostEngine? {
    handle.map { Unmanaged<HostEngine>.fromOpaque(UnsafeRawPointer($0)).takeUnretainedValue() }
}

private func image(_ handle: OpaquePointer?) -> HostImage? {
    handle.map { Unmanaged<HostImage>.fromOpaque(UnsafeRawPointer($0)).takeUnretainedValue() }
}

@_cdecl("fotufilm_api_version")
public func cdecl_fotufilm_api_version() -> Int32 { FOTUFILM_API_VERSION }

@_cdecl("fotufilm_free")
public func cdecl_fotufilm_free(_ string: UnsafeMutablePointer<CChar>?) { free(string) }

@_cdecl("fotufilm_engine_create")
public func cdecl_fotufilm_engine_create(
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> OpaquePointer? {
    do { return OpaquePointer(Unmanaged.passRetained(try HostEngine()).toOpaque()) }
    catch let failure { report(failure, into: error); return nil }
}

@_cdecl("fotufilm_engine_destroy")
public func cdecl_fotufilm_engine_destroy(_ handle: OpaquePointer?) {
    guard let handle else { return }
    Unmanaged<HostEngine>.fromOpaque(UnsafeRawPointer(handle)).release()
}

@_cdecl("fotufilm_capabilities")
public func cdecl_fotufilm_capabilities() -> UnsafeMutablePointer<CChar>? {
    (try? JSONSerialization.data(withJSONObject: HostPlatform.current.capabilities,
                                 options: [.sortedKeys]))
        .flatMap { duplicate(String(decoding: $0, as: UTF8.self)) }
}

@_cdecl("fotufilm_engine_describe")
public func cdecl_fotufilm_engine_describe(_ handle: OpaquePointer?) -> UnsafeMutablePointer<CChar>? {
    engine(handle).flatMap { duplicate($0.describe()) }
}

@_cdecl("fotufilm_engine_cancel")
public func cdecl_fotufilm_engine_cancel(_ handle: OpaquePointer?) { engine(handle)?.cancel() }

@_cdecl("fotufilm_image_open")
public func cdecl_fotufilm_image_open(
    _ handle: OpaquePointer?, _ path: UnsafePointer<CChar>?,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> OpaquePointer? {
    guard engine(handle) != nil, let path else {
        error?.pointee = duplicate("An engine and a path are required.")
        return nil
    }
    do {
        let image = try HostImage.open(URL(fileURLWithPath: String(cString: path)))
        return OpaquePointer(Unmanaged.passRetained(image).toOpaque())
    } catch let failure {
        report(failure, into: error)
        return nil
    }
}

@_cdecl("fotufilm_image_size")
public func cdecl_fotufilm_image_size(_ handle: OpaquePointer?, _ width: UnsafeMutablePointer<UInt32>?,
                                _ height: UnsafeMutablePointer<UInt32>?) {
    guard let image = image(handle) else { return }
    width?.pointee = UInt32(image.width)
    height?.pointee = UInt32(image.height)
}

@_cdecl("fotufilm_image_release")
public func cdecl_fotufilm_image_release(_ handle: OpaquePointer?) {
    guard let handle else { return }
    Unmanaged<HostImage>.fromOpaque(UnsafeRawPointer(handle)).release()
}

@_cdecl("fotufilm_render_size")
public func cdecl_fotufilm_render_size(_ handle: OpaquePointer?, _ maxEdge: UInt32,
                                 _ width: UnsafeMutablePointer<UInt32>?,
                                 _ height: UnsafeMutablePointer<UInt32>?) {
    guard let size = image(handle)?.renderSize(maxEdge: Int(maxEdge)) else { return }
    width?.pointee = UInt32(size.width)
    height?.pointee = UInt32(size.height)
}

@_cdecl("fotufilm_render")
public func cdecl_fotufilm_render(
    _ engineHandle: OpaquePointer?, _ imageHandle: OpaquePointer?,
    _ requestJSON: UnsafePointer<CChar>?,
    _ target: UnsafePointer<fotufilm_render_target>?,
    _ info: UnsafeMutablePointer<fotufilm_render_info>?,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    guard let engine = engine(engineHandle), let image = image(imageHandle),
          let requestJSON, let target = target?.pointee, let pixels = target.pixels,
          let format = HostEngine.PixelFormat(rawValue: target.format) else {
        error?.pointee = duplicate("An engine, an image, a request and a target are required.")
        return Int32(FOTUFILM_ERROR)
    }
    let size = image.renderSize(maxEdge: Int(target.max_edge))
    let bytesPerPixel = format == .rgba8DisplayP3 ? 4 : 16
    if target.row_bytes < size.width * bytesPerPixel
        || target.capacity < target.row_bytes * (size.height - 1) + size.width * bytesPerPixel {
        error?.pointee = duplicate("The target holds less than \(size.width)x\(size.height).")
        return Int32(FOTUFILM_TARGET_TOO_SMALL)
    }
    let start = DispatchTime.now().uptimeNanoseconds
    do {
        let delivered = try engine.render(
            image, request: Data(bytes: requestJSON, count: strlen(requestJSON)),
            into: HostEngine.Target(maxEdge: Int(target.max_edge), format: format, pixels: pixels,
                                    rowBytes: target.row_bytes, capacity: target.capacity))
        info?.pointee = fotufilm_render_info(
            width: UInt32(delivered.width), height: UInt32(delivered.height),
            milliseconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        return Int32(FOTUFILM_OK)
    } catch let failure as HostEngine.Failure where failure.cancelled {
        return Int32(FOTUFILM_CANCELLED)
    } catch let failure {
        report(failure, into: error)
        return Int32(FOTUFILM_ERROR)
    }
}

@_cdecl("fotufilm_host_call")
public func cdecl_fotufilm_host_call(
    _ engineHandle: OpaquePointer?, _ method: UnsafePointer<CChar>?,
    _ paramsJSON: UnsafePointer<CChar>?, _ payload: UnsafeRawPointer?, _ payloadLength: Int,
    _ answer: UnsafeMutablePointer<fotufilm_answer>?,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    cdecl_fotufilm_host_call_progress(engineHandle, method, paramsJSON, payload, payloadLength,
                                      nil, nil, answer, error)
}

@_cdecl("fotufilm_host_call_progress")
public func cdecl_fotufilm_host_call_progress(
    _ engineHandle: OpaquePointer?, _ method: UnsafePointer<CChar>?,
    _ paramsJSON: UnsafePointer<CChar>?, _ payload: UnsafeRawPointer?, _ payloadLength: Int,
    _ progress: fotufilm_progress_callback?, _ context: UnsafeMutableRawPointer?,
    _ answer: UnsafeMutablePointer<fotufilm_answer>?,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    guard let engine = engine(engineHandle), let method, let answer else {
        error?.pointee = duplicate("An engine, a method and an answer are required.")
        return Int32(FOTUFILM_ERROR)
    }
    let params = paramsJSON.map { Data(bytes: $0, count: strlen($0)) } ?? Data("{}".utf8)
    let bytes = payload.map { UnsafeRawBufferPointer(start: $0, count: payloadLength) }
    do {
        let result = try engine.service.call(String(cString: method), params: params,
                                             payload: bytes) { report in
            guard let progress,
                  let json = try? JSONSerialization.data(withJSONObject: report) else { return }
            String(decoding: json, as: UTF8.self).withCString { progress(context, $0) }
        }
        answer.pointee.json = duplicate(String(decoding: result.json, as: UTF8.self))
        if result.payload.isEmpty {
            answer.pointee.payload = nil
            answer.pointee.payload_length = 0
        } else {
            let copy = malloc(result.payload.count)!.assumingMemoryBound(to: UInt8.self)
            result.payload.withUnsafeBufferPointer {
                copy.update(from: $0.baseAddress!, count: $0.count)
            }
            answer.pointee.payload = copy
            answer.pointee.payload_length = result.payload.count
        }
        return Int32(FOTUFILM_OK)
    } catch let failure as HostEngine.Failure where failure.cancelled {
        return Int32(FOTUFILM_CANCELLED)
    } catch let failure {
        report(failure, into: error)
        return Int32(FOTUFILM_ERROR)
    }
}

@_cdecl("fotufilm_answer_free")
public func cdecl_fotufilm_answer_free(_ answer: UnsafeMutablePointer<fotufilm_answer>?) {
    guard let answer else { return }
    free(answer.pointee.json)
    free(answer.pointee.payload)
    answer.pointee = fotufilm_answer()
}

/// A host's `fotufilm_presenter`, reached through its callbacks.
final class CallbackPresenter: HostPresenter {
    private let callbacks: fotufilm_presenter

    init(_ callbacks: fotufilm_presenter) { self.callbacks = callbacks }

    var headroom: Float { callbacks.headroom.map { $0(callbacks.context) } ?? 1 }

    func acquire(width: Int, height: Int, format: HostSurfaceFormat) -> HostSurface? {
        guard let acquire = callbacks.acquire else { return nil }
        var surface = fotufilm_surface()
        guard acquire(callbacks.context, UInt32(width), UInt32(height), format.rawValue, &surface)
                == Int32(FOTUFILM_OK),
              let pixels = surface.pixels,
              let delivered = HostSurfaceFormat(rawValue: surface.format) else { return nil }
        return HostSurface(width: Int(surface.width), height: Int(surface.height),
                           format: delivered, pixels: pixels, rowBytes: surface.row_bytes,
                           handle: surface)
    }

    func present(_ surface: HostSurface, layer: String, info: [String: Any]) -> UInt64 {
        guard var lent = surface.handle as? fotufilm_surface, let present = callbacks.present
        else { return 0 }
        let json = (try? JSONSerialization.data(withJSONObject: info))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return layer.withCString { name in
            json.withCString { present(callbacks.context, name, &lent, $0) }
        }
    }

    func discard(_ surface: HostSurface) {
        guard var lent = surface.handle as? fotufilm_surface else { return }
        callbacks.discard?(callbacks.context, &lent)
    }
}

@_cdecl("fotufilm_engine_set_presenter")
public func cdecl_fotufilm_engine_set_presenter(_ handle: OpaquePointer?,
                                                _ presenter: UnsafePointer<fotufilm_presenter>?) {
    engine(handle)?.service.presenter = presenter.map { CallbackPresenter($0.pointee) }
}
