#if canImport(CoreGraphics)
import Foundation
import CoreGraphics
import CoreText
#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// One finishing pass for CPU/Metal developments, canvas, thumbnails and export.
/// Physical geometry stays fixed; a different crop is fitted into the aperture without resampling.
public enum PrintFrameRenderer {
    public struct Layout {
        public let size: CGSize
        /// Core Graphics coordinates, with the origin at the lower left.
        public let imageRect: CGRect
        public let pixelsPerMM: CGFloat
        public let rotated: Bool
    }

    public static func layout(width: Int, height: Int,
                              configuration: PrintFrameConfiguration,
                              edge: UnexposedEdge.Margins? = nil) -> Layout {
        let p = PrintFramePlacement.layout(width: width, height: height, configuration: configuration,
                                           edge: edge)
        return Layout(size: CGSize(width: p.size.width, height: p.size.height),
                      imageRect: CGRect(x: p.image.x, y: p.image.y, width: p.image.width, height: p.image.height),
                      pixelsPerMM: p.scale, rotated: p.rotated)
    }

    /// Every frame takes the developed photograph, or a developed piece of film larger than the
    /// aperture (`UnexposedEdge`) and how far it reaches beyond the photograph on each side,
    /// `edge`. The Emulsion Border requires that piece. A Film Border given one takes its whole
    /// developed strip (`PrintFramePlacement.filmStrip`) and punches and letters it; without one
    /// it draws the rebate in the stock's colours.
    public static func render(_ image: CGImage, configuration: PrintFrameConfiguration,
                              edge: UnexposedEdge.Margins? = nil) -> CGImage? {
        guard configuration.frame != .none else { return image }
        let strip = configuration.frame.showsFilmStrip ? edge : nil
        let band = configuration.frame == .emulsion ? edge : strip
        if configuration.frame == .emulsion, band == nil { return nil }
        let film = band ?? UnexposedEdge.Margins(left: 0, right: 0, top: 0, bottom: 0)
        let photoWidth = image.width - film.left - film.right
        let photoHeight = image.height - film.top - film.bottom
        guard photoWidth > 0, photoHeight > 0 else { return nil }
        let placement = layout(width: photoWidth, height: photoHeight, configuration: configuration,
                               edge: band)
        // The developed strip is the frame's whole canvas.
        if strip != nil, image.width != Int(placement.size.width) || image.height != Int(placement.size.height) {
            return nil
        }
        guard let space = image.colorSpace, space.model == .rgb,
              let context = CGContext(data: nil, width: Int(placement.size.width),
                                      height: Int(placement.size.height), bitsPerComponent: 16,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                        | CGBitmapInfo.byteOrder16Little.rawValue)
        else { return nil }
        let material = materialGeometry(configuration)
        // The card of a slide mount covers the whole canvas, including any sub-pixel sliver
        // outside the rotated millimetre rectangle; its aperture is cut to the base below. The
        // Emulsion Border's film reaches past its carrier, where the paper saw no light: the
        // margin is that paper, as developed.
        if let band, band.carrier > 0, let paper = cornerColor(image) {
            context.setFillColor(paper)
        } else {
            context.setFillColor(configuration.slideMount == nil ? baseColor(configuration.baseRGB) : cardColor)
        }
        context.fill(CGRect(origin: .zero, size: placement.size))
        if strip != nil {
            drawDeveloped(image, into: context, at: placement.imageRect, film: film)
            if configuration.frame == .filmPositive {
                // The inverted scan's black point sits just past the developed base, so the rebate
                // stands a little above the open holes, its grain kept.
                context.saveGState()
                context.setBlendMode(.screen)
                context.setFillColor(baseColor(configuration.baseRGB))
                context.addRect(CGRect(origin: .zero, size: placement.size))
                context.addRect(placement.imageRect)
                context.fillPath(using: .evenOdd)
                context.restoreGState()
            }
        }
        context.saveGState()
        context.scaleBy(x: placement.pixelsPerMM, y: placement.pixelsPerMM)
        if placement.rotated {
            context.translateBy(x: material.size.height, y: 0)
            context.rotate(by: .pi / 2)
        }
        if configuration.frame == .emulsion || configuration.frame.isPlainMount
            || configuration.canvas != nil {
            // The base fill is the whole mount or canvas; the Emulsion Border's band is part of
            // the film that goes down below.
        } else if let mount = configuration.slideMount {
            drawSlideMount(in: context, mount: mount, base: baseColor(configuration.baseRGB))
        } else if let sheet = configuration.sheet {
            let photo = photoRect(placement, material: material)
            if sheet.rebateMM > 0 {
                drawCarrierRebate(in: context, around: photo, width: CGFloat(sheet.rebateMM),
                                  color: baseColor(configuration.rebateRGB))
            }
            if configuration.hasLustre {
                drawLustre(in: context, size: material.size,
                           excluding: photo.insetBy(dx: -CGFloat(sheet.rebateMM), dy: -CGFloat(sheet.rebateMM)))
            }
        } else if let geometry = configuration.geometry {
            if let printing = configuration.edgePrinting {
                // On a developed strip a negative's letters pass a share of the rebate's light,
                // grain and glow included; lighter letters are laid over the dark rebate.
                let transmission = strip == nil ? nil : configuration.edgeTransmission
                drawEdgePrinting(in: context, geometry: geometry, printing: printing,
                                 color: baseColor(transmission ?? configuration.edgeRGB),
                                 blend: strip == nil ? .normal : transmission == nil ? .screen : .multiply)
            }
            if !configuration.edgeBars.isEmpty {
                let transmission = strip == nil ? nil : configuration.barcodeTransmission
                drawEdgeBars(in: context, geometry: geometry, bars: configuration.edgeBars,
                             color: baseColor(transmission ?? configuration.barcodeRGB),
                             blend: strip == nil ? .normal : transmission == nil ? .screen : .multiply)
            }
            let cutout = baseColor(configuration.cutoutRGB)
            drawPerforations(in: context, geometry: geometry, cutout: cutout)
            if geometry.isSheet, let code = configuration.sheetNotches {
                drawNotches(in: context, size: material.size, code: code, cutout: cutout)
            }
        }
        context.restoreGState()
        if strip == nil { drawDeveloped(image, into: context, at: placement.imageRect, film: film) }
        return context.makeImage()
    }

