#if canImport(AppKit)
import AppKit
import UniformTypeIdentifiers

/// Copy Photo on macOS: PNG and TIFF on the pasteboard, as the Mac app puts them.
struct PasteboardClipboard: HostClipboard {
    var pasteboard = NSPasteboard.general

    func copy(_ still: HostStill) throws -> (width: Int, height: Int) {
        let encoder = ImageIOStillEncoder()
        let image = try ImageIOStillEncoder.picture(still)
        // Written out now, not promised: a promise would be kept on the engine thread, which has
        // no run loop to answer another app's paste.
        let png = try encoder.data(image, type: .png)
        let tiff = try encoder.data(image, type: .tiff)
        pasteboard.clearContents()
        guard pasteboard.setData(png, forType: .png), pasteboard.setData(tiff, forType: .tiff) else {
            throw HostEngine.Failure(description: "The picture could not be copied.")
        }
        return (image.width, image.height)
    }
}
#endif
