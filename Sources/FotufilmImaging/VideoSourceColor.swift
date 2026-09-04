import Foundation

#if canImport(FotufilmCore)
import FotufilmCore
#endif

#if canImport(CoreMedia)
import CoreMedia
import CoreVideo
#endif

/// The color information needed to turn a standard decoded video frame into the engine's one
/// input representation: scene-linear Rec.2020 with diffuse white at 1.0.
public struct VideoSourceColor: Equatable, Sendable {
    public enum Transfer: String, Codable, Sendable {
        /// AVFoundation has converted the source to Display P3 with the sRGB transfer.
        case sRGB
        /// HLG RGB signal values in the source primaries.
        case hlg
        /// ST 2084 RGB signal values in the source primaries.
        case pq
    }

    public enum Primaries: String, Codable, Sendable {
        case rec709
        case displayP3
        case rec2020
    }

    public var transfer: Transfer
    public var primaries: Primaries

    public init(transfer: Transfer, primaries: Primaries) {
        self.transfer = transfer
        self.primaries = primaries
    }

    /// The output requested for an ordinary color-managed SDR decode.
    public static let colorManagedSDR = VideoSourceColor(
        transfer: .sRGB, primaries: .displayP3)

    public var isHDR: Bool { transfer != .sRGB }

    /// Relative diffuse-white headroom represented by this transfer.
    public var sceneHeadroom: Float {
        switch transfer {
        case .sRGB: return 1
        case .hlg: return HLGSceneTransfer.headroom
        case .pq: return PQSceneTransfer.headroom
        }
    }

    /// Converts one decoded RGB triple to scene-linear Rec.2020. HDR decoders are deliberately
    /// asked for untouched code values; SDR is deliberately asked for Display-P3/sRGB. Those are
    /// the only two transport contracts accepted here.
    public func linearRec2020(_ value: SIMD3<Float>) -> SIMD3<Float> {
        let linear: SIMD3<Float>
        switch transfer {
        case .sRGB:
            linear = SIMD3(Self.signedSRGB(value.x),
                           Self.signedSRGB(value.y),
                           Self.signedSRGB(value.z))
        case .hlg:
            linear = SIMD3(Self.hlgScene(value.x),
                           Self.hlgScene(value.y),
                           Self.hlgScene(value.z))
        case .pq:
            linear = SIMD3(Self.pqScene(value.x),
                           Self.pqScene(value.y),
                           Self.pqScene(value.z))
        }

        switch primaries {
        case .rec2020: return linear
        case .displayP3: return ColorScience.linearDisplayP3ToRec2020(linear)
        case .rec709: return ColorScience.linearSRGBToRec2020(linear)
        }
    }

    private static func signedSRGB(_ value: Float) -> Float {
        let magnitude = abs(value)
        let linear = ColorScience.srgbToLinear(magnitude)
        return value < 0 ? -linear : linear
    }

    /// AVFoundation expands video-range Y′CbCr while forming RGB float. The resulting channels
    /// therefore already use the transfer function's full 0...1 signal range.
    private static func transferSignal(_ code: Float) -> Float {
        min(max(code, 0), 1)
    }

    private static func hlgScene(_ code: Float) -> Float {
        HLGSceneTransfer.sceneLight(transferSignal(code)) * HLGSceneTransfer.headroom
    }

    private static func pqScene(_ code: Float) -> Float {
        PQSceneTransfer.sceneLight(transferSignal(code))
    }
}

/// SMPTE ST 2084 converted from absolute display luminance to the app's relative scene scale.
/// BT.2408/ISO HDR reference white is 203 cd/m²; the film engine calls that diffuse white 1.0.
public enum PQSceneTransfer {
    public static let referenceWhiteNits: Float = 203
    public static let peakNits: Float = 10_000
    public static var headroom: Float { peakNits / referenceWhiteNits }

    private static let m1: Float = 2610.0 / 16384.0
    private static let m2: Float = 2523.0 / 32.0
    private static let c1: Float = 3424.0 / 4096.0
    private static let c2: Float = 2413.0 / 128.0
    private static let c3: Float = 2392.0 / 128.0

    /// Full-range ST 2084 signal to relative linear light with reference white at 1.0.
    public static func sceneLight(_ signal: Float) -> Float {
        let encoded = min(max(signal, 0), 1)
        let power = pow(encoded, 1 / m2)
        let numerator = max(power - c1, 0)
        let denominator = max(c2 - c3 * power, Float.leastNonzeroMagnitude)
        let normalizedNits = pow(numerator / denominator, 1 / m1)
        return normalizedNits * headroom
    }
}

#if canImport(CoreMedia)
extension VideoSourceColor {
    /// Reads the first HDR transfer declared by the track. Bit depth is intentionally irrelevant:
    /// it describes storage precision, not whether the numbers represent HDR light.
    public static func tagged(in descriptions: [CMFormatDescription]) -> VideoSourceColor {
        for description in descriptions {
            guard let value = CMFormatDescriptionGetExtension(
                    description,
                    extensionKey: kCMFormatDescriptionExtension_TransferFunction)
                    as? String else { continue }
            let transfer: Transfer
            if value == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String {
                transfer = .hlg
            } else if value
                        == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String {
                transfer = .pq
            } else {
                continue
            }
            return VideoSourceColor(
                transfer: transfer, primaries: primaries(of: description))
        }
        return .colorManagedSDR
    }

    private static func primaries(of description: CMFormatDescription) -> Primaries {
        guard let value = CMFormatDescriptionGetExtension(
                description,
                extensionKey: kCMFormatDescriptionExtension_ColorPrimaries)
                as? String else { return .rec2020 }
        if value == kCVImageBufferColorPrimaries_P3_D65 as String {
            return .displayP3
        }
        if value == kCVImageBufferColorPrimaries_ITU_R_709_2 as String {
            return .rec709
        }
        return .rec2020
    }
}
#endif