    /// Copies the develop at integer pixel coordinates, the photograph at `photo`. The original
    /// profile, 16-bit depth and every developed pixel survive, including P3 and HLG delivery.
    private static func drawDeveloped(_ image: CGImage, into context: CGContext, at photo: CGRect,
                                      film: UnexposedEdge.Margins) {
        context.saveGState()
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: photo.minX - CGFloat(film.left),
                                       y: photo.minY - CGFloat(film.bottom),
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        context.restoreGState()
    }

    private static func materialGeometry(_ configuration: PrintFrameConfiguration)
        -> (size: CGSize, aperture: CGRect) {
        let m = PrintFramePlacement.materialGeometry(configuration)
        return (CGSize(width: m.size.width, height: m.size.height),
                CGRect(x: m.aperture.x, y: m.aperture.y, width: m.aperture.width, height: m.aperture.height))
    }

    /// The photograph in unrotated material millimetres.
    private static func photoRect(_ placement: Layout, material: (size: CGSize, aperture: CGRect)) -> CGRect {
        let scale = placement.pixelsPerMM
        return placement.rotated
            ? CGRect(x: placement.imageRect.minY / scale,
                     y: material.size.height - placement.imageRect.maxX / scale,
                     width: placement.imageRect.height / scale, height: placement.imageRect.width / scale)
            : placement.imageRect.applying(CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
    }

    /// The colour of an image's corner pixel, in its own colour space.
    private static func cornerColor(_ image: CGImage) -> CGColor? {
        guard let space = image.colorSpace, let corner = image.cropping(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        else { return nil }
        var pixel = [Float](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 32,
                                          bytesPerRow: 16, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                            | CGBitmapInfo.floatComponents.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            context.setBlendMode(.copy)
            context.draw(corner, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        let alpha = max(pixel[3], 1e-6)
        return CGColor(colorSpace: space, components: [CGFloat(pixel[0] / alpha), CGFloat(pixel[1] / alpha),
                                                      CGFloat(pixel[2] / alpha), 1])
    }

    private static func baseColor(_ rgb: SIMD3<Float>) -> CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
                components: [CGFloat(rgb.x), CGFloat(rgb.y), CGFloat(rgb.z), 1])!
    }

    /// The edge printer's lettering for `text`: glyph outlines in font units, the baseline at
    /// zero. Stretching its bounding box to a mark's millimetre box letters the way the rebate is.
    ///
    /// System vector lettering approximates the edge printer. No manufacturer font or scanned
    /// asset is shipped. Paths avoid display-sized hinting at small physical sizes.
    public static func letteringPath(_ text: String) -> CGPath {
        let font = CTFontCreateWithName("Helvetica" as CFString, 100, nil)
        let attributes = [kCTFontAttributeName: font] as CFDictionary
        let string = CFAttributedStringCreate(nil, text as CFString, attributes)!
        let line = CTLineCreateWithAttributedString(string)
        let path = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            for i in 0..<count {
                if let glyph = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) {
                    path.addPath(glyph, transform: CGAffineTransform(translationX: positions[i].x,
                                                                    y: positions[i].y))
                }
            }
        }
        return path
    }

