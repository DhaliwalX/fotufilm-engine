#if canImport(UIKit)
import UIKit

#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmEditModel)
import FotufilmEditModel
#endif
#if canImport(FotufilmImaging)
import FotufilmImaging
#endif

/// A tab an app adds to the iPad's negative editor: its rows, what the status line says while it
/// shows, and what a tap on the picture and a layer over it do while it shows.
@MainActor
protocol SessionNegativeScanTab {
    var title: String { get }
    var status: String { get }
    func sections(for session: NegativeScanSession) -> [FormSectionView]
    func tapped(at point: CGPoint, in session: NegativeScanSession) async
    /// A picture laid over the positive at `longEdge`, framed as it is; nil for none.
    func overlay(for session: NegativeScanSession, longEdge: Int) async -> CGImage?
}

/// The iPad's scanned-negative editor, built from the session's own furniture: the picture on the
/// canvas, and a glass column of form sections beside it. Convert holds how the scan is read and
/// only the rows that reading uses; Frame swaps the canvas for the session's crop; the app's own
/// tabs follow.
final class SessionNegativeScanController: SessionViewController {
    /// The tabs an app adds after Convert and Frame.
    static var appTabs: [any SessionNegativeScanTab] = []

    private enum Tab: Hashable {
        case convert, frame, app(Int)

        @MainActor
        static var all: [Tab] {
            [.convert, .frame] + SessionNegativeScanController.appTabs.indices.map(Tab.app)
        }

        @MainActor
        var title: String {
            switch self {
            case .convert: return "Convert"
            case .frame: return "Frame"
            case let .app(index): return SessionNegativeScanController.appTabs[index].title
            }
        }

        @MainActor
        var app: (any SessionNegativeScanTab)? {
            guard case let .app(index) = self else { return nil }
            return SessionNegativeScanController.appTabs[index]
        }
    }

    private let session: NegativeScanSession
    private let lane = NegativeScanSession.Lane()
    private let frameLane = NegativeScanSession.Lane()
    private lazy var cropSource = ScanCropSource(session: session)

    private let root = WorkspaceView()
    private let canvasHost = SessionView()
    private let canvas = SessionCanvasView(frame: .zero)
    private lazy var cropCanvas = CropCanvasView(model: cropSource)
    private let panel = GlassPanelView(radius: Chrome.panelRadius)
    private let tabs = SessionTabStrip(frame: .zero)
    private let form = ScrollColumn(inset: 14, pad: 8, bottom: 24)
    private let titleLabel = makeLabel("Negative", size: 15, weight: .semibold)
    private let statusLabel = makeLabel("", size: 11, color: .secondaryText)
    private let spinner = SessionSpinner()
    private var undoButton: SessionButton!
    private var redoButton: SessionButton!
    private var exportButton: SessionButton!
    private var doneButton: SessionButton!

    private var shownTab = Tab.convert
    private var sections: [FormSectionView] = []
    /// What decides which rows the form holds; a change of it builds the form again.
    private struct Shape: Equatable {
        var tab: Tab, film: Bool, colour: Bool, lights: [String]
    }
    private var builtFor: Shape?
    private var picking = false
    private var positive: UIImage?
    private var negative: UIImage?

    init(source: NegativeScanSource) {
        session = NegativeScanSession(source: source)
        super.init()
        modalPresentationStyle = .fullScreen
    }

    /// The Convert Negative menu, opening what is picked here.
    static func openingMenu(from presenter: @escaping () -> UIViewController?) -> UIMenu {
        NegativeScanOpening.menu(from: presenter) { SessionNegativeScanController(source: $0) }
    }

    // MARK: - Building

