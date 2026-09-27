#if canImport(ImageIO)
import Foundation
import ImageIO
#if canImport(FotufilmCore)
import FotufilmCore
#endif

extension LensShot {
    /// The lens a photograph records, from its ImageIO properties (whole, or just the Exif, ExifAux
    /// and TIFF dictionaries). Nil when the file names no lens.
    public init?(capture metadata: [String: Any]?) {
        guard let metadata,
              let exif = metadata[kCGImagePropertyExifDictionary as String]
                as? [String: Any] else { return nil }
        let auxiliary = metadata[kCGImagePropertyExifAuxDictionary as String]
            as? [String: Any]
        let tiff = metadata[kCGImagePropertyTIFFDictionary as String]
            as? [String: Any]
        // Apple writes the lens name into the auxiliary dictionary rather than the Exif one, so both
        // are asked before giving up.
        let model = (exif[kCGImagePropertyExifLensModel as String] as? String)
            ?? (auxiliary?["LensModel"] as? String)
        guard let model, !model.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        self.init(
            lensModel: model,
            lensMaker: exif[kCGImagePropertyExifLensMake as String] as? String,
            cameraModel: tiff?[kCGImagePropertyTIFFModel as String] as? String,
            focalLength: (exif[kCGImagePropertyExifFocalLength as String]
                as? NSNumber)?.floatValue,
            aperture: (exif[kCGImagePropertyExifFNumber as String]
                as? NSNumber)?.floatValue)
    }

    /// The lens recorded in an image file.
    public init?(contentsOf url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        else { return nil }
        self.init(capture: properties)
    }
}
#endif
