import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(Dispatch)
import Dispatch
#endif

/// The saved edit's geometry, as the web editor writes it (`web/src/editor-state.js`), and the
/// single resample that applies it: the same inverse mapping as `web/src/raw-source.js`, so a
/// crop drawn in the editor lands on the same pixels natively. Lens correction is not yet here.
struct SceneGeometry: Decodable, Equatable {
    var rotation = 0
    var flip = false
    var straighten = 0.0
    var perspectiveV = 0.0
    var perspectiveH = 0.0
    var crop: [[Double]] = SceneGeometry.fullCrop

    static let fullCrop: [[Double]] = [[0, 0], [1, 0], [1, 1], [0, 1]]

    private enum CodingKeys: String, CodingKey {
        case rotation, flip, straighten, perspectiveV, perspectiveH, crop
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rotation = try values.decodeIfPresent(Int.self, forKey: .rotation) ?? 0
        flip = try values.decodeIfPresent(Bool.self, forKey: .flip) ?? false
        straighten = try values.decodeIfPresent(Double.self, forKey: .straighten) ?? 0
        perspectiveV = try values.decodeIfPresent(Double.self, forKey: .perspectiveV) ?? 0
        perspectiveH = try values.decodeIfPresent(Double.self, forKey: .perspectiveH) ?? 0
        crop = try values.decodeIfPresent([[Double]].self, forKey: .crop) ?? Self.fullCrop
        guard (0...3).contains(rotation), abs(straighten) <= 15, crop.count == 4,
              crop.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Invalid geometry."))
        }
    }

    /// The geometry with the crop left out, which is how the crop tool shows the frame.
    func uncropped() -> SceneGeometry {
        var copy = self
        copy.crop = Self.fullCrop
        return copy
    }

    var perspectiveActive: Bool { abs(perspectiveV) > 0.001 || abs(perspectiveH) > 0.001 }
    var straightenActive: Bool { abs(straighten) > 0.001 }
    var isIdentity: Bool {
        rotation == 0 && !flip && !straightenActive && !perspectiveActive && crop == Self.fullCrop
    }

    /// The oriented frame at `maxEdge` (0 or nil: full size) and the delivered size after the crop.
    func sizes(width: Int, height: Int, maxEdge: Int?) -> (frame: (Int, Int), output: (Int, Int)) {
        let swapped = rotation % 2 != 0
        let orientedWidth = swapped ? height : width, orientedHeight = swapped ? width : height
        let limit = Double(maxEdge ?? 0) > 0 ? Double(maxEdge!) : .infinity
        let scale = min(1, limit / Double(max(orientedWidth, orientedHeight)))
        let frame = (max(1, Int((Double(orientedWidth) * scale).rounded())),
                     max(1, Int((Double(orientedHeight) * scale).rounded())))
        func distance(_ a: [Double], _ b: [Double]) -> Double {
            hypot((a[0] - b[0]) * Double(frame.0), (a[1] - b[1]) * Double(frame.1))
        }
        let output = (
            max(1, Int(((distance(crop[0], crop[1]) + distance(crop[3], crop[2])) / 2).rounded())),
            max(1, Int(((distance(crop[0], crop[3]) + distance(crop[1], crop[2])) / 2).rounded())))
        return (frame, output)
    }

    /// Unit square to the crop quadrilateral (`homography` in web/src/geometry.js).
    static func homography(_ p: [[Double]]) -> [Double] {
        let (x0, y0, x1, y1) = (p[0][0], p[0][1], p[1][0], p[1][1])
        let (x2, y2, x3, y3) = (p[2][0], p[2][1], p[3][0], p[3][1])
        let dx1 = x1 - x2, dx2 = x3 - x2, sx = x0 - x1 + x2 - x3
        let dy1 = y1 - y2, dy2 = y3 - y2, sy = y0 - y1 + y2 - y3
        let determinant = dx1 * dy2 - dx2 * dy1
        let g = (sx * dy2 - dx2 * sy) / determinant
        let h = (dx1 * sy - sx * dy1) / determinant
        return [x1 - x0 + g * x1, x3 - x0 + h * x3, x0,
                y1 - y0 + g * y1, y3 - y0 + h * y3, y0, g, h]
    }

    @inline(__always)
    static func map(_ m: [Double], _ u: Double, _ v: Double) -> (Double, Double) {
        let denominator = m[6] * u + m[7] * v + 1
        return ((m[0] * u + m[1] * v + m[2]) / denominator,
                (m[3] * u + m[4] * v + m[5]) / denominator)
    }

    /// Resamples `source` (RGBA float, `width` x `height`, the photograph as decoded) through the
    /// geometry into `output` pixels. `source` may already be reduced; coordinates are unit ones.
    func apply(_ source: [Float], width: Int, height: Int,
               orientedSize: (Int, Int), output: (Int, Int)) -> [Float] {
        let (outputWidth, outputHeight) = output
        let (orientedWidth, orientedHeight) = (Double(orientedSize.0), Double(orientedSize.1))
        let matrix = Self.homography(crop)
        let perspective = perspectiveActive
            ? PerspectiveProjection.inverse(width: orientedWidth, height: orientedHeight,
                                            vertical: perspectiveV, horizontal: perspectiveH)
            : nil
        let angle = straightenActive ? straighten * .pi / 180 : 0
        let cosine = cos(angle), sine = sin(angle)
        let cover = max((orientedWidth * cosine + orientedHeight * abs(sine)) / orientedWidth,
                        (orientedHeight * cosine + orientedWidth * abs(sine)) / orientedHeight)
        let rotation = self.rotation, flip = self.flip
        var result = [Float](repeating: 0, count: outputWidth * outputHeight * 4)
        source.withUnsafeBufferPointer { source in
            result.withUnsafeMutableBufferPointer { target in
                let target = target
                Self.concurrent(outputHeight) { y in
                    for x in 0..<outputWidth {
                        var (u, v) = Self.map(matrix, (Double(x) + 0.5) / Double(outputWidth),
                                              (Double(y) + 0.5) / Double(outputHeight))
                        if let perspective { (u, v) = Self.map(perspective, u, v) }
                        let px = (u - 0.5) * orientedWidth / cover
                        let py = (v - 0.5) * orientedHeight / cover
                        u = (cosine * px + sine * py) / orientedWidth + 0.5
                        v = (-sine * px + cosine * py) / orientedHeight + 0.5
                        if flip { u = 1 - u }
                        switch rotation {
                        case 1: (u, v) = (1 - v, u)
                        case 2: (u, v) = (1 - u, 1 - v)
                        case 3: (u, v) = (v, 1 - u)
                        default: break
                        }
                        let sx = min(max(u * Double(width) - 0.5, 0), Double(width - 1))
                        let sy = min(max(v * Double(height) - 0.5, 0), Double(height - 1))
                        let ix = Int(sx), iy = Int(sy)
                        let fx = Float(sx - Double(ix)), fy = Float(sy - Double(iy))
                        let nx = min(ix + 1, width - 1), ny = min(iy + 1, height - 1)
                        let o = (y * outputWidth + x) * 4
                        for c in 0..<4 {
                            let a = source[(iy * width + ix) * 4 + c]
                            let b = source[(iy * width + nx) * 4 + c]
                            let d = source[(ny * width + ix) * 4 + c]
                            let e = source[(ny * width + nx) * 4 + c]
                            target[o + c] = (a + (b - a) * fx) * (1 - fy) + (d + (e - d) * fx) * fy
                        }
                    }
                }
            }
        }
        return result
    }

    static func concurrent(_ iterations: Int, _ body: (Int) -> Void) {
        #if canImport(Dispatch)
        DispatchQueue.concurrentPerform(iterations: iterations, execute: body)
        #else
        for index in 0..<iterations { body(index) }
        #endif
    }
}
