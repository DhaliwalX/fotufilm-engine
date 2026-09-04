import Foundation

/// Converts the developed linear Display P3 print into a target output color space and transfer.
/// Values are normalized floats; quantization, ICC tagging and container writing belong to the
/// caller so the same converter works in Apple apps, command-line tools and other integrations.
public protocol FilmOutputConverter: Sendable {
    var colorSpace: FilmOutputColorSpace { get }

    func convert(
        _ developed: UnsafeBufferPointer<Float>,
        from sourceOffset: Int,
        count: Int,
        into destination: UnsafeMutableBufferPointer<Float>
    )
}

/// Runtime type erasure for output converters supplied by plug-ins or application configuration.
public struct AnyFilmOutputConverter: FilmOutputConverter {
    public let colorSpace: FilmOutputColorSpace
    private let conversion: @Sendable (
        UnsafeBufferPointer<Float>, Int, Int, UnsafeMutableBufferPointer<Float>
    ) -> Void

    public init<Converter: FilmOutputConverter>(_ converter: Converter) {
        colorSpace = converter.colorSpace
        conversion = { source, offset, count, destination in
            converter.convert(source, from: offset, count: count, into: destination)
        }
    }

    public init(
        colorSpace: FilmOutputColorSpace,
        conversion: @escaping @Sendable (
            UnsafeBufferPointer<Float>, Int, Int, UnsafeMutableBufferPointer<Float>
        ) -> Void
    ) {
        self.colorSpace = colorSpace
        self.conversion = conversion
    }

    public func convert(
        _ developed: UnsafeBufferPointer<Float>,
        from sourceOffset: Int,
        count: Int,
        into destination: UnsafeMutableBufferPointer<Float>
    ) {
        conversion(developed, sourceOffset, count, destination)
    }
}

/// Identifies the normalized pixel contract written by an output converter.
///
/// Known spaces have static values, while integrations can construct another identifier and map
/// it to their platform's ICC profile or color-space object at the container boundary.
public struct FilmOutputColorSpace: RawRepresentable, Hashable, Identifiable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        precondition(!rawValue.isEmpty, "an output color-space identifier cannot be empty")
        self.rawValue = rawValue
    }

    public var id: String { rawValue }

    public static let linearDisplayP3 = Self(rawValue: "linearDisplayP3")
    public static let displayP3 = Self(rawValue: "displayP3")
    public static let linearSRGB = Self(rawValue: "linearSRGB")
    public static let sRGB = Self(rawValue: "sRGB")
    public static let rec709 = Self(rawValue: "rec709")
    public static let linearRec2020 = Self(rawValue: "linearRec2020")
    public static let rec2020HLG = Self(rawValue: "rec2020HLG")

    public static let builtIn: [Self] = [
        .linearDisplayP3, .displayP3, .linearSRGB, .sRGB, .rec709,
        .linearRec2020, .rec2020HLG,
    ]
}

/// Built-in conversions from the engine's developed linear Display P3 print.
public enum FilmOutputConversion: String, CaseIterable, Identifiable, FilmOutputConverter {
    /// Preserve the engine's output values and HDR relight alpha.
    case linearDisplayP3
    /// Clamp and encode Display P3 with its sRGB transfer, without an output shoulder.
    case displayP3
    /// Apply the calibrated SDR shoulder, then encode Display P3 with its sRGB transfer.
    case displayP3SDR
    /// Convert to linear-light sRGB without clipping out-of-gamut values.
    case linearSRGB
    /// Convert to sRGB, apply the SDR shoulder and encode with the sRGB transfer.
    case sRGBSDR
    /// Relight HDR alpha, convert to Rec.709, apply the SDR shoulder and BT.709 OETF.
    case rec709SDR
    /// Convert to linear-light Rec. 2020 without clipping out-of-gamut values.
    case linearRec2020
    /// Relight HDR alpha, roll the print and encode BT.2100 HLG in Rec. 2020 primaries.
    case rec2020HLG

    public var id: String { rawValue }

    public var colorSpace: FilmOutputColorSpace {
        switch self {
        case .linearDisplayP3: return .linearDisplayP3
        case .displayP3, .displayP3SDR: return .displayP3
        case .linearSRGB: return .linearSRGB
        case .sRGBSDR: return .sRGB
        case .rec709SDR: return .rec709
        case .linearRec2020: return .linearRec2020
        case .rec2020HLG: return .rec2020HLG
        }
    }

