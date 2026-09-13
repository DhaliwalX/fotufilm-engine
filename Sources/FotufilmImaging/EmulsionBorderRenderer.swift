#if canImport(CoreGraphics)
import Foundation
import CoreGraphics

/// A reference-inspired presentation style, not a measured emulsion or transfer process.
/// The edge field is fixed in units of 1/1000 of the photograph's short side so menu previews
/// and full exports share the same wear. Only the border is rasterised; the photo is copied
/// at its original resolution by PrintFrameRenderer afterwards.
enum EmulsionBorderRenderer {
    static func draw(in context: CGContext, around photo: CGRect) -> Bool {
        let unit = min(photo.width, photo.height) / 1000
        let w = Float(photo.width / unit), h = Float(photo.height / unit)
        let fringe: CGFloat = 58
        // Bound the texture allocation, including extreme panoramas, independently of export
        // resolution. Sampling still uses the same normalised coordinates at every size.
        let step = max(1, (max(CGFloat(w), CGFloat(h)) + 2 * fringe) / 2048)
        let width = Int(ceil((CGFloat(w) + 2 * fringe) / step))
        let height = Int(ceil((CGFloat(h) + 2 * fringe) / step))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            let y = h / 2 + Float(fringe) - (Float(row) + 0.5) * Float(step)
            for column in 0..<width {
                let x = (Float(column) + 0.5) * Float(step) - Float(fringe) - w / 2
                // The middle is covered by the original photo. Avoid evaluating the field there.
                if abs(x) < w / 2 && abs(y) < h / 2 { continue }
                let qx = abs(x) - w / 2 - 32 + 23
                let qy = abs(y) - h / 2 - 32 + 23
                let ox = max(qx, 0), oy = max(qy, 0)
                let distance = sqrt(ox * ox + oy * oy) + min(max(qx, qy), 0) - 23
                if distance > 23 { continue }

                let coarse = noise(x * 0.014, y * 0.014, seed: 31)
                let tooth = noise(x * 0.14, y * 0.14, seed: 97)
                let fine = noise(x * 0.71, y * 0.71, seed: 211)
                let d = distance - 7 * coarse - 2.2 * tooth
                let solid = 1 - smooth(-2, 1.5, d)
                // Several frequencies break up the transition into mottled translucent residue.
                // The dense inner band stays intact; the outer band carries almost all the wear.
                let residue = (1 - smooth(-3, 15, d))
                    * smooth(-0.75, 0.8, tooth * 0.7 + fine * 0.75)
                let wear = smooth(-9, 2, d) * max(0, fine + tooth * 0.45) * 0.53
                let alpha = min(1, max(solid * (1 - wear), residue * 0.8))
                if alpha < 0.004 { continue }

                // A few subdued brown traces collect on the left edge; no light leak or stain
                // is placed over the photograph. These colours are stylistic, not stock data.
                let position = (y + h / 2) / h
                let left = 1 - smooth(-w / 2 - 8, -w / 2 + 15, x)
                let patches = bump(position, 0.88, 0.035) + bump(position, 0.68, 0.024)
                    + bump(position, 0.39, 0.018) + bump(position, 0.035, 0.035)
                let rust = min(1, patches * left * smooth(-17, -1, d))
                let grain = fine * 2.4 + coarse * 1.4
                let red = 13 + grain + rust * 51
                let green = 23 + grain + rust * 9
                let blue = 24 + grain - rust * 6
                let index = (row * width + column) * 4
                bytes[index] = UInt8(max(0, min(255, red * alpha)).rounded())
                bytes[index + 1] = UInt8(max(0, min(255, green * alpha)).rounded())
                bytes[index + 2] = UInt8(max(0, min(255, blue * alpha)).rounded())
                bytes[index + 3] = UInt8((alpha * 255).rounded())
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent) else { return false }
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: photo.minX - fringe * unit,
                                      y: photo.maxY + fringe * unit - CGFloat(height) * unit * step,
                                      width: CGFloat(width) * unit * step, height: CGFloat(height) * unit * step))
        context.restoreGState()
        return true
    }

    private static func smooth(_ low: Float, _ high: Float, _ value: Float) -> Float {
        let t = max(0, min(1, (value - low) / (high - low)))
        return t * t * (3 - 2 * t)
    }

    private static func bump(_ value: Float, _ centre: Float, _ radius: Float) -> Float {
        1 - smooth(0, radius, abs(value - centre))
    }

    private static func noise(_ x: Float, _ y: Float, seed: UInt32) -> Float {
        let ix = Int32(floor(x)), iy = Int32(floor(y))
        let fx = x - Float(ix), fy = y - Float(iy)
        let u = fx * fx * (3 - 2 * fx), v = fy * fy * (3 - 2 * fy)
        func sample(_ a: Int32, _ b: Int32) -> Float {
            var n = UInt32(bitPattern: a) &* 374_761_393
                &+ UInt32(bitPattern: b) &* 668_265_263 &+ seed &* 1_013_904_223
            n = (n ^ (n >> 13)) &* 1_274_126_177
            n ^= n >> 16
            return Float(n & 0xFFFF) / 32767.5 - 1
        }
        let a = sample(ix, iy), b = sample(ix &+ 1, iy)
        let c = sample(ix, iy &+ 1), d = sample(ix &+ 1, iy &+ 1)
        return (a + (b - a) * u) * (1 - v) + (c + (d - c) * u) * v
    }
}
#endif
