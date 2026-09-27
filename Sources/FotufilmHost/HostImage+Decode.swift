#if canImport(CoreImage) && canImport(ImageIO)
import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmImaging)
import FotufilmImaging
#endif

/// Decoding through Core Image and ImageIO (`SceneImage`), shared with the CLI.
struct CoreImageDecoder: HostImageDecoder {
    func decode(_ url: URL) throws -> HostImage {
        let scene = try SceneImage.decode(url: url)
        let image = HostImage(rgba: scene.rgba, width: scene.width, height: scene.height,
                              contentHeadroom: scene.contentHeadroom)
        image.lensShot = LensShot(contentsOf: url)
        image.captureMetadata = HostCaptureMetadata.read(url)
        return image
    }
}
#endif
