#if canImport(FotufilmEditModel)
import FotufilmEditModel
#endif

/// The names of Fotufilm's own symbols, compiled from shared/Glyphs into Glyphs.xcassets. They
/// are looked up like system symbols; an app built without the catalog finds none of them.
enum Glyph {
    static let filmStrip = "fotu.deck.film"
    static let controls = "fotu.deck.controls"
    static let grade = "fotu.deck.grade"
    static let lens = "fotu.deck.lens"
    static let dust = "fotu.deck.dust"
    static let films = "fotu.tab.films"
    static let lightLeak = "fotu.tab.lightleak"
    static let emulsion = "fotu.tab.emulsion"
    static let local = "fotu.tab.local"
    static let lamp = "fotu.tab.lamp"
    static let source = "fotu.tab.source"
    static let geometry = "fotu.tab.geometry"
    static let eyedropper = "fotu.tab.balance"
    static let sun = "fotu.slider.exposure.high"

    // App chrome
    static let close = "fotu.ui.close"
    static let add = "fotu.ui.add"
    static let remove = "fotu.ui.remove"
    static let check = "fotu.ui.check"
    static let done = "fotu.ui.done"
    static let more = "fotu.ui.more"
    static let share = "fotu.ui.share"
    static let importFile = "fotu.ui.import"
    static let undo = "fotu.ui.undo"
    static let redo = "fotu.ui.redo"
    static let reset = "fotu.ui.reset"
    static let history = "fotu.ui.history"
    static let delete = "fotu.ui.delete"
    static let copy = "fotu.ui.copy"
    static let duplicate = "fotu.ui.duplicate"
    static let paste = "fotu.ui.paste"
    static let folder = "fotu.ui.folder"
    static let lock = "fotu.ui.lock"
    static let unlock = "fotu.ui.unlock"
    static let chevronRight = "fotu.ui.chevron.right"
    static let chevronDown = "fotu.ui.chevron.down"
    static let chevronUp = "fotu.ui.chevron.up"
    static let popUp = "fotu.ui.popup"
    static let settings = "fotu.ui.settings"
    static let pro = "fotu.ui.pro"
    static let warning = "fotu.ui.warning"
    static let photo = "fotu.ui.photo"
    static let photos = "fotu.ui.photos"
    static let video = "fotu.ui.video"
    static let camera = "fotu.ui.camera"
    static let histogram = "fotu.ui.histogram"
    static let histogramShown = "fotu.ui.histogram.shown"
    static let play = "fotu.ui.play"
    static let pause = "fotu.ui.pause"
    static let stop = "fotu.ui.stop"
    static let loop = "fotu.ui.loop"
    static let rotate = "fotu.ui.rotate"
    static let mirror = "fotu.ui.mirror"
    static let findFrame = "fotu.ui.findframe"
    static let filmFormat = "fotu.ui.format"
    static let sidebarLeading = "fotu.ui.sidebar.leading"
    static let sidebarTrailing = "fotu.ui.sidebar.trailing"
    static let contactSheet = "fotu.ui.contactsheet"

    // Camera
    static let flipCamera = "fotu.camera.flip"
    static let stabilization = "fotu.camera.stabilization"
    static let flashOff = "fotu.camera.flash.off"
    static let flashAuto = "fotu.camera.flash.auto"
    static let flashOn = "fotu.camera.flash.on"

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
