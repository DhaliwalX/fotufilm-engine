#if canImport(CFotufilmCodecs) && !canImport(ImageIO)
import CFotufilmCodecs
import Foundation

/// Thumbnails through the portable codecs (`ffc_thumbnail`), as ImageIO draws them on the Mac: a
/// camera RAW's embedded preview, a JPEG decoded at a reduced scale or a HEIF's stored thumbnail,
/// else the image reduced; upright Display P3. Many may be drawn at once.
struct PortableThumbnailer: HostThumbnailer {
    func thumbnail(_ url: URL, maxEdge: Int) throws -> (pixels: [UInt8], width: Int, height: Int) {
        var picture = ffc_picture()
        var message = [CChar](repeating: 0, count: 512)
        guard ffc_thumbnail(url.path, UInt32(clamping: maxEdge), &picture, &message, message.count) == 0
        else {
            throw HostEngine.Failure(description: "\(url.lastPathComponent) has no picture to show: "
                                     + String(cString: message))
        }
        defer { ffc_picture_free(&picture) }
        let width = Int(picture.width), height = Int(picture.height)
        return ([UInt8](UnsafeBufferPointer(start: picture.rgba, count: width * height * 4)), width, height)
    }
}
#endif