    override func loadView() {
        root.frame = CGRect(x: 0, y: 0, width: 1180, height: 820)
        root.backingLayer.backgroundColor = Chrome.canvasBackground.cgColor

        undoButton = SessionButton(title: "Undo", symbol: "arrow.uturn.backward") {
            [weak self] in self?.session.undo()
        }
        redoButton = SessionButton(title: "Redo", symbol: "arrow.uturn.forward") {
            [weak self] in self?.session.redo()
        }
        exportButton = SessionButton(title: "Export…", prominent: true) { [weak self] in
            self?.exportTapped()
        }
        doneButton = SessionButton(title: "Done") { [weak self] in self?.close() }

        for view in [canvasHost, panel, titleLabel, statusLabel, spinner, undoButton, redoButton,
                     exportButton, doneButton] as [PlatformView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            root.addSubview(view)
        }
        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvasHost.addSubview(canvas)
        canvasHost.pin(canvas)

        tabs.setTitles(Tab.all.map(\.title))
        tabs.selectedIndex = Tab.all.firstIndex(of: shownTab) ?? 0
        tabs.onSelect = { [weak self] index in
            guard let self, Tab.all.indices.contains(index) else { return }
            select(Tab.all[index])
        }
        let stack = makeStack(.vertical, spacing: 10)
        stack.addArrangedSubview(tabs)
        stack.addArrangedSubview(form)
        panel.addSubview(stack)
        panel.pin(stack, inset: 12)

        root.onLayout = { [weak self] in self?.layout() }
        view = root

        session.onChange = { [weak self] in self?.recipeChanged() }
        open()
    }

    private func open() {
        spinner.isSpinning = true
        Task {
            do {
                try await session.open()
            } catch {
                spinner.isSpinning = false
                report(error)
            }
        }
    }

    // MARK: - Layout

    private static let formWidth: CGFloat = 340

    private func layout() {
        let bounds = root.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let top = root.safeAreaInsets.top
        let bottom = root.safeAreaInsets.bottom
        titleLabel.frame = CGRect(x: 22, y: top + 14, width: 260,
                                  height: titleLabel.compressedSize.height)
        var x = bounds.width - 20
        for button in [doneButton, exportButton, redoButton, undoButton] as [SessionButton] {
            let size = button.compressedSize
            x -= size.width
            button.frame = CGRect(x: x, y: top + 10, width: size.width, height: size.height)
            x -= button === exportButton ? 16 : 8
        }
        let statusSize = statusLabel.compressedSize
        statusLabel.frame = CGRect(x: max(titleLabel.frame.minX + 120, x - statusSize.width - 6),
                                   y: top + 16, width: statusSize.width, height: statusSize.height)

        let header = top + 46
        let inset: CGFloat = 16
        let height = max(bounds.height - header - bottom - inset, 1)
        let formX = bounds.width - inset - Self.formWidth
        panel.frame = CGRect(x: formX, y: header, width: Self.formWidth, height: height)
        canvasHost.frame = CGRect(x: inset, y: header, width: max(formX - inset * 2, 120),
                                  height: height)
        let spinnerSize = spinner.compressedSize
        spinner.frame = CGRect(x: canvasHost.frame.midX - spinnerSize.width / 2,
                               y: canvasHost.frame.midY - spinnerSize.height / 2,
                               width: spinnerSize.width, height: spinnerSize.height)
    }

    // MARK: - The form

    private func select(_ next: Tab) {
        guard next != shownTab else { return }
        shownTab = next
        if picking { endPicking() }
        statusLabel.text = restingStatus

        rebuild()
        swapCanvas()
        develop()
    }

    private func setSections(_ replacements: [FormSectionView]) {
        for view in form.column.arrangedSubviews {
            form.column.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        sections = replacements
        for section in replacements {
            form.column.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: form.column.widthAnchor).isActive = true
        }
    }

    /// Rebuilds the rows when the reading changes which of them apply; refreshes them in place
    /// otherwise, because rebuilding under a slider takes the slider away mid-drag.
    private func rebuild() {
        let shape = Shape(tab: shownTab, film: session.recipe.conversion == .film,
                          colour: session.carriesColour, lights: session.lightFrames.map(\.id))
        if let builtFor, builtFor == shape {
            for section in sections { for row in section.rows { row.refresh() } }
            return
        }
        builtFor = shape
        switch shownTab {
        case .convert: setSections(convertSections(film: shape.film, colour: shape.colour))
        case .frame: setSections(frameSections())
        case .app: setSections(shownTab.app?.sections(for: session) ?? [])
        }
        for section in sections { section.appear(offset: 8) }
    }

