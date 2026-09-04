import Foundation

/// Apple Log constants from the Apple Log Profile white paper. The curve combines a log segment
/// with a parabolic toe that becomes negative at black.
public enum AppleLogCurve {
    public static let r0: Float = -0.05641088
    public static let c: Float = 47.28711236
    public static let beta: Float = 0.00964052
    public static let gamma: Float = 0.08550479
    public static let delta: Float = 0.69336945
    /// The signal the toe ends at: encode(Rt) with Rt = 0.01.
    public static let toeSignal: Float = 0.20855531595

    /// Signal to scene reflectance.
    public static func linear(_ code: Float) -> Float {
        if code >= toeSignal { return exp2((code - delta) / gamma) - beta }
        if code >= 0 { return (code / c).squareRoot() + r0 }
        return r0
    }

    /// A 90% diffuse reflector — the white card that goes with the 18% grey one — which is what
    /// every other path in this app calls 1.0.
    public static let diffuseWhite: Float = 0.9

    /// Full signal, in the same reflectance units.
    public static let peakReflectance: Float = 12

    /// A decode is scaled by this to put diffuse white on 1.0, which is the referencing
    /// `fotufilm_roll_for_film` and the print encode both assume.
    public static var sceneScale: Float { 1 / diffuseWhite }

    /// The scene runs to 13.3× diffuse white, or 3.74 stops of highlight, against the 3.77× (1.92
    /// stops) an HLG capture carries.
    public static var headroom: Float { peakReflectance / diffuseWhite }

    /// The curve as a Metal function, so no kernel restates the numbers.
    public static var metalFunction: String { """
    static float apple_log_to_linear(float code)
    {
        const float r0 = \(r0)f;
        const float c = \(c)f;
        const float beta = \(beta)f;
        const float gamma_ = \(gamma)f;
        const float delta = \(delta)f;
        const float threshold = \(toeSignal)f;
        if (code >= threshold) { return exp2((code - delta) / gamma_) - beta; }
        if (code >= 0.0f) { return sqrt(code / c) + r0; }
        return r0;
    }
    """ }
}

/// BT.2100's HLG transfer on the scene side, one authority for the constants every path shares:
/// the inverse OETF that reads an HLG signal back to scene light, and the diffuse-white anchor
/// ITU-R BT.2408 places at 75% signal. The encode paths (`FilmOutputConversion`, the imaging
/// package's `PrintEncoding`) state the same numbers; the parity tests hold them to this one.
public enum HLGSceneTransfer {
    public static let a: Float = 0.17883277
    public static let b: Float = 0.28466892
    public static let c: Float = 0.55991073
    /// BT.2408: diffuse white — graphics white, the 90% reflector — sits at 75% signal.
    public static let diffuseWhiteSignal: Float = 0.75

    /// Inverse OETF: full-range signal 0…1 to normalized scene light 0…1.
    public static func sceneLight(_ signal: Float) -> Float {
        signal <= 0.5
            ? signal * signal / 3
            : (exp((signal - c) / a) + b) / 12
    }

    /// Peak scene light over diffuse white's — the container's whole recorded range, ~3.77×
    /// (1.92 stops). This is a *declared* ceiling the way a gain-map still's is, unlike a
    /// camera log's capacity, which is why HLG alone carries it into `sceneHeadroom`.
    public static var headroom: Float { 1 / sceneLight(diffuseWhiteSignal) }
}

/// The exact inverse transfer functions of the camera log encodings this engine can open. The raw
/// value is the index the Metal kernels switch on.
public enum CameraLogCurve: UInt32, CaseIterable, Codable, Sendable {
    case appleLog = 0
    case sLog3 = 1
    case sLog2 = 2
    case hlg = 3
    case fLog = 4
    case fLog2 = 5

    /// Code value (full-scale 0…1) to scene reflectance, 0.18 = mid grey.
    public func linear(_ code: Float) -> Float {
        switch self {
        case .appleLog: return AppleLogCurve.linear(code)
        case .sLog3: return Self.slog3ToLinear(code)
        case .sLog2: return Self.slog2ToLinear(code)
        case .hlg: return Self.hlgToLinear(code)
        case .fLog: return Self.flogToLinear(code)
        case .fLog2: return Self.flog2ToLinear(code)
        }
    }

