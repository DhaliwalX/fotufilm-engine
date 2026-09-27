import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmEditModel)
import FotufilmEditModel
#endif

/// The web editor's native backend (`web/src/backend/macos/host.js`) answered in Swift: every
/// call is a method name, JSON parameters and optional bytes, and every answer JSON plus named
/// byte ranges of one payload. A host only moves messages; what they mean lives here.
public final class HostService {
    public struct Answer {
        public var json: Data
        public var payload: [UInt8]
    }

    public unowned let engine: HostEngine
    private let lock = NSLock()
    private var images: [Int: HostImage] = [:]
    private var nextHandle = 1
    /// The last develop, kept so panning a zoomed picture only cuts new tiles from it.
    private var developed: (key: String, width: Int, height: Int, pixels: [UInt8])?
    private var originals: (key: String, width: Int, height: Int, pixels: [UInt8])?

    public init(engine: HostEngine) {
        self.engine = engine
    }

    public func call(_ method: String, params: Data, payload: UnsafeRawBufferPointer?) throws -> Answer {
        let parameters = (try? JSONSerialization.jsonObject(with: params)) as? [String: Any] ?? [:]
        switch method {
        case "prepare":
            return try answer(["stocks": engine.stockIDs, "backend": engine.backendName,
                               "catalogue": try catalogue()])
        case "import":
            guard let payload, payload.count > 0 else {
                throw HostEngine.Failure(description: "The photograph's bytes did not arrive.")
            }
            return try importImage(name: parameters["name"] as? String ?? "photo",
                                   bytes: payload)
        case "preview":
            let image = try self.image(parameters["handle"])
            return try answer(image.descriptor, images: ["preview": previewPNG(image)])
        case "release":
            if let handle = parameters["handle"] as? Int {
                lock.lock()
                images[handle] = nil
                lock.unlock()
            }
            return try answer([:])
        case "render":
            return try render(params)
        case "lensCatalogue":
            let data = Self.lensCatalogueURL.flatMap { try? Data(contentsOf: $0) }
            let profiles = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? []
            return try answer(value: profiles)
        case "importLensCatalogue":
            guard let profiles = parameters["profiles"] as? [Any], let url = Self.lensCatalogueURL else {
                throw HostEngine.Failure(description: "Choose a Fotufilm lens-profile JSON catalogue.")
            }
            let data = try JSONSerialization.data(withJSONObject: profiles)
            let catalogue = try LensCatalogue.load(from: data)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return try answer(value: catalogue.profiles.count)
        case "removeLensCatalogue":
            if let url = Self.lensCatalogueURL { try? FileManager.default.removeItem(at: url) }
            return try answer(value: NSNull())
        default:
            throw HostEngine.Failure(description: "\(method) is not available in this host yet.")
        }
    }

    private var catalogueEntries: [[String: Any]]?

    /// The film library, built once: the screen conversions solve their meter tables.
    private func catalogue() throws -> [[String: Any]] {
        if let catalogueEntries { return catalogueEntries }
        let entries = try WebStockCatalogue.entries()
        catalogueEntries = entries
        return entries
    }

    // MARK: Images

    private func image(_ handle: Any?) throws -> HostImage {
        lock.lock()
        defer { lock.unlock() }
        guard let handle = handle as? Int, let image = images[handle] else {
            throw HostEngine.Failure(description: "That photograph is no longer open.")
        }
        return image
    }

