import AVFoundation
import Combine
import CoreGraphics
import Foundation
import QuartzCore
import UniformTypeIdentifiers

#if canImport(UIKit)
import PhotosUI
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// The desktop session: one canvas with the film on one side of it and the adjustments on the
/// other. Both columns run the full height of the window, flush to its edges, and the photograph is
/// fitted into what they leave.
///
/// It is the same class on the Mac and on the iPad. What differs is only what each platform does
/// not have the other's version of: an open panel, a menu bar, a hardware Return.
final class DesktopEditorViewController: SessionViewController {
    let model = DesktopEditorModel()

    private lazy var workspace = WorkspaceView()
    private lazy var stockSidebar = StockSidebarViewController(model: model)
    private lazy var inspector = InspectorViewController(model: model)
    private lazy var advisory = CanvasAdvisoryView(model: model)
    private let stockPanel = GlassPanelView(radius: 0)
    private let inspectorPanel = GlassPanelView(radius: 0)
    private let railPanel = GlassPanelView(radius: 0)

    private let canvasHost = SessionView()
    private lazy var zoomCanvas = SessionCanvasView()
    private lazy var cropCanvas = CropCanvasView(model: model)
    private var videoPreview: VideoPreviewViewController?
    private lazy var emptyState = EmptyStateView { [weak self] in
        #if canImport(UIKit)
        self?.presentPhotoPicker()
        #else
        self?.presentOpenPanel()
        #endif
    }
    private var currentCanvas: PlatformView?
    private var videoIdentity = ""

    private var intent = PanelIntent()
    private var roomyIntent = PanelIntent()
    private var settledFit: Fit?

    private struct PanelIntent: Equatable {
        var stocks = true
        /// Whether the film column is the named list rather than the strip of prints.
        var stocksListed = true
        var inspector = true
    }
    private var panelBeforeCrop = InspectorPanel.film
    private var zoom: CGFloat = 1
    private var lastResetToken: UUID?

    private var observation: ObservationLoop?
    private var settingsObserver: AnyCancellable?
    private var filmModelObserver: NSObjectProtocol?
    private var packsObserver: NSObjectProtocol?
    private var proAccessObserver: NSObjectProtocol?
    private var sheetUp = false
    private var histogramPanel: SessionHistogramPanelView?
    var isHistogramShown: Bool { histogramPanel != nil }
    /// Read by the toolbar, which is built next door.
    let zoomLabel = makeLabel("Fit", size: 11, monospacedDigits: true)
    let pixelLabel = makeLabel("", size: 11, color: .secondaryText,
                               monospacedDigits: true)