    private static func drawEdgePrinting(in context: CGContext, geometry g: FilmBorderGeometry,
                                         printing: FilmEdgePrinting, color: CGColor,
                                         blend: CGBlendMode = .normal) {
        context.saveGState()
        // Blending in the delivery's encoding stands in for blending light: for a power-law
        // transfer a product of encoded values is the encoded product of the light.
        context.setBlendMode(blend)
        // In the reference strip x is transport and y is across. Turn that strip with its
        // perforations when the camera transports vertically; portrait rotation is outside.
        if !g.horizontalTransport {
            context.translateBy(x: g.widthMM, y: 0)
            context.rotate(by: .pi / 2)
        }
        let along = g.horizontalTransport ? g.widthMM : g.heightMM
        let across = g.horizontalTransport ? g.heightMM : g.widthMM
        context.clip(to: CGRect(x: 0, y: 0, width: along, height: across))
        context.setFillColor(color)
        for mark in printing.marks {
            let path = letteringPath(mark.text)
            let bounds = path.boundingBoxOfPath
            guard !bounds.isEmpty, !bounds.isNull else { continue }
            context.saveGState()
            context.translateBy(x: mark.xMM, y: mark.yMM)
            context.scaleBy(x: mark.widthMM / bounds.width, y: mark.heightMM / bounds.height)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            context.addPath(path)
            context.fillPath()
            context.restoreGState()
        }
        context.restoreGState()
    }

    /// The DX barcode's bars, in the edge printing's coordinates.
    private static func drawEdgeBars(in context: CGContext, geometry g: FilmBorderGeometry,
                                     bars: [FilmEdgePrinting.Bar], color: CGColor, blend: CGBlendMode) {
        context.saveGState()
        context.setBlendMode(blend)
        if !g.horizontalTransport {
            context.translateBy(x: g.widthMM, y: 0)
            context.rotate(by: .pi / 2)
        }
        let along = g.horizontalTransport ? g.widthMM : g.heightMM
        let across = g.horizontalTransport ? g.heightMM : g.widthMM
        context.clip(to: CGRect(x: 0, y: 0, width: along, height: across))
        context.setFillColor(color)
        context.fill(bars.map { CGRect(x: $0.xMM, y: $0.yMM, width: $0.widthMM, height: $0.heightMM) })
        context.restoreGState()
    }

