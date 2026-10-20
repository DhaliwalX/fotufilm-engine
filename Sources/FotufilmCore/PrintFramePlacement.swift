import Foundation

/// Shared finishing placement. Coordinates have their origin at the lower left, like the
/// native compositor; browser consumers flip the canvas once at the drawing boundary.
public struct PrintFramePlacement: Codable, Equatable, Sendable {
    public struct Size: Codable, Equatable, Sendable { public let width: Double; public let height: Double }
    public struct Point: Codable, Equatable, Sendable { public let x: Double; public let y: Double }
    public struct Rect: Codable, Equatable, Sendable {
        public let x: Double; public let y: Double; public let width: Double; public let height: Double
        var midX: Double { x + width / 2 }; var midY: Double { y + height / 2 }
        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }
    }
    public let size: Size
    public let image: Rect
    public let scale: Double
    public let rotated: Bool

    /// `edge` is the Emulsion Border's developed band around the photograph; the paper margin
    /// stands beyond it. Every other frame ignores it.
    public static func layout(width: Int, height: Int, configuration: PrintFrameConfiguration,
                              edge: UnexposedEdge.Margins? = nil) -> Self {
        guard configuration.frame != .none else {
            return Self(size: Size(width: Double(width), height: Double(height)),
                          image: Rect(x: 0, y: 0, width: Double(width), height: Double(height)),
                          scale: 1, rotated: false)
        }
        if configuration.frame == .emulsion || configuration.frame.isPlainMount {
            // A crop-following mount, not a claim of physical film or paper dimensions. The
            // Emulsion Border's band is the film's own and stands inside the mount.
            let band = configuration.frame == .emulsion
                ? edge ?? UnexposedEdge.Margins(left: 0, right: 0, top: 0, bottom: 0)
                : UnexposedEdge.Margins(left: 0, right: 0, top: 0, bottom: 0)
            let short = Double(min(width, height)) * (configuration.margin ?? 1)
            let horizontal = ceil(short * (configuration.frame == .emulsion ? 0.07 : 0.08))
            let vertical = ceil(short * (configuration.frame == .emulsion ? 0.11 : 0.08))
            return Self(size: Size(width: Double(width + band.left + band.right) + 2 * horizontal,
                                       height: Double(height + band.top + band.bottom) + 2 * vertical),
                          image: Rect(x: horizontal + Double(band.left),
                                            y: vertical + Double(band.bottom),
                                            width: Double(width), height: Double(height)),
                          scale: 1, rotated: false)
        }
        if let canvas = configuration.canvas {
            // The photograph fitted inside a fixed-aspect canvas, touching the margin on the
            // side that binds. Never rotated: a landscape picture on a portrait canvas is the
            // post people make.
            let aspect = Double(canvas.aspectWidth / canvas.aspectHeight)
            let margin = Double(canvas.margin) * min(1, aspect)  // in units of the canvas height
            let canvasHeight = max(Double(width) / (aspect - 2 * margin), Double(height) / (1 - 2 * margin))
            let size = Size(width: ceil(canvasHeight * aspect), height: ceil(canvasHeight))
            return Self(size: size,
                          image: Rect(x: ((size.width - Double(width)) / 2).rounded(),
                                            y: ((size.height - Double(height)) / 2).rounded(),
                                            width: Double(width), height: Double(height)),
                          scale: 1, rotated: false)
        }
        let material = Self.materialGeometry(configuration)
        let aperture = material.aperture
        let rotated = aperture.width != aperture.height
            && (width > height) != (aperture.width > aperture.height)
        let scale = max(Double(rotated ? height : width) / aperture.width,
                        Double(rotated ? width : height) / aperture.height)
        let rawSize = Size(width: material.size.width * scale, height: material.size.height * scale)
        let size = Size(width: ceil(rotated ? rawSize.height : rawSize.width),
                          height: ceil(rotated ? rawSize.width : rawSize.height))
        let centre = rotated
            ? Point(x: rawSize.height - aperture.midY * scale, y: aperture.midX * scale)
            : Point(x: aperture.midX * scale, y: aperture.midY * scale)
        return Self(size: size,
                      image: Rect(x: (centre.x - Double(width) / 2).rounded(),
                                        y: (centre.y - Double(height) / 2).rounded(),
                                        width: Double(width), height: Double(height)),
                      scale: scale, rotated: rotated)
    }

    /// The film a Film Border develops around a photograph of this size, in pixels of its
    /// placement: from the gate, which is the photograph's edge, out to the film's cut edges on
    /// every side and across the perforation rows, which are punched after development. The
    /// developed piece is the frame's whole canvas. Nil for every other frame and for integral
    /// instant film, whose mask is not emulsion.
    public static func filmStrip(width: Int, height: Int,
                                 configuration: PrintFrameConfiguration) -> UnexposedEdge.Margins? {
        guard configuration.frame.showsFilmStrip, let film = configuration.geometry, !film.isInstant
        else { return nil }
        let placement = layout(width: width, height: height, configuration: configuration)
        let left = Int(placement.image.x), bottom = Int(placement.image.y)
        let right = Int(placement.size.width) - left - width
        let top = Int(placement.size.height) - bottom - height
        guard min(left, right, top, bottom) >= 0 else { return nil }
        return UnexposedEdge.Margins(left: left, right: right, top: top, bottom: bottom)
    }

    /// The part of a `width` × `height` photograph a film border shows: the largest rectangle of
    /// its aperture's shape, in the photograph's orientation, placed by the configuration's
    /// `framing`. In photograph pixels from the top left. Nil for every other frame, and when the
    /// photograph already has the aperture's shape to within a pixel, so a cropped picture asks
    /// for no second crop. The frame is laid out around the crop.
    public static func photoCrop(width: Int, height: Int,
                                 configuration: PrintFrameConfiguration) -> Rect? {
        guard width > 0, height > 0, let framing = configuration.framing,
              let film = configuration.geometry else { return nil }
        let across = film.apertureWidth, down = film.apertureHeight
        // The aperture turns with the photograph, as `layout` turns the film.
        let rotated = across != down && (width > height) != (across > down)
        let aspect = rotated ? down / across : across / down
        var cropWidth = width, cropHeight = height
        if Double(width) / Double(height) > aspect {
            cropWidth = min(width, max(1, Int((Double(height) * aspect).rounded())))
        } else {
            cropHeight = min(height, max(1, Int((Double(width) / aspect).rounded())))
        }
        guard width - cropWidth > 1 || height - cropHeight > 1 else { return nil }
        let x = (Double(width - cropWidth) * (framing.x + 1) / 2).rounded()
        let y = (Double(height - cropHeight) * (framing.y + 1) / 2).rounded()
        return Rect(x: x, y: y, width: Double(cropWidth), height: Double(cropHeight))
    }

    /// `crop` of a plane of `channels` floats a pixel, `width` pixels wide, rows from the top.
    public static func cropped(_ plane: [Float], width: Int, channels: Int = 4, to crop: Rect) -> [Float] {
        let x = Int(crop.x), y = Int(crop.y), w = Int(crop.width), h = Int(crop.height)
        var out = [Float](repeating: 0, count: w * h * channels)
        plane.withUnsafeBufferPointer { source in
            out.withUnsafeMutableBufferPointer { target in
                for row in 0..<h {
                    let from = ((y + row) * width + x) * channels
                    target.baseAddress!.advanced(by: row * w * channels)
                        .update(from: source.baseAddress!.advanced(by: from), count: w * channels)
                }
            }
        }
        return out
    }

    public static func materialGeometry(_ configuration: PrintFrameConfiguration) -> (size: Size, aperture: Rect) {
        if let g = configuration.geometry {
            return (Size(width: g.widthMM, height: g.heightMM),
                    Rect(x: g.apertureX, y: g.apertureY, width: g.apertureWidth, height: g.apertureHeight))
        }
        if let m = configuration.slideMount {
            return (Size(width: m.mountMM, height: m.mountMM),
                    Rect(x: (m.mountMM - m.apertureWidth) / 2, y: (m.mountMM - m.apertureHeight) / 2,
                         width: m.apertureWidth, height: m.apertureHeight))
        }
        let sheet = configuration.sheet ?? PaperSheetGeometry.preset(for: .paper)!
        let inset = sheet.marginMM + sheet.rebateMM
        return (Size(width: sheet.widthMM, height: sheet.heightMM),
                Rect(x: inset, y: inset, width: sheet.widthMM - 2 * inset, height: sheet.heightMM - 2 * inset))
    }
}
