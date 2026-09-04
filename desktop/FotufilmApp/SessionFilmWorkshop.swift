import CoreGraphics
import UniformTypeIdentifiers
import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Cross-platform editor for generated and control-point film definitions.
/// It previews a `StockTestChart` or imported image and exposes curve, spectrum, and numeric
/// controls. Imported definitions retain their source lineage for export-policy checks.
final class FilmWorkshopController: SessionViewController {

    /// Called when the sheet has gone, and when the library changed under it, so whoever opened the
    /// workshop can put the film list back up to date.
    var onClose: (() -> Void)?
    var onLibraryChanged: (() -> Void)?

    // MARK: - What is being edited

    private var films: [FilmStockDefinition] = []
    /// The film in hand. `editingID` is nil for one that has not been saved yet.
    private(set) var draft = CustomStockDraft()
    private var editingID: String?
    private var savedDraft = CustomStockDraft()

    private var isDirty: Bool { draft != savedDraft }

    /// The one way the form writes to the film.
    ///
    /// - Parameter rebuild: true when the change alters which rows exist at all — the kind of film,
    ///   which decides whether there is a dye set or a print stage to talk about. Everything else
    ///   only refreshes the rows in place, because rebuilding a form under a slider takes the
    ///   slider away mid-drag.
    func edit(rebuild: Bool = false, _ change: (inout CustomStockDraft) -> Void) {
        var next = draft
        change(&next)
        guard next != draft else { return }
        recordUndo()
        draft = next
        draftChanged(rebuildRows: rebuild)
    }

    // MARK: - History

    private var undoStack: [CustomStockDraft] = []
    private var redoStack: [CustomStockDraft] = []
    private var strokeBase: CustomStockDraft?
    private var openedDraft = CustomStockDraft()

    /// Called by a graph or a slider the moment a drag takes hold of something.
    func beginStroke() {
        guard strokeBase == nil else { return }
        strokeBase = draft
    }

    /// The drag is over: one history entry if anything moved, none if the pointer only landed.
    func endStroke() {
        guard let base = strokeBase else { return }
        strokeBase = nil
        guard base != draft else { return }
        undoStack.append(base)
        redoStack.removeAll()
        trimHistory()
        updateStatus()
    }

    private func recordUndo() {
        guard strokeBase == nil else { return }
        if let last = undoStack.last, isTypingRun(last, draft) {
            redoStack.removeAll()
            return
        }
        undoStack.append(draft)
        redoStack.removeAll()
        trimHistory()
    }

    private func isTypingRun(_ a: CustomStockDraft, _ b: CustomStockDraft) -> Bool {
        guard a.name != b.name || a.subtitle != b.subtitle else { return false }
        var left = a, right = b
        left.name = ""; right.name = ""
        left.subtitle = ""; right.subtitle = ""
        return left == right
    }

    private func trimHistory() {
        if undoStack.count > 200 { undoStack.removeFirst(undoStack.count - 200) }
    }

    @objc func performUndo(_ sender: Any?) {
        guard let previous = undoStack.popLast() else { return }
        strokeBase = nil
        redoStack.append(draft)
        draft = previous
        draftChanged(rebuildRows: true)
    }

    @objc func performRedo(_ sender: Any?) {
        guard let next = redoStack.popLast() else { return }
        strokeBase = nil
        undoStack.append(draft)
        draft = next
        draftChanged(rebuildRows: true)
    }

    private func resetDraft() {
        guard draft != openedDraft else { return }
        recordUndo()
        draft = openedDraft
        draftChanged(rebuildRows: true)
    }

    #if canImport(UIKit)
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: "z", modifierFlags: .command,
                      action: #selector(performUndo(_:))),
         UIKeyCommand(input: "z", modifierFlags: [.command, .shift],
                      action: #selector(performRedo(_:)))]
    }

    override func canPerformAction(_ action: Selector,
                                   withSender sender: Any?) -> Bool {
        switch action {
        case #selector(performUndo(_:)): return !undoStack.isEmpty
        case #selector(performRedo(_:)): return !redoStack.isEmpty
        default: return super.canPerformAction(action, withSender: sender)
        }
    }
    #endif

    // MARK: - Views

    private let root = WorkspaceView()
    private let library = ScrollColumn(inset: 0, pad: 8, bottom: 12, spacing: 2)
    private let libraryPanel = GlassPanelView(radius: Chrome.panelRadius)
    private let previewScroll = ScrollColumn(inset: 0, pad: 0, bottom: 8, spacing: 0,
                                             alignment: .fill, showsScroller: false)
    private let previewPane = LayoutPane()
    private var previewHeight: NSLayoutConstraint!
    private let formColumn = ScrollColumn(inset: 0, pad: 4, bottom: 24)

    private let sceneImage = CrossfadingImageView()
    private let filmImage = CrossfadingImageView()
    private let sceneCaption = makeLabel("Light", size: 11, color: .secondaryText)
    private let filmCaption = makeLabel("This film", size: 11,
                                        color: .secondaryText)
    private let spinner = SessionSpinner()

