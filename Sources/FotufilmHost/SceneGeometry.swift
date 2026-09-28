import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(Dispatch)
import Dispatch
#endif

/// The saved edit's geometry, as the web editor writes it (`web/src/editor-state.js`), and the
/// single resample that applies it: the same inverse mapping as `web/src/raw-source.js`, so a
/// crop drawn in the editor lands on the same pixels natively.
struct SceneGeometry: Decodable, Equatable {
    /// `edit.lens` (web/src/lens-correction.js); the correction itself is a table the lens plan
    /// resolves, sampled here first in the chain, as the Mac app corrects before it orients.
    struct Lens: Decodable, Equatable {
        var enabled = false
        var amount: Double?
        var profileID: String?
        var distortion = 0.0, vignetting = 0.0, redCyan = 0.0, blueYellow = 0.0
    }

    var rotation = 0
    var flip = false
    var straighten = 0.0
    var perspectiveV = 0.0
    var perspectiveH = 0.0
    var crop: [[Double]] = SceneGeometry.fullCrop
    var lens: Lens?

    static let fullCrop: [[Double]] = [[0, 0], [1, 0], [1, 1], [0, 1]]

    private enum CodingKeys: String, CodingKey {
        case rotation, flip, straighten, perspectiveV, perspectiveH, crop, lens
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
        lens = try values.decodeIfPresent(Lens.self, forKey: .lens).flatMap { $0.enabled ? $0 : nil }
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
            && lens == nil
    }

    /// The oriented frame at `maxEdge` (0 or nil: full size) and the delivered size after the crop.
    /// An upright rectangular crop moved out to whole pixels of the oriented frame, as the Mac app
    /// cuts one (`CGRect.integral`); any other crop is sampled as drawn.
    func snapped(width: Int, height: Int) -> SceneGeometry {
        let (left, top, right, bottom) = (crop[0][0], crop[0][1], crop[2][0], crop[2][1])
        guard crop != Self.fullCrop, !straightenActive, !perspectiveActive,
              crop[1] == [right, top], crop[3] == [left, bottom], left < right, top < bottom
        else { return self }
        let (w, h) = rotation % 2 == 0 ? (Double(width), Double(height))
                                       : (Double(height), Double(width))
        func outward(_ low: Double, _ high: Double, _ size: Double) -> (Double, Double) {
            (max(0, (low * size + 1e-6).rounded(.down)) / size,
             min(size, (high * size - 1e-6).rounded(.up)) / size)
        }
        let (x0, x1) = outward(left, right, w), (y0, y1) = outward(top, bottom, h)
        var copy = self
        copy.crop = [[x0, y0], [x1, y0], [x1, y1], [x0, y1]]
        return copy
    }

    /// `maxEdge` bounds the delivered picture's long edge, as the Mac app's `FilmRender` reduces
    /// after the crop: a cropped photograph previews and exports as large as an uncropped one.
    /// A reduced size rounds outward, as Core Image's resampled extents do, and a limit within
    /// half a pixel of the picture leaves it at its own size.
    func sizes(width: Int, height: Int, maxEdge: Int?) -> (frame: (Int, Int), output: (Int, Int)) {
        let swapped = rotation % 2 != 0
        let orientedWidth = swapped ? height : width, orientedHeight = swapped ? width : height
        func distance(_ a: [Double], _ b: [Double]) -> Double {
            hypot((a[0] - b[0]) * Double(orientedWidth), (a[1] - b[1]) * Double(orientedHeight))
        }
        let cropped = ((distance(crop[0], crop[1]) + distance(crop[3], crop[2])) / 2,
                       (distance(crop[0], crop[3]) + distance(crop[1], crop[2])) / 2)
        let longest = max(cropped.0, cropped.1)
        guard let limit = maxEdge, limit > 0, Double(limit) < longest - 0.5 else {
            return ((orientedWidth, orientedHeight),
                    (max(1, Int(cropped.0.rounded())), max(1, Int(cropped.1.rounded()))))
        }
        let scale = Double(limit) / longest
        func outward(_ length: Double) -> Int { max(1, Int((length * scale - 1e-6).rounded(.up))) }
        return ((outward(Double(orientedWidth)), outward(Double(orientedHeight))),
                (outward(cropped.0), outward(cropped.1)))
    }

