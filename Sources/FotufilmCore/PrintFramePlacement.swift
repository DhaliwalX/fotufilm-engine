import Foundation

/// Shared finishing placement. Coordinates have their origin at the lower left, like the
/// native compositor; browser consumers flip the canvas once at the drawing boundary.
public struct PrintFramePlacement: Codable, Equatable, Sendable {
    public struct Size: Codable, Equatable, Sendable { public let width: Double; public let height: Double }
    public struct Point: Codable, Equatable, Sendable { public let x: Double; public let y: Double }
    public struct Rect: Codable, Equatable, Sendable {
        public let x: Double; public let y: Double; public let width: Double; public let height: Double
        var midX: Double { x + width / 2 }; var midY: Double { y + height / 2 }
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
            let short = Double(min(width, height))
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
