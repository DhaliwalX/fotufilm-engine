#if canImport(CoreGraphics)
import Foundation
import CoreGraphics
import CoreText
#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// A resolution-independent border. The photograph is placed at its original pixel size;
/// the deterministic material marks live only outside it. Both CPU and Metal developments
/// use this same finishing pass, after image formation and histogram measurement.
public enum PrintFrameRenderer {
    public struct Layout {
        public let size: CGSize
        /// Core Graphics coordinates, with the origin at the lower left.
        public let imageRect: CGRect
    }

    public static func layout(width: Int, height: Int, frame: PrintFrame) -> Layout {
        guard frame != .none else {
            return Layout(size: CGSize(width: width, height: height),
                          imageRect: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let unit = CGFloat(min(width, height)) / 1000
        let margin: CGFloat
        switch frame {
        case .film35: margin = 125
        case .contact: margin = 85
        case .baryta: margin = 80
        case .cotton: margin = 100
        case .instant: margin = 70
        case .none: margin = 0
        }
        let side = max(1, (margin * unit).rounded())
        let bottom = frame == .instant ? max(1, (270 * unit).rounded()) : side
        return Layout(size: CGSize(width: CGFloat(width) + side * 2,
                                   height: CGFloat(height) + side + bottom),
                      imageRect: CGRect(x: side, y: bottom,
                                        width: CGFloat(width), height: CGFloat(height)))
    }

    public static func render(_ image: CGImage, frame: PrintFrame) -> CGImage? {
        guard frame != .none else { return image }
        let placement = layout(width: image.width, height: image.height, frame: frame)
        // Keep 16-bit output and the source profile, including P3 and HLG. Border colors are
        // specified in sRGB and converted by Quartz into that destination profile.
        guard let space = image.colorSpace, space.model == .rgb,
              let context = CGContext(data: nil, width: Int(placement.size.width),
                                      height: Int(placement.size.height), bitsPerComponent: 16,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                        | CGBitmapInfo.byteOrder16Little.rawValue)
        else { return nil }
        let unit = CGFloat(min(image.width, image.height)) / 1000
        context.saveGState()
        context.scaleBy(x: unit, y: unit)
        let bounds = CGRect(origin: .zero, size: placement.size)
            .applying(CGAffineTransform(scaleX: 1 / unit, y: 1 / unit))
        let window = placement.imageRect
            .applying(CGAffineTransform(scaleX: 1 / unit, y: 1 / unit))
        drawMaterial(in: context, bounds: bounds, window: window, frame: frame)
        context.restoreGState()
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(image, in: placement.imageRect)
        return context.makeImage()
    }

    private static func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat,
                              _ alpha: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                components: [r, g, b, alpha])!
    }