    private func convertSections(film: Bool, colour: Bool) -> [FormSectionView] {
        let session = session
        let reading = FormSectionView(title: "Reading")
        reading.add(PopUpRow("Method", options: [("Automatic", false), ("Film", true)],
                             get: { session.recipe.conversion == .film },
                             set: { film in
            session.read(as: film ? .film(session.recipe.stockID)
                                  : .automatic(monochrome: session.recipe.monochrome))
        }))
        if film {
            reading.add(PopUpRow("Film", options: NegativeScanSession.films.map { ($0.name, $0.id) },
                                 get: { session.recipe.stockID },
                                 set: { session.read(as: .film($0)) }))
            reading.add(PopUpRow("Output Medium",
                                 options: session.papers.map { ($0.name, $0.rawValue) },
                                 get: { session.paper?.rawValue ?? "" },
                                 set: { id in session.edit { $0.paperID = id } }))
        } else {
            reading.add(ToggleRow("Black & White", get: { session.recipe.monochrome },
                                  set: { session.read(as: .automatic(monochrome: $0)) }))
        }
        var result = [reading]

        if film {
            let base = FormSectionView(title: "Film Base")
            base.add(ButtonBarRow([
                (title: "Pick from Frame", symbol: "eyedropper", enabled: { true },
                 action: { [weak self] in self?.beginPicking() }),
                (title: "Measure", symbol: nil, enabled: { session.borderIsSampled },
                 action: { session.measureBorderAutomatically() }),
            ]))
            result.append(base)
        }

        let light = FormSectionView(title: "Light")
        let exposure = NegativeScanRecipe.exposureRange
        let tone = NegativeScanRecipe.toneRange
        let signed = Double(tone.lowerBound)...Double(tone.upperBound)
        let plain = { (value: Double) in String(format: "%+.2f", value) }
        light.add(slider("Exposure", Double(exposure.lowerBound)...Double(exposure.upperBound),
                         \.exposure, display: { String(format: "%+.1f EV", $0) }))
        if colour {
            light.add(slider("Contrast", signed, \.contrast, display: plain))
        } else {
            light.add(SliderRow("Paper Grade", range: NegativeScanRecipe.grades,
                                display: { String(format: "%.1f", $0) },
                                get: { NegativeScanRecipe.grade(forContrast: session.recipe.contrast) },
                                set: { grade in
                session.edit { $0.contrast = NegativeScanRecipe.contrast(forGrade: grade) }
            }, began: { session.beginStroke() }, ended: { session.endStroke() }))
        }
        light.add(slider("Highlights", signed, \.highlights, display: plain))
        light.add(slider("Shadows", signed, \.shadows, display: plain))
        if colour {
            let range = NegativeScanRecipe.colourRange
            let span = Double(range.lowerBound)...Double(range.upperBound)
            light.add(slider("Warmth", span, \.warmth, display: plain))
            light.add(slider("Tint", span, \.tint, display: plain))
        }
        light.add(ButtonRow("Reset", symbol: "arrow.counterclockwise", bordered: false,
                            enabled: { session.isAdjusted },
                            action: { session.resetAdjustments() }))
        result.append(light)

        let source = FormSectionView(title: "Light Source")
        source.add(PopUpRow<String?>(nil, options: [("As Scanned", nil)]
                                        + session.lightFrames.map { ($0.name, $0.id) },
                                     get: { session.recipe.lightFrameID },
                                     set: { session.useLightFrame($0) }))
        source.add(ButtonBarRow([
            (title: "Add from Photos", symbol: "photo.on.rectangle", enabled: { true },
             action: { [weak self] in self?.addLightFrame(fromFiles: false) }),
            (title: "Files", symbol: "folder", enabled: { true },
             action: { [weak self] in self?.addLightFrame(fromFiles: true) }),
        ]))
        result.append(source)

        let roll = FormSectionView(title: "Roll")
        roll.add(ButtonBarRow([
            (title: "Copy Conversion", symbol: "doc.on.doc", enabled: { true },
             action: { session.copyConversion() }),
            (title: "Paste", symbol: "doc.on.clipboard",
             enabled: { session.canPasteConversion },
             action: { session.pasteConversion() }),
        ]))
        result.append(roll)
        return result
    }

