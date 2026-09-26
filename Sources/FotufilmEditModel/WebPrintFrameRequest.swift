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
        /// Encoded sRGB material colours for the current browser delivery boundary.
        public let palette: [String: [Float]]
    }

    public func prepare() throws -> Data {
        guard width > 0, height > 0, width <= 32768, height <= 32768,
              width * height <= 120_000_000,
              viewingKelvin == nil || (viewingKelvin!.isFinite && (1000...25000).contains(viewingKelvin!)) else {
            throw WebProfileRequest.Failure(description: "Invalid print frame dimensions or viewing light.")
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
        func configuration(_ choice: PrintFrame) -> PrintFrameConfiguration {
            PrintFrameConfiguration(frame: choice == .emulsion ? .none : choice, formatID: format,
                definition: definition,
                paper: paper, viewingKelvin: choice.viewsTransparency ? nil : viewingKelvin,
                negativeViewing: .lightBox)
        }
        let config = configuration(frame)
        let placement = PrintFramePlacement.layout(width: width, height: height, configuration: config)
        guard placement.size.width <= 32768, placement.size.height <= 32768,
              placement.size.width * placement.size.height <= 120_000_000 else {
            throw WebProfileRequest.Failure(description: "The framed image is too large. Choose a smaller export size.")
        }
        let renderMedium: String?
        if config.frame == .film, film?.isReversal == false, config.geometry?.isInstant == false {
            renderMedium = PrintPaper.negative.id
        } else if config.frame.viewsTransparency, film?.isReversal == true, paper.isPositivePaper {
            renderMedium = PrintPaper.screen.id
        } else { renderMedium = nil }
        func encoded(_ p3: SIMD3<Float>) -> [Float] {
            let rgb = ColorScience.linearDisplayP3ToSRGBGamut(p3)
            return [rgb.x, rgb.y, rgb.z].map { max(0, min(1, ColorScience.linearToSrgb($0))) }
        }
        let palette = ["base": encoded(config.baseRGB), "edge": encoded(config.edgeRGB),
                       "rebate": encoded(config.rebateRGB), "card": encoded(SIMD3(repeating: 0.86)),
                       "cutout": encoded(SIMD3(repeating: 0.96))]
        return try JSONEncoder().encode(Result(configuration: config, placement: placement,
            perforation: config.geometry?.perforation?.dimensions,
            materialSize: PrintFramePlacement.materialGeometry(config).size,
            renderMedium: renderMedium,
            available: PrintFrame.allCases.filter { configuration($0).frame == $0 }, palette: palette))
    }
}
