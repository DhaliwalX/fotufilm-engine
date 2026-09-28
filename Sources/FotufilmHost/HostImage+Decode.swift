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
        image.sensorFrame = SensorFrame.read(url: url)
        image.isRAW = RawDecode.isRaw(url: url)
        if image.isRAW {
            image.decodeReduced = { longEdge in
                let scene = try SceneImage.decode(url: url, targetLongEdge: longEdge)
                return (scene.rgba, scene.width, scene.height)
            }
        } else {
            image.decodeStandardRange = {
                let scene = try SceneImage.decode(url: url, standardRange: true)
                return HostImage(rgba: scene.rgba, width: scene.width, height: scene.height,
                                 contentHeadroom: 1)
            }
        }
        return image
    }
}
#endif
