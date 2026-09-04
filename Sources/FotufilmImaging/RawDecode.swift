import Foundation

#if canImport(CoreImage)
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// How a camera raw file is turned into the scene the emulsion is exposed to.
public enum RawDecode {

    /// The range Core Image documents for `neutralTemperature`.
    public static let neutralTemperatureRange: ClosedRange<Float> = 2000...50000

    /// A complete, reproducible RAW development request. Call sites choose a recipe instead of
    /// relying on mutable `CIRAWFilter` defaults that may vary between platforms.
    public struct Recipe: Equatable, Sendable {
        public var neutralKelvin: Float?
        public var targetLongEdge: Int?
        /// Nil preserves the decoder's lens-correction choice.
        public var correctsLens: Bool?
        public var extendedDynamicRangeAmount: Float
        public var recoversHighlights: Bool

        public init(neutralKelvin: Float? = nil,
                    targetLongEdge: Int? = nil,
                    correctsLens: Bool? = nil,
                    extendedDynamicRangeAmount: Float = 2,
                    recoversHighlights: Bool = true) {
            precondition(neutralKelvin?.isFinite ?? true,
                         "RAW neutral temperature must be finite")
            precondition(targetLongEdge.map { $0 > 0 } ?? true,
                         "RAW target edge must be positive")
            precondition(extendedDynamicRangeAmount.isFinite
                         && extendedDynamicRangeAmount >= 0,
                         "RAW dynamic-range amount must be finite and nonnegative")
            self.neutralKelvin = neutralKelvin
            self.targetLongEdge = targetLongEdge
            self.correctsLens = correctsLens
            self.extendedDynamicRangeAmount = extendedDynamicRangeAmount
            self.recoversHighlights = recoversHighlights
        }
    }

    /// Where the temperature control's displacement ended up: what the
    /// decoder was asked for, and how far the illuminant actually moved.
    public struct Placement: Equatable, Sendable {
        /// The illuminant to demosaic for, or nil to leave the decoder's own
        /// as-shot balance untouched.
        public var neutralKelvin: Float?
        /// How far the demosaic moved the illuminant from as-shot, in mired.
        public var bakedMired: Float

        public init(neutralKelvin: Float?, bakedMired: Float) {
            self.neutralKelvin = neutralKelvin
            self.bakedMired = bakedMired
        }
    }

    /// Places a temperature displacement for a file whose as-shot illuminant is `asShotMired`.
    public static func placement(displacementMired: Float,
                                 asShotMired: Float) -> Placement {
        guard displacementMired != 0 else {
            return Placement(neutralKelvin: nil, bakedMired: 0)
        }
        let requested = WhiteBalance.miredToKelvin(asShotMired + displacementMired)
        let kelvin = min(max(requested, neutralTemperatureRange.lowerBound),
                         neutralTemperatureRange.upperBound)
        return Placement(neutralKelvin: kelvin,
                         bakedMired: WhiteBalance.kelvinToMired(kelvin) - asShotMired)
    }

    /// What the film model must still adapt for once `bakedMired` has gone into the demosaic.
    public static func remainingBalance(displacementMired: Float,
                                        tint: Float,
                                        bakedMired: Float?) -> WhiteBalance {
        let neutral = WhiteBalance.kelvinToMired(WhiteBalance.neutralKelvin)
        let remaining = neutral + displacementMired - (bakedMired ?? 0)
        return WhiteBalance(kelvin: WhiteBalance.miredToKelvin(remaining), tint: tint)
    }

#if canImport(CoreImage)

    /// What a raw file says about itself, read once.
    public struct Metadata: Sendable {
        /// Native pixel dimensions as the image will be delivered, before any geometry of ours.
        public var pixelSize: CGSize
        /// The as-shot illuminant in mired, when the decoder reports one.
        public var asShotMired: Float?
        /// The body that took the picture, as far as the TIFF record names it — what the
        /// spectral profile store resolves against.
        public var camera: CameraIdentity?

        public init(pixelSize: CGSize, asShotMired: Float?,
                    camera: CameraIdentity? = nil) {
            self.pixelSize = pixelSize
            self.asShotMired = asShotMired
            self.camera = camera
        }
    }

    /// Whether `identifier` names a camera raw container.
    public static func isRawType(_ identifier: String) -> Bool {
        UTType(identifier)?.conforms(to: .rawImage) ?? false
    }

    /// Resolves the vendor-specific type a raw decoder requires from the labels an importer has.
    /// Abstract families such as `public.camera-raw-image` identify the kind but decode no pixels;
    /// a resource filename remains authoritative when PhotoKit reports only that family or TIFF.
    public static func concreteRawIdentifier(identifiers: [String],
                                             filenames: [String] = []) -> String? {
        for identifier in identifiers {
            guard let type = UTType(identifier), type != .rawImage,
                  type.conforms(to: .rawImage) else { continue }
            return type.identifier
        }
        for filename in filenames {
            let pathExtension = (filename as NSString).pathExtension
            guard !pathExtension.isEmpty,
                  let type = UTType(filenameExtension: pathExtension),
                  type != .rawImage, type.conforms(to: .rawImage) else { continue }
            return type.identifier
        }
        return nil
    }

    /// Whether these bytes are camera raw.
    public static func isRaw(data: Data, identifierHint: String? = nil) -> Bool {
        let sniffed = CGImageSourceCreateWithData(data as CFData, nil)
            .flatMap { CGImageSourceGetType($0) as String? }
        if let sniffed, isRawType(sniffed) { return true }
        guard sniffed == nil || sniffed == UTType.tiff.identifier else { return false }
        return identifierHint.map(isRawType) ?? false
    }