    public func convert(
        _ developed: UnsafeBufferPointer<Float>,
        from sourceOffset: Int,
        count: Int,
        into destination: UnsafeMutableBufferPointer<Float>
    ) {
        precondition(sourceOffset >= 0 && count >= 0 && count.isMultiple(of: 4))
        precondition(sourceOffset + count <= developed.count)
        precondition(count <= destination.count)
        for pixel in 0..<(count / 4) {
            let source = sourceOffset + pixel * 4
            let output = pixel * 4
            let rgb = SIMD3(developed[source], developed[source + 1],
                            developed[source + 2])
            let converted: SIMD3<Float>
            switch self {
            case .linearDisplayP3:
                converted = rgb
            case .displayP3:
                converted = encodeSRGB(rgb)
            case .displayP3SDR:
                converted = encodeSRGB(shoulder(rgb))
            case .linearSRGB:
                converted = ColorScience.linearDisplayP3ToSRGB(rgb)
            case .sRGBSDR:
                converted = encodeSRGB(shoulder(
                    ColorScience.linearDisplayP3ToSRGB(rgb)))
            case .rec709SDR:
                let relit = rgb * max(developed[source + 3], 1)
                let rec709 = ColorScience.linearDisplayP3ToSRGB(relit)
                converted = encodeRec709(shoulder(SIMD3(
                    max(rec709.x, 0), max(rec709.y, 0), max(rec709.z, 0))))
            case .linearRec2020:
                converted = displayP3ToRec2020(rgb)
            case .rec2020HLG:
                converted = encodeHLG(rgb * max(developed[source + 3], 1))
            }
            destination[output] = converted.x
            destination[output + 1] = converted.y
            destination[output + 2] = converted.z
            destination[output + 3] = self == .linearDisplayP3
                ? developed[source + 3] : 1
        }
    }

    private static let hlgA = HLGSceneTransfer.a
    private static let hlgB = HLGSceneTransfer.b
    private static let hlgC = HLGSceneTransfer.c
    private static let hlgSystemGamma: Float = 1.2
    private static let hlgHeadroom: Float = HLGSceneTransfer.headroom
    private static let hlgDisplayCeiling: Float = pow(hlgHeadroom, hlgSystemGamma)

    private func encodeSRGB(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(ColorScience.linearToSrgb(rgb.x),
              ColorScience.linearToSrgb(rgb.y),
              ColorScience.linearToSrgb(rgb.z))
    }

    private func encodeRec709(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        func channel(_ linear: Float) -> Float {
            let value = min(max(linear, 0), 1)
            return value < 0.018
                ? 4.5 * value
                : 1.099 * pow(value, 0.45) - 0.099
        }
        return SIMD3(channel(rgb.x), channel(rgb.y), channel(rgb.z))
    }

    /// The established SDR print shoulder is per channel; keeping it here preserves existing output.
    private func shoulder(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(ColorScience.displayShoulder(rgb.x),
              ColorScience.displayShoulder(rgb.y),
              ColorScience.displayShoulder(rgb.z))
    }

    /// `ColorScience`'s matrix, not a local copy of it: the six-place copy this replaces was a
    /// third spelling of the same step, and disagreed with both of the others.
    private func displayP3ToRec2020(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        ColorScience.linearDisplayP3ToRec2020(rgb)
    }

    private func encodeHLG(_ displayP3: SIMD3<Float>) -> SIMD3<Float> {
        let positive = SIMD3(max(displayP3.x, 0), max(displayP3.y, 0),
                             max(displayP3.z, 0))
        let peak = max(positive.x, max(positive.y, positive.z))
        let rolled: SIMD3<Float>
        if peak > 1e-6 {
            rolled = positive * (Self.hdrShoulder(peak) / peak)
        } else {
            rolled = .zero
        }
        let rec2020 = displayP3ToRec2020(rolled)
        let wide = SIMD3(max(rec2020.x, 0), max(rec2020.y, 0), max(rec2020.z, 0))
        let luminance = 0.2627 * wide.x + 0.6780 * wide.y + 0.0593 * wide.z
        guard luminance > 1e-6 else { return .zero }
        let ootfScale = pow(luminance,
                            (1 - Self.hlgSystemGamma) / Self.hlgSystemGamma)
        let open = wide * ootfScale / Self.hlgHeadroom
        return SIMD3(Self.hlg(open.x), Self.hlg(open.y), Self.hlg(open.z))
    }

