import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmEditModel)
import FotufilmEditModel
#endif
#if canImport(FotufilmImaging)
import FotufilmImaging
#endif

/// The scans open in a negative-scan session, and the light frames kept for them.
final class HostNegativeScans {
    private let lock = NSLock()
    private var open: [Int: HostNegativeScan] = [:]
    /// Photographs of bare light sources, kept for every scan made on them.
    let lights: HostNegativeLightFrames

    init(lights: HostNegativeLightFrames) {
        self.lights = lights
    }

    func add(_ scan: HostNegativeScan, handle: Int) {
        lock.withLock { open[handle] = scan }
    }

    func scan(_ handle: Any?) throws -> HostNegativeScan {
        guard let handle = handle as? Int, let scan = lock.withLock({ open[handle] }) else {
            throw HostEngine.Failure(description: "That negative is no longer open.")
        }
        return scan
    }

    func release(_ handle: Any?) {
        guard let handle = handle as? Int else { return }
        lock.withLock { open[handle] = nil }
    }
}

/// Light frames on disk, in the apps' form (`NegativeScanRoll.LightFrame`): one JSON file each
/// holding an id, a name and the measured light.
final class HostNegativeLightFrames {
    struct LightFrame: Codable {
        let id: String
        let name: String
        let measured: NegativeLightFrame
    }

    private let directory: URL?
    private let lock = NSLock()
    private var loaded: [String: LightFrame] = [:]

    init(directory: URL?) {
        self.directory = directory
    }