    /// Whether the file at `url` is camera raw.
    public static func isRaw(url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let identifier = CGImageSourceGetType(source) as String?
        else { return false }
        return isRawType(identifier)
    }

    /// Reads `data` as camera raw, or returns nil if it is not.
    public static func metadata(data: Data, identifierHint: String? = nil) -> Metadata? {
        guard isRaw(data: data, identifierHint: identifierHint),
              let filter = filter(data: data, identifierHint: identifierHint)
        else { return nil }
        var read = metadata(of: filter)
        read.camera = cameraIdentity(
            source: CGImageSourceCreateWithData(data as CFData, nil))
        return read
    }

    /// The camera the file's TIFF record names, for profile resolution. Nil when the record
    /// is absent or empty — the caller falls back to the colorimetric path, it does not guess.
    public static func cameraIdentity(data: Data) -> CameraIdentity? {
        cameraIdentity(source: CGImageSourceCreateWithData(data as CFData, nil))
    }

    /// The same record read off a file on disk, for the CLI path.
    public static func cameraIdentity(url: URL) -> CameraIdentity? {
        cameraIdentity(source: CGImageSourceCreateWithURL(url as CFURL, nil))
    }

    private static func cameraIdentity(source: CGImageSource?) -> CameraIdentity? {
        guard let source,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let tiff = properties[kCGImagePropertyTIFFDictionary]
                as? [CFString: Any] else { return nil }
        func trimmed(_ key: CFString) -> String? {
            guard let value = tiff[key] as? String else { return nil }
            let cut = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return cut.isEmpty ? nil : cut
        }
        guard let make = trimmed(kCGImagePropertyTIFFMake),
              let model = trimmed(kCGImagePropertyTIFFModel) else { return nil }
        return CameraIdentity(make: make, model: model)
    }

    /// A raw filter for these bytes, with the hint tried and then dropped.
    ///
    /// A wrong hint does not fail — it answers. `CIRAWFilter` returns a live object whose
    /// `nativeSize` is (0, 0), whose output extent is empty, and which says it supports no lens
    /// correction. Measured on macOS and iOS 27 against the same Sony ARW: its own
    /// `com.sony.arw-raw-image` opens 7008x4672, while the bare `public.camera-raw-image` family,
    /// the bare extension, and nil all open nothing. So a filter that measures nothing is treated
    /// here as no filter, which is the only thing that lets the drop below actually happen.
    public static func filter(data: Data, identifierHint: String?) -> CIRAWFilter? {
        if let identifierHint,
           let filter = CIRAWFilter(imageData: data, identifierHint: identifierHint),
           filter.nativeSize != .zero {
            return filter
        }
        guard let dropped = CIRAWFilter(imageData: data, identifierHint: nil),
              dropped.nativeSize != .zero else { return nil }
        return dropped
    }

    private static func metadata(of filter: CIRAWFilter) -> Metadata {
        let native = filter.nativeSize
        let size: CGSize
        switch filter.orientation {
        case .leftMirrored, .right, .rightMirrored, .left:
            size = CGSize(width: native.height, height: native.width)
        default:
            size = native
        }
        let kelvin = filter.neutralTemperature
        return Metadata(pixelSize: size,
                        asShotMired: kelvin > 0 ? WhiteBalance.kelvinToMired(kelvin) : nil)
    }

    /// Decodes `data` scene-referred using an explicit development recipe.
    public static func image(data: Data,
                             identifierHint: String? = nil,
                             recipe: Recipe) -> CIImage? {
        guard let filter = filter(data: data, identifierHint: identifierHint)
        else { return nil }
        configure(filter, recipe: recipe)
        return filter.outputImage
    }

    /// Applies the complete shared RAW-decoding policy.
    public static func configure(_ filter: CIRAWFilter, recipe: Recipe) {

        filter.boostAmount = 0
        if filter.isLocalToneMapSupported { filter.localToneMapAmount = 0 }
        if filter.isContrastSupported { filter.contrastAmount = 0 }
        filter.isGamutMappingEnabled = false

        if let correctsLens = recipe.correctsLens, filter.isLensCorrectionSupported {
            filter.isLensCorrectionEnabled = correctsLens
        }

        if filter.isSharpnessSupported { filter.sharpnessAmount = 0 }
        if filter.isDetailSupported { filter.detailAmount = 0 }

        filter.extendedDynamicRangeAmount = recipe.extendedDynamicRangeAmount
        if #available(macOS 16, iOS 19, *) {
            if filter.isHighlightRecoverySupported {
                filter.isHighlightRecoveryEnabled = recipe.recoversHighlights
            }
        }

        if let neutralKelvin = recipe.neutralKelvin {
            filter.neutralTemperature = min(
                max(neutralKelvin, neutralTemperatureRange.lowerBound),
                neutralTemperatureRange.upperBound)
        }

        if let targetLongEdge = recipe.targetLongEdge {
            filter.scaleFactor = scaleFactor(for: filter, targetLongEdge: targetLongEdge)
        }
    }

    public static func scaleFactor(for filter: CIRAWFilter, targetLongEdge: Int) -> Float {
        scaleFactor(nativeLongEdge: Float(max(filter.nativeSize.width,
                                              filter.nativeSize.height)),
                    targetLongEdge: targetLongEdge)
    }

#endif

    /// How much of the frame to ask the decoder for when the result is only going to be reduced to
    /// `targetLongEdge` anyway.
    public static func scaleFactor(nativeLongEdge: Float, targetLongEdge: Int) -> Float {
        guard nativeLongEdge > 0, targetLongEdge > 0 else { return 1 }
        return min(1, max(2 * Float(targetLongEdge) / nativeLongEdge, 1e-3))
    }
}