    private static func hlg(_ scene: Float) -> Float {
        let value = min(max(scene, 0), 1)
        return value <= 1 / 12
            ? (3 * value).squareRoot()
            : hlgA * log(12 * value - hlgB) + hlgC
    }

    /// The engine's one shoulder. The variant this replaces used a different denominator, which
    /// bought an exact fixed point at diffuse white at the cost of a slope break at the knee — and
    /// degenerated to a hard clip at `ceiling == 1`, where the SDR path lives. Diffuse white is
    /// deliberately bent a hair below reference white here, as it is on every other path.
    private static func hdrShoulder(_ value: Float) -> Float {
        ColorScience.highlightShoulder(value, ceiling: hlgDisplayCeiling)
    }
}

/// The kernel's spelling of a built-in delivery.
///
/// A `FilmOutputConverter` is a host walk over finished pixels; a `FilmOutputTransform` is the
/// same step named in the terms the `encodeOut` variants read, so the engine can take it in the
/// producing kernel and hand the caller pixels that are already delivered. Only the deliveries
/// that are a matrix, a shoulder and one of the three transfer shapes can be named this way —
/// which is why these are factories rather than a conformance, and why a caller that does not
/// find its delivery here keeps walking the frame itself.
extension FilmOutputTransform {
    /// Row-major identity: the delivery basis is already the print's own.
    public static let identityMatrix: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1]

    /// The sRGB transfer as the power-law shape reads it:
    /// `|v| <= c4 ? |v| * c0 : c1 * pow(|v|, c2) + c3`. The same curve as
    /// `ColorScience.linearToSrgb`, which clamps its input where the kernel floors before the
    /// matrix instead; both land on the same code value after quantization.
    public static let srgbCoefficients: [Float] = [
        12.92, 1.055, 1 / 2.4, -0.055, 0.0031308, 0,
    ]

    /// Display P3 with its sRGB transfer, optionally over the SDR print shoulder — the still
    /// delivery, and the one `FilmDisplayP3SDRConversion` and `FilmOutputConversion.displayP3`
    /// describe between them. `shoulderKnee` nil is the unshouldered encode.
    public static func displayP3(shoulderKnee: Float? = nil) -> FilmOutputTransform {
        FilmOutputTransform(matrix: identityMatrix, transfer: .powerLaw,
                            coefficients: srgbCoefficients,
                            premultiplied: false,
                            shoulderKnee: shoulderKnee)
    }
}

/// Runs a built-in or client-supplied converter at the developed-print boundary.
public enum DevelopedPrintOutput {
    public static func convert<Converter: FilmOutputConverter>(
        _ developed: UnsafeBufferPointer<Float>,
        from sourceOffset: Int,
        count: Int,
        into destination: UnsafeMutableBufferPointer<Float>,
        using converter: Converter
    ) {
        converter.convert(developed, from: sourceOffset, count: count,
                          into: destination)
    }
}

/// Display-P3 SDR delivery with a caller-selected shoulder placement. FilmRender uses this for
/// direct-positive stocks; the built-in enum retains its standard 0.9-knee compatibility path.
public struct FilmDisplayP3SDRConversion: FilmOutputConverter {
    public let colorSpace = FilmOutputColorSpace.displayP3
    public let shoulderKnee: Float

    public init(shoulderKnee: Float) {
        self.shoulderKnee = shoulderKnee
    }

    public func convert(
        _ developed: UnsafeBufferPointer<Float>, from sourceOffset: Int,
        count: Int, into destination: UnsafeMutableBufferPointer<Float>
    ) {
        precondition(sourceOffset >= 0 && count >= 0 && count.isMultiple(of: 4))
        precondition(sourceOffset + count <= developed.count)
        precondition(count <= destination.count)
        for index in stride(from: 0, to: count, by: 4) {
            let source = sourceOffset + index
            for channel in 0..<3 {
                destination[index + channel] = ColorScience.linearToSrgb(
                    ColorScience.displayShoulder(
                        developed[source + channel], knee: shoulderKnee))
            }
            destination[index + 3] = 1
        }
    }
}