    #if canImport(UIKit)
    private lazy var padStockItem = padToolbarItem(
        symbol: "sidebar.leading", title: "Film Stocks",
        action: #selector(toggleStockSidebar(_:)))
    private lazy var padOpenPhotoItem = UIBarButtonItem(
        title: "Open Photo", style: .plain, target: self,
        action: #selector(openFromLibrary(_:)))
    private lazy var padOpenFilesItem = padToolbarItem(
        symbol: "folder", title: "Open from Files",
        action: #selector(openDocument(_:)))
    private lazy var padHistogramItem = padToolbarItem(
        symbol: "waveform", title: "Histogram",
        action: #selector(toggleHistogram(_:)))
    private lazy var padUndoItem = padToolbarItem(
        symbol: "arrow.uturn.backward", title: "Undo",
        action: #selector(performUndo(_:)))
    private lazy var padRedoItem = padToolbarItem(
        symbol: "arrow.uturn.forward", title: "Redo",
        action: #selector(performRedo(_:)))
    private lazy var padResetItem = padToolbarItem(
        symbol: "arrow.counterclockwise", title: "Reset",
        action: #selector(resetAllEdits(_:)))
    private lazy var padExportItem = padToolbarItem(
        symbol: "square.and.arrow.up", title: "Export",
        action: #selector(exportDocument(_:)))
    private lazy var padInspectorItem = padToolbarItem(
        symbol: "sidebar.trailing", title: "Adjustments",
        action: #selector(toggleInspectorPanel(_:)))
    private lazy var padSettingsItem = padToolbarItem(
        symbol: "gearshape", title: "Settings",
        action: #selector(openSettings(_:)))
    #endif

    private static let stockPanelWidth = StockSidebarViewController.panelWidth
    private static let inspectorWidth: CGFloat = 330
    private static let railWidth: CGFloat = 46
    private static let minimumPicture: CGFloat = 420

    private enum Fit {
        /// Room for the named film list and the open inspector either side of a full picture.
        case desk
        /// Room for the strip of prints and the open inspector, but not the list.
        case narrow
        /// Room for the picture and whichever one panel is wanted, floating over it.
        case tight
    }

    private static let deskWidth =
        stockPanelWidth + 12 + minimumPicture + inspectorWidth + 12
    private static let narrowWidth =
        StockSidebarViewController.stripWidth + 12 + minimumPicture + inspectorWidth + 12

    private var fit: Fit? {
        let width = workspace.bounds.width
        guard width > 0 else { return nil }
        if width >= Self.deskWidth { return .desk }
        if width >= Self.narrowWidth { return .narrow }
        return .tight
    }

    // MARK: - Building

    override func loadView() {
        workspace.backingLayer.backgroundColor = Chrome.canvasBackground.cgColor

        // The canvas and the columns above it are placed by frame in `layoutPanels`, so they keep
        // the autoresizing translation their subviews' constraints hang off.
        workspace.addSubview(canvasHost)

        addChild(stockSidebar)
        stockSidebar.onOpenWorkshop = { [weak self] in
            self?.openFilmWorkshop(nil)
        }
        #if canImport(UIKit)
        stockSidebar.onUpgrade = { ProGate.present() }
        #endif
        stockPanel.content.addSubview(stockSidebar.view)
        stockSidebar.view.translatesAutoresizingMaskIntoConstraints = false
        stockPanel.content.pin(stockSidebar.view)
        workspace.addSubview(stockPanel)

        addChild(inspector)
        inspectorPanel.content.addSubview(inspector.view)
        inspector.view.translatesAutoresizingMaskIntoConstraints = false
        inspectorPanel.content.pin(inspector.view)
        inspector.onPanelChanged = { [weak self] panel in
            self?.inspectorPanelChanged(panel)
        }
        workspace.addSubview(inspectorPanel)

        buildRail()
        workspace.addSubview(railPanel)
        workspace.addSubview(advisory)

        workspace.onLayout = { [weak self] in self?.layoutPanels(animated: false) }
        workspace.onDrop = { [weak self] urls in self?.dropped(urls) ?? false }

        view = workspace
        #if canImport(UIKit)
        for child in [stockSidebar, inspector] as [PlatformViewController] {
            child.didMove(toParent: self)
        }
        #endif
    }

    private func buildRail() {
        let stack = makeStack(.vertical, spacing: 6, alignment: .center)
        railPanel.content.addSubview(stack)
        railStackTop = stack.topAnchor.constraint(
            equalTo: railPanel.content.topAnchor, constant: 8)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                equalTo: railPanel.content.leadingAnchor),
            stack.trailingAnchor.constraint(
                equalTo: railPanel.content.trailingAnchor),
            railStackTop!,
        ])
        rebuildRail(stack: stack)
        railStack = stack
    }

    private var railStack: PlatformStackView?
    private var railStackTop: NSLayoutConstraint?
    private var railPanels: [InspectorPanel] = []

    private func rebuildRail(stack: PlatformStackView) {
        let available = InspectorPanel.available(video: model.hasVideo)
        guard available != railPanels else { return }
        railPanels = available
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for entry in available {
            let button = IconButton(symbol: entry.symbol,
                                    description: entry.title) { [weak self] in
                self?.inspector.panel = entry
                self?.setPanels(animated: true) { $0.inspector = true }
            }
            stack.addArrangedSubview(button)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(
                    equalToConstant: Self.railWidth - 12),
                button.heightAnchor.constraint(equalToConstant: 34),
            ])
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        #if canImport(UIKit)
        configurePadToolbar()
        #endif

        zoomCanvas.onZoom = { [weak self] magnification in
            self?.zoom = magnification
            self?.updateZoomReadout()
        }

        observation = ObservationLoop { [weak self] in
            self?.observe()
        }
        settingsObserver = AppSettings.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
        filmModelObserver = NotificationCenter.default.addObserver(
            forName: AppSettings.filmModelChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.rerender(debounce: false) }
        }
        // A pack that became readable after launch — the device's own key arrives off the launch
        // path now, so a locally-sealed film can appear a moment after the list was built.
        packsObserver = NotificationCenter.default.addObserver(
            forName: StockPacks.installedPacksChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadFilmLibrary() }
        }
        proAccessObserver = NotificationCenter.default.addObserver(
            forName: .proAccessChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !ProAccess.allowsStock(self.model.edit.stockID) {
                    self.model.edit.stockID = StockPreset.defaultID
                    self.model.rerender(debounce: false)
                }
                self.reloadFilmLibrary()
                self.inspector.refresh()
            }
        }

        StockTableWarmup.begin()
        model.handleLaunchArguments()
        if let argument = ProcessInfo.processInfo.arguments
            .first(where: { $0.hasPrefix("--panel=") }),
           let panel = InspectorPanel(
               rawValue: String(argument.dropFirst("--panel=".count))) {
            inspector.panel = panel
        }
        syncCropMode()
        refresh()
    }

    deinit {
        if let filmModelObserver {
            NotificationCenter.default.removeObserver(filmModelObserver)
        }
        if let packsObserver {
            NotificationCenter.default.removeObserver(packsObserver)
        }
        if let proAccessObserver {
            NotificationCenter.default.removeObserver(proAccessObserver)
        }
    }

    private func observe() {
        _ = (model.edit, model.processed, model.original, model.isProcessing,
             model.isExporting, model.errorMessage, model.videoAsset,
             model.documentName, model.canUndo, model.canRedo,
             model.isCropMode, model.canvasResetToken, model.previewSource,
             model.videoProgress, model.videoFrame, model.developingFrame,
             model.sourceEncoding, model.cropAspect, model.videoFrameRate,
             model.isSamplingSelection, model.selective, model.subjectsSettled,
             model.showsSelectionMask, model.showsNegative,
             model.autoAdjustActive)
        refresh()
    }

    // MARK: - The one refresh

    private func refresh() {
        #if !canImport(UIKit)
        view.window?.title = model.title
        #endif
        // A new photograph starts at fit: the last one's magnification was a statement about that
        // picture, not this one.
        if model.canvasResetToken != lastResetToken {
            lastResetToken = model.canvasResetToken
            zoomCanvas.resetZoom()
        }
        updateCanvas()
        // While the sampler is armed a click on the picture names a colour instead of comparing
        // with the original. Handing the canvas nil the rest of the time is what keeps the
        // hold-to-compare press exactly as it was.
        zoomCanvas.onSample = model.isSamplingSelection
            ? { [weak self] point in self?.model.sampleSelection(atUnit: point) }
            : nil
        if let railStack { rebuildRail(stack: railStack) }
        stockSidebar.refresh()
        inspector.refresh()
        advisory.refresh()
        updateZoomReadout()
        if model.isOpen {
            updateHistogram()
        } else if histogramPanel != nil {
            setHistogramShown(false)
        }
        #if canImport(UIKit)
        refreshPadToolbar()
        #else
        view.window?.toolbar?.validateVisibleItems()
        #endif
    }

    private func updateZoomReadout() {
        zoomLabel.textValue = zoom < 1.01 ? "Fit"
            : String(format: "%.1f×", zoom)
        pixelLabel.textValue = "\(model.previewPixels) px"
    }

    #if canImport(UIKit)

    private func padToolbarItem(symbol: String, title: String,
                                action: Selector) -> UIBarButtonItem {
        let item = UIBarButtonItem(image: UIImage(systemName: symbol),
                                   style: .plain, target: self,
                                   action: action)
        item.accessibilityLabel = title
        return item
    }

    private func configurePadToolbar() {
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItems = [
            padStockItem, padOpenPhotoItem, padOpenFilesItem,
        ]
        navigationItem.rightBarButtonItems = [
            padSettingsItem, padInspectorItem, padExportItem, padResetItem,
            padRedoItem, padUndoItem, padHistogramItem,
        ]

        let readout = UIStackView(arrangedSubviews: [zoomLabel, pixelLabel])
        readout.axis = .horizontal
        readout.alignment = .firstBaseline
        readout.spacing = 10
        navigationItem.titleView = readout

        guard let bar = navigationController?.navigationBar else { return }
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = .black
        appearance.shadowColor = UIColor.white.withAlphaComponent(0.08)
        bar.standardAppearance = appearance
        bar.scrollEdgeAppearance = appearance
        bar.compactAppearance = appearance
        bar.prefersLargeTitles = false
        bar.tintColor = .tintColor
        bar.isTranslucent = false
    }

    private func refreshPadToolbar() {
        padOpenPhotoItem.isEnabled = !sheetUp
        padOpenFilesItem.isEnabled = !sheetUp
        padSettingsItem.isEnabled = !sheetUp
        padHistogramItem.isEnabled = model.isOpen
        padHistogramItem.image = UIImage(
            systemName: isHistogramShown ? "waveform.circle.fill" : "waveform")
        padUndoItem.isEnabled = model.canUndo && !model.isExporting
        padRedoItem.isEnabled = model.canRedo && !model.isExporting
        padResetItem.isEnabled = model.canReset && !model.isExporting
        padExportItem.isEnabled = model.canExport
    }

    #endif

    // MARK: - The canvas

    private enum CanvasKind: Equatable {
        case empty, still, crop, video(String)
    }

    private var canvasKind: CanvasKind {
        if model.videoAsset != nil, !model.videoIdentity.isEmpty {
            return .video(model.videoIdentity)
        }
        if model.isCropMode, model.processed != nil { return .crop }
        if model.processed != nil || model.original != nil { return .still }
        return .empty
    }

    private var shownKind: CanvasKind?

    private func updateCanvas() {
        let kind = canvasKind
        if kind != shownKind {
            let next: PlatformView
            switch kind {
            case .empty:
                next = emptyState
            case .still:
                next = zoomCanvas
            case .crop:
                next = cropCanvas
            case .video(let identity):
                guard let asset = model.videoAsset else { return }
                videoIdentity = identity
                // A different clip is a different player: the preview holds a reader positioned in
                // one file, and there is nothing in it worth keeping across a change of film.
                retireVideoPreview()
                let controller = VideoPreviewViewController(asset: asset)
                connectHistogram(to: controller)
                addChild(controller)
                #if canImport(UIKit)
                controller.didMove(toParent: self)
                #endif
                videoPreview = controller
                next = controller.view
            }
            if case .video = kind {} else { retireVideoPreview() }
            shownKind = kind
            swapCanvas(to: next)
        }

        switch kind {
        case .still:
            if let image = model.processed ?? model.original {
                zoomCanvas.show(image: image,
                                original: model.processed == nil
                                    ? nil : model.original)
            }
            zoomCanvas.setInsets(canvasInsets, animated: false)
        case .crop:
            cropCanvas.insets = canvasInsets
            cropCanvas.imageChanged()
        case .video:
            videoPreview?.configure(
                stock: model.edit.stock, stockID: model.edit.stockID,
                formatID: model.edit.formatID, options: editorOptions,
                sourceEncoding: model.sourceEncoding,
                locked: model.isExporting, exportFrame: model.developingFrame)
            videoPreview?.setInsets(canvasInsets, animated: false)
        case .empty:
            emptyState.setInsets(canvasInsets)
        }
    }

    private func retireVideoPreview() {
        videoPreview?.removeFromParent()
        videoPreview = nil
    }

    private func swapCanvas(to next: PlatformView) {
        if let current = currentCanvas, current !== next {
            Motion.run(Motion.crossfade, curve: Motion.exit) {
                current.animated.opacity = 0
            } completion: {
                current.removeFromSuperview()
                current.opacity = 1
            }
        }
        guard next.superview !== canvasHost else { return }
        next.translatesAutoresizingMaskIntoConstraints = false
        next.opacity = 0
        canvasHost.addSubview(next)
        canvasHost.pin(next)
        Motion.run(Motion.crossfade) { next.animated.opacity = 1 }
        currentCanvas = next
    }

    private var editorOptions: FotufilmEngine.Options {
        var options = model.edit.options
        // A clip shows its negative the same way a still does — the simulator takes the reading as
        // one more develop option, so it costs the video path nothing beyond passing it on.
        if let negative = model.negativeViewing {
            options.negativeViewing = negative
        }
        return options
    }

    // MARK: - Layout

    private var stocksShown: Bool {
        intent.stocks && !(fit == .tight && intent.inspector)
    }

    private var stocksCollapsed: Bool { !intent.stocksListed }

    private var inspectorShown: Bool { intent.inspector }

    private var stockColumnWidth: CGFloat {
        let wanted = stocksCollapsed ? StockSidebarViewController.stripWidth
            : Self.stockPanelWidth
        return capped(wanted)
    }

    private var inspectorColumnWidth: CGFloat { capped(Self.inspectorWidth) }

    private func capped(_ width: CGFloat) -> CGFloat {
        let bounds = workspace.bounds.width
        guard bounds > 0 else { return width }
        return min(width, max(bounds - 72, 200))
    }

    private var leadingInset: CGFloat { stocksShown ? stockColumnWidth + 12 : 0 }

    private var trailingInset: CGFloat {
        (inspectorShown ? inspectorColumnWidth : Self.railWidth) + 12
    }

    private var roomyEnough: Bool {
        let width = workspace.bounds.width
        return width == 0
            || width - leadingInset - trailingInset >= Self.minimumPicture
    }

    private var canvasInsets: PlatformEdgeInsets {
        let safe = workspace.safeAreaInsets
        guard roomyEnough else {
            return PlatformEdgeInsets(top: safe.top, left: 0,
                                      bottom: safe.bottom, right: 0)
        }
        return PlatformEdgeInsets(top: safe.top, left: leadingInset,
                                  bottom: safe.bottom, right: trailingInset)
    }

    private func settleForFit() -> Bool {
        guard let fit, fit != settledFit else { return false }

        // What was last chosen is worth keeping, but only where the fit being left let it be
        // chosen: a list stood down for want of room is not a reader closing the list.
        if let settledFit {
            roomyIntent.stocks = intent.stocks
            if settledFit != .tight { roomyIntent.inspector = intent.inspector }
            if settledFit == .desk { roomyIntent.stocksListed = intent.stocksListed }
        }
        settledFit = fit

        var wanted = roomyIntent
        switch fit {
        case .desk:
            break
        case .narrow:
            wanted.stocksListed = false
        case .tight:
            wanted.stocksListed = false
            wanted.inspector = false
        }
        guard wanted != intent else { return false }
        intent = wanted
        return true
    }

    private func setPanels(animated: Bool,
                           _ change: (inout PanelIntent) -> Void) {
        var wanted = intent
        change(&wanted)
        guard wanted != intent else { return }
        intent = wanted
        layoutPanels(animated: animated)
        syncCropMode()
    }

    private func layoutPanels(animated: Bool) {
        let bounds = workspace.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        let restood = settleForFit()
        // The column is the list or the strip; which one is a consequence of the fit and of the
        // reader, so it is set here, where both are already known, rather than at each toggle.
        stockSidebar.collapsed = stocksCollapsed

        let top = workspace.safeAreaInsets.top
        canvasHost.frame = bounds
        // The columns run the whole height of the window; what the chrome overlaps is held off
        // inside them, so the material still reaches the top edge.
        stockSidebar.topInset = top
        inspector.topInset = top
        railStackTop?.constant = top + 8

        let stockFrame = CGRect(x: 0, y: 0, width: stockColumnWidth,
                                height: bounds.height)
        let stockParked = stockFrame.offsetBy(dx: -stockColumnWidth, dy: 0)
        let inspectorWidth = inspectorColumnWidth
        let inspectorFrame = CGRect(x: bounds.width - inspectorWidth, y: 0,
                                    width: inspectorWidth,
                                    height: bounds.height)
        let inspectorParked = inspectorFrame.offsetBy(dx: inspectorWidth, dy: 0)
        let railFrame = CGRect(x: bounds.width - Self.railWidth, y: 0,
                               width: Self.railWidth, height: bounds.height)
        let railParked = railFrame.offsetBy(dx: Self.railWidth, dy: 0)

        let advisorySize = advisory.compressedSize
        let advisoryRoom: CGFloat =
            bounds.width - leadingInset - trailingInset - 24
        let advisoryWidth = min(advisorySize.width, max(advisoryRoom, 80))
        let advisoryBottom: CGFloat =
            bounds.height - workspace.safeAreaInsets.bottom - 14
        let advisoryFrame = CGRect(x: leadingInset + 12,
                                   y: advisoryBottom - advisorySize.height,
                                   width: advisoryWidth,
                                   height: advisorySize.height)

        apply(frame: stocksShown ? stockFrame : stockParked,
              alpha: stocksShown ? 1 : 0, to: stockPanel, animated: animated)
        apply(frame: inspectorShown ? inspectorFrame : inspectorParked,
              alpha: inspectorShown ? 1 : 0, to: inspectorPanel,
              animated: animated)
        // The rail and the panel are the same control in two sizes, so they change places rather
        // than both being on screen: one leaves to the right as the other arrives from it.
        apply(frame: inspectorShown ? railParked : railFrame,
              alpha: inspectorShown ? 0 : 1, to: railPanel, animated: animated)
        advisory.frame = advisoryFrame

        let insets = canvasInsets
        zoomCanvas.setInsets(insets, animated: animated)
        cropCanvas.insets = insets
        emptyState.setInsets(insets)
        videoPreview?.setInsets(insets, animated: animated)

        if let histogramPanel {
            histogramPanel.room = histogramRoom
            histogramPanel.keepInRoom()
        }

        // Crop belongs to the crop tab being visible, and the fit can have just taken it away.
        if restood { syncCropMode() }
    }

    private func apply(frame: CGRect, alpha: CGFloat, to panel: PlatformView,
                       animated: Bool) {
        guard animated else {
            Motion.immediate {
                panel.frame = frame
                panel.opacity = alpha
                panel.isHidden = alpha == 0
            }
            return
        }
        if alpha > 0 { panel.isHidden = false }
        Motion.run(Motion.panel, curve: Motion.smooth) {
            panel.animated.frame = frame
            panel.animated.opacity = alpha
        } completion: {
            panel.isHidden = alpha == 0
        }
    }

    private func syncCropMode() {
        model.setCropMode(inspectorShown && inspector.panel == .crop
                          && !model.hasVideo)
    }

    private func inspectorPanelChanged(_ panel: InspectorPanel) {
        if panel == .crop, lastPanel != .crop { panelBeforeCrop = lastPanel }
        lastPanel = panel
        syncCropMode()
        cropCanvas.cropChangedExternally()
    }

    private var lastPanel = InspectorPanel.film

    private func commitCrop() -> Bool {
        guard model.isCropMode else { return false }
        inspector.panel = panelBeforeCrop
        return true
    }

    // MARK: - Opening

    private func presentOpenPanel() {
        guard !sheetUp else { return }
        #if canImport(UIKit)
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.image, .movie], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = pickerDelegate
        sheetUp = true
        present(picker, animated: true)
        #else
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        sheetUp = true
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            sheetUp = false
            if response == .OK, let url = panel.url { loadIfAllowed(url) }
        }
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
        #endif
    }

    #if canImport(UIKit)

    private func presentPhotoPicker() {
        guard !sheetUp else { return }
        var configuration = PHPickerConfiguration()
        configuration.filter = .any(of: [.images, .videos])
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = libraryDelegate
        sheetUp = true
        present(picker, animated: true)
    }

    private lazy var libraryDelegate = LibraryDelegate { [weak self] url in
        guard let self else { return }
        sheetUp = false
        if let url { loadIfAllowed(url) }
    }

    private final class LibraryDelegate: NSObject, PHPickerViewControllerDelegate {
        private let finish: (URL?) -> Void

        init(finish: @escaping (URL?) -> Void) { self.finish = finish }

        func picker(_ picker: PHPickerViewController,
                    didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider,
                  let type = Self.preferredType(from: provider) else {
                finish(nil)
                return
            }
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) {
                url, _ in
                guard let url else {
                    Task { @MainActor in self.finish(nil) }
                    return
                }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(
                    atPath: url.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue else {
                    Task { @MainActor in self.finish(nil) }
                    return
                }
                // The file the provider hands over is deleted the moment this closure returns, so
                // it is copied before anything else is done with it.
                let suggestedExtension = provider.suggestedName.map {
                    URL(fileURLWithPath: $0).pathExtension
                }.flatMap { $0.isEmpty ? nil : $0 }
                let fileExtension = url.pathExtension.isEmpty
                    ? suggestedExtension ?? type.preferredFilenameExtension
                        ?? (type.conforms(to: .movie) ? "mov" : "jpg")
                    : url.pathExtension
                let copy = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "library-\(UUID().uuidString).\(fileExtension)")
                try? FileManager.default.copyItem(at: url, to: copy)
                Task { @MainActor in
                    self.finish(FileManager.default.fileExists(atPath: copy.path)
                        ? copy : nil)
                }
            }
        }

        /// A Live Photo provider commonly lists its package before its still image. Opening that
        /// package as `Data` succeeds at the copy step and fails later as an unreadable file.
        private static func preferredType(from provider: NSItemProvider) -> UTType? {
            let types = provider.registeredTypeIdentifiers.compactMap(UTType.init)
            let concreteRaw = types.first {
                $0 != .rawImage && $0.conforms(to: .rawImage)
            }
            let concreteImage = types.first {
                $0 != .image && $0.conforms(to: .image)
                    && !$0.conforms(to: .package)
            }
            let image = concreteRaw ?? concreteImage
                ?? types.first { $0.conforms(to: .image) }
            let concreteMovie = types.first {
                $0 != .movie && $0.conforms(to: .movie)
            }
            return image ?? concreteMovie
                ?? types.first { $0.conforms(to: .movie) }
        }
    }