    private static func drawPerforations(in context: CGContext, geometry g: FilmBorderGeometry,
                                         cutout: CGColor) {
        guard let type = g.perforation else { return }
        let hole = type.dimensions
        let width = CGFloat(hole.width), height = CGFloat(hole.height)
        let radius = CGFloat(hole.radius), edge = CGFloat(hole.edge)
        context.saveGState()
        // Put both still and motion perforations in coordinates across/along film transport.
        if g.horizontalTransport {
            context.translateBy(x: 0, y: g.heightMM)
            context.rotate(by: -.pi / 2)
        }
        let across = CGFloat(g.horizontalTransport ? g.heightMM : g.widthMM)
        let along = CGFloat(g.horizontalTransport ? g.widthMM : g.heightMM)
        context.clip(to: CGRect(x: 0, y: 0, width: across, height: along))
        let pitch = CGFloat(g.pitchMM)
        // 16 mm holes align with the frame line; Super 8 holes align with the frame centre.
        let first: CGFloat = type == .sixteen ? 0 : pitch / 2
        let rows: [CGFloat] = g.rows == 2 ? [edge, across - edge - width] : [edge]
        context.setFillColor(cutout)
        for (row, x) in rows.enumerated() {
            var centre = first
            var index = 0
            while centre <= along {
                let outline = perforationOutline(x: Double(x), centre: Double(centre),
                                                 width: Double(width), height: Double(height),
                                                 radius: Double(radius), bellHowell: type == .bellHowell,
                                                 hole: row * 4096 + index)
                context.addLines(between: outline.map { CGPoint(x: $0.x, y: $0.y) })
                context.closePath()
                context.fillPath()
                centre += pitch
                index += 1
            }
        }
        context.restoreGState()
    }

