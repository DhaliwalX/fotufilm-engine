import Foundation

/// Packs transfer-encoded RGB into BT.709 non-constant-luminance Y′CbCr. The RGB values retain
/// their separately tagged primaries; this type supplies only the matrix and 4:2:0 reduction.
public enum SDRVideoTransfer {
    /// One transfer-encoded RGB pixel to normalized video luma and chroma.
    public static func encode(_ rgb: SIMD3<Float>)
        -> (y: Float, u: Float, v: Float) {
        let signal = SIMD3<Float>(
            min(max(rgb.x, 0), 1), min(max(rgb.y, 0), 1),
            min(max(rgb.z, 0), 1))
        let y = 0.2126 * signal.x + 0.7152 * signal.y + 0.0722 * signal.z
        return (y: y,
                u: (signal.z - y) / 1.8556,
                v: (signal.x - y) / 1.5748)
    }

    /// Four transfer-encoded RGB pixels reduced to one 4:2:0 chroma sample.
    public static func encode420(
        topLeft: SIMD3<Float>, topRight: SIMD3<Float>,
        bottomLeft: SIMD3<Float>, bottomRight: SIMD3<Float>
    ) -> (luma: SIMD4<Float>, u: Float, v: Float) {
        let a = encode(topLeft)
        let b = encode(topRight)
        let c = encode(bottomLeft)
        let d = encode(bottomRight)
        return (
            luma: SIMD4(a.y, b.y, c.y, d.y),
            u: (a.u + b.u + c.u + d.u) * 0.25,
            v: (a.v + b.v + c.v + d.v) * 0.25)
    }
}