    /// S-Log3, from Sony's technical summary for S-Gamut3/S-Log3.
    public static func slog3ToLinear(_ code: Float) -> Float {
        let c = code * 1023
        if c >= 171.2102946929 {
            return pow(10, (c - 420) / 261.5) * 0.19 - 0.01
        }
        return (c - 95) * 0.01125 / (171.2102946929 - 95)
    }

    /// S-Log2, via the S-Log curve it rescales (Sony's S-Log2 paper): the legal-range signal to
    /// IRE, the log segment with a linear toe, then the 219/155 gain that distinguishes S-Log2
    /// from S-Log.
    public static func slog2ToLinear(_ code: Float) -> Float {
        let y = (code * 1023 - 64) / 876
        let toe: Float = 0.030001222851889303
        let x: Float
        if y >= toe {
            x = pow(10, (y - 0.616596 - 0.03) / 0.432699) - 0.037584
        } else {
            x = (y - toe) / 5.0
        }
        return x * 0.9 * (219.0 / 155.0)
    }

    /// HLG RGB signal after AVFoundation has expanded the source's video-range Y′CbCr. BT.2100's
    /// inverse OETF is scaled so BT.2408's 75%-signal diffuse white lands on the 0.9 reflectance
    /// every other camera curve calls a white card.
    public static func hlgToLinear(_ code: Float) -> Float {
        let signal = min(max(code, 0), 1)
        return HLGSceneTransfer.sceneLight(signal) * 0.9
            / HLGSceneTransfer.sceneLight(HLGSceneTransfer.diffuseWhiteSignal)
    }

    /// F-Log, from Fujifilm's F-Log Data Sheet Ver.1.2.
    public static func flogToLinear(_ code: Float) -> Float {
        let a: Float = 0.555556
        let b: Float = 0.009468
        let c: Float = 0.344676
        let d: Float = 0.790453
        let e: Float = 8.735631
        let f: Float = 0.092864
        let cut: Float = 0.100537775223865
        if code >= cut {
            return (pow(10, (code - d) / c) - b) / a
        }
        return (code - f) / e
    }

    /// F-Log2 and F-Log2 C share this curve; their only difference is the recorded gamut.
    /// Constants are from Fujifilm's F-Log2 Data Sheet Ver.1.1 and F-Log2 C Data Sheet Ver.1.0.
    public static func flog2ToLinear(_ code: Float) -> Float {
        let a: Float = 5.555556
        let b: Float = 0.064829
        let c: Float = 0.245281
        let d: Float = 0.384316
        let e: Float = 8.799461
        let f: Float = 0.092864
        let cut: Float = 0.100686685370811
        if code >= cut {
            return (pow(10, (code - d) / c) - b) / a
        }
        return (code - f) / e
    }

    /// All the curves plus the `decode_curve(code, curve)` dispatcher, as Metal source, indexed
    /// by this enum's raw values.
    public static var metalSource: String { """
    \(AppleLogCurve.metalFunction)

    static float slog3_to_linear(float code)
    {
        float c = code * 1023.0f;
        if (c >= 171.2102946929f) {
            return pow(10.0f, (c - 420.0f) / 261.5f) * 0.19f - 0.01f;
        }
        return (c - 95.0f) * 0.01125f / (171.2102946929f - 95.0f);
    }

    static float slog2_to_linear(float code)
    {
        float y = (code * 1023.0f - 64.0f) / 876.0f;
        const float toe = 0.030001222851889303f;
        float x;
        if (y >= toe) {
            x = pow(10.0f, (y - 0.616596f - 0.03f) / 0.432699f) - 0.037584f;
        } else {
            x = (y - toe) / 5.0f;
        }
        return x * 0.9f * (219.0f / 155.0f);
    }

    static float hlg_to_linear(float code)
    {
        float signal = clamp(code, 0.0f, 1.0f);
        const float a = \(HLGSceneTransfer.a)f;
        const float b = \(HLGSceneTransfer.b)f;
        const float c = \(HLGSceneTransfer.c)f;
        float scene = signal <= 0.5f
            ? signal * signal / 3.0f
            : (exp((signal - c) / a) + b) / 12.0f;
        return scene * \(0.9 / HLGSceneTransfer.sceneLight(HLGSceneTransfer.diffuseWhiteSignal))f;
    }

    static float flog_to_linear(float code)
    {
        const float a = 0.555556f;
        const float b = 0.009468f;
        const float c = 0.344676f;
        const float d = 0.790453f;
        const float e = 8.735631f;
        const float f = 0.092864f;
        const float cut = 0.100537775223865f;
        if (code >= cut) { return (pow(10.0f, (code - d) / c) - b) / a; }
        return (code - f) / e;
    }

    static float flog2_to_linear(float code)
    {
        const float a = 5.555556f;
        const float b = 0.064829f;
        const float c = 0.245281f;
        const float d = 0.384316f;
        const float e = 8.799461f;
        const float f = 0.092864f;
        const float cut = 0.100686685370811f;
        if (code >= cut) { return (pow(10.0f, (code - d) / c) - b) / a; }
        return (code - f) / e;
    }

    static float decode_curve(float code, uint curve)
    {
        switch (curve) {
        case 0: return apple_log_to_linear(code);
        case 1: return slog3_to_linear(code);
        case 2: return slog2_to_linear(code);
        case 3: return hlg_to_linear(code);
        case 4: return flog_to_linear(code);
        default: return flog2_to_linear(code);
        }
    }
    """ }
}

