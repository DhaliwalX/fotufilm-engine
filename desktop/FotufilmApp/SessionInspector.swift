import CoreGraphics
import Foundation
#if canImport(FotufilmImaging)
import FotufilmImaging
#endif
import QuartzCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmEditModel)
import FotufilmEditModel
#endif

/// Which set of controls the trailing column is showing.
enum InspectorPanel: String, CaseIterable {
    case film
    #if canImport(UIKit)
    case lens, adjustments
    #else
    case adjustments, development, print
    #endif
    case selective, crop

    var title: String {
        switch self {
        case .film: return "Film"
        #if canImport(UIKit)
        case .lens: return "Lens"
        case .adjustments: return "Light & Color"
        #else
        case .adjustments: return "Expose"
        case .development: return "Develop"
        case .print: return "Print"
        #endif
        case .selective: return "Selective"
        case .crop: return "Crop"
        }
    }

    /// The collapsed rail and iPad tabs use glyphs; the Mac darkroom uses visible stage names.
    var symbol: String {
        switch self {
        case .film: return "film"
        #if canImport(UIKit)
        case .lens: return "camera.aperture"
        case .adjustments: return "slider.horizontal.3"
        #else
        case .adjustments: return "sun.max"
        case .development: return "flask"
        case .print: return "photo.on.rectangle"
        #endif
        case .selective: return "circle.dashed"
        case .crop: return "crop.rotate"
        }
    }

    /// The tabs a session actually offers.
    ///
    /// A clip gets neither the crop nor the selection: the crop is dragged on a still canvas, and
    /// the selection would have to be re-sampled every frame to mean anything.
    static func available(video: Bool) -> [InspectorPanel] {
        #if canImport(UIKit)
        video ? [.film, .lens, .adjustments] : allCases
        #else
        video ? [.film, .adjustments, .development, .print] : allCases
        #endif
    }
}

/// The trailing column: a tab bar over a scrolling stack of grouped sections.
///
/// The panel is rebuilt when its *shape* changes — a different tab, a clip opened, the lens switch
/// thrown — and only re-read when a value changes, so dragging a slider does not tear the column it
/// is in down and put it back up sixty times a second.
final class InspectorViewController: SessionViewController {
    private let model: DesktopEditorModel
    #if canImport(UIKit)
    private let tabs = SessionTabStrip()
    #else
    private let tabs = MacDarkroomNavigation()
    #endif
    private let column = ScrollColumn()

    private var rows: [FormRowView] = []
    private var printerRows: [FormRowView] = []
    private var printCorrectionRow: FormRowView?
    private var gaugePicker: GaugePickerView?
    private var gradeDeck: GradeDeckView?
    #if !canImport(UIKit)
    private var selectedGradeBand: GradeBandStyle = .shadows
    #endif
    private var structure = ""

    /// Held by the window rather than here: when the panel is minimized to a rail, the rail's
    /// buttons choose which tab it opens back onto.
    var panel: InspectorPanel = .film {
        didSet {
            guard panel != oldValue else { return }
            // The composite costs a second develop of every frame; it is paid for while the panel
            // showing it is up and not a moment longer.
            model.isSelectiveMode = panel == .selective
            if panel != .selective { model.isSamplingSelection = false }
            rebuildTabs()
            rebuild(direction: order(panel) >= order(oldValue) ? 1 : -1)
            onPanelChanged?(panel)
        }
    }

    var onPanelChanged: ((InspectorPanel) -> Void)?
    var onExport: (() -> Void)?

    private var tabsTop: NSLayoutConstraint?

    /// How far the column's contents are held below its own top edge — see the film column's own
    /// note: the column reaches the window's edge and the chrome is drawn over that edge.
    var topInset: CGFloat = 0 {
        didSet {
            guard topInset != oldValue else { return }
            tabsTop?.constant = topInset + 12
        }
    }

    init(model: DesktopEditorModel) {
        self.model = model
        super.init()
    }