    /// One punched hole's edge, in the millimetres across and along the film that
    /// `drawPerforations` draws in: the die's shape — a rounded KS rectangle, or BH's circle
    /// clipped by two flats — traced every 0.04 mm, each point moved along its outward normal.
    /// Perforators cut to about a hundredth of a millimetre, but the edge a scan shows is burred,
    /// chipped and torn: 0.04 mm of wander over about half a millimetre and 0.015 mm over a
    /// tenth, closing on itself, and each hole sits up to 0.015 mm off its pitch and cuts up to
    /// 0.012 mm wider or narrower. Representative amplitudes, not measured. `hole` numbers the
    /// hole along its row, rows 4096 apart, so every hole has its own; web/src/print-frame-renderer.js
    /// traces the same outline from the same noise.
    public static func perforationOutline(x: Double, centre: Double, width: Double, height: Double,
                                          radius: Double, bellHowell: Bool,
                                          hole: Int) -> [SIMD2<Double>] {
        enum Piece {
            case line(SIMD2<Double>, SIMD2<Double>, normal: SIMD2<Double>)
            case arc(SIMD2<Double>, radius: Double, from: Double, to: Double)
            var length: Double {
                switch self {
                case let .line(a, b, _): return ((b - a) * (b - a)).sum().squareRoot()
                case let .arc(_, r, a0, a1): return r * abs(a1 - a0)
                }
            }
            func point(_ t: Double) -> (SIMD2<Double>, SIMD2<Double>) {
                switch self {
                case let .line(a, b, n): return (a + (b - a) * t, n)
                case let .arc(c, r, a0, a1):
                    let angle = a0 + (a1 - a0) * t
                    let n = SIMD2(cos(angle), sin(angle))
                    return (c + n * r, n)
                }
            }
        }
        let y = centre - height / 2
        var pieces: [Piece]
        if bellHowell {
            let r = width / 2, half = height / 2
            let c = SIMD2(x + r, centre)
            let flat = asin(min(1, half / r)), run = r * cos(flat)
            pieces = [.line(SIMD2(c.x - run, c.y - half), SIMD2(c.x + run, c.y - half), normal: SIMD2(0, -1)),
                      .arc(c, radius: r, from: -flat, to: flat),
                      .line(SIMD2(c.x + run, c.y + half), SIMD2(c.x - run, c.y + half), normal: SIMD2(0, 1)),
                      .arc(c, radius: r, from: .pi - flat, to: .pi + flat)]
        } else {
            let r = min(radius, width / 2, height / 2)
            pieces = [.line(SIMD2(x + r, y), SIMD2(x + width - r, y), normal: SIMD2(0, -1)),
                      .arc(SIMD2(x + width - r, y + r), radius: r, from: -.pi / 2, to: 0),
                      .line(SIMD2(x + width, y + r), SIMD2(x + width, y + height - r), normal: SIMD2(1, 0)),
                      .arc(SIMD2(x + width - r, y + height - r), radius: r, from: 0, to: .pi / 2),
                      .line(SIMD2(x + width - r, y + height), SIMD2(x + r, y + height), normal: SIMD2(0, 1)),
                      .arc(SIMD2(x + r, y + height - r), radius: r, from: .pi / 2, to: .pi),
                      .line(SIMD2(x, y + height - r), SIMD2(x, y + r), normal: SIMD2(-1, 0)),
                      .arc(SIMD2(x + r, y + r), radius: r, from: .pi, to: 3 * .pi / 2)]
        }
        let perimeter = pieces.reduce(0) { $0 + $1.length }
        // Each hole's own noise is its seed, so the coordinates stay small and exact.
        let own = UInt32(truncatingIfNeeded: hole) &* 3
        func noise(_ x: Float, _ y: Float, _ seed: UInt32) -> Double {
            Double(filingNoise(x, y, seed: seed &+ own))
        }
        let shift = SIMD2(0.015 * noise(0.5, 0.5, 401), 0.015 * noise(1.5, 0.5, 401))
        let grow = 0.012 * noise(2.5, 0.5, 401)
        // Around a circle in the noise, so the wander closes where the trace began.
        func wander(_ s: Double) -> Double {
            let turn = 2 * Double.pi * s / perimeter
            func ring(_ wavelength: Double, _ seed: UInt32) -> Double {
                let r = perimeter / (2 * .pi * wavelength)
                return noise(Float(r * cos(turn)), Float(r * sin(turn)), seed)
            }
            return 0.04 * ring(0.5, 211) + 0.015 * ring(0.1, 307)
        }
        var outline: [SIMD2<Double>] = []
        var travelled = 0.0
        for piece in pieces where piece.length > 0 {
            let steps = max(1, Int((piece.length / 0.04).rounded(.up)))
            for step in 0..<steps {
                let t = Double(step) / Double(steps)
                let (point, normal) = piece.point(t)
                outline.append(point + shift + normal * (grow + wander(travelled + piece.length * t)))
            }
            travelled += piece.length
        }
        return outline
    }

    private static func drawNotches(in context: CGContext, size: CGSize, code: SheetFilmNotchCode,
                                    cutout: CGColor) {
        // The code occupies the upper right edge when the sheet is upright, emulsion facing us.
        // Manufacturer diagrams specify shapes/order, not absolute dimensions: a 20 mm code
        // span and 10 mm corner setback are presentation conventions, documented as such.
        let span: CGFloat = 20
        let start = size.width - 10 - span
        context.setFillColor(cutout)
        for notch in code.notches {
            let rect = CGRect(x: start + CGFloat(notch.position) * span,
                              y: size.height - CGFloat(notch.depth) * span,
                              width: CGFloat(notch.width) * span,
                              height: CGFloat(notch.depth) * span * 2)
            context.fillEllipse(in: rect)
        }
    }

