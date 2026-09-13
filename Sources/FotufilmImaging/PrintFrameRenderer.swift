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
                              configuration: PrintFrameConfiguration) -> Layout {
        guard configuration.frame != .none else {
            return Layout(size: CGSize(width: width, height: height),
                          imageRect: CGRect(x: 0, y: 0, width: width, height: height),
                          pixelsPerMM: 1, rotated: false)
        }
        if configuration.frame == .emulsion {
            // A crop-following mount, not a claim of physical film or paper dimensions.
            let short = CGFloat(min(width, height))
            let horizontal = ceil(short * 0.095), vertical = ceil(short * 0.135)
            return Layout(size: CGSize(width: CGFloat(width) + 2 * horizontal,
                                       height: CGFloat(height) + 2 * vertical),
                          imageRect: CGRect(x: horizontal, y: vertical,
                                            width: CGFloat(width), height: CGFloat(height)),
                          pixelsPerMM: 1, rotated: false)
        }
        let material = materialGeometry(configuration)
        let aperture = material.aperture
        let rotated = aperture.width != aperture.height
            && (width > height) != (aperture.width > aperture.height)
        let scale = max(CGFloat(rotated ? height : width) / aperture.width,
                        CGFloat(rotated ? width : height) / aperture.height)
        let rawSize = CGSize(width: material.size.width * scale, height: material.size.height * scale)
        let size = CGSize(width: ceil(rotated ? rawSize.height : rawSize.width),
                          height: ceil(rotated ? rawSize.width : rawSize.height))
        let centre = rotated
            ? CGPoint(x: rawSize.height - aperture.midY * scale, y: aperture.midX * scale)
            : CGPoint(x: aperture.midX * scale, y: aperture.midY * scale)
        return Layout(size: size,
                      imageRect: CGRect(x: (centre.x - CGFloat(width) / 2).rounded(),
                                        y: (centre.y - CGFloat(height) / 2).rounded(),
                                        width: CGFloat(width), height: CGFloat(height)),
                      pixelsPerMM: scale, rotated: rotated)
    }

    public static func render(_ image: CGImage, configuration: PrintFrameConfiguration) -> CGImage? {
        guard configuration.frame != .none else { return image }
        let placement = layout(width: image.width, height: image.height, configuration: configuration)
        guard let space = image.colorSpace, space.model == .rgb,
              let context = CGContext(data: nil, width: Int(placement.size.width),
                                      height: Int(placement.size.height), bitsPerComponent: 16,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                        | CGBitmapInfo.byteOrder16Little.rawValue)
        else { return nil }
        let material = materialGeometry(configuration)
        context.setFillColor(baseColor(configuration.baseRGB))
        context.fill(CGRect(origin: .zero, size: placement.size))
        context.saveGState()
        context.scaleBy(x: placement.pixelsPerMM, y: placement.pixelsPerMM)
        if placement.rotated {
            context.translateBy(x: material.size.height, y: 0)
            context.rotate(by: .pi / 2)
        }
        if configuration.frame == .emulsion {
            guard EmulsionBorderRenderer.draw(in: context, around: placement.imageRect) else { return nil }
        } else if configuration.frame == .paper {
            let scale = placement.pixelsPerMM
            let photo = placement.rotated
                ? CGRect(x: placement.imageRect.minY / scale,
                         y: material.size.height - placement.imageRect.maxX / scale,
                         width: placement.imageRect.height / scale, height: placement.imageRect.width / scale)
                : placement.imageRect.applying(CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
            drawLustre(in: context, size: material.size, excluding: photo)
        } else if let geometry = configuration.geometry {
            if let printing = configuration.edgePrinting {
                drawEdgePrinting(in: context, geometry: geometry, printing: printing,
                                 color: baseColor(configuration.edgeRGB))
            }
            drawPerforations(in: context, geometry: geometry)
            if geometry.isSheet, let code = configuration.sheetNotches {
                drawNotches(in: context, size: material.size, code: code)
            }
        }
        context.restoreGState()
        // Copy at integer pixel coordinates after the border is drawn. The original profile,
        // 16-bit depth and every photograph pixel survive, including P3 and HLG delivery.
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(image, in: placement.imageRect)
        return context.makeImage()
    }

    private static func materialGeometry(_ configuration: PrintFrameConfiguration)
        -> (size: CGSize, aperture: CGRect) {
        if let g = configuration.geometry {
            return (CGSize(width: g.widthMM, height: g.heightMM),
                    CGRect(x: g.apertureX, y: g.apertureY,
                           width: g.apertureWidth, height: g.apertureHeight))
        }
        // A real 4 × 6 inch sheet cut from a paper roll, with a chosen 3 mm easel margin.
        // Sheet/crop size is a presentation choice; it is not an intrinsic size of the emulsion.
        return (CGSize(width: 152.4, height: 101.6),
                CGRect(x: 3, y: 3, width: 146.4, height: 95.6))
    }

    private static func baseColor(_ rgb: SIMD3<Float>) -> CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
                components: [CGFloat(rgb.x), CGFloat(rgb.y), CGFloat(rgb.z), 1])!
    }

    /// The neutral scan-bed visible through the physical holes.
    private static var cutoutColor: CGColor { baseColor(SIMD3(repeating: 0.96)) }

    private static func drawEdgePrinting(in context: CGContext, geometry g: FilmBorderGeometry,
                                         printing: FilmEdgePrinting, color: CGColor) {
        context.saveGState()
        // In the reference strip x is transport and y is across. Turn that strip with its
        // perforations when the camera transports vertically; portrait rotation is outside.
        if !g.horizontalTransport {
            context.translateBy(x: g.widthMM, y: 0)
            context.rotate(by: .pi / 2)
        }
        let along = g.horizontalTransport ? g.widthMM : g.heightMM
        let across = g.horizontalTransport ? g.heightMM : g.widthMM
        context.clip(to: CGRect(x: 0, y: 0, width: along, height: across))
        // System vector lettering approximates the edge printer. No manufacturer font or
        // scanned asset is shipped. Paths avoid display-sized hinting at small physical sizes.
        let font = CTFontCreateWithName("Helvetica" as CFString, 100, nil)
        context.setFillColor(color)
        for mark in printing.marks {
            let attributes = [kCTFontAttributeName: font] as CFDictionary
            let string = CFAttributedStringCreate(nil, mark.text as CFString, attributes)!
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

    private static func drawPerforations(in context: CGContext, geometry g: FilmBorderGeometry) {
        guard let type = g.perforation else { return }
        let width: CGFloat, height: CGFloat, radius: CGFloat, edge: CGFloat
        switch type {
        case .kodakStandard: (width, height, radius, edge) = (2.794, 1.981, 0.51, 2.01)
        case .bellHowell: (width, height, radius, edge) = (2.794, 1.854, 0, 2.01)
        case .sixteen: (width, height, radius, edge) = (1.829, 1.270, 0.25, 0.914)
        case .superEight: (width, height, radius, edge) = (0.914, 1.143, 0.13, 0.51)
        }
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
        context.setFillColor(cutoutColor)
        for x in rows {
            var centre = first
            while centre <= along {
                let rect = CGRect(x: x, y: centre - height / 2, width: width, height: height)
                if type == .bellHowell {
                    // BH is a circle clipped by two parallel flats, not a rounded KS rectangle.
                    context.saveGState()
                    context.clip(to: rect)
                    context.fillEllipse(in: CGRect(x: x, y: centre - width / 2,
                                                   width: width, height: width))
                    context.restoreGState()
                } else {
                    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius,
                                           cornerHeight: radius, transform: nil))
                    context.fillPath()
                }
                centre += pitch
            }
        }
        context.restoreGState()
    }

    private static func drawNotches(in context: CGContext, size: CGSize, code: SheetFilmNotchCode) {
        // The code occupies the upper right edge when the sheet is upright, emulsion facing us.
        // Manufacturer diagrams specify shapes/order, not absolute dimensions: a 20 mm code
        // span and 10 mm corner setback are presentation conventions, documented as such.
        let span: CGFloat = 20
        let start = size.width - 10 - span
        context.setFillColor(cutoutColor)
        for notch in code.notches {
            let rect = CGRect(x: start + CGFloat(notch.position) * span,
                              y: size.height - CGFloat(notch.depth) * span,
                              width: CGFloat(notch.width) * span,
                              height: CGFloat(notch.depth) * span * 2)
            context.fillEllipse(in: rect)
        }
    }

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