    override func loadView() {
        let root = SessionView()
        root.translatesAutoresizingMaskIntoConstraints = false
        tabs.onSelect = { [weak self] index in self?.tabChanged(index) }
        root.addSubview(tabs)
        root.addSubview(column)

        let tabsTop = tabs.topAnchor.constraint(equalTo: root.topAnchor,
                                                constant: topInset + 12)
        self.tabsTop = tabsTop

        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor,
                                          constant: 14),
            tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor,
                                           constant: -14),
            tabsTop,
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            column.topAnchor.constraint(equalTo: tabs.bottomAnchor,
                                        constant: 8),
            column.bottomAnchor.constraint(
                equalTo: root.safeAreaLayoutGuide.bottomAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        rebuildTabs()
        rebuild(direction: 0)
        model.isSelectiveMode = panel == .selective
    }

    // MARK: - Selective

    private func selectiveSections() -> [FormSectionView] {
        SelectiveSection.sections(model: model) {
            [weak self] title, range, display, get, set in
            guard let self else {
                return SliderRow(title, range: range, display: display,
                                 get: get, set: set, began: {}, ended: {})
            }
            return adjustment(title, range: range, display: display,
                              get: get, set: set)
        }
    }

    private func order(_ panel: InspectorPanel) -> Int {
        InspectorPanel.allCases.firstIndex(of: panel) ?? 0
    }

    private func tabChanged(_ index: Int) {
        let available = InspectorPanel.available(video: model.hasVideo)
        guard available.indices.contains(index) else { return }
        panel = available[index]
    }

    private func rebuildTabs() {
        let available = InspectorPanel.available(video: model.hasVideo)
        #if canImport(UIKit)
        tabs.setTabs(available.map { (symbol: $0.symbol, title: $0.title) })
        #else
        tabs.setPanels(available)
        #endif
        if let index = available.firstIndex(of: panel) {
            tabs.selectedIndex = index
        }
    }

    private var structureSignature: String {
        [
            panel.rawValue,
            model.edit.stockID,
            model.edit.resolvedPaper.id,
            String(model.hasVideo),
            String(model.hasPhoto),
            String(model.sourceInterpretationAvailable),
            String(model.edit.sourceLightIndex),
            String(showsViewingLight),
            String(showsEnlarger),
            String(showsPrintCorrection),
            String(model.edit.lensCorrectionEnabled),
            String(model.hasLensMeasurement),
            String(model.matchedLensProfile != nil),
            String(ProAccess.isPro),
            // With no film loaded there is no emulsion to give character to and no lab to send
            // it to, so those sections are not dimmed — they are not there.
            String(model.edit.hasFilm),
            // The reciprocity row exists only where the sheet states a failure, which is the
            // film's business and changes with it.
            String(shutterChoices.count),
            // One row per fitted filter, so fitting or taking one off rebuilds the list.
            model.edit.lensFilterIDs.joined(separator: ","),
            // A subject selection asks for different rows from a colour one, and the sampler's
            // own button changes what it says while it is armed.
            String(describing: model.selective.kind),
            String(model.isSamplingSelection),
        ].joined(separator: "|")
    }

    /// Only a physical reflection or projection print has a viewing illuminant to replace.
    private var showsViewingLight: Bool {
        model.edit.hasFilm && !(model.edit.stock?.isReversal ?? false)
            && model.edit.resolvedPaper.acceptsViewingIlluminant
    }

    /// Only an optically enlarged reflection print has a lamp house to choose.
    private var showsEnlarger: Bool {
        guard model.edit.hasFilm, let stock = model.edit.stock else { return false }
        return Enlarger.illuminates(stock: stock, paper: model.edit.resolvedPaper)
    }

    private var showsPrintCorrection: Bool {
        model.edit.hasFilm && !(model.edit.stock?.isReversal ?? false)
            && !(model.edit.stock?.isMonochrome ?? false)
            && model.edit.resolvedPaper.acceptsPrintCorrection
    }

    private var shutterChoices: [Double] {
        guard let stated = model.edit.stock?.reciprocityFailure,
              stated.lostStopsPerDecade > 0 else { return [] }
        let ladder: [Double] = [1, 2, 4, 8, 15, 30, 60, 120, 240, 480]
        let past = ladder.filter { $0 > Double(stated.thresholdSeconds) }
        guard let end = stated.statedThroughSeconds.map(Double.init),
              let last = past.firstIndex(where: { $0 >= end })
        else { return past }
        return Array(past.prefix(through: last))
    }

    private static func shutterName(_ seconds: Double) -> String {
        guard seconds >= 60 else { return String(format: "%.0f s", seconds) }
        let minutes = seconds / 60
        return minutes == minutes.rounded()
            ? "\(Int(minutes)) min" : String(format: "%.1f min", minutes)
    }

    /// Catches the column up with the model, rebuilding it only if its shape has changed.
    func refresh() {
        let available = InspectorPanel.available(video: model.hasVideo)
        if tabs.count != available.count { rebuildTabs() }
        if !available.contains(panel) { panel = .film }
        if let index = available.firstIndex(of: panel),
           tabs.selectedIndex != index {
            tabs.selectedIndex = index
        }

        if structureSignature != structure {
            rebuild(direction: 0)
            return
        }
        rows.forEach { $0.refresh() }
        gaugePicker?.refresh()
        gradeDeck?.refresh()

        refreshEnabledRows()
    }

    private func refreshEnabledRows() {
        let enabled = !model.isExporting
        if tabs.isEnabled != enabled { tabs.isEnabled = enabled }
        for row in rows {
            let allowed = enabled
                && (!printerRows.contains(where: { $0 === row }) || model.edit.printerEnabled)
                && (row !== printCorrectionRow || !showsEnlarger || !model.edit.printerEnabled)
            if row.isRowEnabled != allowed { row.isRowEnabled = allowed }
        }
    }

    private func rebuild(direction: CGFloat) {
        structure = structureSignature
        rows.removeAll()
        printerRows.removeAll()
        printCorrectionRow = nil
        gaugePicker = nil
        gradeDeck = nil
        for view in column.column.arrangedSubviews {
            column.column.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let sections: [FormSectionView]
        switch panel {
        case .film: sections = filmSections()
        #if canImport(UIKit)
        case .lens: sections = lensSections()
        case .adjustments: sections = adjustmentSections()
        #else
        case .adjustments: sections = exposureSections()
        case .development: sections = developmentSections()
        case .print: sections = finishingSections()
        #endif
        case .selective: sections = selectiveSections()
        case .crop: sections = cropSections()
        }
        for section in sections {
            column.column.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: column.column.widthAnchor)
                .isActive = true
            rows.append(contentsOf: section.rows)
        }
        refreshEnabledRows()
        column.scrollToTop()

        guard direction != 0 else { return }
        let content = column.content.backingLayer
        content.removeAnimation(forKey: "panel")
        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = 18 * direction
        slide.toValue = 0
        slide.duration = Motion.panel * 0.7
        slide.timingFunction = Motion.smooth.timingFunction
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = Motion.panel * 0.7
        let group = CAAnimationGroup()
        group.animations = [slide, fade]
        group.duration = Motion.panel * 0.7
        content.add(group, forKey: "panel")
    }

    // MARK: - Film

    private func adjustment(_ title: String, range: ClosedRange<Double>,
                            display: @escaping (Double) -> String,
                            get: @escaping () -> Double,
                            set: @escaping (Double) -> Void) -> SliderRow {
        SliderRow(title, range: range, display: display, get: get, set: set,
                  began: { [weak model] in model?.beginContinuousEdit() },
                  ended: { [weak model] in model?.endContinuousEdit() })
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    private var activeStock: FilmStock? {
        model.edit.hasFilm ? model.edit.stock : nil
    }

    private var rowFactory: InspectorRowFactory {
        InspectorRowFactory(model: model, adjustment: { [unowned self] title, range, display, get, set in
            self.adjustment(title, range: range, display: display, get: get, set: set)
        }, bespoke: { [unowned self] control in self.bespokeRows(for: control) })
    }

    private func rows(in section: EditorControlSection,
                      matching predicate: (EditorControl) -> Bool = { _ in true }) -> [FormRowView] {
        rowFactory.controls(in: section).filter(predicate).filter { control in
            switch control.field {
            case .sceneLightKelvin:
                return EditorControlCatalogue.sourceLights[model.edit.sourceLightIndex].id == "custom"
            case .enlarger: return showsEnlarger
            case .printCorrection: return showsPrintCorrection
            default: return true
            }
        }.flatMap { control in
            let made = rowFactory.rows(for: control)
            switch control.field {
            case .printCorrection: printCorrectionRow = made.first
            case .printerLamp, .printerExposure, .printerMagenta, .printerYellow:
                printerRows.append(contentsOf: made)
            default: break
            }
            return made
        }
    }

    private func bespokeRows(for control: EditorControl) -> [FormRowView] {
        switch control.field {
        case .shutter:
            let times = EditorControlCatalogue.shutterTimes(for: activeStock)
            guard !times.isEmpty else { return [] }
            return [PopUpRow<Double?>(
                control.title,
                options: [(title: "Instantaneous", value: Double?.none)]
                    + times.map { (title: EditorControlCatalogue.shutterName($0), value: Double?($0)) },
                get: { [model] in model.edit.shutterSeconds },
                set: { [model] in model.edit.shutterSeconds = $0 }),
                NoteRow { [model] in
                    guard model.edit.shutterSeconds != nil else {
                        return "Apply the film’s measured correction for sensitivity and color changes during long exposures."
                    }
                    return "Uses the film’s measured long-exposure correction for this shutter time."
                }]
        case .paper:
            return paperRows()
        case .printLight:
            guard showsViewingLight else { return [] }
            return [PopUpRow<Double?>(
                control.title,
                options: EditorControlCatalogue.viewingLights(for: model.edit.resolvedPaper)
                    .map { (title: $0.label, value: $0.value) },
                get: { [model] in model.edit.printLightKelvin },
                set: { [model] in model.edit.printLightKelvin = $0 })]
        case .enlarger:
            guard showsEnlarger else { return [] }
            return [PopUpRow<Enlarger>(
                control.title,
                options: Enlarger.allCases.map { ($0.name, $0) },
                get: { [model] in model.edit.enlarger },
                set: { [model] in model.edit.enlarger = $0 }),
                NoteRow { [model] in model.edit.enlarger.detail }]
        default:
            return []
        }
    }

    private func formatSection() -> FormSectionView {
        let format = FormSectionView(title: "Film Format")
        let picker = GaugePickerView(model: model)
        gaugePicker = picker
        format.add(view: picker)
        #if !canImport(UIKit)
        format.add(NoteRow { [model] in
            "Smaller film formats are enlarged more, so the same film shows coarser grain and softer highlights. "
                + model.edit.gaugeFollowingNote(sensor: model.sensorFrame)
        })
        #endif
        return format
    }

    private func filmReturnResetRow() -> ButtonRow {
        ButtonRow("Use Film Return", bordered: false, enabled: { [model] in model.edit.halationReturnRatio != nil }) { [model] in
            model.edit.reset(.halationReturn)
        }
    }

    #if canImport(UIKit)
    private func filmSections() -> [FormSectionView] {
        var sections: [FormSectionView] = []

        let format = formatSection()
        sections.append(format)

        // The film's own controls only exist where there is a film: on Normal the sensor's
        // picture is what it is, and a grain slider over it would move nothing. This is the
        // phone's `hasFilm` rule, which the Mac had never applied.
        guard model.edit.hasFilm else {
            sections.append(contentsOf: printSections())
            if model.sourceInterpretationAvailable {
                sections.append(contentsOf: sourceSections())
            }
            if model.hasVideo { sections.append(contentsOf: videoSections()) }
            sections.append(hintSection())
            return sections
        }

        let character = FormSectionView(title: "Character")
        for row in rows(in: .filmGrain) + rows(in: .filmEmulsion) { character.add(row) }
        if model.edit.stock?.halationStrength.first.map({ $0 > 0 }) == true {
            character.add(filmReturnResetRow())
        }
        character.add(ButtonRow("New Grain Pattern") { [model] in
            model.edit.rerollGrain()
        })
        sections.append(character)

        if allows(.labControls) {
            let lab = FormSectionView(title: "Lab")
            for row in rows(in: .filmLab) { lab.add(row) }
            lab.add(NoteRow("Push changes contrast, color, and grain. Bleach bypass retains silver in the negative. Expired film simulates changes from age."))
            sections.append(lab)
        } else {
            sections.append(proSection(
                title: "Lab", button: "Unlock Lab Controls…",
                note: "Push and pull, bleach bypass, expired film, and reciprocity are part of Fotufilm Pro."))
        }

        sections.append(contentsOf: printSections())
        if model.sourceInterpretationAvailable {
            sections.append(contentsOf: sourceSections())
        }
        if model.hasVideo { sections.append(contentsOf: videoSections()) }
        sections.append(hintSection())
        return sections
    }

    #else
    private func isHalation(_ control: EditorControl) -> Bool {
        control.field == .halationReturn || control.host?.group == .halation || control.host?.group == .halationSpectrum
    }

    private func filmSections() -> [FormSectionView] {
        guard model.edit.hasFilm else {
            let plain = noFilmSection()
            plain.addNotes(from: hintSection())
            return [plain]
        }
        let stock = FormSectionView(title: "Loaded Film")
        stock.add(ValueRow("Stock", value: { [model] in
            StockPreset.preset(id: model.edit.stockID)?.name ?? StockPreset.noFilmName
        }))
        stock.add(NoteRow("Choose a stock from the film library on the left."))
        let condition = FormSectionView(title: "Film Condition")
        for row in rows(in: .filmLab, matching: { $0.field == .expired }) { condition.add(row) }
        let halation = FormSectionView(title: "Halation")
        for row in rows(in: .filmEmulsion, matching: isHalation) { halation.add(row) }
        if model.edit.stock?.halationStrength.first.map({ $0 > 0 }) == true {
            halation.add(filmReturnResetRow())
        }
        stock.addNotes(from: hintSection())
        return [stock, formatSection(), condition, halation]
    }

    private func exposureSections() -> [FormSectionView] {
        var sections = [lightSection()] + gradeSections()
        if model.edit.hasFilm && !shutterChoices.isEmpty {
            let reciprocity = FormSectionView(title: "Long Exposure")
            for row in rows(in: .filmLab, matching: { $0.field == .shutter }) { reciprocity.add(row) }
            sections.append(reciprocity)
        }
        sections += lensSections()
        if model.sourceInterpretationAvailable { sections += sourceSections() }
        if model.hasVideo { sections.append(videoSourceSection()) }
        return sections
    }

    private func developmentSections() -> [FormSectionView] {
        guard model.edit.hasFilm else { return [noFilmSection()] }
        let chemistry = FormSectionView(title: "Development")
        for row in rows(in: .filmLab, matching: { $0.field != .expired && $0.field != .shutter }) {
            chemistry.add(row)
        }
        chemistry.add(NoteRow(chemistry.rows.isEmpty
            ? "This film uses standard development. Push and pull are available only when the film has measured settings."
            : "Push and pull, where supported, change development. Exposure changes the light reaching the film. Bleach bypass retains silver in the negative."))
        let grain = FormSectionView(title: "Grain")
        for row in rows(in: .filmGrain) { grain.add(row) }
        grain.add(ButtonRow("New Grain Pattern") { [model] in model.edit.rerollGrain() })
        let separation = FormSectionView(title: "Colour Separation")
        for row in rows(in: .filmEmulsion, matching: { !isHalation($0) }) { separation.add(row) }
        var sections = [chemistry, grain]
        if !separation.rows.isEmpty { sections.append(separation) }
        return sections
    }

    private func finishingSections() -> [FormSectionView] {
        var sections = printSections()
        if model.hasVideo { sections.append(cadenceSection()) }
        let export = FormSectionView(title: "Export")
        export.add(ButtonRow(model.hasVideo ? "Export Video…" : "Export Photo…",
                             enabled: { [model] in model.canExport }) { [weak self] in
            self?.onExport?()
        })
        export.add(NoteRow("Choose the file format and size for the finished image."))
        sections.append(export)
        return sections
    }

    private func noFilmSection() -> FormSectionView {
        let section = FormSectionView(title: "Normal")
        section.add(NoteRow(status: true) {
            "Film simulation is off. Choose a film from the library."
        })
        section.add(NoteRow("Choose a film from the library on the left to use film format, halation, development, and grain. With Normal selected, use Expose to adjust the source and Print to finish the image."))
        return section
    }

    #endif

    private func printSections() -> [FormSectionView] {
        let print = FormSectionView(title: "Output")
        let catalogued = rows(in: .printPaper)
        for row in catalogued { print.add(row) }
        if catalogued.isEmpty { for row in paperRows() { print.add(row) } }
        guard showsEnlarger else { return [print] }
        let lamp = FormSectionView(title: EditorControlSection.printLamp.title)
        for row in rows(in: .printLamp) { lamp.add(row) }
        lamp.add(NoteRow { [model] in
            model.edit.printerEnabled
                ? "A simulated tungsten lamp and colour filters expose the paper through the negative. More paper exposure makes a darker print."
                : "Enable Simulated Printer to adjust lamp temperature, paper exposure and filtration."
        })
        return [print, lamp]
    }

    private func paperRows() -> [FormRowView] {
        let papers = model.edit.stock.map(PrintPaper.choices(for:))
            ?? PrintPaper.allCases
        let canFollowStock = model.edit.stock?.isReversal != true
        let options: [(title: String, value: OutputMediumChoice)] =
            (canFollowStock ? [("Match Film", .matchFilm)] : [])
            + papers.map { ($0.name, .medium($0)) }
        let paperRow = PopUpRow<OutputMediumChoice>(
            "Output Medium", options: options,
            get: { [model] in
                model.edit.paperFollowsStock
                    ? .matchFilm : .medium(model.edit.resolvedPaper)
            },
            set: { [model] choice in
                switch choice {
                case .matchFilm:
                    model.edit.paperFollowsStock = true
                case let .medium(paper):
                    model.edit.paper = paper
                    model.edit.paperFollowsStock = false
                }
            })
        paperRow.isRowEnabled = papers.count > 1
        let note = NoteRow { [model] in
            guard let stock = model.edit.stock else {
                guard model.edit.hasFilm else {
                    return "Choose a film to see the output medium made for it."
                }
                return model.edit.resolvedPaper.detail
            }
            if stock.isReversal {
                return "This film is already a positive, so you see it directly instead of printing it onto another medium."
            }
            if model.edit.resolvedPaper.isNegative {
                return model.edit.resolvedPaper.detail
            }
            if stock.isMonochrome {
                return "Black-and-white film stays neutral here; the medium mainly changes contrast and whether the result is physical or digital."
            }
            return model.edit.resolvedPaper.detail
        }
        return [paperRow, note]
    }

    private enum OutputMediumChoice: Equatable {
        case matchFilm
        case medium(PrintPaper)
    }

    private func sourceSections() -> [FormSectionView] {
        let source = FormSectionView(title: "Source Interpretation")
        source.add(PopUpRow<FilmSourceInterpretation>(
            "Highlights",
            options: FilmSourceInterpretation.allCases.map {
                ($0.label, $0)
            },
            get: { [model] in model.edit.sourceInterpretation },
            set: { [model] in model.edit.sourceInterpretation = $0 }))
        source.add(NoteRow { [model] in
            model.edit.sourceInterpretation.detail
        })
        return [source]
    }

    private func videoSourceSection() -> FormSectionView {
        let source = FormSectionView(title: "Source")
        source.add(PopUpRow<VideoSourceEncoding>(
            "Encoding",
            options: VideoSourceEncoding.allCases.map { ($0.title, $0) },
            get: { [model] in model.sourceEncoding },
            set: { [model] in model.sourceEncoding = $0 }))
        source.add(NoteRow("Standard reads the file’s color tags automatically. Choose a camera encoding if the file’s tags are missing or incorrect."))

        return source
    }

    private func cadenceSection() -> FormSectionView {
        let cadence = FormSectionView(title: "Cadence")
        cadence.add(PopUpRow<Int?>(
            "Cadence",
            options: [("Native", nil), ("16 fps · silent era", 16),
                      ("18 fps · Super 8", 18), ("24 fps · cine", 24)],
            get: { [model] in model.videoFrameRate },
            set: { [model] in model.videoFrameRate = $0 }))
        cadence.add(NoteRow("Choose the export frame rate. Lower rates hold each frame longer."))
        return cadence
    }

    private func videoSections() -> [FormSectionView] {
        [videoSourceSection(), cadenceSection()]
    }

    private func hintSection() -> FormSectionView {
        let hint = FormSectionView(title: nil)
        hint.add(NoteRow { [model] in
            // The one sentence in the inspector that describes a gesture rather than the film, so
            // it is the one that has to name the pointer the reader actually has.
            #if canImport(UIKit)
            let compare = "Touch and hold the photo to compare with the original."
            #else
            let compare = "Click and hold the photo to compare with the original."
            #endif
            return model.hasVideo
                ? "Press Space to play or pause. Scrubbing shows a preview; stopping displays the frame at full resolution."
                : compare
        })
        return hint
    }

    // MARK: - Adjustments

    private func lightSection() -> FormSectionView {
        let light = FormSectionView(title: "Light")
        for section in [EditorControlSection.lightExposure, .lightBalance, .lightColor] {
            for row in rows(in: section) { light.add(row) }
        }

        return light
    }

    private func adjustmentSections() -> [FormSectionView] {
        let reset = FormSectionView(title: nil)
        reset.add(ButtonRow("Reset All Edits", destructive: true,
                            enabled: { [model] in
                                model.edit != EditState.defaults
                            }) { [model] in model.reset() })
        return [lightSection()] + gradeSections() + [reset]
    }

    // MARK: - Grade

    private func gradeSections() -> [FormSectionView] {
        let deckSection = FormSectionView(title: "Grade")
        let deck = GradeDeckView(model: model)
        #if !canImport(UIKit)
        deck.selectedBand = selectedGradeBand
        deck.onSelectBand = { [weak self] in self?.selectedGradeBand = $0 }
        #endif
        gradeDeck = deck
        deckSection.add(view: deck)
        for row in rows(in: .lightGrade) where row.rowTitle == "Encoded Grade" { deckSection.add(row) }
        let note = FormSectionView(title: nil)
        note.add(NoteRow("Choose Shadows, Midtones, or Highlights. Use the pad to adjust color and the slider to adjust brightness. Grade is applied after the film response."))

        let reset = FormSectionView(title: nil)
        reset.add(ButtonRow("Reset Grade", destructive: true,
                            enabled: { [model] in
                                !model.edit.grade.isNeutral
                            }) { [model, weak self] in
            model.beginContinuousEdit()
            model.edit.grade = .neutral
            model.endContinuousEdit()
            self?.gradeDeck?.refresh()
        })
        #if canImport(UIKit)
        return [deckSection, note, reset]
        #else
        deckSection.addNotes(from: note)
        return [deckSection, reset]
        #endif
    }

    // MARK: - Crop

    private func cropSections() -> [FormSectionView] {
        let orientation = FormSectionView(title: "Orientation")
        orientation.add(ButtonBarRow([
            (title: "Rotate", symbol: "rotate.left",
             enabled: { [model] in model.hasPhoto },
             action: { [model] in model.rotateLeft() }),
            (title: "Flip",
             symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right",
             enabled: { [model] in model.hasPhoto },
             action: { [model] in model.flipHorizontal() }),
        ]))

        let crop = FormSectionView(title: "Crop")
        crop.add(ButtonRow("Four-Corner Crop", enabled: { [model] in model.hasPhoto }) { [model] in
            var next = model.edit
            next.cornerCrop = QuadrilateralCrop(rect: UnitCropCoordinates.verticallyFlipped(
                next.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)))
            next.crop = nil
            model.edit = next
            model.cropAspect = .free
        })
        crop.add(PopUpRow<AspectOption>(
            "Aspect",
            options: AspectOption.allCases.map { ($0.rawValue, $0) },
            get: { [model] in model.cropAspect },
            set: { [model] in model.applyAspect($0) }))
        let geometry = rows(in: .frameGeometry)
        if let straighten = geometry.first(where: { $0.rowTitle == "Straighten" }) { crop.add(straighten) }

        let perspective = FormSectionView(title: "Perspective")
        for row in geometry where row.rowTitle == "Vertical" || row.rowTitle == "Horizontal" {
            perspective.add(row)
        }
        perspective.add(NoteRow("Straighten converging lines caused by camera angle. Strong corrections crop more of the image."))

        let reset = FormSectionView(title: nil)
        reset.add(ButtonRow("Reset Crop", destructive: true,
                            enabled: { [model] in
                                model.edit.hasGeometryEdits
                            }) { [model] in model.resetGeometry() })

        let hint = FormSectionView(title: nil)
        hint.add(NoteRow("Drag the frame to crop. Four-Corner Crop lets you move each corner independently and straightens the selection when you leave Crop. Choose an aspect ratio to return to a rectangular crop."))

        #if canImport(UIKit)
        return [orientation, crop, perspective, reset, hint]
        #else
        crop.addNotes(from: hint)
        return [orientation, crop, perspective, reset]
        #endif
    }

    private func lensSections() -> [FormSectionView] {
        let hint = FormSectionView(title: nil)
        hint.add(NoteRow("Correct lens distortion, dark corners, and color fringing. A matching profile is selected from the photo’s metadata when available."))
        #if canImport(UIKit)
        return [filterSection(), lensSection(), hint]
        #else
        let lens = lensSection()
        lens.addNotes(from: hint)
        return [filterSection(), lens]
        #endif
    }

    private func filterSection() -> FormSectionView {
        guard allows(.lensFilters) else {
            return proSection(
                title: "Filters", button: "Unlock Lens Filters…",
                note: "Absorbing and diffusion filters are part of Fotufilm Pro. Lens correction remains available below.")
        }
        let filters = FormSectionView(title: "Filters")
        for row in LensFilterSection.rows(model: model) { filters.add(row) }
        filters.add(NoteRow { [model] in
            LensFilterSection.note(for: model)
        })
        return filters
    }

    private func allows(_ feature: ProUnlock.Feature) -> Bool {
        #if canImport(UIKit)
        return ProAccess.allows(feature)
        #else
        return true
        #endif
    }

    private func proSection(title: String, button: String,
                            note: String) -> FormSectionView {
        let section = FormSectionView(title: title)
        #if canImport(UIKit)
        section.add(ButtonRow(button) { ProGate.present() })
        #endif
        section.add(NoteRow(note))
        return section
    }

    private func lensSection() -> FormSectionView {
        let lens = FormSectionView(title: "Lens")
        if let toggle = rows(in: .lensCorrection).first(where: { $0.rowTitle == "Lens Correction" }) {
            toggle.isRowEnabled = model.hasPhoto
            lens.add(toggle)
        }

        guard model.edit.lensCorrectionEnabled else { return lens }

        if let profile = model.matchedLensProfile {
            lens.add(ValueRow("Profile", value: { profile.model }))
        } else {
            // Saying what is correcting the picture, or why nothing is, is the difference between a
            // photographer reaching for the sliders and wondering whether the switch is broken.
            lens.add(NoteRow(status: true) { [model] in model.lensCorrectionNote })
        }
        for row in rows(in: .lensCorrection) where row.rowTitle != "Lens Correction" {
            if row.rowTitle == "Amount", !model.hasLensMeasurement { continue }
            lens.add(row)
        }
        lens.add(ButtonRow("Reset Lens",
                           enabled: { [model] in model.hasLensEdits }) { [model] in
            model.resetLensCorrection()
        })
        return lens
    }
}
