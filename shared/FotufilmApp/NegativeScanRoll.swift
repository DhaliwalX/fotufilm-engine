import Foundation

#if canImport(FotufilmEditModel)
import FotufilmEditModel
#endif
#if canImport(FotufilmImaging)
import FotufilmImaging
#endif

/// What the frames of one roll share across scans: the light source they were scanned on, and a
/// conversion copied from one frame to paste onto the next.
enum NegativeScanRoll {
    // MARK: - Light frames

    /// A photograph of a bare light source, kept to even out every scan made on it.
    struct LightFrame: Codable, Identifiable, Equatable {
        let id: String
        let name: String
        let measured: NegativeLightFrame
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var loaded: [String: LightFrame] = [:]

    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LightFrames", isDirectory: true)
    }

    private static func url(_ id: String) -> URL {
        directory.appendingPathComponent(id).appendingPathExtension("json")
    }

    /// Every kept light frame, oldest first.
    static func lightFrames() -> [LightFrame] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return files.filter { $0.pathExtension == "json" }
            .sorted { created($0) < created($1) }
            .compactMap { lightFrame($0.deletingPathExtension().lastPathComponent) }
    }

    private static func created(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    static func lightFrame(_ id: String) -> LightFrame? {
        if let frame = lock.withLock({ loaded[id] }) { return frame }
        guard let data = try? Data(contentsOf: url(id)),
              let frame = try? JSONDecoder().decode(LightFrame.self, from: data) else { return nil }
        lock.withLock { loaded[id] = frame }
        return frame
    }

    /// Measures and keeps a photograph of the bare light source.
    static func addLightFrame(data: Data, typeHint: String?) throws -> LightFrame {
        let photo = try NegativeScanImport.decode(data: data, identifierHint: typeHint)
        let count = lightFrames().count
        let frame = LightFrame(id: UUID().uuidString, name: "Light \(count + 1)",
                               measured: try NegativeLightFrame(photo: photo))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(frame).write(to: url(frame.id), options: .atomic)
        lock.withLock { loaded[frame.id] = frame }
        return frame
    }

    static func removeLightFrame(_ id: String) {
        try? FileManager.default.removeItem(at: url(id))
        lock.withLock { loaded[id] = nil }
    }

    // MARK: - A copied conversion

    private static let copiedKey = "fotufilm.negative-scan.copied-conversion"

    static func copy(_ recipe: NegativeScanRecipe) {
        UserDefaults.standard.set(try? JSONEncoder().encode(recipe), forKey: copiedKey)
    }

    /// The conversion last copied, if any.
    static var copied: NegativeScanRecipe? {
        UserDefaults.standard.data(forKey: copiedKey)
            .flatMap { try? JSONDecoder().decode(NegativeScanRecipe.self, from: $0) }
    }
}