    /// Measures a photograph of the bare light source and evens the scan out by it.
    private func addLightFrame(fromFiles: Bool) {
        let add: (NegativeScanSource) -> Void = { [weak self] source in
            guard let self else { return }
            Task {
                do {
                    try await self.session.addLightFrame(from: source)
                } catch {
                    self.report(error)
                }
            }
        }
        if fromFiles {
            NegativeScanOpening.pickFromFiles(from: self, then: add)
        } else {
            NegativeScanOpening.pickFromPhotos(from: self, then: add)
        }
    }

    private func slider(_ title: String, _ range: ClosedRange<Double>,
                        _ path: WritableKeyPath<NegativeScanRecipe, Float>,
                        display: @escaping (Double) -> String) -> SliderRow {
        let session = session
        return SliderRow(title, range: range, display: display,
                         get: { Double(session.recipe[keyPath: path]) },
                         set: { value in session.edit { $0[keyPath: path] = Float(value) } },
                         began: { session.beginStroke() },
                         ended: { session.endStroke() })
    }

    /// The status line when nothing is under way: what the shown app tab says.
    private var restingStatus: String {
        shownTab.app?.status ?? ""
    }

    private func frameSections() -> [FormSectionView] {
        let session = session
        let source = cropSource
        let orientation = FormSectionView(title: "Orientation")
        orientation.add(ButtonBarRow([
            (title: "Rotate", symbol: "rotate.left", enabled: { true },
             action: { session.edit { $0.quarterTurns = ($0.quarterTurns + 3) % 4; $0.crop = .full } }),
            (title: "Flip",
             symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right",
             enabled: { true }, action: { session.edit { $0.toggleMirror() } }),
        ]))
        let straighten = NegativeScanRecipe.straightenRange
        orientation.add(SliderRow("Straighten", range: straighten,
                                  display: { String(format: "%+.1f°", $0) },
                                  get: { session.recipe.straighten },
                                  set: { degrees in session.edit { $0.straighten = degrees } },
                                  began: { session.beginStroke() },
                                  ended: { session.endStroke() }))
        let crop = FormSectionView(title: "Crop")
        crop.add(PopUpRow("Aspect", options: AspectOption.allCases.map { ($0.rawValue, $0) },
                          get: { source.cropAspect },
                          set: { [weak self] aspect in
            source.cropAspect = aspect
            self?.applyAspect(aspect)
        }))
        crop.add(ButtonBarRow([
            (title: "Find Frame", symbol: "viewfinder", enabled: { true },
             action: { [weak self] in self?.findFrame() }),
            (title: "Reset", symbol: "arrow.counterclockwise", enabled: {
                let recipe = session.recipe
                return recipe.crop != .full || recipe.quarterTurns != 0 || recipe.mirrored
                    || recipe.straighten != 0
            }, action: {
                source.cropAspect = .free
                session.edit {
                    $0.crop = .full
                    $0.quarterTurns = 0
                    $0.mirrored = false
                    $0.straighten = 0
                }
            }),
        ]))
        return [orientation, crop]
    }

    /// Crops to the exposed picture, when one stands out from the rebate and the holder.
    private func findFrame() {
        Task {
            guard let area = await session.detectFrame() else {
                statusLabel.text = "No frame edge found"
                root.setNeedsLayout()
                return
            }
            cropSource.cropAspect = .free
            session.edit { $0.crop = area }
        }
    }

