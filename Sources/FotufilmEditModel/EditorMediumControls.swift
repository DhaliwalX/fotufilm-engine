import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif

extension EditorControlCatalogue {
    /// Whether the output medium puts this control in front of the user.
    ///
    /// The stock decides what a control can reach (`EditorControlAvailability`); the medium decides
    /// whether it means anything there: a lamp house only over an enlarged print, a viewing lamp
    /// and a paper black only on a physical medium, a paper grade only on the graded screen
    /// conversions. Every editor asks here, so a control stands on the same media on every surface. `stock` is nil when no
    /// film is chosen, which leaves nothing to print.
    public static func medium(_ paper: PrintPaper, offers field: EditorControlField,
                              stock: FilmStock?,
                              digitalReference: DigitalReferenceStyle) -> Bool {
        if control(field)?.section == .printLamp {
            return stock.map { Enlarger.illuminates(stock: $0, paper: paper) } ?? false
        }
        switch field {
        case .printLight:
            return stock != nil && viewingLights(for: paper).count > 1
        case .displayBlack:
            return stock.map { paper.hasPaperBlack(for: $0) } ?? false
        case .printCorrection:
            guard let stock else { return false }
            return !stock.isReversal && !stock.isMonochrome && paper.acceptsPrintCorrection
        case .negativeViewing:
            return paper.isNegative
        case .digitalReference, .screenExposure:
            guard let stock else { return false }
            return paper == .screen && !stock.isReflectionPrint
        case .screenGrade:
            // The grade shapes the graded curve, which only a negative is printed through, and
            // Reference Exposure keeps the calibrated curve without one.
            guard let stock else { return false }
            return paper == .screen && !stock.isReflectionPrint && !stock.isReversal
                && digitalReference != .referenceExposure
        default:
            return true
        }
    }
}