    @objc func openFromLibrary(_ sender: Any?) { presentPhotoPicker() }

    /// The same question `validateMenuItem` answers on the Mac: the menu above an iPad window runs
    /// through the responder chain, and this is where the chain ends up.
    override func canPerformAction(_ action: Selector,
                                   withSender sender: Any?) -> Bool {
        switch action {
        case #selector(exportDocument(_:)): return model.canExport
        case #selector(closePhoto(_:)): return model.isOpen && !model.isExporting
        case #selector(performUndo(_:)): return model.canUndo && !model.isExporting
        case #selector(performRedo(_:)): return model.canRedo && !model.isExporting
        case #selector(resetAllEdits(_:)): return model.canReset && !model.isExporting
        case #selector(rerollGrain(_:)): return model.isOpen
        case #selector(forgetLearning(_:)):
            return StockPreferenceStore.shared.hasLearnedAnything
        case #selector(openFilmWorkshop(_:)): return !sheetUp
        case #selector(zoomIn(_:)): return zoomCanvas.canZoomIn
        case #selector(zoomOut(_:)), #selector(zoomToFit(_:)):
            return zoomCanvas.canZoomOut
        case #selector(toggleShowOriginal(_:)):
            return zoomCanvas.canShowOriginal || zoomCanvas.isPeeking
        case #selector(copyPhoto(_:)): return canCopyPhoto
        case #selector(toggleShowNegative(_:)): return model.canShowNegative
        case #selector(toggleAutoAdjust(_:)): return model.canAutoAdjust
        case #selector(sampleSelection(_:)):
            return model.hasPhoto && !model.hasVideo
        case #selector(openSettings(_:)): return !sheetUp
        default: return super.canPerformAction(action, withSender: sender)
        }
    }

