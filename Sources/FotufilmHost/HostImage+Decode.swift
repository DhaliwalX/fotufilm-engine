import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmImaging)
import FotufilmImaging
#endif

extension HostImage {
    /// Decodes a photograph the way the CLI and the apps do: RAW with its camera profile,
    /// HDR sources with the range they recorded.
    convenience init(opening url: URL) throws {
        #if canImport(CoreImage) && canImport(ImageIO)
        let scene = try SceneImage.decode(url: url)
        self.init(rgba: scene.rgba, width: scene.width, height: scene.height,
                  contentHeadroom: scene.contentHeadroom)
        lensShot = LensShot(contentsOf: url)
        captureMetadata = HostCaptureMetadata.read(url)
        #else
        throw HostEngine.Failure(description: "This build has no image decoder.")
        #endif
    }
}