    /// The clear rebate of the negative, exposed through a carrier filed wider than its
    /// aperture. Hand filing leaves a slightly uneven outer edge; the inner edge is the
    /// camera gate and stays straight. The line prints at the paper's maximum density.
    private static func drawCarrierRebate(in context: CGContext, around photo: CGRect,
                                          width: CGFloat, color: CGColor) {
        let outer = photo.insetBy(dx: -width, dy: -width)
        let path = CGMutablePath()
        let corners = [CGPoint(x: outer.minX, y: outer.minY), CGPoint(x: outer.maxX, y: outer.minY),
                       CGPoint(x: outer.maxX, y: outer.maxY), CGPoint(x: outer.minX, y: outer.maxY)]
        let step: CGFloat = 0.5
        for side in 0..<4 {
            let from = corners[side], to = corners[(side + 1) % 4]
            let length = hypot(to.x - from.x, to.y - from.y)
            let count = max(2, Int(ceil(length / step)))
            for i in 0...count {
                let t = CGFloat(i) / CGFloat(count)
                let point = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
                // Displacement is normal to the side, in millimetres, bounded to a quarter
                // of the rebate so the line never closes over the photograph.
                let along = Float(length * t)
                let wobble = CGFloat(filingNoise(along * 0.35, Float(side) * 7.3, seed: 409)
                                     + 0.4 * filingNoise(along * 1.6, Float(side) * 3.1, seed: 613))
                let amount = min(max(wobble * 0.22, -width * 0.25), width * 0.25)
                let normal: CGPoint
                switch side {
                case 0: normal = CGPoint(x: 0, y: -1)
                case 1: normal = CGPoint(x: 1, y: 0)
                case 2: normal = CGPoint(x: 0, y: 1)
                default: normal = CGPoint(x: -1, y: 0)
                }
                let displaced = CGPoint(x: point.x + normal.x * amount, y: point.y + normal.y * amount)
                if side == 0 && i == 0 { path.move(to: displaced) } else { path.addLine(to: displaced) }
            }
        }
        path.closeSubpath()
        context.saveGState()
        context.setFillColor(color)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
    }

    /// Smooth value noise in about -1...1 for the filed carrier's hand-worked edge.
    private static func filingNoise(_ x: Float, _ y: Float, seed: UInt32) -> Float {
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

    /// The rounded aperture cut through a plain white card mount. The transparency's rebate
    /// shows through it around a nonmatching crop.
    private static func drawSlideMount(in context: CGContext, mount: SlideMountGeometry, base: CGColor) {
        let aperture = CGRect(x: (mount.mountMM - mount.apertureWidth) / 2,
                              y: (mount.mountMM - mount.apertureHeight) / 2,
                              width: mount.apertureWidth, height: mount.apertureHeight)
        context.saveGState()
        context.addPath(CGPath(roundedRect: aperture, cornerWidth: mount.cornerRadiusMM,
                               cornerHeight: mount.cornerRadiusMM, transform: nil))
        context.clip()
        context.setFillColor(base)
        context.fill(aperture)
        // The aperture is die-cut through card of finite thickness: a faint shadow on the
        // film along the upper and left edges. A presentation choice, not a measured mount.
        context.setFillColor(CGColor(gray: 0, alpha: 0.18))
        context.fill(CGRect(x: aperture.minX, y: aperture.maxY - 0.35, width: aperture.width, height: 0.35))
        context.fill(CGRect(x: aperture.minX, y: aperture.minY, width: 0.35, height: aperture.height))
        context.restoreGState()
    }

    /// A neutral white card, the common colour of cardboard and plastic mounts.
    private static var cardColor: CGColor { baseColor(SIMD3(repeating: 0.86)) }

    private static func drawLustre(in context: CGContext, size: CGSize, excluding photo: CGRect) {
        // Fine resin-coated stipple, never cotton fibres or deckled paper. The visible finish
        // is a restrained procedural approximation, not measured surface microtopography.
        var random = MaterialRandom()
        context.setFillColor(CGColor(gray: 0.12, alpha: 0.035))
        let pitch: CGFloat = 0.17
        var y: CGFloat = 0
        while y < size.height {
            var x: CGFloat = 0
            while x < size.width {
                let point = CGPoint(x: x + random.next() * pitch, y: y + random.next() * pitch)
                if !photo.contains(point) {
                    context.fillEllipse(in: CGRect(x: point.x, y: point.y, width: 0.065, height: 0.065))
                }
                x += pitch
            }
            y += pitch
        }
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
