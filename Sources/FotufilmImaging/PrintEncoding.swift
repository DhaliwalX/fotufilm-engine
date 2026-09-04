import Dispatch
import Foundation

#if canImport(CoreImage)
import CoreImage
#endif

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Turning the developed print into deliverable pixels.
///
/// The transfer functions and row packing below are pure arithmetic and build on every platform.
/// The Core Graphics surface — wrapping a buffer as a `CGImage` and naming a `CGColorSpace` —
/// lives in `PrintEncoding+AppleImaging.swift`.
public enum PrintEncoding {
    /// Non-finite colour is no scene light, matching the engine's input repair. Keep that rule at
    /// the delivery boundary too: a damaged source or client converter must not make integer
    /// packing trap.
    @inline(__always)
    private static func quantizeNormalized(_ value: Float) -> UInt16 {
        let finite = value.isFinite ? value : 0
        return UInt16((min(max(finite, 0), 1) * 65535).rounded())
    }

    @inlinable
    public static func encode(_ linear: Float) -> Float {
        let clamped = min(max(linear, 0), 1)
        return clamped <= 0.0031308
            ? clamped * 12.92
            : 1.055 * pow(clamped, 1 / 2.4) - 0.055
    }

    @inlinable
    static func shoulder(_ x: Float) -> Float {
        ColorScience.displayShoulder(x)
    }

    /// BT.2100 hybrid log-gamma constants. `b` is `1 - 4a` and `c` is `0.5 - a·ln(4a)`, which is
    /// what makes the two branches meet at 0.5.
    public static let hlgA: Float = 0.17883277
    public static let hlgB: Float = 0.28466892
    public static let hlgC: Float = 0.55991073

    /// Where HDR reference white — the diffuse white a print's paper base
    /// stands for — sits on the HLG signal.
    public static let hlgReferenceWhiteSignal: Float = 0.75

    /// How far above diffuse white an HLG signal can still go: the reciprocal of the scene light
    /// reference white lands on, 3.7745.
    public static let hdrHeadroom: Float = 1 / hlgSceneLight(at: hlgReferenceWhiteSignal)

    /// The same ceiling in *display* light, which is where the print lives: `hdrHeadroom` raised
    /// to the power of HLG's system gamma (3.7745 ^ 1.2), which is 4.92.
    public static let hdrDisplayCeiling: Float =
        pow(hdrHeadroom, HLGTransfer.systemGamma)


    @inlinable
    public static func encodeHLG(_ scene: Float) -> Float {
        let e = min(max(scene, 0), 1)
        return e <= 1 / 12
            ? (3 * e).squareRoot()
            : hlgA * log(12 * e - hlgB) + hlgC
    }

    /// The inverse: signal back to scene light.
    public static func hlgSceneLight(at signal: Float) -> Float {
        signal <= 0.5
            ? signal * signal / 3
            : (exp((signal - hlgC) / hlgA) + hlgB) / 12
    }

    @inlinable
    public static func hdrShoulder(_ x: Float, ceiling: Float = hdrDisplayCeiling) -> Float {
        ColorScience.highlightShoulder(x, ceiling: ceiling)
    }

    @inlinable
    public static func hdrShoulderPreservingHue(
        _ value: SIMD3<Float>, ceiling: Float = hdrDisplayCeiling
    ) -> SIMD3<Float> {
        let positive = SIMD3<Float>(max(value.x, 0), max(value.y, 0),
                                    max(value.z, 0))
        let peak = max(positive.x, max(positive.y, positive.z))
        guard peak > 1e-6 else { return .zero }
        return positive * (hdrShoulder(peak, ceiling: ceiling) / peak)
    }

    /// How a display-linear print becomes code values.
    public enum Transfer: Sendable {
        /// The sRGB curve alone — the exact inverse of the EOTF a decode
        /// assumes, with no gamut handling.
        case srgb
        /// The soft display shoulder, then sRGB: the SDR print.
        case shoulderedSRGB
        /// The HDR shoulder, then HLG: the same print, with the highlights the SDR shoulder
        /// compresses into `[0.9, 1)` given room above diffuse white instead.
        case hlg
    }

    /// Encodes interleaved display-linear RGBA rows into 16-bit output.
    static let encodeChunkRows = 64