    private var canCopyPhoto: Bool {
        model.processed != nil || model.original != nil
    }

    /// The picker reports through a delegate rather than a completion handler, so there has to be
    /// something to be that delegate for as long as it is up.
    private lazy var pickerDelegate = PickerDelegate { [weak self] url in
        guard let self else { return }
        sheetUp = false
        if let url { loadIfAllowed(url) }
    }

    private final class PickerDelegate: NSObject,
        UIDocumentPickerDelegate {
        private let finish: (URL?) -> Void

        init(finish: @escaping (URL?) -> Void) { self.finish = finish }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            finish(urls.first)
        }

        func documentPickerWasCancelled(
            _ controller: UIDocumentPickerViewController) {
            finish(nil)
        }
    }
    #endif

    private func loadIfAllowed(_ url: URL) {
        guard allowsOpening(url) else { return }
        model.load(url: url)
    }

    private func allowsOpening(_ url: URL) -> Bool {
        #if canImport(UIKit)
        let resourceType = try? url.resourceValues(
            forKeys: [.contentTypeKey]).contentType
        let type = resourceType
            ?? UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .movie) == true {
            return ProGate.allow(.videoDevelop)
        }
        if type?.conforms(to: .rawImage) == true {
            return ProGate.allow(.rawImport)
        }
        #endif
        return true
    }

    private func dropped(_ urls: [URL]) -> Bool {
        let types: [UTType] = [.image, .movie]
        let wanted = urls.first { url in
            guard let type = UTType(filenameExtension: url.pathExtension)
            else { return false }
            return types.contains { type.conforms(to: $0) }
        }
        guard let wanted, allowsOpening(wanted) else { return false }

        let scoped = wanted.startAccessingSecurityScopedResource()
        defer { if scoped { wanted.stopAccessingSecurityScopedResource() } }
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "dropped-\(UUID().uuidString).\(wanted.pathExtension)")
        do {
            try FileManager.default.copyItem(at: wanted, to: copy)
        } catch {
            model.errorMessage = error.localizedDescription
            return false
        }
        model.load(url: copy)
        return true
    }

    // MARK: - Exporting

    private func presentRenderOptions(_ destination: RenderOptionsDestination) {
        sheetUp = true
        let sheet: ExportSheetController
        switch destination {
        case .photo:
            sheet = PhotoExportSheetController(
                sourceSize: model.sourcePixelSize,
                state: model.edit,
                sensorFrame: model.sensorFrame,
                originalRAWAvailable: model.originalRAWAvailable
            ) { [weak self] request in
                self?.model.export(request)
            }
        case .video(let asset):
            sheet = VideoExportSheetController(
                asset: asset, initialFrameRate: model.videoFrameRate
            ) { [weak self] request in
                self?.model.export(request)
            }
        }
        sheet.onClose = { [weak self] in
            self?.sheetUp = false
        }
        #if canImport(UIKit)
        sheet.modalPresentationStyle = .formSheet
        present(sheet, animated: true)
        #else
        presentAsSheet(sheet)
        #endif
    }

    // MARK: - The film workshop

    /// Opens the workshop over the session. It comes up as large as the window will let it — three
    /// columns of its own — rather than as a form sheet, because it is a place to work and not a
    /// question to answer.
    @objc func openFilmWorkshop(_ sender: Any?) {
        guard !sheetUp else { return }
        #if canImport(UIKit)
        guard ProGate.allow(.customStocks) else { return }
        #endif
        sheetUp = true
        let workshop = FilmWorkshopController()
        workshop.onLibraryChanged = { [weak self] in
            // A film saved in the workshop is one the session can pick immediately.
            self?.stockSidebar.reloadStocks()
        }
        workshop.onClose = { [weak self] in self?.sheetUp = false }
        #if canImport(UIKit)
        workshop.modalPresentationStyle = .fullScreen
        present(workshop, animated: true)
        #else
        presentAsSheet(workshop)
        #endif
    }

    // MARK: - Settings

    /// The app's settings, over the session. A form sheet rather than the workshop's full pane:
    /// it is a set of questions to answer, not a place to work.
    @objc func openSettings(_ sender: Any?) {
        guard !sheetUp else { return }
        sheetUp = true
        let settings = SettingsSheetController()
        settings.onClose = { [weak self] in
            guard let self else { return }
            sheetUp = false
            // A starting film or a film-model number changed under the open photograph is a
            // different develop, so the canvas catches up rather than waiting for the next edit.
            model.rerender(debounce: false)
        }
        #if canImport(UIKit)
        settings.modalPresentationStyle = .formSheet
        present(settings, animated: true)
        #else
        presentAsSheet(settings)
        #endif
    }

    // MARK: - Menu and toolbar actions

    @objc func openDocument(_ sender: Any?) { presentOpenPanel() }

    @objc func loadSamplePhoto(_ sender: Any?) { model.loadSample() }

    @objc func exportDocument(_ sender: Any?) {
        guard !sheetUp, model.canExport else { return }
        let destination = model.videoAsset.map(RenderOptionsDestination.video)
            ?? .photo
        presentRenderOptions(destination)
    }

    @objc func closePhoto(_ sender: Any?) { model.close() }

    @objc func performUndo(_ sender: Any?) { model.undo() }

    @objc func performRedo(_ sender: Any?) { model.redo() }

    @objc func goToEditHistory(_ sender: Any?) {
        #if !canImport(UIKit)
        guard let index = (sender as? NSMenuItem)?.representedObject as? Int,
              model.history.indices.contains(index), !model.isExporting
        else { return }
        model.goToHistory(index)
        #endif
    }

    @objc func resetAllEdits(_ sender: Any?) { model.reset() }

    @objc func rerollGrain(_ sender: Any?) { model.edit.rerollGrain() }

    @objc func toggleDiscGrain(_ sender: Any?) {
        AppSettings.shared.discGrainEnabled.toggle()
    }

    /// The annular halation shapes, app-wide like disc grain: shape is a property of the film
    /// model, not of one photograph's edit — the per-photo halation slider stays the amount.
    @objc func toggleEstimatedHalation(_ sender: Any?) {
        AppSettings.shared.estimatedHalationEnabled.toggle()
    }

    @objc func toggleAutoStock(_ sender: Any?) {
        AppSettings.shared.autoStock.toggle()
    }

    @objc func forgetLearning(_ sender: Any?) {
        StockPreferenceStore.shared.forget()
    }

    /// One command, two meanings, chosen by what the window can hold: where the list fits, this is
    /// the film column coming and going; where it does not, the column is already the strip of
    /// prints and the command opens the names over the picture.
    @objc func toggleStockSidebar(_ sender: Any?) {
        setPanels(animated: true) { wanted in
            if fit == .desk {
                wanted.stocks.toggle()
            } else if wanted.stocks, !wanted.stocksListed {
                wanted.stocksListed = true
                wanted.inspector = false
            } else if wanted.stocks {
                wanted.stocksListed = false
            } else {
                wanted.stocks = true
            }
        }
    }

    @objc func toggleInspectorPanel(_ sender: Any?) {
        setPanels(animated: true) { wanted in
            wanted.inspector.toggle()
            // Opening the names and then the adjustments should not leave the picture between two
            // columns on a screen with no room for both.
            if wanted.inspector, fit != .desk { wanted.stocksListed = false }
        }
    }

    // MARK: - Commands the menu bar carries

    /// Which tab the inspector is on, asked for by name rather than by pointing at it.
    ///
    /// The sender's tag is the panel's place in `InspectorPanel.allCases`, which is how a menu item
    /// or a key command carries an enumeration it cannot hold. Asking for a tab also opens the
    /// column: a command that put a tab up behind a closed panel would look like nothing happened.
    @objc func chooseInspectorPanel(_ sender: Any?) {
        guard let panel = panel(from: sender),
              InspectorPanel.available(video: model.hasVideo).contains(panel)
        else { return }
        inspector.panel = panel
        setPanels(animated: true) { wanted in
            wanted.inspector = true
            if fit != .desk { wanted.stocksListed = false }
        }
    }

    private func panel(from sender: Any?) -> InspectorPanel? {
        #if canImport(UIKit)
        let tag = (sender as? UIKeyCommand)
            .flatMap { $0.propertyList as? Int }
        #else
        let tag = (sender as? NSMenuItem)?.tag
        #endif
        guard let tag, InspectorPanel.allCases.indices.contains(tag) else {
            return nil
        }
        return InspectorPanel.allCases[tag]
    }

    /// The film, chosen from a list of names rather than from the wall of prints. The sender carries
    /// the stock's id, which is the only thing about a film that is stable.
    @objc func chooseFilm(_ sender: Any?) {
        #if !canImport(UIKit)
        guard let id = (sender as? NSMenuItem)?.representedObject as? String
        else { return }
        model.edit.stockID = id
        #endif
    }

    @objc func zoomIn(_ sender: Any?) { zoomCanvas.zoom(by: 1.5) }

    @objc func zoomOut(_ sender: Any?) { zoomCanvas.zoom(by: 1 / 1.5) }

    @objc func zoomToFit(_ sender: Any?) { zoomCanvas.resetZoom() }

    /// The press that shows the undeveloped picture, held open by a command instead of a finger.
    @objc func toggleShowOriginal(_ sender: Any?) {
        guard zoomCanvas.canShowOriginal || zoomCanvas.isPeeking else { return }
        zoomCanvas.setPeeking(!zoomCanvas.isPeeking)
    }

    @objc func togglePlayback(_ sender: Any?) {
        videoPreview?.togglePlayback()
    }

    @objc func toggleHistogram(_ sender: Any?) {
        setHistogramShown(histogramPanel == nil)
    }

    private var histogramRoom: CGRect {
        let top = workspace.safeAreaInsets.top
        return CGRect(x: leadingInset + 12, y: top + 12,
                      width: max(0, workspace.bounds.width
                          - leadingInset - trailingInset - 24),
                      height: max(0, workspace.bounds.height - top
                          - workspace.safeAreaInsets.bottom - 24))
    }

    private func setHistogramShown(_ shown: Bool) {
        guard shown != (histogramPanel != nil) else { return }
        if shown {
            guard model.isOpen else { return }
            let panel = SessionHistogramPanelView()
            panel.frame = CGRect(
                origin: CGPoint(x: histogramRoom.minX + 8,
                                y: histogramRoom.minY + 8),
                size: SessionHistogramPanelView.panelSize)
            panel.room = histogramRoom
            panel.opacity = 0
            histogramPanel = panel
            workspace.addSubview(panel)
            connectHistogram(to: videoPreview)
            updateHistogram()
            panel.setShown(true)
        } else if let panel = histogramPanel {
            histogramPanel = nil
            videoPreview?.onHistogramSample = nil
            panel.setShown(false) { panel.removeFromSuperview() }
        }
        #if canImport(UIKit)
        refreshPadToolbar()
        #else
        view.window?.toolbar?.validateVisibleItems()
        #endif
    }

    private func connectHistogram(to preview: VideoPreviewViewController?) {
        preview?.onHistogramSample = histogramPanel == nil ? nil : {
            [weak self] bins in self?.histogramPanel?.setCounts(bins)
        }
    }

    private func updateHistogram() {
        guard let histogramPanel else { return }
        if model.hasVideo {
            histogramPanel.setImage(videoPreview?.currentDisplayImage)
        } else {
            histogramPanel.setImage(model.processed ?? model.original)
        }
    }

    /// The negative under the print — the phone's own switch, and like the phone's it changes the
    /// way the picture is looked at rather than the edit behind it. Which reading is shown is
    /// Settings › Negative.
    @objc func toggleShowNegative(_ sender: Any?) {
        guard model.canShowNegative else { return }
        model.setShowsNegative(!model.showsNegative)
    }

    /// The Auto dial: solves the exposure and the two tone controls against the film's latitude
    /// and applies them. Pressing it again lets go without putting the values back — they are
    /// ordinary slider positions once solved.
    @objc func toggleAutoAdjust(_ sender: Any?) {
        guard model.canAutoAdjust else { return }
        model.toggleAutoAdjust()
    }

    /// Arms the selective sampler, opening its panel first if it is not the one up: asking for a
    /// sample with the controls it feeds out of sight would be a click that appeared to do
    /// nothing.
    @objc func sampleSelection(_ sender: Any?) {
        guard model.hasPhoto, !model.hasVideo else { return }
        if inspector.panel != .selective {
            inspector.panel = .selective
            setPanels(animated: true) { $0.inspector = true }
        }
        model.isSamplingSelection = true
    }

    /// The developed picture, on the clipboard. What is copied is the print as it stands — the same
    /// pixels the canvas is showing, not the file that was opened.
    @objc func copyPhoto(_ sender: Any?) {
        guard let image = model.processed ?? model.original else { return }
        #if canImport(UIKit)
        UIPasteboard.general.image = image
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        #endif
    }

    /// Puts the film list back up after the library changed underneath it.
    func reloadFilmLibrary() { stockSidebar.reloadStocks() }

    #if canImport(UIKit)

    /// The iPad's keyboard, when there is one: the same commands the Mac's menus carry, under the
    /// same keys, so the two machines are not two different instruments.
    override var keyCommands: [UIKeyCommand]? {
        var commands = [
            UIKeyCommand(title: "Commit Crop", action: #selector(returnPressed),
                         input: "\r"),
            UIKeyCommand(title: "Open…", action: #selector(openDocument(_:)),
                         input: "o", modifierFlags: .command),
            UIKeyCommand(title: "Export…", action: #selector(exportDocument(_:)),
                         input: "e", modifierFlags: .command),
            UIKeyCommand(title: "Copy Photo", action: #selector(copyPhoto(_:)),
                         input: "c", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "Undo", action: #selector(performUndo(_:)),
                         input: "z", modifierFlags: .command),
            UIKeyCommand(title: "Redo", action: #selector(performRedo(_:)),
                         input: "z", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "Film Stocks",
                         action: #selector(toggleStockSidebar(_:)),
                         input: "s", modifierFlags: [.command, .control]),
            UIKeyCommand(title: "Inspector",
                         action: #selector(toggleInspectorPanel(_:)),
                         input: "i", modifierFlags: [.command, .alternate]),
            UIKeyCommand(title: "Zoom In", action: #selector(zoomIn(_:)),
                         input: "+", modifierFlags: .command),
            UIKeyCommand(title: "Zoom Out", action: #selector(zoomOut(_:)),
                         input: "-", modifierFlags: .command),
            UIKeyCommand(title: "Zoom to Fit", action: #selector(zoomToFit(_:)),
                         input: "0", modifierFlags: .command),
            UIKeyCommand(title: "Show Original",
                         action: #selector(toggleShowOriginal(_:)),
                         input: "\\", modifierFlags: .command),
            UIKeyCommand(title: "Film Workshop…",
                         action: #selector(openFilmWorkshop(_:)),
                         input: "n", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "Show Negative",
                         action: #selector(toggleShowNegative(_:)),
                         input: "n", modifierFlags: [.command, .alternate]),
            UIKeyCommand(title: "Auto Adjust",
                         action: #selector(toggleAutoAdjust(_:)),
                         input: "a", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "Settings…",
                         action: #selector(openSettings(_:)),
                         input: ",", modifierFlags: .command),
            UIKeyCommand(title: "Sample a Selection",
                         action: #selector(sampleSelection(_:)),
                         input: "s", modifierFlags: [.command, .shift]),
        ]
        // The tabs, numbered the way they are stacked.
        for (index, panel) in InspectorPanel.allCases.enumerated() {
            commands.append(UIKeyCommand(
                title: panel.title, image: nil,
                action: #selector(chooseInspectorPanel(_:)),
                input: String(index + 1), modifierFlags: .command,
                propertyList: index))
        }
        return commands
    }

    @objc private func returnPressed() { _ = commitCrop() }

    #else

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, commitCrop() { return }
        // Space plays the clip, the way it does in every other player. It is not a menu key
        // equivalent, because a bare space in the menu bar is a space the film search field would
        // never see again; here it arrives only when nothing is being typed into.
        if event.keyCode == 49, canPlayClip {
            togglePlayback(nil)
            return
        }
        super.keyDown(with: event)
    }

    #endif

    #if !canImport(UIKit)
    /// What the menu bar is allowed to offer, given what is open.
    var stocksAreListed: Bool { stocksShown && !stocksCollapsed }
    var inspectorIsUp: Bool { inspectorShown }
    /// The tab the inspector is on, whether or not the column is up.
    var currentPanel: InspectorPanel { inspector.panel }
    var canOpenSheet: Bool { !sheetUp }
    /// The still canvas is the only one that magnifies: a clip is played, and a crop is dragged.
    var canvasZooms: Bool { canvasKind == .still }
    var canvasCanZoomIn: Bool { canvasZooms && zoomCanvas.canZoomIn }
    var canvasCanZoomOut: Bool { canvasZooms && zoomCanvas.canZoomOut }
    var canvasShowsOriginal: Bool { zoomCanvas.isPeeking }
    var canvasCanShowOriginal: Bool { canvasZooms && zoomCanvas.canShowOriginal }
    /// Who the window should give the keyboard to when it opens. See `WorkspaceView`.
    var keyboardView: PlatformView { workspace }
    var clipIsPlaying: Bool { videoPreview?.isPlaying ?? false }
    var canPlayClip: Bool { videoPreview?.canPlay ?? false }
    var canCopyPhoto: Bool { model.processed != nil || model.original != nil }
    #endif
}

