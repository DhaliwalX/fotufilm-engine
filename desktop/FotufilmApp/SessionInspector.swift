import CoreGraphics
import Foundation
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
    case film, lens, adjustments, selective, crop

    var title: String {
        switch self {
        case .film: return "Film"
        case .lens: return "Lens"
        case .adjustments: return "Light & Color"
        case .selective: return "Selective"
        case .crop: return "Crop"
        }
    }

    /// How every surface names the panel — the tab bar and the rail both draw the glyph, with the
    /// word held back for tool tips and for anyone listening rather than looking.
    var symbol: String {
        switch self {
        case .film: return "film"
        case .lens: return "camera.aperture"
        case .adjustments: return "slider.horizontal.3"
        case .selective: return "circle.dashed"
        case .crop: return "crop.rotate"
        }
    }

    /// The tabs a session actually offers.
    ///
    /// A clip gets neither the crop nor the selection: the crop is dragged on a still canvas, and
    /// the selection would have to be re-sampled every frame to mean anything.
    static func available(video: Bool) -> [InspectorPanel] {
        video ? [.film, .lens, .adjustments] : allCases
    }
}

/// The trailing column: a tab bar over a scrolling stack of grouped sections.
///
/// The panel is rebuilt when its *shape* changes — a different tab, a clip opened, the lens switch
/// thrown — and only re-read when a value changes, so dragging a slider does not tear the column it
/// is in down and put it back up sixty times a second.
final class InspectorViewController: SessionViewController {
    private let model: DesktopEditorModel
    private let tabs = SessionTabStrip()
    private let column = ScrollColumn()

