import Foundation

/// The photo strip's pictures of files opened together but not yet decoded
/// (`web/src/backend/desktop/host.js` `thumbnail`): only the photograph being edited is decoded,
/// the others show these until they are chosen. The photo library's grid draws the files of the
/// folders the host reads from these too (`web/src/backend/desktop/library-folders.js`).
extension HostService {
    func thumbnail(_ parameters: [String: Any], payload: UnsafeRawBufferPointer?) throws -> Answer {
        let maxEdge = max(16, min(1024, parameters["maxEdge"] as? Int ?? 256))
        let picture: (pixels: [UInt8], width: Int, height: Int)
        if let path = parameters["path"] as? String, !path.isEmpty {
            picture = try thumbnail(of: URL(fileURLWithPath: path), maxEdge: maxEdge)
        } else if let payload, payload.count > 0 {
            // Bytes handed over (a photo-library file): read from a private copy, whose extension
            // is the decoders' hint.
            let name = parameters["name"] as? String ?? "photo"
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("fotufilm-import", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(
                UUID().uuidString + "." + URL(fileURLWithPath: name).pathExtension)
            try Data(bytes: payload.baseAddress!, count: payload.count).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            picture = try thumbnail(of: file, maxEdge: maxEdge)
        } else {
            throw HostEngine.Failure(description: "No file was named.")
        }
        let png = picture.pixels.withUnsafeBytes {
            StoredPNG.encode($0.baseAddress!, width: picture.width, height: picture.height,
                             rowBytes: picture.width * 4)
        }
        return try answer(["width": picture.width, "height": picture.height],
                          images: ["thumbnail": png])
    }

    /// A movie's first frame decoded small, a still's embedded or reduced preview.
    private func thumbnail(of url: URL, maxEdge: Int) throws
        -> (pixels: [UInt8], width: Int, height: Int) {
        if let videos = HostPlatform.current.videoSource, videos.isMovie(url) {
            let source = try videos.open(url)
            let size = AreaResample.size(width: source.width, height: source.height, maxEdge: maxEdge)
            let frame = try source.frame(at: source.start, width: size.width, height: size.height,
                                         interpretation: .standard, displayCodes: true)
            if let codes = frame.display8 { return (codes.bytes, frame.width, frame.height) }
            let image = HostImage(rgba: frame.rgba, width: frame.width, height: frame.height,
                                  contentHeadroom: 1)
            return (image.display(image.scene(width: frame.width, height: frame.height),
                                  width: frame.width, height: frame.height),
                    frame.width, frame.height)
        }
        guard let thumbnails = HostPlatform.current.thumbnails else {
            throw HostEngine.Failure(description: "This host draws no thumbnails.")
        }
        return try thumbnails.thumbnail(url, maxEdge: maxEdge)
    }
}
