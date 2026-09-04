import Foundation

/// Recovers one exposure placement from paired renditions without substituting the rendered
/// reference for scene light. The HDR samples remain scene-linear; only one uniform gain is
/// applied, so spatial contrast, colour ratios, and values above diffuse white are retained.
public enum SceneExposureCalibration {
    /// Estimates the gain that aligns the middle of a scene-linear HDR rendition with its
    /// platform SDR reference. Both inputs are interleaved linear Rec.2020 RGBA at identical
    /// geometry. Highlights are excluded because the reference has already tone-mapped them.
    public static func referenceGain(
        sceneLinearHDR hdr: [Float],
        linearSDRReference sdr: [Float]
    ) -> Float {
        guard hdr.count == sdr.count, hdr.count >= 4, hdr.count.isMultiple(of: 4)
        else { return 1 }
        return hdr.withUnsafeBufferPointer { hdrBuffer in
            sdr.withUnsafeBufferPointer { sdrBuffer in
                referenceGain(sceneLinearHDR: hdrBuffer,
                              linearSDRReference: sdrBuffer)
            }
        }
    }

    public static func referenceGain(
        sceneLinearHDR hdr: UnsafeBufferPointer<Float>,
        linearSDRReference sdr: UnsafeBufferPointer<Float>
    ) -> Float {
        guard hdr.count == sdr.count, hdr.count >= 4, hdr.count.isMultiple(of: 4)
        else { return 1 }
        let pixelCount = hdr.count / 4
        let stride = max(1, pixelCount / 65_536)
        let weights = ColorScience.luminanceWeights
        var offsets: [Float] = []
        offsets.reserveCapacity(min(pixelCount, 65_536))
        for pixel in Swift.stride(from: 0, to: pixelCount, by: stride) {
            let index = pixel * 4
            let reference = weights.0 * sdr[index]
                + weights.1 * sdr[index + 1]
                + weights.2 * sdr[index + 2]
            // Stay above decode noise and below the reference rendition's shoulder.
            guard reference >= 0.01, reference <= 0.65 else { continue }
            let scene = weights.0 * hdr[index]
                + weights.1 * hdr[index + 1]
                + weights.2 * hdr[index + 2]
            guard scene.isFinite, reference.isFinite, scene > 0 else { continue }
            offsets.append(log2(scene / reference))
        }
        guard offsets.count >= min(64, max(8, pixelCount / 16)) else { return 1 }
        offsets.sort()
        let middle = offsets.count / 2
        let median = offsets.count.isMultiple(of: 2)
            ? (offsets[middle - 1] + offsets[middle]) * 0.5
            : offsets[middle]
        guard median.isFinite, median > 0 else { return 1 }
        // Standard processed HDR should only be brought back to its reference placement. A
        // malformed pair cannot brighten the source or move it by more than two stops.
        return min(1, max(0.25, exp2(-median)))
    }
}