/// A source gamut, held as chromaticities and turned into working-space matrices on demand. The
/// construction is the standard one — columns are the primaries' XYZ, scaled so RGB (1,1,1) lands
/// on D65 — kept in Double so the Float matrices the converters bake are bit-stable.
public struct CameraGamut: Equatable, Sendable {
    public struct Primaries: Equatable, Codable, Sendable {
        public var rx, ry, gx, gy, bx, by: Double

        public init(r: (Double, Double), g: (Double, Double), b: (Double, Double)) {
            rx = r.0; ry = r.1; gx = g.0; gy = g.1; bx = b.0; by = b.1
        }
    }

    public var primaries: Primaries

    public init(primaries: Primaries) { self.primaries = primaries }

    /// S-Gamut3.Cine (Sony technical summary).
    public static let sGamut3Cine = CameraGamut(primaries: Primaries(
        r: (0.76600, 0.27500), g: (0.22500, 0.80000), b: (0.08900, -0.08700)))

    /// S-Gamut3 shares the original S-Gamut's gamut (Sony states they differ
    /// only in transform precision), so S-Log2 footage uses it too.
    public static let sGamut = CameraGamut(primaries: Primaries(
        r: (0.73000, 0.28000), g: (0.14000, 0.85500), b: (0.10000, -0.05000)))

    /// Apple Log records in BT.2020 primaries (ITU-R BT.2020, D65).
    public static let rec2020 = CameraGamut(primaries: Primaries(
        r: (0.70800, 0.29200), g: (0.17000, 0.79700), b: (0.13100, 0.04600)))

    /// Fujifilm F-Gamut uses the BT.2020 primaries and D65 white exactly.
    public static let fGamut = rec2020

    /// Fujifilm F-Gamut C, used by F-Log2 C.
    public static let fGamutC = CameraGamut(primaries: Primaries(
        r: (0.73470, 0.26530), g: (0.02630, 0.97370), b: (0.11730, -0.02240)))

    public static let displayP3 = CameraGamut(primaries: Primaries(
        r: (0.680, 0.320), g: (0.265, 0.690), b: (0.150, 0.060)))

    private static let d65 = (x: 0.3127, y: 0.3290)

    /// Row-major 3×3 carrying this gamut's linear RGB to Display P3, both sides D65. This is
    /// the basis of the encoded-P3 *byte* contract (video preview frames), not the engine's
    /// working space — a float path headed for the engine wants `toRec2020`.
    public var toDisplayP3: [Double] {
        Self.multiply(Self.invert(Self.rgbToXYZ(Self.displayP3.primaries)),
                      Self.rgbToXYZ(primaries))
    }

    /// Row-major 3×3 carrying this gamut's linear RGB to the linear Rec.2020 working space,
    /// both sides D65 — the basis camera-profile deltas are solved in, so a correction must be
    /// composed here and only then carried to a delivery or byte basis.
    public var toRec2020: [Double] {
        Self.multiply(Self.invert(Self.rgbToXYZ(Self.rec2020.primaries)),
                      Self.rgbToXYZ(primaries))
    }

