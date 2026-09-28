#if canImport(FotufilmEditModel)
import FotufilmEditModel
#endif

/// The names of Fotufilm's own symbols for the editor, compiled from shared/Glyphs into
/// Glyphs.xcassets. They are looked up like system symbols; an app built without the catalog
/// finds none of them.
enum Glyph {
    static let filmStrip = "fotu.deck.film"
    static let controls = "fotu.deck.controls"
    static let grade = "fotu.deck.grade"
    static let dust = "fotu.deck.dust"
    static let films = "fotu.tab.films"
    static let lightLeak = "fotu.tab.lightleak"

    static func deck(_ group: EditorControlGroup) -> String {
        switch group {
        case .film: return "fotu.deck.film"
        case .lens: return "fotu.deck.lens"
        case .light: return "fotu.deck.light"
        case .print: return "fotu.deck.print"
        case .frame: return "fotu.deck.frame"
        case .pipeline: return "fotu.tab.pipeline"
        }
    }

    static func tab(_ section: EditorControlSection) -> String {
        switch section {
        case .filmStock: return "fotu.deck.film"
        case .filmGrain: return "fotu.tab.grain"
        case .filmEmulsion: return "fotu.tab.emulsion"
        case .filmLab: return "fotu.tab.lab"
        case .lensGlass: return "fotu.tab.filters"
        case .lensCorrection: return "fotu.tab.correction"
        case .lightExposure: return "fotu.tab.exposure"
        case .lightBalance: return "fotu.tab.balance"
        case .lightColor: return "fotu.tab.color"
        case .lightGrade: return "fotu.deck.grade"
        case .sourceInterpretation: return "fotu.tab.source"
        case .printPaper: return "fotu.tab.output"
        case .printLamp: return "fotu.tab.lamp"
        case .frameGeometry: return "fotu.tab.geometry"
        case .frameLocal: return "fotu.tab.local"
        case .pipeline: return "fotu.tab.pipeline"
        }
    }

    /// The symbols at a slider's low and high ends. The glyph set draws a pair for every
    /// catalogue slider.
    static func sliderEndNames(_ field: EditorControlField) -> (low: String, high: String) {
        ("fotu.slider.\(field.rawValue).low", "fotu.slider.\(field.rawValue).high")
    }
}
