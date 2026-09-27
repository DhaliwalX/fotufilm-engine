#if canImport(ImageIO) && canImport(CoreImage)
import Foundation

extension HostPlatform {
    /// macOS (and iOS): Core Image and ImageIO for files, the pasteboard, Vision subjects, Core
    /// Graphics frames, the Metal developer, AVFoundation movies, CryptoKit file digests and, on
    /// the Mac, the Resolve and Final Cut plug-ins.
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
        #if canImport(CryptoKit)
        platform.fileDigest = CryptoKitFileDigest()
        #endif
        #if os(macOS)
        platform.plugins = MacPluginInstaller()
        #endif
        #if canImport(AVFoundation)
        platform.videoSource = AVFoundationVideoSources()
        platform.videoWriter = AVFoundationVideoWriters()
        #endif
        return platform
    }
}
#endif
