import Foundation

/// The film just outside the camera gate, which the Emulsion Border prints around the photograph.
///
/// Nothing about the band is drawn. The photograph's light falls on a piece of film larger than
/// the camera's aperture, and the whole piece is developed and printed as one frame. The lens forms
/// its image — with a diffusion filter's halo, veiling glare, a preflash — over the whole plane;
/// the gate passes it only inside the aperture, softened at the edge by the shadow the lens pupil
/// casts of it. Beyond, the film saw no light, so it prints as whatever the chosen medium makes of
/// unexposed film — base plus fog on a negative, maximum density on a slide — with the stock's own
/// grain; and the frame's light spreads into it through the film's halation and emulsion scatter,
/// as far and in the colour that stock's layers return it.
public enum UnexposedEdge {
    /// Set on the options of a develop of that larger piece of film.
    public struct Develop: Sendable, Equatable {
        /// The unexposed film around the aperture, in pixels of the buffer: the aperture — the
        /// photograph — is the buffer less these, and the film's scale is reckoned from it.
        public var margins: Margins
        /// The photograph's Auto Levels reading, so the frame prints on the photograph's levels
        /// rather than on levels metered over film the gate shaded.
        public var sceneHighlightStops: Float?

        public init(margins: Margins, sceneHighlightStops: Float? = nil) {
            self.margins = margins
            self.sceneHighlightStops = sceneHighlightStops
        }
    }

    /// Distance from the gate edge to the camera's aperture plate, where the gate's shadow forms.
    /// The aperture mask sits in front of the emulsion by about the step between the film's outer
    /// and inner rails, roughly one support thickness. A representative figure, not a measurement
    /// of any one camera; see docs/print-frame-model.md.
    public static let gateSeparationMM: Float = 0.15
    /// The taking aperture the gate's penumbra is drawn for. Each point of the lens's exit pupil
    /// casts the gate edge at a different place, so the shadow's blur is the pupil's cone over
    /// the separation: about `gateSeparationMM / fNumber` across.
    public static let referenceFNumber: Float = 8

    /// Radius of the pupil's shadow of the gate edge on the film.
    public static var gateRadiusMM: Float { gateSeparationMM / (2 * referenceFNumber) }

    /// Share of the lens's light that passes the gate edge at `distanceMM` beyond it (negative
    /// inside the aperture). The pupil is a uniform disc, so the edge's shadow is the fraction of
    /// that disc on the open side of a straight line, `(acos(v) - v sqrt(1 - v^2)) / pi` for `v`
    /// the distance in radii. The renderers apply the same law per axis (`gate_transmission`),
    /// with acos by Abramowitz and Stegun 4.4.45 so that all of them compute it in the same exact
    /// arithmetic; this is that computation.
    public static func gateTransmission(beyondMM distanceMM: Float) -> Float {
        let u = min(max(distanceMM / gateRadiusMM, -1), 1)
        let v = abs(u)
        let arc = (1 - v).squareRoot()
            * (1.5707288 + v * (-0.2121144 + v * (0.0742610 + v * -0.0187293)))
        let shaded = (arc - v * (1 - v * v).squareRoot()) * 0.318309886
        return u >= 0 ? shaded : 1 - shaded
    }

    /// Unexposed emulsion on each side of the aperture, in millimetres of film, up to the first
    /// thing that is not continuous emulsion: a perforation row, the film's cut edge, or halfway to
    /// the next frame on the roll. In `FilmBorderGeometry` coordinates, x across the film's width
    /// and y along its length.
    public struct Geometry: Equatable, Sendable {
        public let left: Double
        public let right: Double
        public let bottom: Double
        public let top: Double
        public let apertureWidth: Double
        public let apertureHeight: Double

        /// Nil for integral instant film: its white mask covers the emulsion beyond the image.
        public static func preset(_ formatID: String, motionPictureStock: Bool = false) -> Self? {
            guard let film = FilmBorderGeometry.preset(formatID, motionPictureStock: motionPictureStock),
                  !film.isInstant else { return nil }
            var left = film.apertureX
            var right = film.widthMM - film.apertureX - film.apertureWidth
            var bottom = film.apertureY
            var top = film.heightMM - film.apertureY - film.apertureHeight
            // Perforations run along the film's length; the band stops at their inner edge.
            if let hole = film.perforation?.dimensions {
                let perforated = hole.edge + hole.width
                if film.horizontalTransport {
                    bottom -= perforated
                    if film.rows == 2 { top -= perforated }
                } else {
                    left -= perforated
                    if film.rows == 2 { right -= perforated }
                }
            }
            return Self(left: max(left, 0), right: max(right, 0),
                        bottom: max(bottom, 0), top: max(top, 0),
                        apertureWidth: film.apertureWidth, apertureHeight: film.apertureHeight)
        }

