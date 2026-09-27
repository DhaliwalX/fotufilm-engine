#if canImport(ImageIO) && canImport(CoreImage)
import Foundation

extension HostPlatform {
    /// macOS (and iOS): Core Image and ImageIO for files, the pasteboard, Vision subjects, Core
    /// Graphics frames and the Metal developer.
    static var apple: HostPlatform {
        var platform = HostPlatform(decoder: CoreImageDecoder(), encoder: ImageIOStillEncoder())
        #if canImport(AppKit)
        platform.clipboard = PasteboardClipboard()
        #endif
        #if canImport(Vision)
        platform.subjects = VisionSubjectDetector()
        #endif
        #if canImport(CoreGraphics)
        platform.frames = CoreGraphicsFrameCompositor()
        #endif
        #if canImport(Metal)
        platform.developer = MetalDeveloper()
        #endif
        return platform
    }
}
#endif
