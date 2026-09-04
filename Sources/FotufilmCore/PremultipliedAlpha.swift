import Foundation

/// Scene-linear compositing for associated RGBA before nonlinear or spatial film processing.
public enum PremultipliedAlpha {
    /// Flattens associated RGBA over an opaque scene-linear background in place.
    ///
    /// Alpha is coverage, so finite values are constrained to `[0, 1]`; a non-finite alpha is
    /// treated as opaque, matching the engine's device decode repair. Non-finite color is no
    /// scene light and is replaced with zero. Finite signed and HDR color values are preserved.
    public static func flatten(_ rgba: inout [Float], over background: SIMD3<Float>) {
        precondition(rgba.count.isMultiple(of: 4))
        precondition(background.x.isFinite && background.y.isFinite && background.z.isFinite)

        rgba.withUnsafeMutableBufferPointer { pixels in
            for base in stride(from: 0, to: pixels.count, by: 4) {
                let storedAlpha = pixels[base + 3]
                let alpha = storedAlpha.isFinite ? clamp(storedAlpha, 0, 1) : 1
                let backgroundShare = 1 - alpha
                for channel in 0..<3 {
                    let stored = pixels[base + channel]
                    let associated = stored.isFinite ? stored : 0
                    pixels[base + channel] = associated
                        + backgroundShare * background[channel]
                }
                pixels[base + 3] = 1
            }
        }
    }
}
