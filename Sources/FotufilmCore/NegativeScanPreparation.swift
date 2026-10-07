import Foundation
import FotufilmHalide

/// A scanned negative's scan made ready for the editor by the engine's kernels: the light
/// source's unevenness divided out, then, for a scan read without a film, its plain positive.
public enum NegativeScanPreparation {
    /// `rgba`, interleaved linear Rec. 2020, evened under `light`, cells of interleaved linear
    /// RGB gains (`NegativeLightFrame`), then read by `plain` when given. Alpha is kept.
    public static func prepare(_ rgba: inout [Float], width: Int, height: Int,
                               light: (width: Int, height: Int, gains: [Float])?,
                               plain: PlainNegativeScan?) throws {
        guard width > 0, height > 0, rgba.count == width * height * 4 else { throw Failure.unprepared }
        let light = light.flatMap {
            $0.width > 0 && $0.height > 0 && $0.gains.count == $0.width * $0.height * 3 ? $0 : nil
        }
        guard light != nil || plain != nil else { return }
        var parameters: [Float] = [light == nil ? 0 : 1, plain == nil ? 0 : 1, 1, 1, 1, 1, 1, 1, 0]
        if let plain {
            for c in 0..<3 {
                parameters[2 + c] = plain.border[c]
                parameters[5 + c] = plain.gains[c]
            }
            parameters[8] = plain.reference
        }
        let gains = light?.gains ?? [1, 1, 1]
        let status = rgba.withUnsafeMutableBufferPointer { rgba in
            gains.withUnsafeBufferPointer { gains in
                fotufilm_scan_prepare(rgba.baseAddress, rgba.baseAddress, Int32(width), Int32(height),
                                      gains.baseAddress, Int32(light?.width ?? 1),
                                      Int32(light?.height ?? 1), parameters)
            }
        }
        guard status == 0 else { throw Failure.unprepared }
    }

    public enum Failure: LocalizedError {
        case unprepared
        public var errorDescription: String? { "The scan could not be prepared." }
    }
}
