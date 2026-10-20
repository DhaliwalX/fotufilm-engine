import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Physical finishing metadata and placement, using the same model as native photo delivery.
/// The browser sends only public stock data, settings and dimensions, never image pixels.
public struct WebPrintFrameRequest: Decodable {
    public let stock: FilmStockDefinition?
    public let frame: PrintFrame
    public let format: String?
    public let medium: String?
    public let viewingKelvin: Float?
    /// Border Width, as a multiple of the frame's preset margin; absent keeps the preset.
    public let margin: Double?
    /// The frame number a Film Border's edge printing and DX barcode show; absent is frame 1.
    public let frameNumber: Int?
    /// Whether a Film Border shows the stock's edge printing; absent shows it.
    public let edgePrinting: Bool?
    public let width: Int
    public let height: Int

    public struct Result: Codable {
        public let configuration: PrintFrameConfiguration
        public let placement: PrintFramePlacement
        public let perforation: FilmBorderGeometry.PerforationDimensions?
        public let materialSize: PrintFramePlacement.Size
        /// A frame can change the delivered medium without replacing the saved paper selection.
        public let renderMedium: String?
        public let available: [PrintFrame]
        /// The film a Film Border develops with the photograph, beyond it on each side, at this
        /// size (`PrintFramePlacement.filmStrip`); nil draws the rebate around the photograph.
        public let strip: UnexposedEdge.Margins?
        /// Whether this frame shows the stock's edge printing for the gauge when it is not hidden,
        /// and whether that printing carries a frame number or DX barcode to set.
        public let edgePrinting: Bool
        public let frameNumber: Bool
        /// Encoded sRGB material colours for the current browser delivery boundary.
        public let palette: [String: [Float]]
    }

    public func prepare() throws -> Data {
        guard width > 0, height > 0, width <= 32768, height <= 32768,
              width * height <= 120_000_000,
              viewingKelvin == nil || (viewingKelvin!.isFinite && (1000...25000).contains(viewingKelvin!)) else {
            throw WebProfileRequest.Failure(description: "Invalid print frame dimensions or viewing light.")
        }
        guard margin == nil || PrintFrameConfiguration.marginRange.contains(margin!) else {
            throw WebProfileRequest.Failure(description: "Invalid print frame border width.")
        }
        guard frameNumber == nil || FilmEdgePrinting.frameNumberRange.contains(frameNumber!) else {
            throw WebProfileRequest.Failure(description: "Invalid film border frame number.")
        }
        let definition = try stock?.validated()
        let film = definition?.stock
        let format = format ?? definition?.nativeFormatID ?? FilmFormat.houseDefaultID
        guard FilmFormat.preset(id: format) != nil,
              medium == nil || PrintPaper.preset(id: medium!) != nil else {
            throw WebProfileRequest.Failure(description: "Unknown print frame format or output medium.")
        }
        let requestedPaper = medium.flatMap(PrintPaper.preset(id:)) ?? film.map(PrintPaper.default(for:)) ?? .editorDefault
        let paper = film.map { requestedPaper.resolved(for: $0) } ?? requestedPaper
        // Emulsion Border develops a piece of film larger than the aperture, which the browser's
        // host does not build.
        func configuration(_ choice: PrintFrame, recorded: Bool = false) -> PrintFrameConfiguration {
            PrintFrameConfiguration(frame: choice == .emulsion ? .none : choice, formatID: format,
                definition: definition,
                paper: paper, viewingKelvin: choice.viewsTransparency ? nil : viewingKelvin,
                negativeViewing: .lightBox, margin: margin ?? 1,
                frameNumber: recorded ? FilmEdgePrinting.recordedFrameNumber
                    : frameNumber ?? FilmEdgePrinting.recordedFrameNumber,
                showsEdgePrinting: recorded || edgePrinting ?? true)
        }
        let config = configuration(frame)
        // The stock's own cut, at its recorded frame number, says which settings apply.
        let recorded = configuration(frame, recorded: true)
        let numbers = [String(FilmEdgePrinting.recordedFrameNumber),
                       "\(FilmEdgePrinting.recordedFrameNumber)A"]
        let numbered = !recorded.edgeBars.isEmpty
            || recorded.edgePrinting?.marks.contains { numbers.contains($0.text) } == true
        let placement = PrintFramePlacement.layout(width: width, height: height, configuration: config)
        guard placement.size.width <= 32768, placement.size.height <= 32768,
              placement.size.width * placement.size.height <= 120_000_000 else {
            throw WebProfileRequest.Failure(description: "The framed image is too large. Choose a smaller export size.")
        }
        let renderMedium: String?
        if config.frame == .film, film?.isReversal == false, config.geometry?.isInstant == false {
            renderMedium = PrintPaper.negative.id
        } else if config.frame == .filmPositive, paper.isNegative {
            // The inverted scan's photograph is a positive; the negative itself is scanned.
            renderMedium = PrintPaper.labScan.id
        } else if config.frame.viewsTransparency, film?.isReversal == true, paper.isPositivePaper {
            renderMedium = PrintPaper.screen.id
        } else { renderMedium = nil }
        func encoded(_ p3: SIMD3<Float>) -> [Float] {
            let rgb = ColorScience.linearDisplayP3ToSRGB(p3)
            return [rgb.x, rgb.y, rgb.z].map { max(0, min(1, ColorScience.linearToSrgb($0))) }
        }
        let palette = ["base": encoded(config.baseRGB), "edge": encoded(config.edgeRGB),
                       "rebate": encoded(config.rebateRGB), "card": encoded(SIMD3(repeating: 0.86)),
                       "cutout": encoded(config.cutoutRGB)]
            .merging(config.edgeTransmission.map { ["edgeTransmission": encoded($0)] } ?? [:]) { $1 }
            .merging(["barcode": encoded(config.barcodeRGB)]) { $1 }
            .merging(config.barcodeTransmission.map { ["barcodeTransmission": encoded($0)] } ?? [:]) { $1 }
        return try JSONEncoder().encode(Result(configuration: config, placement: placement,
            perforation: config.geometry?.perforation?.dimensions,
            materialSize: PrintFramePlacement.materialGeometry(config).size,
            renderMedium: renderMedium,
            available: PrintFrame.allCases.filter { configuration($0).frame == $0 },
            strip: PrintFramePlacement.filmStrip(width: width, height: height, configuration: config),
            edgePrinting: recorded.edgePrinting != nil, frameNumber: numbered,
            palette: palette))
    }
}
