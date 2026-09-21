import Foundation

/// The native picture-plane tilt, including the minimum enlargement needed to keep every
/// output corner inside the photograph. Results use normalized, top-origin coordinates.
public enum PerspectiveProjection {
    public static func corners(width: Double, height: Double,
                               vertical: Double, horizontal: Double) -> [SIMD2<Double>] {
        let cx = width / 2, cy = height / 2
        let focal = 1.3 * max(width, height)
        let v = vertical * .pi / 180, h = horizontal * .pi / 180

        func project(_ px: Double, _ py: Double) -> SIMD2<Double> {
            let dx = px - cx, dy = py - cy
            let y = dy * cos(v)
            var z = dy * sin(v)
            let x = dx * cos(h) - z * sin(h)
            z = dx * sin(h) + z * cos(h)
            let s = focal / (focal + z)
            return SIMD2(cx + x * s, cy + y * s)
        }

        var quad = [
            project(0, height),
            project(width, height),
            project(width, 0),
            project(0, 0),
        ]

        var scale = 1.0
        let rectCorners = [
            (0, height),
            (width, height),
            (width, 0),
            (0, 0),
        ]
        for (rx, ry) in rectCorners {
            let dx = rx - cx, dy = ry - cy
            var reach = Double.infinity
            for i in 0..<4 {
                let a = quad[i], b = quad[(i + 1) % 4]
                let ex = Double(b.x - a.x), ey = Double(b.y - a.y)
                let denominator = dx * ey - dy * ex
                guard abs(denominator) > 1e-9 else { continue }
                let ax = Double(a.x) - cx, ay = Double(a.y) - cy
                let u = (ax * ey - ay * ex) / denominator
                let w = (ax * dy - ay * dx) / denominator
                if u > 0, w >= -1e-6, w <= 1 + 1e-6 { reach = min(reach, u) }
            }
            if reach.isFinite, reach > 0 { scale = max(scale, 1 / reach) }
        }
        if scale > 1 {
            quad = quad.map {
                SIMD2(cx + (Double($0.x) - cx) * scale,
                      cy + (Double($0.y) - cy) * scale)
            }
        }
        return quad.map { SIMD2($0.x / width, 1 - $0.y / height) }
    }

    /// Output unit coordinates to the untilted photograph, for tiled scene-linear samplers.
    public static func inverse(width: Double, height: Double,
                               vertical: Double, horizontal: Double) -> [Double] {
        let p = corners(width: width, height: height, vertical: vertical, horizontal: horizontal)
        let dx1 = p[1].x - p[2].x, dx2 = p[3].x - p[2].x
        let dy1 = p[1].y - p[2].y, dy2 = p[3].y - p[2].y
        let sx = p[0].x - p[1].x + p[2].x - p[3].x
        let sy = p[0].y - p[1].y + p[2].y - p[3].y
        let determinant = dx1 * dy2 - dx2 * dy1
        let g = (sx * dy2 - dx2 * sy) / determinant
        let h = (dx1 * sy - sx * dy1) / determinant
        let a = p[1].x - p[0].x + g * p[1].x, b = p[3].x - p[0].x + h * p[3].x, c = p[0].x
        let d = p[1].y - p[0].y + g * p[1].y, e = p[3].y - p[0].y + h * p[3].y, f = p[0].y
        let scale = a * e - b * d
        return [e - f * h, c * h - b, b * f - c * e,
                f * g - d, a - c * g, c * d - a * f,
                d * h - e * g, b * g - a * h].map { $0 / scale }
    }
}