#if !canImport(UIKit)

extension DesktopEditorViewController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(exportDocument(_:)):
            return model.canExport
        case #selector(closePhoto(_:)):
            return model.isOpen && !model.isExporting
        case #selector(performUndo(_:)):
            return model.canUndo && !model.isExporting
        case #selector(performRedo(_:)):
            return model.canRedo && !model.isExporting
        case #selector(goToEditHistory(_:)):
            guard let index = item.representedObject as? Int else { return false }
            item.state = index == model.historyIndex ? .on : .off
            return model.history.indices.contains(index) && !model.isExporting
        case #selector(resetAllEdits(_:)):
            return model.canReset && !model.isExporting
        case #selector(rerollGrain(_:)):
            return model.isOpen
        case #selector(toggleDiscGrain(_:)):
            item.state = AppSettings.shared.discGrainEnabled ? .on : .off
            return true
        case #selector(toggleEstimatedHalation(_:)):
            item.state = AppSettings.shared.estimatedHalationEnabled ? .on : .off
            return true
        case #selector(toggleAutoStock(_:)):
            item.state = AppSettings.shared.autoStock ? .on : .off
            return true
        case #selector(forgetLearning(_:)):
            return StockPreferenceStore.shared.hasLearnedAnything
        case #selector(toggleInspectorPanel(_:)):
            item.state = inspectorIsUp ? .on : .off
            return true
        case #selector(toggleStockSidebar(_:)):
            item.state = stocksAreListed ? .on : .off
            return true
        case #selector(chooseInspectorPanel(_:)):
            guard InspectorPanel.allCases.indices.contains(item.tag) else {
                return false
            }
            let panel = InspectorPanel.allCases[item.tag]
            item.state = inspectorIsUp && currentPanel == panel ? .on : .off
            return InspectorPanel.available(video: model.hasVideo)
                .contains(panel)
        case #selector(chooseFilm(_:)):
            let id = item.representedObject as? String
            item.state = id == model.edit.stockID ? .on : .off
            return !model.isExporting
        case #selector(openFilmWorkshop(_:)):
            return canOpenSheet
        case #selector(zoomIn(_:)):
            return canvasCanZoomIn
        case #selector(zoomOut(_:)):
            return canvasCanZoomOut
        case #selector(zoomToFit(_:)):
            return canvasCanZoomOut
        case #selector(toggleShowOriginal(_:)):
            item.state = canvasShowsOriginal ? .on : .off
            return canvasCanShowOriginal || canvasShowsOriginal
        case #selector(togglePlayback(_:)):
            // One item, two names: what it will do next, rather than what the clip is doing.
            item.title = clipIsPlaying ? "Pause" : "Play"
            return canPlayClip
        case #selector(toggleHistogram(_:)):
            item.state = isHistogramShown ? .on : .off
            return model.isOpen
        case #selector(copyPhoto(_:)):
            return canCopyPhoto
        case #selector(toggleShowNegative(_:)):
            item.state = model.showsNegative ? .on : .off
            return model.canShowNegative && !model.isExporting
        case #selector(toggleAutoAdjust(_:)):
            item.state = model.autoAdjustActive ? .on : .off
            return model.canAutoAdjust && !model.isExporting
        case #selector(sampleSelection(_:)):
            item.state = model.isSamplingSelection ? .on : .off
            return model.hasPhoto && !model.hasVideo && !model.isExporting
        case #selector(openSettings(_:)):
            return canOpenSheet
        default:
            return true
        }
    }
}

