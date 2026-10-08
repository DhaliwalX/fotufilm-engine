import Foundation
import FotufilmHalide

/// A trichromatic scan: a negative photographed under red, green and blue light, each exposure
/// read as the layer it records, green's and blue's lined up with red's, and the three merged
/// into one scan, an untagged 16-bit TIFF the editors read as linear samples
/// (`FotufilmTrichromatic.h`).
public enum TrichromaticScan {
    /// The light an exposure was made under.
    public enum Light: Int32, Sendable {
        case red = 0, green, blue
        /// One of the three lights through no picture: a light frame, or the film's leader.
        case blank
        /// White or mixed light.
        case other = -1
    }

    /// What an exposure shows about its light.
    public struct Measured: Sendable {
        public var light: Light
        /// The light's colour in the exposure, as decoded.
        public var colour: SIMD3<Float>
    }

    /// Which light `rgba`, interleaved linear RGBA of any size, was made under.
    public static func measure(_ rgba: [Float], width: Int, height: Int) throws -> Measured {
        guard rgba.count == width * height * 4 else { throw Failure.unreadable }
        var measured = [Float](repeating: 0, count: 4)
        var light: Int32 = 0
        guard fotufilm_trichromatic_measure(rgba, Int32(width), Int32(height), &measured, &light) == 0
        else { throw Failure.unreadable }
        return Measured(light: Light(rawValue: light) ?? .other,
                        colour: SIMD3(measured[0], measured[1], measured[2]))
    }

    /// Exposures grouped into frames, in the order they were made: index triples (red, green,
    /// blue) into `lights`; blank and other exposures are left out. Throws `.ungrouped` with the
    /// first exposure that fits no frame.
    public static func frames(_ lights: [Light]) throws -> [[Int]] {
        var frames = [Int32](repeating: 0, count: max(3, lights.count / 3 * 3))
        let count = fotufilm_trichromatic_group(lights.map(\.rawValue), Int32(lights.count), &frames)
        guard count >= 0 else { throw Failure.ungrouped(Int(-1 - count)) }
        return (0..<Int(count)).map { f in (0..<3).map { Int(frames[3 * f + $0]) } }
    }

    /// The layer `rgba` records under a light of `colour`: its transmittance, a plane.
    public static func layer(_ rgba: [Float], width: Int, height: Int,
                             colour: SIMD3<Float>) throws -> [Float] {
        guard rgba.count == width * height * 4 else { throw Failure.unreadable }
        var layer = [Float](repeating: 0, count: width * height)
        let status = fotufilm_trichromatic_layer(rgba, Int32(width), Int32(height),
                                                 [colour.x, colour.y, colour.z], &layer)
        guard status == 0 else { throw Failure.unmerged }
        return layer
    }

    /// How a layer lines up with the reference layer.
    public struct Registration: Sendable {
        /// The layer's sample for reference pixel (x, y) is at
        /// (a0 x + a1 y + a2, a3 x + a4 y + a5).
        public var affine: [Float]
        /// The patches that agreed, and the median and 90th-percentile distance (pixels) by which
        /// they still disagree.
        public var patches: Int
        public var residual: Float
        public var residual90: Float
    }

    public static func register(_ moving: [Float], to reference: [Float], width: Int,
                                height: Int) throws -> Registration {
        guard moving.count == width * height, reference.count == moving.count else {
            throw Failure.unreadable
        }
        var affine = [Float](repeating: 0, count: 6), report = [Float](repeating: 0, count: 3)
        let status = fotufilm_trichromatic_register(reference, moving, Int32(width), Int32(height),
                                                    &affine, &report)
        guard status == 0 else { throw status == -4 ? Failure.unaligned : Failure.unmerged }
        return Registration(affine: affine, patches: Int(report[0]), residual: report[1],
                            residual90: report[2])
    }

    /// The merged scan's file: red as it is, green and blue through their registrations.
    public static func merge(red: [Float], green: [Float], blue: [Float], width: Int, height: Int,
                             green greenRegistration: Registration,
                             blue blueRegistration: Registration) throws -> Data {
        let count = width * height
        guard red.count == count, green.count == count, blue.count == count else {
            throw Failure.unreadable
        }
        let size = fotufilm_trichromatic_file_size(Int32(width), Int32(height))
        guard size > 0 else { throw Failure.unmerged }
        var file = Data(count: Int(size))
        let status = file.withUnsafeMutableBytes { bytes in
            fotufilm_trichromatic_merge(red, green, blue, Int32(width), Int32(height),
                                        greenRegistration.affine, blueRegistration.affine,
                                        bytes.bindMemory(to: UInt8.self).baseAddress, size)
        }
        guard status == 0 else { throw Failure.unmerged }
        return file
    }

    public enum Failure: LocalizedError, Equatable {
        case unreadable, unmerged, unaligned, ungrouped(Int)
        public var errorDescription: String? {
            switch self {
            case .unreadable: return "The exposure could not be read."
            case .unmerged: return "The exposures could not be merged."
            case .unaligned:
                return "The exposures share too little detail to line up: pick three exposures of the same frame."
            case .ungrouped:
                return "The exposures do not group into frames."
            }
        }
    }
}
