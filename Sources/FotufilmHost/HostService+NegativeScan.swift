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

/// The scanned negatives open in the editor, and the light frames kept for them.
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

    /// The scan a document's handle names, nil for a photograph.
    func scan(_ handle: Any?) -> HostNegativeScan? {
        guard let handle = handle as? Int else { return nil }
        return lock.withLock { open[handle] }
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

/// Scanned negatives in the editor (`web/src/backend/desktop/negative-scans.js`): a scan opens as
/// a document, its film is the edit's, and every develop of it prints the framed scan through the
/// edit's own print (`HostEngine.printNegative`).
extension HostService {
    static let negativeScanMethods: Set<String> = [
        "negativeSampleFilmBase", "negativeLightFrames", "negativeAddLightFrame",
        "negativeRemoveLightFrame",
    ]

    func negativeScan(_ method: String, parameters: [String: Any],
                      payload: UnsafeRawBufferPointer?) throws -> Answer {
        do {
            switch method {
            case "negativeSampleFilmBase":
                return try answer(value: sampleFilmBase(parameters))
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
            throw HostEngine.Failure(description: "The file's bytes did not arrive.")
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

    /// Opens a scanned negative as a document: decoded as a scan, kept under a handle like any
    /// photograph, and described with the films its base looks like and the kept light frames.
    func importNegative(_ url: URL) throws -> Answer {
        let image: HostImage
        if let scans = HostPlatform.current.scans {
            image = try scans.decodeScan(url)
        } else {
            image = try HostImage.open(url)
        }
        let lights = negativeScans.lights
        var descriptor = image.descriptor
        let handle = register(image)
        negativeScans.add(HostNegativeScan(scan: image) { lights.frame($0)?.measured },
                          handle: handle)
        descriptor["handle"] = handle
        descriptor["negative"] = [
            "suggestions": negativeFilmSuggestions(image),
            "lightFrames": lights.all().map { ["id": $0.id, "name": $0.name] },
        ]
        return try answer(descriptor, images: ["preview": previewPNG(image)])
    }

    /// A negative document's develop: the scan evened under the edit's light frame, and its
    /// framing read against the sampled or estimated film base: as the edit's film, or without one
    /// (Normal) as a plain positive developed like any photograph.
    func readNegative(_ prepared: inout Prepared, scan: HostNegativeScan) throws {
        let negative = prepared.edit.edit.negative
        let light = negative?.lightFrame
        prepared.image = try scan.image(light: light)
        let stock = try prepared.edit.edit.stock.map { id -> FilmStock in
            guard let stock = engine.stock(id) else {
                throw HostEngine.Failure(description: "This film is not installed.")
            }
            guard NegativeScanPrint.reads(stock) else { throw NegativeScanPrint.Failure.reversalFilm }
            return stock
        }
        let border = try negative?.border ?? scan.estimatedBorder(light: light)
        // The picture as framed, crop included even while the crop tool shows the whole frame:
        // the reading follows what will print.
        let image = prepared.image
        let framing = prepared.request.edit.snapped(width: image.width, height: image.height)
        let key = "\(framing)|\(border)|\(light ?? "")"
        let preview = {
            let sizes = framing.sizes(width: image.width, height: image.height, maxEdge: nil)
            return HostNegativeScan.preview(try self.makeScene(image, geometry: framing, sizes: sizes),
                                            width: sizes.output.0, height: sizes.output.1)
        }
        let roll = negative?.roll
        if let stock {
            prepared.edit.negativeReading = try scan.reading(key, stock: stock, border: border,
                                                             roll: roll, preview: preview)
        } else {
            prepared.image = try scan.positive(key, border: border, light: light, roll: roll,
                                               preview: preview)
        }
        // What this frame measures for its roll, kept from the reading above.
        let measured = try scan.measure(key, border: border, preview: preview)
        prepared.negativeMeasure = [
            "border": (0..<3).map { Double(measured.border[$0]) },
            "denseEnd": measured.dense.map { dense in (0..<3).map { Double(dense[$0]) } as Any }
                ?? NSNull(),
        ]
    }

    /// Clear film sampled where the page points on the framed scan: the median over a patch a
    /// fortieth of the picture's long edge across.
    private func sampleFilmBase(_ parameters: [String: Any]) throws -> [Double] {
        guard var render = parameters["render"] as? [String: Any],
              let point = parameters["point"] as? [Double], point.count == 2,
              (0...1).contains(point[0]), (0...1).contains(point[1]) else {
            throw HostEngine.Failure(description: "Point at clear film on the negative.")
        }
        render["viewport"] = nil
        let prepared = try prepare(JSONSerialization.data(withJSONObject: render), readsNegative: false)
        let scene = try sceneFor(prepared.image, geometry: prepared.geometry, sizes: prepared.sizes)
        let (width, height) = prepared.sizes.output
        let radius = max(2, max(width, height) / 80)
        let x = Int(point[0] * Double(width)), y = Int(point[1] * Double(height))
        return try HostNegativeScan.border(scene, width: width, height: height,
                                           x0: x - radius, y0: y - radius,
                                           x1: x + radius + 1, y1: y + radius + 1)
            .map(Double.init)
    }

    /// Up to three readings of the film base, each naming the films it could be.
    func negativeFilmSuggestions(_ image: HostImage) -> [[String: Any]] {
        let catalogue = NegativeFilmSuggestions(stocks: FilmStock.presets)
        let suggestions = NegativeFilmSuggestions.read(preview: HostNegativeScan.preview(image))
            .map { catalogue.suggest($0, limit: 3) } ?? []
        return suggestions.map { suggestion in
            ["films": suggestion.films.map { ["id": $0.id, "name": $0.name] },
             "likelihood": suggestion.likelihood]
        }
    }
}