    /// Runs an engine-owned or client-supplied output conversion and packs its normalized result
    /// into 16-bit RGBA. The caller tags the image with `colorSpace(for: converter.colorSpace)`.
    public static func encodeRows<Converter: FilmOutputConverter>(
        _ developed: UnsafeBufferPointer<Float>,
        rows: Range<Int>, width: Int,
        into destination: UnsafeMutableBufferPointer<UInt16>,
        converter: Converter
    ) {
        let count = rows.count * width * 4
        guard width > 0, rows.count > 0, developed.count >= count,
              destination.count >= rows.upperBound * width * 4 else { return }
        var converted = [Float](repeating: 0, count: count)
        converted.withUnsafeMutableBufferPointer { converted in
            DevelopedPrintOutput.convert(
                developed, from: 0, count: count, into: converted,
                using: converter)
            let destinationStart = rows.lowerBound * width * 4
            for index in 0..<count {
                destination[destinationStart + index] =
                    quantizeNormalized(converted[index])
            }
        }
    }

    /// Packs rows the engine has already delivered — what a render that carried its
    /// `FilmOutputTransform` in the producing kernel hands back — into 16-bit RGBA.
    ///
    /// The colour is finished, so this is only the quantization and the opaque alpha a print
    /// always has; the intermediate float array and the per-component transform `encodeRows`
    /// needs are exactly what moving the delivery into the kernel removes. The clamp stays:
    /// the kernel floors before its matrix but does not clamp above white, and a damaged source
    /// must not make integer packing trap here either.
    public static func packRows(
        _ delivered: UnsafeBufferPointer<Float>,
        rows: Range<Int>, width: Int,
        into destination: UnsafeMutableBufferPointer<UInt16>
    ) {
        guard width > 0, !rows.isEmpty,
              delivered.count >= rows.count * width * 4,
              destination.count >= rows.upperBound * width * 4 else { return }
        let start = rows.lowerBound * width * 4
        let chunks = (rows.count + encodeChunkRows - 1) / encodeChunkRows

        func band(_ band: Range<Int>) {
            for index in stride(from: band.lowerBound * width * 4,
                                to: band.upperBound * width * 4, by: 4) {
                for channel in 0..<3 {
                    destination[start + index + channel] =
                        quantizeNormalized(delivered[index + channel])
                }
                destination[start + index + 3] = 65535
            }
        }

        guard chunks > 1 else { return band(0..<rows.count) }
        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
            let first = chunk * encodeChunkRows
            band(first..<min(rows.count, first + encodeChunkRows))
        }
    }

    public static func encodeRows(
        _ developed: UnsafeBufferPointer<Float>,
        rows: Range<Int>, width: Int,
        into destination: UnsafeMutableBufferPointer<UInt16>,
        transfer: Transfer = .srgb,
        shoulderKnee: Float = FilmSDRDelivery.standardShoulderKnee
    ) {
        let chunks = (rows.count + encodeChunkRows - 1) / encodeChunkRows
        guard chunks > 1 else {
            return encodeBand(developed, rows: rows, band: 0..<rows.count,
                              width: width, into: destination,
                              transfer: transfer, shoulderKnee: shoulderKnee)
        }
        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
            let first = chunk * encodeChunkRows
            let last = min(rows.count, first + encodeChunkRows)
            encodeBand(developed, rows: rows, band: first..<last,
                       width: width, into: destination, transfer: transfer,
                       shoulderKnee: shoulderKnee)
        }
    }

    /// `band` is relative to the start of `rows`.
    private static func encodeBand(
        _ developed: UnsafeBufferPointer<Float>,
        rows: Range<Int>, band: Range<Int>, width: Int,
        into destination: UnsafeMutableBufferPointer<UInt16>,
        transfer: Transfer, shoulderKnee: Float
    ) {
        let start = rows.lowerBound * width * 4
        for index in stride(from: band.lowerBound * width * 4,
                            to: band.upperBound * width * 4, by: 4) {
            switch transfer {
            case .hlg:
                // Colour only. A print is opaque, and the fourth channel of a still is
                // coverage rather than the gain the video recording path reads it as;
                // `testEncodeIgnoresAlpha` holds this path to that.
                let coded = HLGTransfer.encodeRGB(
                    r: developed[index],
                    g: developed[index + 1],
                    b: developed[index + 2])
                destination[start + index] =
                    quantizeNormalized(coded.r)
                destination[start + index + 1] =
                    quantizeNormalized(coded.g)
                destination[start + index + 2] =
                    quantizeNormalized(coded.b)
            case .srgb, .shoulderedSRGB:
                for channel in 0..<3 {
                    let linear = developed[index + channel]
                    let coded: Float
                    switch transfer {
                    case .srgb: coded = encode(linear)
                    case .shoulderedSRGB:
                        coded = encode(ColorScience.displayShoulder(
                            linear, knee: shoulderKnee))
                    case .hlg: preconditionFailure("handled above")
                    }
                    destination[start + index + channel] =
                        quantizeNormalized(coded)
                }
            }
            destination[start + index + 3] = 65535
        }
    }
}