#endif

/// The workspace's own view: it reports its size up, takes a dropped file, and lights its edge
/// while one is over it.
final class WorkspaceView: SessionView {
    var onLayout: (() -> Void)?
    var onDrop: (([URL]) -> Bool)?

    private let dropBorder = CALayer()

    override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        dropBorder.borderColor = PlatformColor.accent.cgColor
        dropBorder.borderWidth = 3
        dropBorder.cornerRadius = 14
        dropBorder.cornerCurve = .continuous
        dropBorder.opacity = 0
        backingLayer.addSublayer(dropBorder)
        #if canImport(UIKit)
        addInteraction(UIDropInteraction(delegate: self))
        #else
        registerForDraggedTypes([.fileURL])
        #endif
    }

    override func layoutContents() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dropBorder.frame = bounds.insetBy(dx: 6, dy: 6)
        CATransaction.commit()
        onLayout?()
    }

    fileprivate func setBorder(lit: Bool) {
        Motion.run(Motion.quick) { [dropBorder] in
            dropBorder.opacity = lit ? 1 : 0
        }
    }

    #if !canImport(UIKit)

    /// The window opens with the picture in hand rather than the search field.
    ///
    /// Left alone, AppKit gives the keyboard to the first control it finds, which here is the film
    /// search field — and a window whose keyboard belongs to a text field is a window where Space
    /// types a space and Return goes nowhere. This view takes it instead and passes every key it is
    /// given up to the editor. Clicking the search field still hands it over.
    override var acceptsFirstResponder: Bool { true }

    override var focusRingType: NSFocusRingType {
        get { .none }
        set { _ = newValue }
    }

    /// And takes it back when the picture is clicked on, so a visit to the search field is not a
    /// one-way trip out of the keyboard's reach.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        setBorder(lit: true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setBorder(lit: false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setBorder(lit: false)
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        return onDrop?(urls) ?? false
    }

    #endif
}