    static var defaultDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Fotufilm Desktop/LightFrames", isDirectory: true)
    }

    private func url(_ id: String) -> URL? {
        // Ids are the host's own UUIDs; anything else names no file.
        guard UUID(uuidString: id) != nil else { return nil }
        return directory?.appendingPathComponent(id).appendingPathExtension("json")
    }

    /// Every kept light frame, oldest first.
    func all() -> [LightFrame] {
        guard let directory else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        func created(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        }
        return files.filter { $0.pathExtension == "json" }
            .sorted { created($0) < created($1) }
            .compactMap { frame($0.deletingPathExtension().lastPathComponent) }
    }

    func frame(_ id: String) -> LightFrame? {
        if let frame = lock.withLock({ loaded[id] }) { return frame }
        guard let url = url(id), let data = try? Data(contentsOf: url),
              let frame = try? JSONDecoder().decode(LightFrame.self, from: data) else { return nil }
        lock.withLock { loaded[id] = frame }
        return frame
    }

    func add(_ measured: NegativeLightFrame) throws -> LightFrame {
        let frame = LightFrame(id: UUID().uuidString, name: "Light \(all().count + 1)",
                               measured: measured)
        guard let directory, let url = url(frame.id) else {
            throw HostEngine.Failure(description: "This host has nowhere to keep light frames.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(frame).write(to: url, options: .atomic)
        lock.withLock { loaded[frame.id] = frame }
        return frame
    }

    func remove(_ id: String) {
        if let url = url(id) { try? FileManager.default.removeItem(at: url) }
        lock.withLock { loaded[id] = nil }
    }
}

/// The negative-scan session's calls (`web/src/negative-scan/`): a scan opens once, and every
/// preview, border sample and the imported positive is a print of it to the page's
/// `NegativeScanRecipe`, as the apps' `NegativeScanSession` makes them.
extension HostService {
    static let negativeScanMethods: Set<String> = [
        "negativeScanOpen", "negativeScanRender", "negativeScanSampleBorder",
        "negativeScanDetectFrame", "negativeScanCommit", "negativeLightFrames",
        "negativeAddLightFrame", "negativeRemoveLightFrame",
    ]

    func negativeScan(_ method: String, parameters: [String: Any],
                      payload: UnsafeRawBufferPointer?) throws -> Answer {
        do {
            switch method {
            case "negativeScanOpen":
                return try openNegativeScan(parameters, payload: payload)
            case "negativeScanRender":
                return try renderNegativeScan(parameters)
            case "negativeScanSampleBorder":
                let scan = try negativeScans.scan(parameters["handle"])
                let area = try decode(NegativeScanRecipe.Area.self, parameters["area"])
                let sampled = try scan.sampleBorder(area, recipe: recipe(parameters))
                return try answer(["border": sampled.border.map(Double.init),
                                   "borderArea": JSONSerialization.jsonObject(
                                    with: JSONEncoder().encode(sampled.area))])
            case "negativeScanDetectFrame":
                let scan = try negativeScans.scan(parameters["handle"])
                let found = try scan.detectedFrame(recipe(parameters))
                return try answer(["crop": try found.map {
                    try JSONSerialization.jsonObject(with: JSONEncoder().encode($0))
                } ?? NSNull()])
            case "negativeScanCommit":
                return try commitNegativeScan(parameters)
            case "negativeLightFrames":
                return try answer(value: negativeScans.lights.all().map { ["id": $0.id, "name": $0.name] })
            case "negativeAddLightFrame":
                let frame = try withFile(parameters, payload: payload) { url in
                    try negativeScans.lights.add(measureLight(url))
                }
                return try answer(["id": frame.id, "name": frame.name])
            default:
                if let id = parameters["id"] as? String { negativeScans.lights.remove(id) }
                return try answer([:])
            }
        } catch let failure as HostEngine.Failure {
            throw failure
        } catch {
            throw HostEngine.Failure(description: (error as? LocalizedError)?.errorDescription
                                     ?? String(describing: error))
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ value: Any?) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(
            withJSONObject: value ?? [String: Any](), options: [.fragmentsAllowed]))
    }

    private func recipe(_ parameters: [String: Any]) throws -> NegativeScanRecipe {
        do { return try decode(NegativeScanRecipe.self, parameters["recipe"]) }
        catch { throw HostEngine.Failure(description: "Unreadable negative recipe: \(error)") }
    }

    /// Runs `body` on the file the call names: a path the host chose, read in place, or the bytes
    /// the page sent, written where the decoders can read them with their extension.
    private func withFile<T>(_ parameters: [String: Any], payload: UnsafeRawBufferPointer?,
                             _ body: (URL) throws -> T) throws -> T {
        if let path = parameters["path"] as? String, !path.isEmpty {
            guard FileManager.default.isReadableFile(atPath: path) else {
                throw HostEngine.Failure(
                    description: "\(URL(fileURLWithPath: path).lastPathComponent) cannot be read.")
            }
            return try body(URL(fileURLWithPath: path))
        }
        // A binary channel sends the bytes beside the message; WebKit's sends base64.
        let bytes: Data
        if let payload, payload.count > 0, let base = payload.baseAddress {
            bytes = Data(bytes: base, count: payload.count)
        } else if let text = parameters["data"] as? String, let data = Data(base64Encoded: text) {
            bytes = data
        } else {
            throw HostEngine.Failure(description: "The scan's bytes did not arrive.")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fotufilm-import", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = parameters["name"] as? String ?? "scan"
        let file = directory.appendingPathComponent(
            UUID().uuidString + "." + URL(fileURLWithPath: name).pathExtension)
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        return try body(file)
    }

    private func measureLight(_ url: URL) throws -> NegativeLightFrame {
        if let scans = HostPlatform.current.scans { return try scans.measureLight(url) }
        let photo = try HostImage.open(url)
        let rgba = photo.scene(width: photo.width, height: photo.height)
        var srgb = rgba
        for i in 0..<(photo.width * photo.height) {
            let rgb = AutomaticNegativeScan.rec2020ToSRGB(SIMD3(rgba[i * 4], rgba[i * 4 + 1],
                                                                rgba[i * 4 + 2]))
            for c in 0..<3 { srgb[i * 4 + c] = rgb[c] }
        }
        return try NegativeLightFrame(linearSRGB: srgb, width: photo.width, height: photo.height)
    }

    /// Decodes the scan and describes what a session of it can offer: its size, whether it is
    /// camera RAW, the films it can be read as with their receivers, a first guess at the film,
    /// the kept light frames and a starting recipe.
    private func openNegativeScan(_ parameters: [String: Any],
                                  payload: UnsafeRawBufferPointer?) throws -> Answer {
        let linear = parameters["linearSamples"] as? Bool ?? false
        let file = try withFile(parameters, payload: payload) { url -> HostScanFile in
            if let scans = HostPlatform.current.scans {
                return try scans.decodeScan(url, linearSamples: linear)
            }
            let image = try HostImage.open(url)
            return HostScanFile(image: image, isRAW: image.isRAW)
        }
        let lights = negativeScans.lights
        let scan = HostNegativeScan(scan: file.image, isRAW: file.isRAW) {
            lights.frame($0)?.measured
        }
        // The scan is a photograph too, so the film suggestions read it by the same handle.
        let handle = register(file.image)
        negativeScans.add(scan, handle: handle)

        let films = NegativeScanPrint.filmIDs.compactMap { id -> [String: Any]? in
            guard let stock = engine.stock(id) else { return nil }
            return ["id": id, "name": stock.name, "monochrome": stock.isMonochrome,
                    "papers": NegativeScanRecipe.papers(for: stock).map {
                        ["id": $0.rawValue, "name": $0.name]
                    }]
        }
        var recipe = NegativeScanRecipe()
        let ids = films.compactMap { $0["id"] as? String }
        if !ids.contains(recipe.stockID), let first = ids.first { recipe.stockID = first }
        return try answer([
            "handle": handle, "naturalWidth": scan.width, "naturalHeight": scan.height,
            "raw": scan.isRAW, "films": films,
            "suggestions": negativeFilmSuggestions(file.image),
            "lightFrames": lights.all().map { ["id": $0.id, "name": $0.name] },
            "recipe": try JSONSerialization.jsonObject(with: JSONEncoder().encode(recipe)),
        ])
    }

    /// A preview of the session: the print of the recipe, or the negative itself as the recipe
    /// frames it, cropped unless `cropped` is false, drawn down to `maxEdge`.
    private func renderNegativeScan(_ parameters: [String: Any]) throws -> Answer {
        let started = DispatchTime.now().uptimeNanoseconds
        let scan = try negativeScans.scan(parameters["handle"])
        let recipe = try recipe(parameters)
        let maxEdge = (parameters["maxEdge"] as? Int).flatMap { $0 > 0 ? $0 : nil }
        let cropped = parameters["cropped"] as? Bool ?? true
        let pixels: [UInt8], width: Int, height: Int
        if parameters["negative"] as? Bool == true {
            let framed = scan.frame(recipe, longEdge: maxEdge, cropped: cropped, wide: true)
            (width, height) = (framed.width, framed.height)
            pixels = scan.scan.display(framed.rgba, width: width, height: height)
        } else {
            let print = try scan.print(recipe, longEdge: maxEdge, cropped: cropped, engine: engine)
            (width, height) = (print.width, print.height)
            pixels = HostNegativeScan.encode8(print)
        }
        let rendered = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        let png = pixels.withUnsafeBytes {
            StoredPNG.encode($0.baseAddress!, width: width, height: height, rowBytes: width * 4)
        }
        return try answer([
            "width": width, "height": height, "colorSpace": "display-p3",
            "previewType": "image/png", "renderMilliseconds": rendered,
            "elapsed": Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6,
        ], images: ["preview": png])
    }

    /// The full-resolution print of the recipe as a new photograph the editor owns, with no film
    /// of its own: the apps' delivered positive, opened.
    private func commitNegativeScan(_ parameters: [String: Any]) throws -> Answer {
        let scan = try negativeScans.scan(parameters["handle"])
        let print = try scan.print(recipe(parameters), longEdge: nil, engine: engine)
        let positive = HostImage(rgba: HostNegativeScan.positive(print), width: print.width,
                                 height: print.height, contentHeadroom: 1)
        var descriptor = positive.descriptor
        descriptor["handle"] = register(positive)
        return try answer(descriptor, images: ["preview": previewPNG(positive)])
    }

    /// Up to three readings of the film base, each naming the films it could be.
    func negativeFilmSuggestions(_ image: HostImage) -> [[String: Any]] {
        let catalogue = NegativeFilmSuggestions(stocks: FilmStock.presets)
        let (width, height) = image.renderSize(maxEdge: 512)
        let scene = image.scene(width: width, height: height)
        var preview = ImageBuffer(width: width, height: height)
        for i in 0..<(width * height) { for c in 0..<3 { preview.planes[c][i] = scene[i * 4 + c] } }
        let suggestions = NegativeFilmSuggestions.read(preview: preview)
            .map { catalogue.suggest($0, limit: 3) } ?? []
        return suggestions.map { suggestion in
            ["films": suggestion.films.map { ["id": $0.id, "name": $0.name] },
             "likelihood": suggestion.likelihood]
        }
    }
}