    private var rows: [FormRowView] = []
    private var gaugePicker: GaugePickerView?
    private var gradeDeck: GradeDeckView?
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
            rebuild(direction: order(panel) >= order(oldValue) ? 1 : -1)
            onPanelChanged?(panel)
        }
    }

    var onPanelChanged: ((InspectorPanel) -> Void)?

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
        tabs.setTabs(available.map { (symbol: $0.symbol, title: $0.title) })
        if let index = available.firstIndex(of: panel) {
            tabs.selectedIndex = index
        }
    }

    private var structureSignature: String {
        [
            panel.rawValue,
            String(model.hasVideo),
            String(model.hasPhoto),
            String(model.sourceInterpretationAvailable),
            String(showsViewingLight),
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

        let enabled = !model.isExporting
        if tabs.isEnabled != enabled {
            tabs.isEnabled = enabled
            rows.forEach { $0.isRowEnabled = enabled }
        }
    }

    private func rebuild(direction: CGFloat) {
        structure = structureSignature
        rows.removeAll()
        gaugePicker = nil
        gradeDeck = nil
        for view in column.column.arrangedSubviews {
            column.column.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let sections: [FormSectionView]
        switch panel {
        case .film: sections = filmSections()
        case .lens: sections = lensSections()
        case .adjustments: sections = adjustmentSections()
        case .selective: sections = selectiveSections()
        case .crop: sections = cropSections()
        }
        for section in sections {
            column.column.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: column.column.widthAnchor)
                .isActive = true
            rows.append(contentsOf: section.rows)
        }
        rows.forEach { $0.isRowEnabled = !model.isExporting }
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

    private func catalogued(_ field: EditorControlField) -> EditorControl? {
        EditorControlCatalogue.controls(for: activeStock)
            .first { $0.field == field }
    }

    private func cataloguedSlider(_ field: EditorControlField) -> SliderRow? {
        guard let control = catalogued(field),
              let scale = control.kind.scale else { return nil }
        return adjustment(
            control.title, range: scale.range,
            display: scale.unit.format,
            get: { [model] in model.edit.value(of: field) ?? scale.neutral },
            set: { [model] value in
                var next = model.edit
                next.setValue(value, of: field)
                model.edit = next
            })
    }

    private func cataloguedToggle(_ field: EditorControlField) -> ToggleRow? {
        guard let control = catalogued(field),
              case .toggle = control.kind else { return nil }
        return ToggleRow(
            control.title,
            get: { [model] in model.edit.flag(of: field) ?? false },
            set: { [model] value in
                var next = model.edit
                next.setFlag(value, of: field)
                model.edit = next
            })
    }

    private func cataloguedCurve(_ field: EditorControlField)
        -> ControlCurveFormRow? {
        guard let control = catalogued(field),
              let curve = control.kind.curve else { return nil }
        return ControlCurveFormRow(
            control.title, curve: curve,
            get: { [model] in
                model.edit.curve(of: field) ?? curve.restingValues
            },
            set: { [model] values in
                var next = model.edit
                next.setCurve(values, of: field)
                model.edit = next
            },
            began: { [weak model] in model?.beginContinuousEdit() },
            ended: { [weak model] in model?.endContinuousEdit() })
    }

    private func filmSections() -> [FormSectionView] {
        var sections: [FormSectionView] = []

        let format = FormSectionView(title: "Film Format")
        let picker = GaugePickerView(model: model)
        gaugePicker = picker
        format.add(view: picker)
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
        if let row = cataloguedSlider(.grain) { character.add(row) }
        // The share of the published granularity's variance carried by the coarse field under the
        // sharp grain. Named choices rather than a slider, as the phone names them: the numbers
        // are shares of a variance and mean nothing dragged past.
        character.add(PopUpRow<Double?>(
            "Grain Mottle",
            options: [(title: "Film’s Own", value: Double?.none),
                      (title: "None", value: Double?(0)),
                      (title: "Light · 20%", value: Double?(0.2)),
                      (title: "Moderate · 45%", value: Double?(0.45)),
                      (title: "Heavy · 70%", value: Double?(0.7)),
                      (title: "Maximum · 90%", value: Double?(0.9))],
            get: { [model] in model.edit.grainMottleShare },
            set: { [model] in model.edit.grainMottleShare = $0 }))
        if let row = cataloguedToggle(.grainModel) { character.add(row) }
        if let row = cataloguedSlider(.halation) { character.add(row) }
        if let row = cataloguedSlider(.halationColour) { character.add(row) }
        if let row = cataloguedCurve(.halationSpectrum) { character.add(row) }
        if let row = cataloguedSlider(.couplers) { character.add(row) }
        if let row = cataloguedSlider(.couplerReach) { character.add(row) }
        if let row = cataloguedSlider(.couplerSelf) { character.add(row) }
        character.add(ButtonRow("New Grain Pattern") { [model] in
            model.edit.rerollGrain()
        })
        sections.append(character)

        if allows(.labControls) {
            let lab = FormSectionView(title: "Lab")
            lab.add(adjustment("Push / Pull", range: -1...3,
                               display: { String(format: "%+.1f stops", $0) },
                               get: { [model] in model.edit.push },
                               set: { [model] in model.edit.push = $0 }))
            lab.add(adjustment("Bleach Bypass", range: 0...1, display: percent,
                               get: { [model] in model.edit.bleach },
                               set: { [model] in model.edit.bleach = $0 }))
            lab.add(adjustment("Expired", range: 0...30,
                               display: { $0 < 0.5 ? "Fresh"
                                   : String(format: "%.0f yr", $0) },
                               get: { [model] in model.edit.expiredYears },
                               set: { [model] in model.edit.expiredYears = $0 }))
            let times = shutterChoices
            if !times.isEmpty {
                lab.add(PopUpRow<Double?>(
                    "Exposure Time",
                    options: [(title: "Instantaneous", value: Double?.none)]
                        + times.map {
                            (title: Self.shutterName($0), value: Double?($0))
                        },
                    get: { [model] in model.edit.shutterSeconds },
                    set: { [model] in model.edit.shutterSeconds = $0 }))
                lab.add(NoteRow { [model] in
                    guard model.edit.shutterSeconds != nil else {
                        return "A long exposure loses speed and gains crossover as the layers fail at different rates. This film's sheet states how much."
                    }
                    return "Developed with this film's stated reciprocity correction for an exposure that long."
                })
            }
            lab.add(NoteRow("The film can's sticker rather than the darkroom: push develops harder with the crossover and grain that costs, bleach bypass leaves the silver in the negative, and an expired roll loses speed from the blue layer first."))
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

    /// Where the finished image lives, and—only for physical media—the light it is judged under.
    private func printSections() -> [FormSectionView] {
        let print = FormSectionView(title: "Output")
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
        print.add(paperRow)
        print.add(NoteRow { [model] in
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
        })
        if showsViewingLight {
            print.add(PopUpRow<Double?>(
                "Viewing Illuminant",
                options: Self.viewingLightChoices(for: model.edit.resolvedPaper),
                get: { [model] in model.edit.printLightKelvin },
                set: { [model] in model.edit.printLightKelvin = $0 }))
        }
        if showsPrintCorrection {
            print.add(adjustment("Channel Contrast Match", range: 0...1,
                                 display: percent,
                                 get: { [model] in model.edit.printCorrection },
                                 set: { [model] in
                                     model.edit.printCorrection = $0
                                 }))
        }
        return [print]
    }

    private enum OutputMediumChoice: Equatable {
        case matchFilm
        case medium(PrintPaper)
    }

    private static func viewingLightChoices(for paper: PrintPaper)
        -> [(title: String, value: Double?)] {
        if paper.isProjected {
            return [("Reference Projector · Xenon 5400 K", nil),
                    ("Light Table · D65", 6504),
                    ("Proofing Booth · D50", 5003),
                    ("Tungsten · 2856 K", 2856)]
        }
        return [("Reference Booth · D50", nil),
                ("Daylight · D65", 6504),
                ("Tungsten · 2856 K", 2856)]
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

    private func videoSections() -> [FormSectionView] {
        let source = FormSectionView(title: "Source")
        source.add(PopUpRow<VideoSourceEncoding>(
            "Encoding",
            options: VideoSourceEncoding.allCases.map { ($0.title, $0) },
            get: { [model] in model.sourceEncoding },
            set: { [model] in model.sourceEncoding = $0 }))
        source.add(NoteRow("Standard converts tagged SDR, HLG, and PQ to scene-linear Rec.2020. Choose an explicit camera encoding when the file does not identify its curve and gamut reliably."))

        let cadence = FormSectionView(title: "Cadence")
        cadence.add(PopUpRow<Int?>(
            "Cadence",
            options: [("Native", nil), ("16 fps · silent era", 16),
                      ("18 fps · Super 8", 18), ("24 fps · cine", 24)],
            get: { [model] in model.videoFrameRate },
            set: { [model] in model.videoFrameRate = $0 }))
        cadence.add(NoteRow("Retimes the export to a film cadence by developing fewer, longer-lived frames."))
        return [source, cadence]
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
                ? "Press space to play or pause. Scrubbing develops each frame live; when the playhead settles, that frame develops again at full resolution."
                : compare
        })
        return hint
    }

    // MARK: - Adjustments

    /// Light, colour, and the finished grade in one place, matching the phone's deck.
    private func adjustmentSections() -> [FormSectionView] {
        let light = FormSectionView(title: "Light")
        light.add(adjustment("Exposure", range: -3...3,
                             display: { String(format: "%+.2f", $0) },
                             get: { [model] in model.edit.exposure },
                             set: { [model] in model.edit.exposure = $0 }))
        light.add(adjustment("Highlights", range: -1...1,
                             display: { String(format: "%+.0f", $0 * 100) },
                             get: { [model] in model.edit.highlights },
                             set: { [model] in model.edit.highlights = $0 }))
        light.add(adjustment("Shadows", range: -1...1,
                             display: { String(format: "%+.0f", $0 * 100) },
                             get: { [model] in model.edit.shadows },
                             set: { [model] in model.edit.shadows = $0 }))
        if let row = cataloguedToggle(.localTone) { light.add(row) }
        let mired = ClosedRange(
            uncheckedBounds: (Double(WhiteBalance.miredRange.lowerBound),
                              Double(WhiteBalance.miredRange.upperBound)))
        let tint = ClosedRange(
            uncheckedBounds: (Double(WhiteBalance.tintRange.lowerBound),
                              Double(WhiteBalance.tintRange.upperBound)))
        light.add(adjustment(
            "Temperature",
            range: mired,
            display: {
                String(format: "%.0f K", WhiteBalance.miredToKelvin(Float($0)))
            },
            get: { [model] in model.edit.temperatureMired },
            set: { [model] in model.edit.temperatureMired = $0 }))
        light.add(adjustment(
            "Tint",
            range: tint,
            display: { String(format: "%+.0f", $0) },
            get: { [model] in model.edit.tint },
            set: { [model] in model.edit.tint = $0 }))
        light.add(adjustment("Vibrance", range: -1...1,
                             display: { String(format: "%+.0f", $0 * 100) },
                             get: { [model] in model.edit.vibrance },
                             set: { [model] in model.edit.vibrance = $0 }))
        light.add(adjustment("Saturation", range: 0...2,
                             display: { String(format: "%+.0f", ($0 - 1) * 100) },
                             get: { [model] in model.edit.saturation },
                             set: { [model] in model.edit.saturation = $0 }))

        let reset = FormSectionView(title: nil)
        reset.add(ButtonRow("Reset All Edits", destructive: true,
                            enabled: { [model] in
                                model.edit != EditState.defaults
                            }) { [model] in model.reset() })
        return [light] + gradeSections() + [reset]
    }

    // MARK: - Grade

    private func gradeSections() -> [FormSectionView] {
        let deckSection = FormSectionView(title: "Grade")
        let deck = GradeDeckView(model: model)
        gradeDeck = deck
        deckSection.add(view: deck)
        if let row = cataloguedToggle(.gradeSpace) { deckSection.add(row) }

        let note = FormSectionView(title: nil)
        note.add(NoteRow("Lift, gamma and gain over the developed print — the pad tilts the band’s color, and the slider moves its level. The film has already responded to the light, so these controls grade the resulting image."))

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
        return [deckSection, note, reset]
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
        crop.add(PopUpRow<AspectOption>(
            "Aspect",
            options: AspectOption.allCases.map { ($0.rawValue, $0) },
            get: { [model] in model.cropAspect },
            set: { [model] in model.applyAspect($0) }))
        crop.add(adjustment("Straighten", range: -15...15,
                            display: { String(format: "%+.1f°", $0) },
                            get: { [model] in model.edit.straighten },
                            set: { [model] in model.edit.straighten = $0 }))

        // Keystone. The photograph's own plane rather than its frame, which is why it is here and
        // not under Lens: correcting a lens undoes what the glass did, and this undoes where the
        // camera was standing. The phone has carried both since the crop takeover was written.
        let perspective = FormSectionView(title: "Perspective")
        let degrees: (Double) -> String = { String(format: "%+.1f°", $0) }
        perspective.add(adjustment("Vertical", range: -15...15,
                                   display: degrees,
                                   get: { [model] in model.edit.perspectiveV },
                                   set: { [model] in
                                       model.edit.perspectiveV = $0
                                   }))
        perspective.add(adjustment("Horizontal", range: -15...15,
                                   display: degrees,
                                   get: { [model] in model.edit.perspectiveH },
                                   set: { [model] in
                                       model.edit.perspectiveH = $0
                                   }))
        perspective.add(NoteRow("Tilts the picture plane, for a building photographed from the pavement or a wall shot from one side. The frame is filled again afterwards, so a strong correction crops."))

        let reset = FormSectionView(title: nil)
        reset.add(ButtonRow("Reset Crop", destructive: true,
                            enabled: { [model] in
                                model.edit.hasGeometryEdits
                            }) { [model] in model.resetGeometry() })

        let hint = FormSectionView(title: nil)
        hint.add(NoteRow("Drag the photo’s frame edges to resize it, or drag inside the frame to move it. Choosing an aspect ratio keeps that shape locked."))

        return [orientation, crop, perspective, reset, hint]
    }

    private func lensSections() -> [FormSectionView] {
        let hint = FormSectionView(title: nil)
        hint.add(NoteRow("Lens correction undoes what the taking lens did to the frame — its distortion, its darkened corners, the colour fringing at the edges. It is read from the photograph's own metadata when a matching profile is known."))
        return [filterSection(), lensSection(), hint]
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
        let toggle = ToggleRow("Correct Lens",
                               get: { [model] in
                                   model.edit.lensCorrectionEnabled
                               },
                               set: { [model] in
                                   model.edit.lensCorrectionEnabled = $0
                               })
        toggle.isRowEnabled = model.hasPhoto
        lens.add(toggle)

        guard model.edit.lensCorrectionEnabled else { return lens }

        if let profile = model.matchedLensProfile {
            lens.add(ValueRow("Profile", value: { profile.model }))
        } else {
            // Saying what is correcting the picture, or why nothing is, is the difference between a
            // photographer reaching for the sliders and wondering whether the switch is broken.
            lens.add(NoteRow { [model] in model.lensCorrectionNote })
        }
        if model.hasLensMeasurement {
            lens.add(adjustment("Amount", range: 0...1,
                                display: { "\(Int(($0 * 100).rounded()))%" },
                                get: { [model] in model.edit.lensProfileAmount },
                                set: { [model] in
                                    model.edit.lensProfileAmount = $0
                                }))
        }
        let signed: (Double) -> String = { String(format: "%+.0f", $0 * 100) }
        lens.add(adjustment("Distortion", range: -1...1, display: signed,
                            get: { [model] in
                                model.edit.lensAdjustment.distortion
                            },
                            set: { [model] in
                                model.edit.lensAdjustment.distortion = $0
                            }))
        lens.add(adjustment("Vignetting", range: -1...1, display: signed,
                            get: { [model] in
                                model.edit.lensAdjustment.vignetting
                            },
                            set: { [model] in
                                model.edit.lensAdjustment.vignetting = $0
                            }))
        lens.add(adjustment("Red / Cyan", range: -1...1, display: signed,
                            get: { [model] in model.edit.lensAdjustment.redCyan },
                            set: { [model] in
                                model.edit.lensAdjustment.redCyan = $0
                            }))
        lens.add(adjustment("Blue / Yellow", range: -1...1, display: signed,
                            get: { [model] in
                                model.edit.lensAdjustment.blueYellow
                            },
                            set: { [model] in
                                model.edit.lensAdjustment.blueYellow = $0
                            }))
        lens.add(ButtonRow("Reset Lens",
                           enabled: { [model] in model.hasLensEdits }) { [model] in
            model.resetLensCorrection()
        })
        return lens
    }
}