    private let spectrum = SpectrumEditorView(frame: .zero)
    private let dyeGraph = SpectrumEditorView(frame: .zero)
    private let curve = CurveEditorView(frame: .zero)
    private let paperCurve = CurveEditorView(frame: .zero)
    private let spectrumTitle = CapsLabel("Layer sensitivity")
    private let dyeTitle = CapsLabel("Dye density")
    private let curveTitle = CapsLabel("Characteristic curve")
    private let paperTitle = CapsLabel("Print curve")

    private let titleLabel = makeLabel("Film Workshop", size: 15,
                                       weight: .semibold)
    private let statusLabel = makeLabel("", size: 11, color: .secondaryText)
    private var saveButton: SessionButton!
    private var doneButton: SessionButton!
    private var undoButton: SessionButton!
    private var redoButton: SessionButton!
    private var resetButton: SessionButton!
    private var pictureButton: SessionButton!
    private var chartButton: SessionButton!
    private let sourceStrip = SessionTabStrip(frame: .zero)

    private enum Shown: Int { case light, film, both }
    private var shown = Shown.both

    private var ownScene: FilmRender.Scene?
    private var ownName: String?
    #if canImport(UIKit)
    private enum PickerWant { case pack, picture }
    private var wants = PickerWant.pack
    #endif
    private var previewAspect: CGFloat { ownAspect ?? StockTestChart.aspect }
    private var ownAspect: CGFloat?

    private var sections: [FormSectionView] = []
    private var libraryRows: [OptionRow] = []
    /// Whether the films that come with the application — the sealed pack inside the bundle and
    /// any JSON on the search path — are offered for study. Off, the shelf carries only the packs
    /// the user was sent, and a film that shipped here cannot be opened whole into the editor.
    /// Build with `-D FOTUFILM_STUDY_BUILT_IN_FILMS` to put them back.
    #if FOTUFILM_STUDY_BUILT_IN_FILMS
    static let offersBuiltInFilms = true
    #else
    static let offersBuiltInFilms = false
    #endif

    private static func isBuiltIn(_ id: String) -> Bool {
        switch FilmStock.origin(of: id) {
        case .community, .local: return false
        case .installed, .vault, nil: return true
        }
    }

    private var studyFilms: [(id: String, definition: FilmStockDefinition)] = []
    private var studyRows: [OptionRow] = []
    private var studyID: String?
    private var libraryViews: [PlatformView] = []