    private func importImage(name: String, bytes: UnsafeRawBufferPointer) throws -> Answer {
        // The decoders read files, and RAW decoding wants the extension as its hint.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fotufilm-import", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(
            UUID().uuidString + "." + (URL(fileURLWithPath: name).pathExtension))
        try Data(bytes: bytes.baseAddress!, count: bytes.count).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let image = try HostImage(opening: file)
        lock.lock()
        let handle = nextHandle
        nextHandle += 1
        images[handle] = image
        lock.unlock()
        var descriptor = image.descriptor
        descriptor["handle"] = handle
        return try answer(descriptor, images: ["preview": previewPNG(image)])
    }

    /// The photograph as decoded, bounded for the library and the strip.
    private func previewPNG(_ image: HostImage) -> [UInt8] {
        let size = image.renderSize(maxEdge: 2048)
        let pixels = image.display(image.scene(width: size.width, height: size.height),
                                   width: size.width, height: size.height)
        return pixels.withUnsafeBytes {
            StoredPNG.encode($0.baseAddress!, width: size.width, height: size.height,
                             rowBytes: size.width * 4)
        }
    }

    // MARK: Rendering

    private struct RenderRequest: Decodable {
        struct Viewport: Decodable {
            struct Region: Decodable { var x, y, width, height: Int }
            var width: Int
            var height: Int
            var region: Region
        }
        var handle: Int
        var maxEdge: Int?
        var cropMode: Bool?
        var viewport: Viewport?
        var edit: SceneGeometry
    }

    private func render(_ params: Data) throws -> Answer {
        let started = DispatchTime.now().uptimeNanoseconds
        let request: RenderRequest, edit: WebNativeEdit
        do {
            request = try JSONDecoder().decode(RenderRequest.self, from: params)
            edit = try JSONDecoder().decode(WebNativeEdit.self, from: params)
        } catch {
            throw HostEngine.Failure(description: "Unreadable render request: \(error)")
        }
        let image = try self.image(request.handle)
        let geometry = request.cropMode == true ? request.edit.uncropped() : request.edit
        // A viewport asks for part of a larger virtual picture: develop the whole frame at that
        // size, bounded by the photograph's own pixels, and cut the region out of it.
        var maxEdge = request.maxEdge
        if let viewport = request.viewport {
            let native = geometry.sizes(width: image.width, height: image.height, maxEdge: nil).output
            let scale = min(1, Double(max(native.0, native.1))
                                / Double(max(viewport.width, viewport.height)))
            maxEdge = nil
            if scale < 1 {
                let full = geometry.sizes(width: image.width, height: image.height, maxEdge: nil)
                maxEdge = max(full.frame.0, full.frame.1)
            } else {
                // The frame whose cropped output is the viewport's virtual size.
                let full = geometry.sizes(width: image.width, height: image.height, maxEdge: nil)
                let ratio = Double(max(viewport.width, viewport.height))
                    / Double(max(full.output.0, full.output.1))
                maxEdge = max(1, Int((Double(max(full.frame.0, full.frame.1)) * ratio).rounded()))
            }
        }
        // A limit at or past the photograph's own size is no limit, and keys the same develop.
        let fullFrame = geometry.sizes(width: image.width, height: image.height, maxEdge: nil).frame
        if let limit = maxEdge, limit <= 0 || limit >= max(fullFrame.0, fullFrame.1) { maxEdge = nil }
        let sizes = geometry.sizes(width: image.width, height: image.height, maxEdge: maxEdge)
        let (width, height) = sizes.output

        // Cache keys: everything but the viewport decides the developed frame.
        let sceneKey = "\(request.handle)|\(maxEdge ?? 0)|\(request.cropMode == true)|\(geometry)"
        var keyed = (try? JSONSerialization.jsonObject(with: params)) as? [String: Any] ?? [:]
        for name in ["viewport", "maxEdge", "handle"] { keyed[name] = nil }
        let developKey = sceneKey + "|" + String(decoding: (try? JSONSerialization.data(
            withJSONObject: keyed, options: [.sortedKeys])) ?? Data(), as: UTF8.self)

        let scene = try sceneFor(image, geometry: geometry, sizes: sizes)
        var renderMilliseconds = 0.0
        if developed?.key != developKey {
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let developStart = DispatchTime.now().uptimeNanoseconds
            try pixels.withUnsafeMutableBytes { buffer in
                try engine.develop(scene, width: width, height: height,
                                   contentHeadroom: image.contentHeadroom, edit: edit,
                                   into: .init(maxEdge: 0, format: .rgba8DisplayP3,
                                               pixels: buffer.baseAddress!, rowBytes: width * 4,
                                               capacity: buffer.count))
            }
            renderMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - developStart) / 1e6
            developed = (developKey, width, height, pixels)
        }
        if originals?.key != sceneKey {
            originals = (sceneKey, width, height, image.display(scene, width: width, height: height))
        }
        let developedFrame = developed!, originalFrame = originals!

        // The region of the frame to deliver, in developed pixels.
        var region = (x: 0, y: 0, width: width, height: height)
        if let viewport = request.viewport {
            let sx = Double(width) / Double(viewport.width)
            let sy = Double(height) / Double(viewport.height)
            let x = max(0, min(width - 1, Int((Double(viewport.region.x) * sx).rounded(.down))))
            let y = max(0, min(height - 1, Int((Double(viewport.region.y) * sy).rounded(.down))))
            let right = min(width, Int((Double(viewport.region.x + viewport.region.width) * sx)
                .rounded(.up)))
            let bottom = min(height, Int((Double(viewport.region.y + viewport.region.height) * sy)
                .rounded(.up)))
            region = (x, y, max(1, right - x), max(1, bottom - y))
        }
        func png(_ pixels: [UInt8]) -> [UInt8] {
            pixels.withUnsafeBytes {
                StoredPNG.encode($0.baseAddress! + (region.y * width + region.x) * 4,
                                 width: region.width, height: region.height, rowBytes: width * 4)
            }
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        return try answer([
            "width": region.width, "height": region.height, "colorSpace": "display-p3",
            "previewType": "image/png", "backend": engine.backendName,
            "elapsed": elapsed, "renderMilliseconds": renderMilliseconds,
        ], images: ["preview": png(developedFrame.pixels), "original": png(originalFrame.pixels)])
    }

    private var sceneCache: (key: String, scene: [Float])?

    /// The photograph through the edit's geometry at the frame's size, scene-linear.
    private func sceneFor(_ image: HostImage, geometry: SceneGeometry,
                          sizes: (frame: (Int, Int), output: (Int, Int))) throws -> [Float] {
        let key = "\(ObjectIdentifier(image))|\(geometry)|\(sizes.frame)|\(sizes.output)"
        if let sceneCache, sceneCache.key == key { return sceneCache.scene }
        // Reduce the unrotated photograph to the frame's scale first, so the one bilinear
        // resample never skips pixels.
        let swapped = geometry.rotation % 2 != 0
        let frameWidth = swapped ? sizes.frame.1 : sizes.frame.0
        let frameHeight = swapped ? sizes.frame.0 : sizes.frame.1
        let reduced = image.scene(width: frameWidth, height: frameHeight)
        let scene = geometry.isIdentity && (frameWidth, frameHeight) == sizes.output
            ? reduced
            : geometry.apply(reduced, width: frameWidth, height: frameHeight,
                             orientedSize: (swapped ? image.height : image.width,
                                            swapped ? image.width : image.height),
                             output: sizes.output)
        sceneCache = (key, scene)
        return scene
    }

    /// The imported lens catalogue, shared with the Mac app (`LensCatalogueStore`).
    static var lensCatalogueURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Fotufilm/lens-profiles.json")
    }

    // MARK: Answers

    /// An answer that is a bare JSON value rather than an object.
    private func answer(value: Any) throws -> Answer {
        Answer(json: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
               payload: [])
    }

    private func answer(_ body: [String: Any], images: [String: [UInt8]] = [:]) throws -> Answer {
        var body = body
        var payload: [UInt8] = []
        var ranges: [String: [Int]] = [:]
        for (name, bytes) in images.sorted(by: { $0.key < $1.key }) {
            // Page views of the payload start on 64-byte boundaries, as the bridge aligns it.
            while payload.count % 64 != 0 { payload.append(0) }
            ranges[name] = [payload.count, bytes.count]
            payload += bytes
        }
        if !ranges.isEmpty { body["payloads"] = ranges }
        return Answer(json: try JSONSerialization.data(withJSONObject: body), payload: payload)
    }
}