    /// Holds the crop to the aspect, centred in the frame.
    private func applyAspect(_ aspect: AspectOption) {
        guard let size = cropSource.cropPicture?.size, size.width > 0, size.height > 0,
              let ratio = aspect.ratio(for: size) else {
            cropCanvas.cropChangedExternally()
            return
        }
        let imageRatio = size.width / size.height
        let w = ratio < imageRatio ? ratio / imageRatio : 1
        let h = ratio < imageRatio ? 1 : imageRatio / ratio
        session.edit { $0.crop = .init(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h) }
    }

    // MARK: - The recipe

    private var lastRecipe: NegativeScanRecipe?

    private func recipeChanged() {
        let recipe = session.recipe
        let previous = lastRecipe
        lastRecipe = recipe
        titleLabel.text = session.scan == nil ? "Negative" : session.reading.name
        undoButton.isEnabled = session.canUndo
        redoButton.isEnabled = session.canRedo
        rebuild()
        guard recipe != previous else { return }
        if previous?.crop != recipe.crop || previous?.quarterTurns != recipe.quarterTurns
            || previous?.mirrored != recipe.mirrored || previous?.straighten != recipe.straighten
            || previous?.lightFrameID != recipe.lightFrameID {
            cropSource.token = UUID()
            developNegative()
        }
        develop()
    }

    private var previewLongEdge: Int {
        let side = max(canvasHost.bounds.width, canvasHost.bounds.height)
            * traitCollection.displayScale
        return min(2400, max(800, Int(side)))
    }

    private func develop() {
        guard !picking else { return }
        let framing = shownTab == .frame
        let longEdge = previewLongEdge
        Task {
            guard let result = await session.preview(on: framing ? frameLane : lane,
                                                     longEdge: longEdge, cropped: !framing)
            else { return }
            spinner.isSpinning = false
            switch result {
            case let .success(print):
                statusLabel.text = restingStatus
                let image = UIImage(cgImage: print)
                if framing {
                    cropSource.picture = image
                    cropCanvas.imageChanged()
                    cropCanvas.cropChangedExternally()
                } else {
                    positive = image
                    showPositive()
                }
            case let .failure(error):
                report(error)
            }
        }
    }

    private func developNegative() {
        let longEdge = previewLongEdge
        Task {
            negative = await session.negative(longEdge: longEdge).map(UIImage.init(cgImage:))
            showPositive()
        }
    }

    /// The positive on the canvas, with the scan behind it for a press to reveal.
    private func showPositive() {
        guard let positive, !picking, shownTab != .frame else { return }
        canvas.show(image: positive, original: negative)
        let tab = shownTab
        guard let app = tab.app else {
            canvas.onSample = nil
            return
        }
        canvas.onSample = { [weak self] point in
            guard let self else { return }
            Task { await app.tapped(at: point, in: self.session) }
        }
        let longEdge = previewLongEdge
        Task {
            guard let layer = await app.overlay(for: session, longEdge: longEdge),
                  shownTab == tab, !picking, self.positive === positive else { return }
            let size = positive.size
            let marked = UIGraphicsImageRenderer(size: size, format: positive.imageRendererFormat)
                .image { _ in
                    positive.draw(in: CGRect(origin: .zero, size: size))
                    UIImage(cgImage: layer).draw(in: CGRect(origin: .zero, size: size))
                }
            canvas.show(image: marked, original: negative)
        }
    }

    private func swapCanvas() {
        let next: PlatformView = shownTab == .frame ? cropCanvas : canvas
        guard next.superview !== canvasHost else { return }
        for view in canvasHost.subviews { view.removeFromSuperview() }
        next.translatesAutoresizingMaskIntoConstraints = false
        canvasHost.addSubview(next)
        canvasHost.pin(next)
        next.appear(offset: 0)
    }

    // MARK: - Film base

