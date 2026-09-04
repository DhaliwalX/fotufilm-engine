import Foundation

#if canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

#if canImport(FotufilmCore)
import FotufilmCore
#endif

#if canImport(ImageIO)

/// Reading the frame off a file, which is ImageIO's job; the arithmetic that turns what it finds
/// into millimetres is `SensorFrame`'s, in FotufilmCore, where the CLI and the engine can reach it.
extension SensorFrame {
    /// The frame these bytes were exposed on, or nil when the file says nothing that settles it —
    /// a scan, a screenshot, a render, and anything that has been through an editor that dropped
    /// the camera's own record.
    public static func read(data: Data) -> SensorFrame? {
        read(source: CGImageSourceCreateWithData(data as CFData, nil))
    }

    /// The same read off a file on disk, for the CLI path.
    public static func read(url: URL) -> SensorFrame? {
        read(source: CGImageSourceCreateWithURL(url as CFURL, nil))
    }

    static func read(source: CGImageSource?) -> SensorFrame? {
        guard let source,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any] else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]

        func number(_ key: CFString) -> Double? {
            (exif?[key] as? NSNumber)?.doubleValue
        }
        // The pixels the file actually holds, which is what the focal-plane resolution is written
        // against: a camera that resizes on the way out rewrites the resolution to match. The Exif
        // dimensions stand in only where the container did not say, and the shape is all the
        // equivalent-focal route wants, so an orientation swap changes nothing here.
        let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
            ?? (exif?[kCGImagePropertyExifPixelXDimension] as? NSNumber)?.intValue
        let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
            ?? (exif?[kCGImagePropertyExifPixelYDimension] as? NSNumber)?.intValue
        guard let pixelWidth, let pixelHeight else { return nil }

        // Both records are read, not just the first that answers: the measurement is still preferred
        // over the inference, but a file that carries both lets the second check the first, and a
        // focal-plane record left behind by a resize is caught nowhere else. `SensorFrame.measured`
        // holds that reasoning, beside the arithmetic it judges.
        var focalPlane: SensorFrame?
        if let x = number(kCGImagePropertyExifFocalPlaneXResolution),
           let y = number(kCGImagePropertyExifFocalPlaneYResolution),
           let unit = (exif?[kCGImagePropertyExifFocalPlaneResolutionUnit] as? NSNumber)?.intValue {
            focalPlane = SensorFrame.focalPlane(xResolution: x, yResolution: y, unit: unit,
                                                pixelWidth: pixelWidth,
                                                pixelHeight: pixelHeight)
        }
        var equivalentFocal: SensorFrame?
        if let focal = number(kCGImagePropertyExifFocalLength),
           let equivalent = number(kCGImagePropertyExifFocalLenIn35mmFilm) {
            equivalentFocal = SensorFrame.equivalentFocal(focalLengthMM: focal,
                                                          equivalent35mmMM: equivalent,
                                                          pixelWidth: pixelWidth,
                                                          pixelHeight: pixelHeight)
        }
        return SensorFrame.measured(focalPlane: focalPlane, equivalentFocal: equivalentFocal)
    }
}

#endif