    private static func rgbToXYZ(_ p: Primaries) -> [Double] {
        func xyz(_ x: Double, _ y: Double) -> [Double] {
            [x / y, 1, (1 - x - y) / y]
        }
        let r = xyz(p.rx, p.ry), g = xyz(p.gx, p.gy), b = xyz(p.bx, p.by)
        let white = [d65.x / d65.y, 1, (1 - d65.x - d65.y) / d65.y]
        let primaries = [r[0], g[0], b[0],
                         r[1], g[1], b[1],
                         r[2], g[2], b[2]]
        let scale = multiply(invert(primaries), white)
        return [r[0] * scale[0], g[0] * scale[1], b[0] * scale[2],
                r[1] * scale[0], g[1] * scale[1], b[1] * scale[2],
                r[2] * scale[0], g[2] * scale[1], b[2] * scale[2]]
    }

    private static func invert(_ m: [Double]) -> [Double] {
        let det = m[0] * (m[4] * m[8] - m[5] * m[7])
                - m[1] * (m[3] * m[8] - m[5] * m[6])
                + m[2] * (m[3] * m[7] - m[4] * m[6])
        let d = 1 / det
        return [
            (m[4] * m[8] - m[5] * m[7]) * d,
            (m[2] * m[7] - m[1] * m[8]) * d,
            (m[1] * m[5] - m[2] * m[4]) * d,
            (m[5] * m[6] - m[3] * m[8]) * d,
            (m[0] * m[8] - m[2] * m[6]) * d,
            (m[2] * m[3] - m[0] * m[5]) * d,
            (m[3] * m[7] - m[4] * m[6]) * d,
            (m[1] * m[6] - m[0] * m[7]) * d,
            (m[0] * m[4] - m[1] * m[3]) * d,
        ]
    }

    private static func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        if b.count == 3 {
            return (0..<3).map { row -> Double in
                let base = row * 3
                return a[base] * b[0] + a[base + 1] * b[1] + a[base + 2] * b[2]
            }
        }
        var out = [Double](repeating: 0, count: 9)
        for row in 0..<3 {
            for col in 0..<3 {
                out[row * 3 + col] = a[row * 3] * b[col]
                    + a[row * 3 + 1] * b[3 + col]
                    + a[row * 3 + 2] * b[6 + col]
            }
        }
        return out
    }
}

/// The camera log encodings the engine decodes, as data: the exact inverse curve, the recorded
/// gamut, and the `SourceLight` contract each one implies. New formats extend this table — not a
/// converter's switch.
public enum CameraLogEncoding: String, CaseIterable, Codable, Sendable, Identifiable {
    case appleLog
    case slog3Cine
    case slog3
    case slog2
    case flog
    case flog2
    case flog2C
    case hlg

    public var id: String { rawValue }

    public var curve: CameraLogCurve {
        switch self {
        case .appleLog: return .appleLog
        case .slog3Cine, .slog3: return .sLog3
        case .slog2: return .sLog2
        case .flog: return .fLog
        case .flog2, .flog2C: return .fLog2
        case .hlg: return .hlg
        }
    }

    public var gamut: CameraGamut {
        switch self {
        case .appleLog, .hlg: return .rec2020
        case .slog3Cine: return .sGamut3Cine
        case .slog3, .slog2: return .sGamut
        case .flog, .flog2: return .fGamut
        case .flog2C: return .fGamutC
        }
    }

    public var transferFunction: SourceTransferFunction {
        switch self {
        case .appleLog: return .appleLog
        case .slog3Cine, .slog3: return .sLog3
        case .slog2: return .sLog2
        case .flog: return .fLog
        case .flog2, .flog2C: return .fLog2
        case .hlg: return .hlg
        }
    }

    /// The recorded range above diffuse white this encoding *declares*, when it declares one —
    /// the fact `Options.sceneHeadroom` carries. HLG is a bounded container with BT.2408's
    /// diffuse white built into its signal axis, so its ceiling is a statement about the
    /// content, like a gain-map still's. A camera log's full-code value is only the format's
    /// capacity: that light rides the negative's own latitude, the same deliberately unrolled
    /// path a raw capture takes, so those encodings declare nothing.
    public var declaredHeadroom: Float? {
        switch self {
        case .appleLog, .slog3Cine, .slog3, .slog2,
             .flog, .flog2, .flog2C: return nil
        case .hlg: return HLGSceneTransfer.headroom
        }
    }

    /// The contract a clip in this encoding presents to the engine.
    public var sourceLight: SourceLight {
        SourceLight(domain: .sceneLinear(colorSpace: .rec2020Linear),
                    transferFunction: transferFunction,
                    primaries: gamut.primaries,
                    normalization: .sceneReflectance)
    }
}
