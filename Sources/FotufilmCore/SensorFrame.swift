import Foundation

/// The frame a digital camera exposed, in millimetres.
///
/// A gauge is a physical size before it is a name, and every millimetre-sized structure the engine
/// draws — grain, halation, the emulsion's own blur — is scaled by it. A digital capture has a size
/// of its own, and where the file states it there is nothing to guess: the frame picks the gauge
/// nearest it, so a Four Thirds picture is developed on the small piece of film it most resembles
/// and a full-frame one lands on 135, which is the size it already is.
public struct SensorFrame: Sendable, Equatable {
    /// The exposed area's long side.
    public var longSideMM: Float
    /// Its short side, which is what a gauge is measured by.
    public var shortSideMM: Float
    /// Which record the size came from, carried because one route is the camera's own measurement
    /// and the other is arithmetic on a number it rounded.
    public var derivation: Derivation

    public enum Derivation: String, Sendable, Equatable, Codable {
        /// EXIF's focal-plane resolution — the camera stating its own pixel pitch.
        case focalPlane
        /// The 35 mm equivalent focal length divided by the real one.
        case equivalentFocalLength
    }

    /// The diagonal of the 135 frame, which is what a 35 mm equivalence is defined against.
    public static let diagonal135MM: Float = 43.266615

    /// Short sides a digital frame can plausibly have: a phone's ultrawide is around 3 mm and the
    /// largest medium-format backs are around 40 mm, so this is loose enough to admit anything real
    /// and tight enough to reject a file whose focal-plane record is in the wrong unit — off by 25.4
    /// either way, which is what a mistaken inch looks like.
    static let plausibleShortSideMM: ClosedRange<Float> = 1...80
    /// Long over short. Nothing photographic is squarer than 1 or longer than the 65:24 of an
    /// XPan-shaped crop, and a value outside that says the two dimensions did not come from the
    /// same picture.
    static let plausibleAspectRatio: ClosedRange<Float> = 1...3

    /// Fails rather than clamps: a frame that cannot be believed is one the develop should ignore,
    /// and a clamped one would silently grain the picture at a size nothing measured.
    public init?(longSideMM: Float, shortSideMM: Float, derivation: Derivation) {
        guard longSideMM.isFinite, shortSideMM.isFinite, shortSideMM > 0,
              Self.plausibleShortSideMM.contains(shortSideMM),
              Self.plausibleAspectRatio.contains(longSideMM / shortSideMM)
        else { return nil }
        self.longSideMM = longSideMM
        self.shortSideMM = shortSideMM
        self.derivation = derivation
    }

    /// From EXIF's focal-plane record: the picture's pixel count over the resolution the camera
    /// reports, in whatever unit it reports it in. A measurement rather than an inference, so it is
    /// preferred wherever a file carries it.
    public static func focalPlane(xResolution: Double, yResolution: Double,
                                  unit: Int, pixelWidth: Int,
                                  pixelHeight: Int) -> SensorFrame? {
        guard let mmPerUnit = millimetres(perResolutionUnit: unit),
              xResolution > 0, yResolution > 0, pixelWidth > 0, pixelHeight > 0
        else { return nil }
        let width = Double(pixelWidth) / xResolution * mmPerUnit
        let height = Double(pixelHeight) / yResolution * mmPerUnit
        return SensorFrame(longSideMM: Float(max(width, height)),
                           shortSideMM: Float(min(width, height)),
                           derivation: .focalPlane)
    }

    /// EXIF FocalPlaneResolutionUnit. Inches and centimetres are all the standard defines; 4 and 5
    /// are the millimetre and micrometre some makers write anyway. Unit 1 says the resolution has no
    /// unit at all, which makes the record unreadable rather than wrong.
    private static func millimetres(perResolutionUnit unit: Int) -> Double? {
        switch unit {
        case 2: return 25.4
        case 3: return 10
        case 4: return 1
        case 5: return 0.001
        default: return nil
        }
    }

    /// From the 35 mm equivalent the camera wrote beside the real focal length. Their ratio is the
    /// crop factor; the crop factor divides the 135 diagonal, and what is left is cut to the
    /// picture's own shape.
    ///
    /// Coarser than the focal-plane route, because the equivalent is written as a whole number: a
    /// millimetre either way on a phone's 24 mm equivalent moves the frame by about 4%. It is the
    /// only route most phones offer, and 4% of a frame height is far below what the grain shows.
    public static func equivalentFocal(focalLengthMM: Double,
                                       equivalent35mmMM: Double,
                                       pixelWidth: Int,
                                       pixelHeight: Int) -> SensorFrame? {
        guard focalLengthMM > 0, equivalent35mmMM > 0,
              pixelWidth > 0, pixelHeight > 0 else { return nil }
        let cropFactor = equivalent35mmMM / focalLengthMM
        let diagonal = Double(diagonal135MM) / cropFactor
        let long = Double(max(pixelWidth, pixelHeight))
        let short = Double(min(pixelWidth, pixelHeight))
        let aspect = long / short
        let shortSide = diagonal / (aspect * aspect + 1).squareRoot()
        return SensorFrame(longSideMM: Float(shortSide * aspect),
                           shortSideMM: Float(shortSide),
                           derivation: .equivalentFocalLength)
    }

    /// Maximum fractional disagreement between focal-plane and equivalent-focal records.
    /// A corpus of 2,533 images found 187 dual-record files within 1% and 19 resized exports at
    /// 1.10×–7.32× disagreement. The 0.25 threshold is below the 1.59× nearest gauge half-step.
    static let corroborationTolerance: Float = 0.25

    /// The frame a file states, from whichever of its records can be believed.
    ///
    /// The measurement is preferred over the inference, as it always was, but only while the two
    /// agree: a focal-plane record the 35 mm equivalent contradicts is a record about pixels the
    /// file no longer holds, and the equivalent is what is left that still describes this exposure.
    public static func measured(focalPlane: SensorFrame?,
                                equivalentFocal: SensorFrame?) -> SensorFrame? {
        guard let focalPlane else { return equivalentFocal }
        guard let equivalentFocal else { return focalPlane }
        let measured = focalPlane.shortSideMM, inferred = equivalentFocal.shortSideMM
        let disagreement = max(measured / inferred, inferred / measured)
        return disagreement <= 1 + corroborationTolerance ? focalPlane : equivalentFocal
    }

    /// Diagonal crop factor relative to a 135 frame.
    public var cropFactor: Float {
        let diagonal = (longSideMM * longSideMM + shortSideMM * shortSideMM).squareRoot()
        return diagonal > 0 ? Self.diagonal135MM / diagonal : 1
    }

    /// Nearest standard film gauge. See `FilmFormat.nearest`.
    public var gauge: (id: String, format: FilmFormat) {
        FilmFormat.nearest(toFrameHeightMM: shortSideMM)
    }

    /// Scale factor between the captured frame and matched gauge. One is exact; the maximum
    /// between-gauge value is 1.59, midway between 16 mm and Super 35.
    public var gaugeStretch: Float {
        let height = gauge.format.frameHeightMM
        guard height > 0, shortSideMM > 0 else { return 1 }
        return max(shortSideMM / height, height / shortSideMM)
    }

    /// The two numbers alone, for a line of prose or a subtitle.
    public var frameSize: String {
        "\(millimetres(longSideMM)) × \(millimetres(shortSideMM)) mm"
    }

    /// Whole millimetres where it lands on one, a decimal where it does not — the same rule the
    /// gauge list reads by.
    private func millimetres(_ value: Float) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }
}