    /// Puts the form's sections in the column, replacing whatever was there.
    func setSections(_ replacements: [FormSectionView]) {
        for view in formColumn.column.arrangedSubviews {
            formColumn.column.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        sections = replacements
        for section in replacements {
            formColumn.column.addArrangedSubview(section)
            section.widthAnchor.constraint(
                equalTo: formColumn.column.widthAnchor).isActive = true
        }
    }

    // MARK: - Lifecycle

    override func loadView() {
        // Everything inside is placed by frame, so the root has to arrive with one: a sheet takes
        // its size from the view it is handed, and a view laid out by hand has no opinion of its
        // own to offer. The floor underneath is the width the three columns stop fitting at.
        root.frame = CGRect(x: 0, y: 0, width: 1180, height: 820)
        root.backingLayer.backgroundColor = Chrome.canvasBackground.cgColor

        saveButton = SessionButton(title: "Save", prominent: true) { [weak self] in
            self?.save()
        }
        doneButton = SessionButton(title: "Done") { [weak self] in
            self?.close()
        }
        undoButton = SessionButton(title: "Undo",
                                   symbol: "arrow.uturn.backward") { [weak self] in
            self?.performUndo(nil)
        }
        redoButton = SessionButton(title: "Redo",
                                   symbol: "arrow.uturn.forward") { [weak self] in
            self?.performRedo(nil)
        }
        resetButton = SessionButton(title: "Reset",
                                    symbol: "arrow.counterclockwise") { [weak self] in
            self?.resetDraft()
        }
        pictureButton = SessionButton(title: "Use a Photo…",
                                      symbol: "photo") { [weak self] in
            self?.choosePicture()
        }
        chartButton = SessionButton(title: "Test Chart",
                                    symbol: "square.grid.3x3") { [weak self] in
            self?.useChart()
        }
        chartButton.isEnabled = false

        buildLibrary()
        buildPreview()
        buildForm()

        for view in [titleLabel, statusLabel, undoButton, redoButton, resetButton,
                     saveButton, doneButton] as [PlatformView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            root.addSubview(view)
        }
        // The three panes are placed by frame, like the session's own columns. A `ScrollColumn`
        // arrives with its autoresizing translation off, and a view whose frame is ignored is a
        // view that is not there.
        for pane in [libraryPanel, previewScroll, formColumn] as [PlatformView] {
            pane.translatesAutoresizingMaskIntoConstraints = true
            root.addSubview(pane)
        }

        root.onLayout = { [weak self] in self?.layoutPanes() }
        // The same gesture the editor answers: a photograph dropped on the workshop is the
        // photograph the film is judged on.
        root.onDrop = { [weak self] urls in
            guard let url = urls.first(where: { Self.isPicture($0) }) else { return false }
            self?.took(picture: url)
            return true
        }
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 560),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 520),
        ])
        view = root

        reloadLibrary()
        newFilm()
    }

    // MARK: - Layout

    private enum Fit { case bench, narrow, tight }

    private var fit: Fit {
        let width = root.bounds.width
        if width >= 1020 { return .bench }
        if width >= 720 { return .narrow }
        return .tight
    }

    private static let libraryWidth: CGFloat = 220
    private static let formWidth: CGFloat = 340

    private func layoutPanes() {
        let bounds = root.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let top = root.safeAreaInsets.top
        let bottom = root.safeAreaInsets.bottom

        let headerHeight: CGFloat = 46
        let header = top + headerHeight
        titleLabel.frame = CGRect(x: 22, y: top + 14,
                                  width: 260,
                                  height: titleLabel.compressedSize.height)
        let doneSize = doneButton.compressedSize
        let saveSize = saveButton.compressedSize
        doneButton.frame = CGRect(x: bounds.width - doneSize.width - 20,
                                  y: top + 10, width: doneSize.width,
                                  height: doneSize.height)
        saveButton.frame = CGRect(x: doneButton.frame.minX - saveSize.width - 10,
                                  y: top + 10, width: saveSize.width,
                                  height: saveSize.height)
        // History sits left of Save in the order it reads: undo, redo, then the big reset.
        var buttonX = saveButton.frame.minX
        for button in [resetButton, redoButton, undoButton] as [SessionButton] {
            let size = button.compressedSize
            button.frame = CGRect(x: buttonX - size.width - 8, y: top + 10,
                                  width: size.width, height: size.height)
            buttonX = button.frame.minX
        }
        let statusSize = statusLabel.compressedSize
        statusLabel.frame = CGRect(
            x: max(titleLabel.frame.maxX + 12,
                   buttonX - statusSize.width - 14),
            y: top + 16, width: statusSize.width, height: statusSize.height)

        let content = CGRect(x: 0, y: header, width: bounds.width,
                             height: max(bounds.height - header - bottom, 1))
        let inset: CGFloat = 16
        let showsLibrary = fit == .bench

        var x = content.minX + inset
        if showsLibrary {
            libraryPanel.isHidden = false
            libraryPanel.frame = CGRect(x: x, y: content.minY,
                                        width: Self.libraryWidth,
                                        height: content.height - inset)
            x += Self.libraryWidth + inset
        } else {
            libraryPanel.isHidden = true
        }

        switch fit {
        case .bench, .narrow:
            let formX = content.maxX - inset - Self.formWidth
            previewScroll.frame = CGRect(x: x, y: content.minY,
                                         width: max(formX - x - inset, 120),
                                         height: content.height - inset)
            formColumn.frame = CGRect(x: formX, y: content.minY,
                                      width: Self.formWidth,
                                      height: content.height - inset)
        case .tight:
            // One column: the picture keeps the top third and the numbers scroll under it, because
            // a form squeezed beside a preview on a phone-width window is two unusable halves.
            let paneHeight = min(max(content.height * 0.42, 220),
                                 content.height - 200)
            previewScroll.frame = CGRect(x: content.minX + inset, y: content.minY,
                                         width: content.width - inset * 2,
                                         height: paneHeight)
            formColumn.frame = CGRect(
                x: content.minX + inset, y: content.minY + paneHeight + 12,
                width: content.width - inset * 2,
                height: max(content.height - paneHeight - 12 - inset, 1))
        }
        previewHeight.constant = previewContentHeight(
            width: previewScroll.frame.width,
            available: previewScroll.frame.height)
    }

    private static let titleHeight: CGFloat = 16
    private static let captionHeight: CGFloat = 15
    private static let pictureGap: CGFloat = 12
    private static let minGraphHeight: CGFloat = 130
    private static let maxGraphHeight: CGFloat = 300

    private func pictureBox(width: CGFloat) -> (side: Bool, size: CGSize) {
        let aspect = max(previewAspect, 0.2)
        guard shown == .both else {
            let height = max(min(width / aspect, 380), 40)
            return (true, CGSize(width: min(height * aspect, width), height: height))
        }
        let side = width >= 460
        let room = side ? (width - Self.pictureGap) / 2 : width
        let height = max(min(room / aspect, side ? 260 : 190), 40)
        return (side, CGSize(width: min(height * aspect, room), height: height))
    }

    private static let sourceRowHeight: CGFloat = 30

    private func picturesHeight(width: CGFloat) -> CGFloat {
        let box = pictureBox(width: width)
        let pictures = shown != .both || box.side
            ? box.size.height + Self.captionHeight + 4
            : box.size.height * 2 + Self.captionHeight * 2 + 12
        return pictures + Self.sourceRowHeight * 2 + 18
    }

    private var graphs: [(title: PlatformView, view: PlatformView)] {
        var stack: [(title: PlatformView, view: PlatformView)] = [
            (spectrumTitle, spectrum),
        ]
        if !dyeGraph.isHidden { stack.append((dyeTitle, dyeGraph)) }
        stack.append((curveTitle, curve))
        if !paperCurve.isHidden { stack.append((paperTitle, paperCurve)) }
        return stack
    }

    private func previewContentHeight(width: CGFloat,
                                      available: CGFloat) -> CGFloat {
        let count = CGFloat(graphs.count)
        let needed = picturesHeight(width: width) + 26
            + count * (Self.titleHeight + 4 + Self.minGraphHeight)
            + (count - 1) * 10
        return max(needed, available)
    }

    private func layoutPreview() {
        let bounds = previewPane.bounds
        guard bounds.width > 0 else { return }

        let captionHeight = Self.captionHeight
        let (side, size) = pictureBox(width: bounds.width)
        let showsLight = shown != .film
        let showsFilm = shown != .light
        sceneImage.isHidden = !showsLight
        sceneCaption.isHidden = !showsLight
        filmImage.isHidden = !showsFilm
        filmCaption.isHidden = !showsFilm

        if shown != .both {
            // The two take the same box, so flipping between them moves the film and nothing else:
            // a difference that shows up as the picture jumping is a difference you cannot read.
            let alone = CGRect(x: (bounds.width - size.width) / 2, y: 0,
                               width: size.width, height: size.height)
            sceneImage.frame = alone
            filmImage.frame = alone
        } else if side {
            let left = (bounds.width - (size.width * 2 + Self.pictureGap)) / 2
            sceneImage.frame = CGRect(origin: CGPoint(x: left, y: 0), size: size)
            filmImage.frame = CGRect(
                origin: CGPoint(x: left + size.width + Self.pictureGap, y: 0),
                size: size)
        } else {
            let left = (bounds.width - size.width) / 2
            sceneImage.frame = CGRect(origin: CGPoint(x: left, y: 0), size: size)
            filmImage.frame = CGRect(
                origin: CGPoint(x: left,
                                y: sceneImage.frame.maxY + captionHeight + 8),
                size: size)
        }
        sceneCaption.frame = CGRect(x: sceneImage.frame.minX,
                                    y: sceneImage.frame.maxY + 3,
                                    width: sceneImage.frame.width,
                                    height: captionHeight)
        filmCaption.frame = CGRect(x: filmImage.frame.minX,
                                   y: filmImage.frame.maxY + 3,
                                   width: filmImage.frame.width,
                                   height: captionHeight)
        spinner.frame = CGRect(x: filmImage.frame.midX - 10,
                               y: filmImage.frame.midY - 10,
                               width: 20, height: 20)

        // Which picture is up, and then what the pictures are of: the first row changes the reading,
        // the second changes the subject.
        var rowY = max(sceneCaption.frame.maxY, filmCaption.frame.maxY) + 10
        let stripWidth = min(max(sourceStrip.compressedSize.width, 240),
                             bounds.width)
        sourceStrip.frame = CGRect(x: max((bounds.width - stripWidth) / 2, 0),
                                   y: rowY, width: stripWidth,
                                   height: Self.sourceRowHeight)
        rowY += Self.sourceRowHeight + 8

        let pictureSize = pictureButton.compressedSize
        let chartSize = chartButton.compressedSize
        let rowWidth = pictureSize.width + chartSize.width + 8
        var rowX = max((bounds.width - rowWidth) / 2, 0)
        pictureButton.frame = CGRect(x: rowX, y: rowY, width: pictureSize.width,
                                     height: Self.sourceRowHeight)
        rowX += pictureSize.width + 8
        chartButton.frame = CGRect(x: rowX, y: rowY, width: chartSize.width,
                                   height: Self.sourceRowHeight)

        let stack = graphs
        let count = CGFloat(stack.count)
        var y = picturesHeight(width: bounds.width) + 26
        let room = bounds.height - y - count * (Self.titleHeight + 4)
            - (count - 1) * 10
        let height = min(max(room / count, Self.minGraphHeight),
                         Self.maxGraphHeight)
        for graph in stack {
            graph.title.frame = CGRect(x: 2, y: y, width: bounds.width,
                                       height: Self.titleHeight)
            y += Self.titleHeight + 4
            graph.view.frame = CGRect(x: 0, y: y, width: bounds.width,
                                      height: height)
            y += height + 10
        }
    }

    // MARK: - Building

    private func buildLibrary() {
        libraryPanel.content.addSubview(library)
        libraryPanel.content.pin(library, inset: 10)
    }

    private func buildPreview() {
        previewPane.translatesAutoresizingMaskIntoConstraints = false
        previewScroll.column.addArrangedSubview(previewPane)
        previewHeight = previewPane.heightAnchor.constraint(equalToConstant: 600)
        NSLayoutConstraint.activate([
            previewPane.widthAnchor.constraint(
                equalTo: previewScroll.column.widthAnchor),
            previewHeight,
        ])
        previewPane.onLayout = { [weak self] in self?.layoutPreview() }

        for image in [sceneImage, filmImage] {
            image.fitProportionally()
            image.backingLayer.backgroundColor = PlatformColor.black.cgColor
            image.backingLayer.cornerRadius = 10
            image.backingLayer.cornerCurve = .continuous
            image.backingLayer.masksToBounds = true
            image.translatesAutoresizingMaskIntoConstraints = true
            previewPane.addSubview(image)
        }
        for label in [sceneCaption, filmCaption] {
            label.translatesAutoresizingMaskIntoConstraints = true
            label.alignment = .center
            previewPane.addSubview(label)
        }
        spinner.translatesAutoresizingMaskIntoConstraints = true
        previewPane.addSubview(spinner)
        for button in [pictureButton, chartButton] as [PlatformView] {
            button.translatesAutoresizingMaskIntoConstraints = true
            previewPane.addSubview(button)
        }

        sourceStrip.setTitles(["Light", "This film", "Both"])
        sourceStrip.selectedIndex = shown.rawValue
        sourceStrip.onSelect = { [weak self] index in
            guard let self, let choice = Shown(rawValue: index),
                  choice != self.shown else { return }
            self.shown = choice
            self.previewLayoutChanged()
        }
        sourceStrip.translatesAutoresizingMaskIntoConstraints = true
        previewPane.addSubview(sourceStrip)

        curve.limits = .negative
        paperCurve.limits = .paper
        paperCurve.showsLayers = false
        curve.onEdit = { [weak self] shape in self?.tookCurve(shape) }
        paperCurve.onEdit = { [weak self] shape in self?.tookPaperCurve(shape) }
        spectrum.onEdit = { [weak self] shape in self?.tookSpectrum(shape) }
        spectrum.onPointsEdit = { [weak self] rows in
            self?.tookSpectrumPoints(rows)
        }
        dyeGraph.flavor = .dye
        dyeGraph.setAXLabel("Dye density")
        dyeGraph.onPointsEdit = { [weak self] rows in self?.tookDyePoints(rows) }
        // A drag is one history entry however far it travels: the stroke opens on the grab, and
        // closes — recording the film as the pointer found it — when the pointer lifts.
        for graph in [curve, paperCurve] {
            graph.onEditBegan = { [weak self] in self?.beginStroke() }
            graph.onEditEnded = { [weak self] in
                self?.endStroke()
                self?.refreshRows()
            }
        }
        for graph in [spectrum, dyeGraph] {
            graph.onEditBegan = { [weak self] in self?.beginStroke() }
            graph.onEditEnded = { [weak self] in
                self?.endStroke()
                self?.refreshRows()
            }
        }

        for view in [spectrumTitle, spectrum, dyeTitle, dyeGraph, curveTitle,
                     curve, paperTitle, paperCurve] as [PlatformView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            previewPane.addSubview(view)
        }
    }

    private func tookCurve(_ shape: CurveShape) {
        draft.baseDensity = shape.dMin
        draft.contrast = shape.gamma
        draft.toe = shape.toe
        draft.toeWidth = shape.toeWidth
        draft.shoulder = shape.shoulder
        draft.shoulderWidth = shape.shoulderWidth
        draftChanged(rebuildRows: false)
    }

    private func tookSpectrum(_ shape: SpectrumShape) {
        if shape.isMonochrome {
            draft.monoWeights = shape.monoWeights
        } else {
            draft.peaksNM = shape.peaks
            draft.widthsNM = shape.widths
        }
        draftChanged(rebuildRows: false)
    }

    private func tookSpectrumPoints(_ rows: [[SpectralControlPoint]]) {
        draft.sensitivityPoints = rows
        draftChanged(rebuildRows: false)
    }

    private func tookDyePoints(_ rows: [[SpectralControlPoint]]) {
        draft.dyePoints = rows
        draftChanged(rebuildRows: false)
    }

    private func tookPaperCurve(_ shape: CurveShape) {
        draft.paperDMin = shape.dMin
        draft.paperContrast = shape.gamma
        draft.paperToe = shape.toe
        draft.paperToeWidth = shape.toeWidth
        draft.paperShoulder = shape.shoulder
        draft.paperShoulderWidth = shape.shoulderWidth
        draftChanged(rebuildRows: false)
    }

    // MARK: - The library

    private func reloadLibrary() {
        films = CustomStockStore.mine()
        for view in libraryViews {
            library.column.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        libraryViews = []
        libraryRows = []

        func add(_ row: FormRowView) {
            row.translatesAutoresizingMaskIntoConstraints = false
            library.column.addArrangedSubview(row)
            row.widthAnchor.constraint(
                equalTo: library.column.widthAnchor).isActive = true
            libraryViews.append(row)
        }

        let heading = CapsLabel("My Films")
        heading.translatesAutoresizingMaskIntoConstraints = false
        library.column.addArrangedSubview(heading)
        libraryViews.append(heading)

        for film in films {
            let row = OptionRow(title: film.name,
                                detail: film.subtitle ?? film.id) { [weak self] in
                self?.open(film)
            }
            add(row)
            libraryRows.append(row)
        }
        if films.isEmpty {
            add(NoteRow("Nothing here yet. Everything below makes a film; "
                        + "Save keeps it."))
        }

        add(ButtonBarRow([
            (title: "New", symbol: "plus", enabled: { true },
             action: { [weak self] in self?.newFilm() }),
            (title: "Duplicate", symbol: "plus.square.on.square",
             enabled: { [weak self] in self?.editingID != nil },
             action: { [weak self] in self?.duplicate() }),
        ]))
        // One to a row: a pair of these two titles does not fit the column's width on the iPad, and
        // a button that wraps appears as "Import / …".
        add(ButtonRow("Import…", symbol: "square.and.arrow.down") {
            [weak self] in self?.importPack()
        })
        add(ButtonRow("Export…", symbol: "square.and.arrow.up",
                      enabled: { [weak self] in
                          self?.editingID != nil
                              && self?.draftBlocksExport == false
                      }) {
            [weak self] in self?.exportPack()
        })
        add(ButtonRow("Delete Film", destructive: true,
                      enabled: { [weak self] in self?.editingID != nil }) {
            [weak self] in self?.deleteFilm()
        })

        // Each remaining pack opens as an unsaved editable study. Pack lineage is retained for
        // export validation. Built-in films appear only when `offersBuiltInFilms` is enabled.
        studyFilms = FilmStock.presetDefinitions
            .filter { id, definition in
                definition.isExample != true
                    && !id.hasPrefix("\(CustomStockStore.mineID).")
                    && (Self.offersBuiltInFilms || !Self.isBuiltIn(id))
            }
            .map { (id: $0.key, definition: $0.value) }
            .sorted { $0.definition.name < $1.definition.name }
        studyRows = []
        if !studyFilms.isEmpty {
            let heading = CapsLabel("Library")
            heading.translatesAutoresizingMaskIntoConstraints = false
            library.column.addArrangedSubview(heading)
            libraryViews.append(heading)
            for film in studyFilms {
                let row = OptionRow(title: film.definition.name,
                                    detail: film.definition.subtitle ?? film.id) {
                    [weak self] in self?.study(film.id, film.definition)
                }
                add(row)
                studyRows.append(row)
            }
        }
        markSelection()
    }

    private func markSelection() {
        for (row, film) in zip(libraryRows, films) {
            row.setSelected(film.id == editingID)
        }
        for (row, film) in zip(studyRows, studyFilms) {
            row.setSelected(editingID == nil && film.id == studyID)
        }
    }

    private func study(_ id: String, _ definition: FilmStockDefinition) {
        draft = CustomStockDraft.recovered(from: definition, lineage: id)
        editingID = nil
        studyID = id
        savedDraft = CustomStockDraft(name: "")
        adopted()
    }

    private func open(_ film: FilmStockDefinition) {
        draft = CustomStockDraft.recovered(from: film)
        editingID = film.id
        studyID = nil
        savedDraft = draft
        adopted()
    }

    private func newFilm() {
        draft = CustomStockDraft()
        editingID = nil
        studyID = nil
        // A new film is dirty from the moment it exists: there is nothing on disk it matches.
        savedDraft = CustomStockDraft(name: "")
        adopted()
    }

    private func duplicate() {
        var copy = draft
        copy.name = draft.name + " Copy"
        draft = copy
        editingID = nil
        savedDraft = CustomStockDraft(name: "")
        adopted()
    }

    private func adopted() {
        // History belongs to one film; what was done to the last one is not undoable into this one.
        undoStack.removeAll()
        redoStack.removeAll()
        strokeBase = nil
        openedDraft = draft
        buildForm()
        syncCurves()
        markSelection()
        renderPreview()
        updateStatus()
    }

    // MARK: - Saving

    private func save() {
        let id = editingID ?? CustomStockDraft.suggestedID(for: draft.name)
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            report("A film needs a name", "Give it one and Save again.")
            return
        }
        do {
            try CustomStockStore.save(draft.definition(id: id),
                                      replacingExisting: true)
            StockPacks.refresh()
            editingID = id
            studyID = nil
            savedDraft = draft
            openedDraft = draft
            reloadLibrary()
            updateStatus()
            onLibraryChanged?()
        } catch {
            report("That film could not be saved", "\(error)")
        }
    }

    private func deleteFilm() {
        guard let editingID else { return }
        do {
            try CustomStockStore.delete(stockID: editingID)
            StockPacks.refresh()
            onLibraryChanged?()
            reloadLibrary()
            newFilm()
        } catch {
            report("That film could not be deleted", "\(error)")
        }
    }

    private func updateStatus() {
        // A film that has never been saved is not "edited" — there is nothing on disk for it to
        // differ from, which is exactly what "unsaved" already says.
        if editingID != nil {
            let name = draft.name.trimmingCharacters(in: .whitespaces)
            statusLabel.textValue = isDirty ? "\(name) · edited" : name
        } else {
            statusLabel.textValue = "Unsaved film"
        }
        saveButton.isEnabled = isDirty || editingID == nil
        undoButton.isEnabled = !undoStack.isEmpty
        redoButton.isEnabled = !redoStack.isEmpty
        resetButton.isEnabled = draft != openedDraft
        root.relayout()
    }

    // MARK: - The preview

    private static let renderQueue = DispatchQueue(label: "film-workshop-preview",
                                                   qos: .userInitiated)
    private var renderGeneration = 0
    private var pendingRender: DispatchWorkItem?

    private var lightRendered = false

    private func renderPreview() {
        pendingRender?.cancel()
        renderGeneration += 1
        let generation = renderGeneration
        let stock = draft.definition(id: editingID ?? "workshop-preview").stock
        let needsLight = !lightRendered
        spinner.isSpinning = true

        let subject = ownScene
        let work = DispatchWorkItem { [weak self] in
            guard let scene = subject ?? Self.chart else {
                Task { @MainActor in self?.showNoChart() }
                return
            }
            var state = EditState()
            state.stockID = StockPreset.noFilmID
            let light = needsLight
                ? FilmRender.develop(scene, state: state)?.image.image : nil
            let developed = FilmRender.develop(scene, state: state,
                                               stock: stock)?.image.image

            Task { @MainActor in
                guard let self, generation == self.renderGeneration else { return }
                self.spinner.isSpinning = false
                if let light {
                    self.lightRendered = true
                    self.sceneImage.setImage(PlatformImage.from(light))
                }
                if let developed {
                    self.filmImage.setImage(PlatformImage.from(developed))
                }
            }
        }
        pendingRender = work
        Self.renderQueue.asyncAfter(deadline: .now() + 0.09, execute: work)
    }

    // MARK: - What the pictures show

    private func choosePicture() {
        #if canImport(UIKit)
        wants = .picture
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image])
        picker.allowsMultipleSelection = false
        picker.delegate = self
        present(picker, animated: true)
        #else
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.took(picture: url)
        }
        #endif
    }

    private func useChart() {
        guard ownScene != nil else { return }
        ownScene = nil
        ownName = nil
        ownAspect = nil
        chartButton.isEnabled = false
        sourceChanged()
    }

    static func isPicture(_ url: URL) -> Bool {
        let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        return type?.conforms(to: .image) ?? false
    }

    func took(picture url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            report("That picture could not be read",
                   "\(url.lastPathComponent) would not open.")
            return
        }
        let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        // A raw file needs its own type stated: the decoder is chosen by it, and sniffing an ARW
        // finds a TIFF and opens an empty picture.
        let hint = (type?.conforms(to: .rawImage) ?? false) ? type?.identifier : nil
        adopt(picture: data, hint: hint, named: url.lastPathComponent)
    }

    private func adopt(picture data: Data, hint: String?, named name: String) {
        spinner.isSpinning = true
        Self.renderQueue.async { [weak self] in
            let source = PhotoSource.raw(data: data, hint: hint)
                ?? PhotoSource.file(data: data)
            let scene = FilmRender.scene(source: source, state: EditState(),
                                         longEdge: StockTestChart.previewLongEdge)
            Task { @MainActor in
                guard let self else { return }
                guard let scene, scene.width > 0, scene.height > 0 else {
                    self.spinner.isSpinning = false
                    self.report("That picture could not be developed",
                                "\(name) is not a photograph this build can read.")
                    return
                }
                self.ownScene = scene
                self.ownName = name
                self.ownAspect = CGFloat(scene.width) / CGFloat(scene.height)
                self.chartButton.isEnabled = true
                self.sourceChanged()
            }
        }
    }

    private func sourceChanged() {
        lightRendered = false
        sceneCaption.textValue = ownName.map { "Light · \($0)" } ?? "Light"
        previewLayoutChanged()
        renderPreview()
    }

    private func previewLayoutChanged() {
        root.relayout()
        previewPane.relayout()
    }

    private func showNoChart() {
        spinner.isSpinning = false
        statusLabel.textValue = "No preview on this build."
        root.relayout()
    }

    private static let chart: FilmRender.Scene? =
        StockTestChart.scene(longEdge: StockTestChart.previewLongEdge)

    // MARK: - Changes

    private func draftChanged(rebuildRows: Bool = false) {
        if rebuildRows { buildForm() } else { refreshRows() }
        syncCurves()
        renderPreview()
        updateStatus()
    }

    private func syncCurves() {
        curve.shape = CurveShape(dMin: draft.baseDensity, gamma: draft.contrast,
                                 toe: draft.toe, toeWidth: draft.toeWidth,
                                 shoulder: draft.shoulder,
                                 shoulderWidth: draft.shoulderWidth)
        curve.showsLayers = !draft.isMonochrome
        curve.layerGammaTrim = draft.contrastTrim
        curve.layerDMinOffset = draft.kind == .colorNegative
            ? draft.maskOffsets : [0, 0, 0]

        paperCurve.shape = CurveShape(dMin: draft.paperDMin,
                                      gamma: draft.paperContrast,
                                      toe: draft.paperToe,
                                      toeWidth: draft.paperToeWidth,
                                      shoulder: draft.paperShoulder,
                                      shoulderWidth: draft.paperShoulderWidth)
        spectrum.shape = SpectrumShape(peaks: draft.peaksNM,
                                       widths: draft.widthsNM,
                                       monoWeights: draft.monoWeights,
                                       isMonochrome: draft.isMonochrome)
        // Drawn mode replaces the lobes with handles, and for a colour film puts the dye record
        // on screen under them; the healed accessors mean there is always a curve to show, even
        // just after the film's kind changed shape under the points.
        let drawn = draft.spectralModel == .drawn
        spectrum.points = drawn ? draft.drawnSensitivityPoints() : nil
        let showsDyes = drawn && !draft.isMonochrome
        if showsDyes { dyeGraph.points = draft.drawnDyePoints() }

        let prints = draft.kind == .colorNegative
        let wasPrinting = !paperCurve.isHidden
        let wasShowingDyes = !dyeGraph.isHidden
        paperTitle.isHidden = !prints
        paperCurve.isHidden = !prints
        dyeTitle.isHidden = !showsDyes
        dyeGraph.isHidden = !showsDyes
        // One graph more or fewer changes both what the column asks for and how the room in it is
        // shared.
        if wasPrinting != prints || wasShowingDyes != showsDyes {
            previewLayoutChanged()
        }
    }

    private func refreshRows() {
        for section in sections {
            for row in section.rows { row.refresh() }
        }
    }

    // MARK: - Packs

    private var draftBlocksExport: Bool {
        guard draft.spectralModel == .drawn,
              let lineage = draft.spectralLineage else { return false }
        return FilmStock.origin(of: lineage)?.isShareable != true
    }

    private func exportPack() {
        guard let editingID else { return }
        if isDirty { save() }
        // A stock out of a custom pack is known to the loader by the pack it came in, and that
        // qualified id is what the export gate reads the origin off.
        let loadedID = "\(CustomStockStore.mineID).\(editingID)"
        do {
            let file = try CustomStockStore.exportFile(
                stockIDs: [loadedID],
                name: draft.name.isEmpty ? "My Films" : draft.name)
            offer(file)
        } catch {
            report("That film could not be exported", "\(error)")
        }
    }

    private func offer(_ file: URL) {
        #if canImport(UIKit)
        let share = UIActivityViewController(activityItems: [file],
                                             applicationActivities: nil)
        // A popover has to come from somewhere; on an iPad with no bar button, the workshop's own
        // Save button is the nearest thing the user just touched.
        share.popoverPresentationController?.sourceView = saveButton
        share.popoverPresentationController?.sourceRect = saveButton.bounds
        present(share, animated: true)
        #else
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.lastPathComponent
        panel.allowedContentTypes = []
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.copyItem(at: file, to: destination)
        }
        #endif
    }

    private func importPack() {
        let type = UTType(filenameExtension: FilmStockPack.sealedPathExtension)
            ?? .data
        #if canImport(UIKit)
        wants = .pack
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [type])
        picker.allowsMultipleSelection = false
        picker.delegate = self
        present(picker, animated: true)
        #else
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [type]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.took(pack: url)
        }
        #endif
    }

    func took(pack url: URL) {
        do {
            let result = try CustomStockStore.importPack(from: url)
            onLibraryChanged?()
            reloadLibrary()
            report("Added \(result.name)",
                   result.stockNames.joined(separator: ", "))
        } catch {
            report("That pack could not be opened", "\(error)")
        }
    }

    // MARK: - Presenting

    private func close() {
        onClose?()
        onClose = nil
        #if canImport(UIKit)
        presentingViewController?.dismiss(animated: true)
        #else
        presentingViewController?.dismiss(self)
        #endif
    }

    private func report(_ title: String, _ message: String) {
        #if canImport(UIKit)
        let alert = UIAlertController(title: title, message: message,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
        #else
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.beginSheetModal(for: view.window ?? NSApp.keyWindow ?? NSWindow())
        #endif
    }
}

#if !canImport(UIKit)
/// Enables Undo and Redo menu items from the workshop's local stacks while its sheet is active.
extension FilmWorkshopController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(performUndo(_:)): return !undoStack.isEmpty
        case #selector(performRedo(_:)): return !redoStack.isEmpty
        default: return true
        }
    }
}
#endif

#if canImport(UIKit)
extension FilmWorkshopController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        // One delegate, two pickers: what was asked for decides what comes back.
        switch wants {
        case .pack: took(pack: url)
        case .picture: took(picture: url)
        }
    }
}
#endif