#if canImport(UIKit)

/// A file dragged in from Files or from another app on the iPad, which is the same gesture the Mac
/// serves through the pasteboard.
extension WorkspaceView: UIDropInteractionDelegate {
    func dropInteraction(_ interaction: UIDropInteraction,
                         canHandle session: any UIDropSession) -> Bool {
        session.canLoadObjects(ofClass: URL.self)
    }

    func dropInteraction(_ interaction: UIDropInteraction,
                         sessionDidEnter session: any UIDropSession) {
        setBorder(lit: true)
    }

    func dropInteraction(_ interaction: UIDropInteraction,
                         sessionDidExit session: any UIDropSession) {
        setBorder(lit: false)
    }

    func dropInteraction(_ interaction: UIDropInteraction,
                         sessionDidEnd session: any UIDropSession) {
        setBorder(lit: false)
    }

    func dropInteraction(
        _ interaction: UIDropInteraction,
        sessionDidUpdate session: any UIDropSession
    ) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction,
                         performDrop session: any UIDropSession) {
        setBorder(lit: false)
        _ = session.loadObjects(ofClass: URL.self) { [weak self] urls in
            _ = self?.onDrop?(urls)
        }
    }
}

#endif

/// What the window says when nothing is open.
final class EmptyStateView: SessionView {
    private var centering: NSLayoutConstraint?