    /// Physical film coverage, before preview dimensions are rounded to whole pixels.
    func frameCoverage(width: Int, height: Int) -> Float {
        let w = Double(rotation % 2 == 0 ? width : height)
        let h = Double(rotation % 2 == 0 ? height : width)
        func distance(_ a: [Double], _ b: [Double]) -> Double {
            hypot((a[0] - b[0]) * w, (a[1] - b[1]) * h)
        }
        let croppedWidth = (distance(crop[0], crop[1]) + distance(crop[3], crop[2])) / 2
        let croppedHeight = (distance(crop[0], crop[3]) + distance(crop[1], crop[2])) / 2
        return Float(min(croppedWidth, croppedHeight) / max(1, min(w, h)))
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
    ///
    /// `lensTable` is the correction's radial resampling table (`WebLensRequest.Plan.table`):
    /// 1024 rows of a per-channel radius ratio and a gain, over the half diagonal.
    func apply(_ source: [Float], width: Int, height: Int,
               orientedSize: (Int, Int), output: (Int, Int), lensTable: [Float]? = nil) -> [Float] {
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
                        let o = (y * outputWidth + x) * 4
                        guard let lensTable else {
                            for c in 0..<4 {
                                target[o + c] = Self.bilinear(source, width, height, c,
                                                              u * Double(width) - 0.5,
                                                              v * Double(height) - 0.5)
                            }
                            continue
                        }
                        // Each channel from its own radius: lateral chroma is a per-channel scale.
                        let lx = (u - 0.5) * Double(width), ly = (v - 0.5) * Double(height)
                        let rows = lensTable.count / 4
                        let t = min(1, hypot(lx, ly) / (hypot(Double(width), Double(height)) / 2))
                            * Double(rows - 1)
                        let lo = Int(t), hi = min(lo + 1, rows - 1), f = Float(t - Double(lo))
                        func at(_ c: Int) -> Double {
                            Double(lensTable[lo * 4 + c] * (1 - f) + lensTable[hi * 4 + c] * f)
                        }
                        let gain = Float(at(3))
                        for c in 0..<3 {
                            let ratio = at(c)
                            target[o + c] = Self.bilinear(
                                source, width, height, c,
                                Double(width) / 2 + lx * ratio - 0.5,
                                Double(height) / 2 + ly * ratio - 0.5) * gain
                        }
                        target[o + 3] = 1
                    }
                }
            }
        }
        return result
    }

    @inline(__always)
    static func bilinear(_ source: UnsafeBufferPointer<Float>, _ width: Int, _ height: Int,
                         _ c: Int, _ x: Double, _ y: Double) -> Float {
        let sx = min(max(x, 0), Double(width - 1)), sy = min(max(y, 0), Double(height - 1))
        let ix = Int(sx), iy = Int(sy)
        let fx = Float(sx - Double(ix)), fy = Float(sy - Double(iy))
        let nx = min(ix + 1, width - 1), ny = min(iy + 1, height - 1)
        let a = source[(iy * width + ix) * 4 + c], b = source[(iy * width + nx) * 4 + c]
        let d = source[(ny * width + ix) * 4 + c], e = source[(ny * width + nx) * 4 + c]
        return (a + (b - a) * fx) * (1 - fy) + (d + (e - d) * fx) * fy
    }

    static func concurrent(_ iterations: Int, _ body: (Int) -> Void) {
        #if canImport(Dispatch)
        DispatchQueue.concurrentPerform(iterations: iterations, execute: body)
        #else
        for index in 0..<iterations { body(index) }
        #endif
    }
}