    private static func drawMaterial(in context: CGContext, bounds: CGRect,
                                     window: CGRect, frame: PrintFrame) {
        let film = frame == .film35
        let base: CGColor
        switch frame {
        case .film35: base = color(0.055, 0.042, 0.032)
        case .contact: base = color(0.92, 0.895, 0.84)
        case .baryta: base = color(0.965, 0.956, 0.93)
        case .cotton: base = color(0.94, 0.92, 0.865)
        case .instant: base = color(0.96, 0.954, 0.935)
        case .none: return
        }
        context.setFillColor(base)
        context.fill(bounds)
        context.saveGState()
        context.addRect(bounds)
        context.addRect(window)
        context.clip(using: .evenOdd)

        var random = MaterialRandom()
        // Marks use normalized paper coordinates, so export does not acquire a new texture
        // and changing the film grain seed does not change the physical sheet.
        let count = Int(bounds.width * bounds.height / 55)
        for _ in 0..<count {
            let x = random.next() * bounds.width
            let y = random.next() * bounds.height
            let strength = random.next()
            guard !window.insetBy(dx: -1, dy: -1).contains(CGPoint(x: x, y: y)) else { continue }
            let dark = strength < 0.5
            let alpha: CGFloat = frame == .cotton ? 0.075 : film ? 0.035 : 0.025
            context.setFillColor(dark ? color(0.30, 0.25, 0.18, alpha)
                                     : color(1, 0.99, 0.94, alpha))
            let length: CGFloat = frame == .cotton ? 2 + strength * 5 : 0.8 + strength * 1.4
            context.fillEllipse(in: CGRect(x: x, y: y, width: length,
                                           height: frame == .cotton ? 0.6 : length))
        }

        if film || frame == .contact {
            // A slightly wandering rebate with a warm emulsion lip, entirely outside the image.
            let outer = window.insetBy(dx: film ? -10 : -16, dy: film ? -10 : -16)
            context.setFillColor(color(0.085, 0.068, 0.047))
            context.addPath(roughRect(outer, amplitude: 1.8))
            context.fillPath()
            context.setStrokeColor(color(0.47, 0.25, 0.095, film ? 0.6 : 0.35))
            context.setLineWidth(1.7)
            context.addPath(roughRect(window.insetBy(dx: -2, dy: -2), amplitude: 0.8))
            context.strokePath()
        } else {
            context.setStrokeColor(color(0.40, 0.36, 0.28, 0.20))
            context.setLineWidth(1.5)
            context.stroke(window.insetBy(dx: -0.75, dy: -0.75))
        }

        if frame == .cotton {
            context.setStrokeColor(color(0.66, 0.60, 0.48, 0.25))
            context.setLineWidth(2)
            context.addPath(roughRect(bounds.insetBy(dx: 3, dy: 3), amplitude: 2.2))
            context.strokePath()
        }
        if film { drawFilmEdges(in: context, bounds: bounds, window: window) }
        context.restoreGState()
    }

    private static func roughRect(_ rect: CGRect, amplitude: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let corners = [CGPoint(x: rect.minX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY),
                       CGPoint(x: rect.minX, y: rect.maxY)]
        var random = MaterialRandom()
        path.move(to: corners[0])
        for side in 0..<4 {
            let a = corners[side], b = corners[(side + 1) % 4]
            let steps = max(1, Int(hypot(b.x - a.x, b.y - a.y) / 5))
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                let jitter = step == steps ? 0 : (random.next() - 0.5) * amplitude * 2
                path.addLine(to: CGPoint(x: a.x + (b.x - a.x) * t + (a.x == b.x ? jitter : 0),
                                        y: a.y + (b.y - a.y) * t + (a.y == b.y ? jitter : 0)))
            }
        }
        path.closeSubpath()
        return path
    }

    private static func drawFilmEdges(in context: CGContext, bounds: CGRect, window: CGRect) {
        context.saveGState()
        var bounds = bounds, window = window
        if window.height > window.width {
            context.translateBy(x: bounds.width, y: 0)
            context.rotate(by: .pi / 2)
            bounds = CGRect(x: 0, y: 0, width: bounds.height, height: bounds.width)
            window = CGRect(x: window.minY, y: window.minX,
                            width: window.height, height: window.width)
        }
        // Eight perforations across a nominal 36 mm still frame. A chosen crop is presented
        // inside that window; these marks describe the border, not the capture's real gauge.
        let pitch = window.width / 8
        let holeWidth = min(70, pitch * 0.45)
        for index in 0..<8 {
            let x = window.minX + pitch * (CGFloat(index) + 0.5) - holeWidth / 2
            for y in [CGFloat(27), bounds.maxY - 82] {
                context.setFillColor(color(0.83, 0.805, 0.735))
                context.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: holeWidth, height: 55),
                                       cornerWidth: 8, cornerHeight: 8, transform: nil))
                context.fillPath()
            }
        }
        let amber = color(0.81, 0.48, 0.16, 0.88)
        let font = CTFontCreateWithName("Menlo" as CFString, 17, nil)
        for (text, point) in [("FOTUFILM  •  35", CGPoint(x: window.minX + 12, y: 94)),
                              ("01     ▸", CGPoint(x: window.maxX - 115, y: bounds.maxY - 114))] {
            let string = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): amber,
            ])
            context.textPosition = point
            CTLineDraw(CTLineCreateWithAttributedString(string), context)
        }
        context.restoreGState()
    }

    private struct MaterialRandom {
        var state: UInt64 = 0x5052494E54534854
        mutating func next() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(state >> 40) / CGFloat(1 << 24)
        }
    }
}
#endif
