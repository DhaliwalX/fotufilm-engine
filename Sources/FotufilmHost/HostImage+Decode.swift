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
        try Self.decode(url, correctsLens: nil)
    }

    /// `correctsLens` false leaves out Core Image's lens correction, for RAW Corrections off;
    /// Core Image always delivers the camera's crop. Nil keeps its own choice.
    private static func decode(_ url: URL, correctsLens: Bool?) throws -> HostImage {
        let scene = try SceneImage.decode(url: url, correctsLens: correctsLens)
        let image = HostImage(rgba: scene.rgba, width: scene.width, height: scene.height,
                              contentHeadroom: scene.contentHeadroom)
        image.lensShot = LensShot(contentsOf: url)
        image.captureMetadata = HostCaptureMetadata.read(url)
        image.sensorFrame = SensorFrame.read(url: url)
        image.isRAW = RawDecode.isRaw(url: url)
        if image.isRAW {
            image.decodeReduced = { longEdge in
                let scene = try SceneImage.decode(url: url, targetLongEdge: longEdge,
                                                  correctsLens: correctsLens)
                return (scene.rgba, scene.width, scene.height)
            }
            if correctsLens == nil {
                image.decodeUncorrected = { try Self.decode(url, correctsLens: false) }
            }
        }
        return image
    }
}
#endif
