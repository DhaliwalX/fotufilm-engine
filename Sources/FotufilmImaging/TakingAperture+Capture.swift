import Foundation

#if canImport(ImageIO)
import ImageIO
#endif

#if canImport(FotufilmCore)
import FotufilmCore
#endif

#if canImport(ImageIO)

/// Reading the aperture off a file, which is ImageIO's job; what it means for the gate's shadow is
/// `UnexposedEdge.TakingAperture`'s, in FotufilmCore.
extension UnexposedEdge.TakingAperture {
    /// From the Exif dictionaries a photo source keeps (`kCGImagePropertyExifDictionary` and
    /// friends): FNumber, or the APEX ApertureValue where a writer kept only that. Unlike
    /// `LensShot`, this does not need the lens's name.
    public init?(capture metadata: [String: Any]?, sensor: SensorFrame?) {
        let exif = metadata?[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let fNumber = (exif?[kCGImagePropertyExifFNumber as String] as? NSNumber)?.floatValue
            ?? (exif?[kCGImagePropertyExifApertureValue as String] as? NSNumber)
                .map { Float(pow(2, $0.doubleValue / 2)) }
        self.init(fNumber: fNumber, sensor: sensor)
    }

    /// The same read off a file on disk, for the CLI path.
    public init?(contentsOf url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        else { return nil }
        self.init(capture: properties, sensor: SensorFrame.read(url: url))
    }
}

#endif