    /// Shows the whole negative, and takes the next tap on it as clear film.
    private func beginPicking() {
        guard !picking else { return }
        picking = true
        lane.cancel()
        statusLabel.text = "Tap clear film between frames"
        let longEdge = previewLongEdge
        Task {
            guard let whole = await session.negative(longEdge: longEdge, cropped: false),
                  picking else { return }
            canvas.show(image: UIImage(cgImage: whole), original: nil)
        }
        canvas.onSample = { [weak self] point in self?.picked(point) }
    }

    private func picked(_ point: CGPoint) {
        do {
            try session.pickBorder(at: point, cropped: false)
            endPicking()
        } catch {
            report(error)
        }
    }

    private func endPicking() {
        guard picking else { return }
        picking = false
        canvas.onSample = nil
        statusLabel.text = restingStatus
        showPositive()
        develop()
    }

    // MARK: - Leaving

    private func exportTapped() {
        guard session.scan != nil else { return }
        let sheet = NegativeExportSheet(session: session)
        sheet.modalPresentationStyle = .formSheet
        present(sheet, animated: true)
    }

    private func close() {
        lane.cancel()
        frameLane.cancel()
        Task {
            await session.close()
            presentingViewController?.dismiss(animated: true)
        }
    }

    private func report(_ error: Error) {
        statusLabel.text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        root.setNeedsLayout()
    }
}

/// The scan's framing as the session's crop canvas reads it.
@MainActor
private final class ScanCropSource: CropCanvasSource {
    private let session: NegativeScanSession
    /// The whole frame of the current framing, printed.
    var picture: UIImage?
    var cropAspect = AspectOption.free
    var token = UUID()

    init(session: NegativeScanSession) {
        self.session = session
    }

    var cropPicture: PlatformImage? { picture }
    var cropRectangle: CGRect? { session.recipe.crop.unitRect }
    var cropCorners: QuadrilateralCrop? { nil }
    var cropToken: UUID { token }

    func commitCrop(rectangle: CGRect?, corners: QuadrilateralCrop?) {
        session.edit { $0.crop = rectangle.map(NegativeScanRecipe.Area.init) ?? .full }
    }
}

/// File type for a converted scan, in the session's export sheet.
private final class NegativeExportSheet: ExportSheetController {
    private let session: NegativeScanSession
    private let lane = NegativeScanSession.Lane()
    private var format = NegativeScan.Format.jpeg
    private var rows: [(format: NegativeScan.Format, row: OptionRow)] = []

    init(session: NegativeScanSession) {
        self.session = session
        super.init(heading: "Export Photo")
        if session.paper == .labScan { format = .tiff }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let fileType = FormSectionView(title: "File Type")
        rows = NegativeScan.Format.allCases.map { candidate in
            let row = OptionRow(title: candidate.title, detail: nil) { [weak self] in
                self?.format = candidate
                self?.sync()
            }
            fileType.add(row)
            return (candidate, row)
        }
        setSections([fileType])
        sync()
    }

    private func sync() {
        for entry in rows { entry.row.setSelected(entry.format == format) }
    }

    override func export() {
        guard let presenter = presentingViewController else { return }
        Self.deliver(session, as: format, lane: lane, from: presenter)
    }

    /// Writes the positive and offers it through the share sheet, once the export is allowed.
    private static func deliver(_ session: NegativeScanSession, as format: NegativeScan.Format,
                                lane: NegativeScanSession.Lane, from presenter: UIViewController) {
        guard ProGate.allowExport(stockID: session.exportStockID, resume: { [weak presenter] in
            guard let presenter else { return }
            deliver(session, as: format, lane: lane, from: presenter)
        }) else { return }
        Task {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(NegativeScanSession.exportName)
                .appendingPathExtension(format.fileExtension)
            do {
                try await session.export(as: format, to: url, lane: lane)
            } catch {
                return
            }
            let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            share.popoverPresentationController?.sourceView = presenter.view
            share.popoverPresentationController?.sourceRect = CGRect(
                x: presenter.view.bounds.maxX - 80, y: presenter.view.safeAreaInsets.top + 20,
                width: 1, height: 1)
            presenter.present(share, animated: true)
        }
    }
}

#endif