    init(open: @escaping () -> Void) {
        super.init(frame: .zero)

        let glyph = PlatformImageView()
        glyph.image = Symbol.image("photo.on.rectangle.angled", size: 42,
                                   weight: .light, description: "No media")
        glyph.translatesAutoresizingMaskIntoConstraints = false
        #if canImport(UIKit)
        glyph.tintColor = .secondaryText
        #else
        glyph.contentTintColor = .tertiaryLabelColor
        #endif

        let title = makeLabel("No Media", size: 18, weight: .semibold)
        title.alignment = .center
        let detail = makeFootnote(
            "Open a photo or video — or drop one here — to develop it as film.")
        detail.alignment = .center
        detail.font = PlatformType.system(13)

        let button = SessionButton(title: "Open…", prominent: true,
                                   action: open)

        let stack = makeStack(.vertical, spacing: 10, alignment: .center)
        stack.addArrangedSubview(glyph)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(detail)
        stack.setCustomSpacing(18, after: detail)
        stack.addArrangedSubview(button)
        addSubview(stack)

        let centering = stack.centerXAnchor.constraint(equalTo: centerXAnchor)
        self.centering = centering
        NSLayoutConstraint.activate([
            centering,
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor,
                                           constant: 24),
            trailingAnchor.constraint(greaterThanOrEqualTo: stack.trailingAnchor,
                                      constant: 24),
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
        ])
    }

    /// Centred in what the columns leave rather than in the window, so the invitation is not half
    /// hidden behind the film column.
    ///
    /// It has to be the centre constraint that carries this. Widening the margins cannot move a
    /// view that something else is holding in the middle — they are minimums, and the centre wins.
    func setInsets(_ insets: PlatformEdgeInsets) {
        guard let centering else { return }
        let offset = (insets.left - insets.right) / 2
        guard abs(offset - centering.constant) > 0.5 else { return }
        centering.constant = offset
    }
}