        /// The band in whole pixels around a photograph of this size. A photograph standing the
        /// other way from the aperture was taken with the camera turned, so the film turns with it.
        public func margins(photoWidth: Int, photoHeight: Int, pixelsPerMM: Float) -> Margins {
            let turned = apertureWidth != apertureHeight && photoWidth != photoHeight
                && (photoWidth > photoHeight) != (apertureWidth > apertureHeight)
            func pixels(_ mm: Double) -> Int { Int((mm * Double(pixelsPerMM)).rounded()) }
            return turned
                ? Margins(left: pixels(bottom), right: pixels(top), top: pixels(left), bottom: pixels(right))
                : Margins(left: pixels(left), right: pixels(right), top: pixels(top), bottom: pixels(bottom))
        }
    }

    /// The band's width on each side of the photograph, in pixels.
    public struct Margins: Equatable, Sendable {
        public let left: Int
        public let right: Int
        public let top: Int
        public let bottom: Int

        public init(left: Int, right: Int, top: Int, bottom: Int) {
            self.left = left; self.right = right; self.top = top; self.bottom = bottom
        }
    }

    /// The lens's image over the larger piece of film: `photo`, interleaved RGBA, in the middle,
    /// continued outward past its edges as the scene beyond them would have been. The world does
    /// not stop at the frame edge — the gate does — so a diffusion filter's halo and the glare
    /// meter near the edge see what they see in the photograph's own develop, and the gate then
    /// shades all of it. `extended` holds `(width + left + right) * (height + top + bottom) * 4`.
    public static func extend(_ photo: UnsafeBufferPointer<Float>, width: Int, height: Int,
                              margins: Margins, into extended: UnsafeMutableBufferPointer<Float>) {
        let outerWidth = width + margins.left + margins.right
        let outerHeight = height + margins.top + margins.bottom
        precondition(photo.count >= width * height * 4
                     && extended.count >= outerWidth * outerHeight * 4)
        ParallelWork.forEach(iterations: outerHeight) { row in
            let source = min(max(row - margins.top, 0), height - 1) * width * 4
            let target = row * outerWidth * 4
            for column in 0..<outerWidth {
                let from = source + min(max(column - margins.left, 0), width - 1) * 4
                let to = target + column * 4
                extended[to] = photo[from]
                extended[to + 1] = photo[from + 1]
                extended[to + 2] = photo[from + 2]
                extended[to + 3] = photo[from + 3]
            }
        }
    }
}

extension FotufilmEngine.Options {
    /// Pixels per millimetre of film for a buffer of this size — the one scale every
    /// millimetre-sized stage and backend is sized from. A crop keeps only `frameCoverage` of the
    /// frame's short edge, so the same buffer spans fewer millimetres of emulsion; the floor keeps
    /// a degenerate sliver from asking for unbounded radii.
    public func pixelsPerMM(width: Int, height: Int) -> Float {
        let coverage = min(max(frameCoverage, 0.05), 1)
        return Float(frameShortEdgePixels(width: width, height: height))
            / (format.frameHeightMM * coverage)
    }

    /// Millimetres of film per pixel, in double precision for the layered transport's kernels.
    public func pixelPitchMM(width: Int, height: Int) -> Double {
        Double(format.frameHeightMM * min(max(frameCoverage, 0.05), 1))
            / Double(frameShortEdgePixels(width: width, height: height))
    }

    /// The short edge, in pixels, of the photograph in a buffer of this size: the buffer's own,
    /// or on a larger piece of film the aperture's.
    public func frameShortEdgePixels(width: Int, height: Int) -> Int {
        guard let margins = unexposedEdge?.margins else { return min(width, height) }
        return max(1, min(width - margins.left - margins.right, height - margins.top - margins.bottom))
    }

    /// FOTUFILM_CONFIG_GATE for a buffer of this size: on a larger piece of film, the aperture's
    /// edges in frame pixels and the radius of the pupil's shadow of them in pixels; otherwise no
    /// gate.
    func gateConfiguration(width: Int, height: Int) -> [Float] {
        guard let margins = unexposedEdge?.margins else { return [0, 0, 0, 0, -1] }
        return [Float(margins.left), Float(margins.top),
                Float(width - margins.right), Float(height - margins.bottom),
                UnexposedEdge.gateRadiusMM * pixelsPerMM(width: width, height: height)]
    }
}

extension FilmFormat {
    /// The preset identifier this format was made from, for the gauge's physical geometry.
    public var presetID: String? {
        Self.presets.first { $0.format == self }?.id
    }
}
