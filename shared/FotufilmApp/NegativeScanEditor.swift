#if canImport(UIKit)
import Photos
import PhotosUI
import UIKit
import UniformTypeIdentifiers

#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmEditModel)
import FotufilmEditModel
#endif

/// The scanned-negative workflow: a scan in, a positive out, and nothing of the photo editor's
/// film simulation in between. The scan stays the shelf original; the recipe is what is saved.
final class NegativeScanViewController: UIViewController {
    enum Source {
        /// A scan just picked, not yet on the shelf.
        case picked(Data, typeHint: String?)
        /// A scan already on the shelf.
        case stored(id: String)
    }

    private enum Mode { case adjust, crop, border }

    private let source: Source
    private var scan: NegativeScan?
    private var recipe = NegativeScanRecipe()
    private var entryID: String?
    private var mode = Mode.adjust
    private var lastPrint: CGImage?

    private let imageView = UIImageView()
    private let overlay = ScanOverlayView()
    private let message = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let panel = UIStackView()
    private let panelScroll = UIScrollView()
    private let conversionControl = UISegmentedControl(items: ["Automatic", "Film"])
    private let colourControl = UISegmentedControl(items: ["Colour", "Black & White"])
    private let filmButton = UIButton(type: .system)
    private let paperButton = UIButton(type: .system)
    private let borderButton = UIButton(type: .system)
    private let modeBar = UIStackView()
    private var exposure: ScanSliderRow!
    private var warmth: ScanSliderRow!
    private var tint: ScanSliderRow!
    private lazy var automaticRow = row(colourControl)
    private lazy var filmRow: UIStackView = {
        borderButton.setContentHuggingPriority(.required, for: .horizontal)
        borderButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = UIStackView(arrangedSubviews: [row(filmButton, borderButton), paperButton])
        stack.axis = .vertical
        stack.spacing = 8
        return stack
    }()
    private var compactConstraints: [NSLayoutConstraint] = []
    private var regularConstraints: [NSLayoutConstraint] = []

    private var renderGeneration = 0
    /// Stops the render in flight once a newer one has been asked for.
    private var renderCancel: RenderCancel?
    private var saveTask: Task<Void, Never>?
    /// Whether the recipe has changed since it was last written.
    private var unsaved = false
    private var busy = false

    init(source: Source) {
        self.source = source
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        overrideUserInterfaceStyle = .dark
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Layout

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.tintColor = .label

        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.accessibilityLabel = "Converted negative"
        view.addSubview(imageView)

        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.onCropChanged = { [weak self] crop in self?.cropChanged(crop) }
        overlay.onPick = { [weak self] point in self?.pickBorder(at: point) }
        view.addSubview(overlay)

        message.textColor = .secondaryLabel
        message.font = .preferredFont(forTextStyle: .footnote)
        message.numberOfLines = 0
        message.textAlignment = .center
        message.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(message)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)

        let close = UIButton(type: .system, primaryAction: UIAction { [weak self] _ in
            self?.close()
        })
        close.setImage(UIImage(systemName: "xmark"), for: .normal)
        close.accessibilityLabel = "Close"
        let title = UILabel()
        title.text = "Negative"
        title.font = .preferredFont(forTextStyle: .headline)
        title.textAlignment = .center
        let export = UIButton(type: .system)
        export.setImage(UIImage(systemName: "square.and.arrow.up"), for: .normal)
        export.accessibilityLabel = "Export"
        export.showsMenuAsPrimaryAction = true
        export.menu = exportMenu()
        let top = UIStackView(arrangedSubviews: [close, title, export])
        top.distribution = .equalCentering
        top.alignment = .center
        top.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(top)

        buildPanel()
        panelScroll.translatesAutoresizingMaskIntoConstraints = false
        panelScroll.alwaysBounceVertical = false
        panelScroll.addSubview(panel)
        view.addSubview(panelScroll)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            top.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
            top.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20),
            top.heightAnchor.constraint(equalToConstant: 44),
            imageView.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 8),
            imageView.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12),
            overlay.topAnchor.constraint(equalTo: imageView.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: imageView.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
            message.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: imageView.widthAnchor, constant: -40),
            spinner.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
            panel.topAnchor.constraint(equalTo: panelScroll.contentLayoutGuide.topAnchor),
            panel.bottomAnchor.constraint(equalTo: panelScroll.contentLayoutGuide.bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: panelScroll.frameLayoutGuide.leadingAnchor, constant: 16),
            panel.trailingAnchor.constraint(equalTo: panelScroll.frameLayoutGuide.trailingAnchor, constant: -16),
        ])
        let fitted = panelScroll.heightAnchor.constraint(equalTo: panel.heightAnchor)
        fitted.priority = .defaultHigh
        compactConstraints = [
            imageView.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -12),
            panelScroll.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 12),
            panelScroll.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            panelScroll.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            panelScroll.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -8),
            panelScroll.heightAnchor.constraint(lessThanOrEqualTo: guide.heightAnchor, multiplier: 0.45),
            fitted,
        ]
        regularConstraints = [
            imageView.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -12),
            panelScroll.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 12),
            panelScroll.topAnchor.constraint(equalTo: imageView.topAnchor),
            panelScroll.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            panelScroll.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            panelScroll.widthAnchor.constraint(equalToConstant: 340),
        ]
        applySizeClass()
        registerForTraitChanges([UITraitHorizontalSizeClass.self]) {
            (self: Self, _: UITraitCollection) in self.applySizeClass()
        }
        open()
    }

    private func applySizeClass() {
        let regular = traitCollection.horizontalSizeClass == .regular
        NSLayoutConstraint.deactivate(regular ? compactConstraints : regularConstraints)
        NSLayoutConstraint.activate(regular ? regularConstraints : compactConstraints)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        overlay.imageRect = displayedRect()
    }

    private func buildPanel() {
        panel.axis = .vertical
        panel.spacing = 14
        panel.translatesAutoresizingMaskIntoConstraints = false

        conversionControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            recipe.conversion = conversionControl.selectedSegmentIndex == 0 ? .automatic : .film
            changed()
        }, for: .valueChanged)
        colourControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            recipe.monochrome = colourControl.selectedSegmentIndex == 1
            changed()
        }, for: .valueChanged)

        for button in [filmButton, paperButton, borderButton] {
            var configuration = UIButton.Configuration.gray()
            configuration.cornerStyle = .capsule
            configuration.titleLineBreakMode = .byTruncatingTail
            configuration.buttonSize = .small
            button.configuration = configuration
        }
        filmButton.showsMenuAsPrimaryAction = true
        paperButton.showsMenuAsPrimaryAction = true
        borderButton.configuration?.image = UIImage(systemName: "eyedropper")
        borderButton.configuration?.imagePadding = 4
        borderButton.configuration?.title = "Border"
        borderButton.accessibilityHint = "Tap clear film at the edge of the frame"
        borderButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            setMode(mode == .border ? .adjust : .border)
        }, for: .touchUpInside)

        exposure = ScanSliderRow(title: "Exposure", range: NegativeScanRecipe.exposureRange) {
            [weak self] value in self?.recipe.exposure = value; self?.changed()
        }
        warmth = ScanSliderRow(title: "Warmth", range: NegativeScanRecipe.colourRange) {
            [weak self] value in self?.recipe.warmth = value; self?.changed()
        }
        tint = ScanSliderRow(title: "Tint", range: NegativeScanRecipe.colourRange) {
            [weak self] value in self?.recipe.tint = value; self?.changed()
        }

        modeBar.axis = .horizontal
        modeBar.distribution = .fillEqually
        modeBar.spacing = 8
        let tools: [(String, String, () -> Void)] = [
            ("rotate.right", "Rotate", { [weak self] in
                self?.recipe.rotateClockwise(); self?.changed()
            }),
            ("arrow.left.and.right.righttriangle.left.righttriangle.right", "Mirror", { [weak self] in
                self?.recipe.toggleMirror(); self?.changed()
            }),
            ("crop", "Crop", { [weak self] in
                guard let self else { return }
                setMode(mode == .crop ? .adjust : .crop)
            }),
        ]
        for (symbol, title, action) in tools {
            var configuration = UIButton.Configuration.plain()
            configuration.image = UIImage(systemName: symbol)
            configuration.title = title
            configuration.imagePlacement = .top
            configuration.imagePadding = 4
            configuration.buttonSize = .small
            let button = UIButton(configuration: configuration,
                                  primaryAction: UIAction { _ in action() })
            modeBar.addArrangedSubview(button)
        }

        for view in [conversionControl, automaticRow, filmRow, exposure, warmth, tint, modeBar] as [UIView] {
            panel.addArrangedSubview(view)
        }
    }

    private func row(_ views: UIView...) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .horizontal
        stack.spacing = 8
        stack.distribution = .fill
        return stack
    }

    /// Shows the controls the recipe uses.
    private func syncControls() {
        conversionControl.selectedSegmentIndex = recipe.conversion == .automatic ? 0 : 1
        colourControl.selectedSegmentIndex = recipe.monochrome ? 1 : 0
        automaticRow.isHidden = recipe.conversion != .automatic
        filmRow.isHidden = recipe.conversion != .film
        let film = NegativeScan.films.first { $0.id == recipe.stockID }
        filmButton.configuration?.title = film?.name ?? "Film"
        filmButton.menu = filmMenu()
        if let stock = film?.stock {
            paperButton.configuration?.title = recipe.paper(for: stock).name
            paperButton.menu = paperMenu(for: stock)
        }
        borderButton.configuration?.baseBackgroundColor = mode == .border ? .tintColor : nil
        borderButton.configuration?.baseForegroundColor = mode == .border ? .black : nil
        exposure.value = recipe.exposure
        warmth.value = recipe.warmth
        tint.value = recipe.tint
        let monochrome = recipe.conversion == .automatic
            ? recipe.monochrome : film?.stock.isMonochrome == true
        warmth.isHidden = monochrome
        tint.isHidden = monochrome
    }

    private func filmMenu() -> UIMenu {
        UIMenu(children: NegativeScan.films.map { film in
            UIAction(title: film.name, subtitle: film.subtitle.isEmpty ? nil : film.subtitle,
                     state: film.id == recipe.stockID ? .on : .off) { [weak self] _ in
                self?.recipe.stockID = film.id
                self?.changed()
            }
        })
    }

    private func paperMenu(for stock: FilmStock) -> UIMenu {
        let current = recipe.paper(for: stock)
        return UIMenu(children: NegativeScanRecipe.papers(for: stock).map { paper in
            UIAction(title: paper.name, state: paper == current ? .on : .off) { [weak self] _ in
                self?.recipe.paperID = paper.rawValue
                self?.changed()
            }
        })
    }

    private func exportMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: "Save to Photos", image: UIImage(systemName: "photo.badge.plus")) {
                [weak self] _ in self?.export(.jpeg, toPhotos: true)
            },
        ] + NegativeScan.Format.allCases.map { format in
            UIAction(title: "Share \(format.title)…", image: UIImage(systemName: "square.and.arrow.up")) {
                [weak self] _ in self?.export(format, toPhotos: false)
            }
        })
    }

    // MARK: - Opening

    private func open() {
        spinner.startAnimating()
        let source = source
        Task {
            do {
                let (data, typeHint, recipe, id): (Data, String?, NegativeScanRecipe?, String?)
                switch source {
                case let .picked(bytes, hint):
                    (data, typeHint, recipe, id) = (bytes, hint, nil, nil)
                case let .stored(entry):
                    guard let stored = await EditLibrary.shared.loadScan(id: entry) else {
                        throw NegativeScanImport.Failure.unreadable
                    }
                    (data, typeHint, recipe, id) = (stored.original, stored.rawTypeHint,
                                                    stored.recipe, entry)
                }
                let scan = try await Task.detached(priority: .userInitiated) {
                    try NegativeScan(data: data, typeHint: typeHint)
                }.value
                self.scan = scan
                entryID = id
                if let recipe { self.recipe = recipe }
                if !NegativeScan.films.contains(where: { $0.id == self.recipe.stockID }),
                   let first = NegativeScan.films.first {
                    self.recipe.stockID = first.id
                }
                syncControls()
                render()
            } catch {
                spinner.stopAnimating()
                show(error)
            }
        }
    }

    // MARK: - Changes

    private func changed() {
        syncControls()
        render()
        scheduleSave()
    }

    private func setMode(_ newMode: Mode) {
        mode = newMode
        overlay.mode = switch newMode {
        case .adjust: .none
        case .crop: .crop
        case .border: .border
        }
        overlay.crop = recipe.crop
        overlay.border = recipe.borderArea.map { recipe.orient($0) }
        syncControls()
        render()
    }

    private func cropChanged(_ crop: NegativeScanRecipe.Area) {
        recipe.crop = crop.clamped()
        scheduleSave()
    }

    private func pickBorder(at point: CGPoint) {
        guard let scan else { return }
        do {
            let picked = try scan.sampleBorder(at: point, recipe: recipe)
            recipe.border = picked.border
            recipe.borderArea = picked.area
            overlay.border = recipe.orient(picked.area)
            message.text = nil
            setMode(.adjust)
            scheduleSave()
        } catch {
            show(error)
        }
    }

    // MARK: - Rendering

    /// The long edge a preview is drawn at: the view's pixels, bounded.
    private var previewLongEdge: Int {
        let side = max(imageView.bounds.width, imageView.bounds.height) * traitCollection.displayScale
        return min(2400, max(800, Int(side)))
    }

    private func render() {
        guard let scan else { return }
        renderGeneration += 1
        let generation = renderGeneration
        let recipe = recipe
        let cropped = mode == .adjust
        let longEdge = previewLongEdge
        renderCancel?.cancel()
        let cancel = RenderCancel()
        renderCancel = cancel
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try scan.develop(recipe, longEdge: longEdge, cropped: cropped,
                                          shouldContinue: { !cancel.isCancelled }) }
            }.value
            guard let self, generation == renderGeneration else { return }
            spinner.stopAnimating()
            switch result {
            case let .success(print):
                imageView.image = UIImage(cgImage: print)
                message.text = nil
                if cropped { lastPrint = print }
                overlay.imageRect = displayedRect()
                if entryID == nil, case .picked = source { await createEntry() }
            case let .failure(error):
                show(error)
            }
        }
    }

    private func displayedRect() -> CGRect {
        guard let size = imageView.image?.size, size.width > 0, size.height > 0 else {
            return imageView.bounds
        }
        let bounds = imageView.bounds
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }

    private func show(_ error: Error) {
        message.text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - Saving

    private func createEntry() async {
        guard case let .picked(data, typeHint) = source, entryID == nil else { return }
        entryID = ""  // Held while the first write is on its way.
        entryID = await EditLibrary.shared.create(scan: data, rawTypeHint: typeHint, recipe: recipe)
        // A change made while the entry was being written has not reached it.
        if unsaved { await saveNow() } else { await saveThumbnail() }
    }

    private func scheduleSave() {
        unsaved = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.saveNow()
        }
    }

    private func saveNow() async {
        guard unsaved, let entryID, !entryID.isEmpty else { return }
        unsaved = false
        await EditLibrary.shared.save(id: entryID, scan: recipe)
        await saveThumbnail()
    }

    private func saveThumbnail() async {
        guard let entryID, !entryID.isEmpty, let lastPrint else { return }
        await EditLibrary.shared.saveThumbnail(id: entryID, image: lastPrint)
    }

    private func close() {
        saveTask?.cancel()
        renderCancel?.cancel()
        Task {
            await saveNow()
            dismiss(animated: true)
        }
    }

    // MARK: - Export

    private func export(_ format: NegativeScan.Format, toPhotos: Bool) {
        guard let scan, !busy else { return }
        let stockID = recipe.conversion == .film ? recipe.stockID : StockPreset.noFilmID
        guard ProGate.allowExport(stockID: stockID, resume: { [weak self] in
            self?.export(format, toPhotos: toPhotos)
        }) else { return }
        busy = true
        spinner.startAnimating()
        let recipe = recipe
        Task {
            defer {
                busy = false
                spinner.stopAnimating()
            }
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try scan.export(recipe, as: format, named: "Negative")
                }.value
                if toPhotos {
                    try await saveToPhotos(url)
                } else {
                    let share = UIActivityViewController(activityItems: [url],
                                                         applicationActivities: nil)
                    share.popoverPresentationController?.sourceView = view
                    share.popoverPresentationController?.sourceRect = CGRect(
                        x: view.bounds.maxX - 44, y: view.safeAreaInsets.top + 30, width: 1, height: 1)
                    present(share, animated: true)
                }
            } catch {
                show(error)
            }
        }
    }

    private func saveToPhotos(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            message.text = "Allow Fotufilm to add photos in Settings to save the positive."
            return
        }
        var identifier: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = false
            request.addResource(with: .photo, fileURL: url, options: options)
            identifier = request.placeholderForCreatedAsset?.localIdentifier
        }
        if let identifier { EditLibrary.shared.markDeveloped(assetIdentifier: identifier) }
        message.text = "Saved to Photos"
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if self?.message.text == "Saved to Photos" { self?.message.text = nil }
        }
    }
}

/// Picks a scan from Photos or Files and opens it in the scan editor. Both the phone's gallery
/// and the iPad session offer it the same way.
@MainActor
enum NegativeScanOpening {
    /// The delegate of the picker on screen, which the picker itself does not keep.
    private static var pending: NSObject?

    static func menu(from presenter: @escaping () -> UIViewController?) -> UIMenu {
        UIMenu(title: "Convert Negative", children: [
            UIAction(title: "From Photos", image: UIImage(systemName: "photo.on.rectangle")) { _ in
                presenter().map { pickFromPhotos(from: $0) }
            },
            UIAction(title: "From Files", image: UIImage(systemName: "folder")) { _ in
                presenter().map { pickFromFiles(from: $0) }
            },
        ])
    }

    /// Presents over whatever is already up, so a shelf or widget open lands on top.
    static func open(_ source: NegativeScanViewController.Source, from presenter: UIViewController) {
        var top = presenter
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        top.present(NegativeScanViewController(source: source), animated: true)
    }

    static func pickFromPhotos(from presenter: UIViewController) {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        let delegate = LibraryDelegate { [weak presenter] data, hint in
            pending = nil
            guard let presenter, let data else { return }
            open(.picked(data, typeHint: hint), from: presenter)
        }
        pending = delegate
        picker.delegate = delegate
        presenter.present(picker, animated: true)
    }

    static func pickFromFiles(from presenter: UIViewController) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image], asCopy: true)
        picker.allowsMultipleSelection = false
        let delegate = FilesDelegate { [weak presenter] url in
            pending = nil
            guard let presenter, let url, let data = try? Data(contentsOf: url) else { return }
            let hint = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.identifier
            open(.picked(data, typeHint: hint), from: presenter)
        }
        pending = delegate
        picker.delegate = delegate
        presenter.present(picker, animated: true)
    }

    private final class LibraryDelegate: NSObject, PHPickerViewControllerDelegate {
        private let finish: @MainActor (Data?, String?) -> Void
        init(finish: @escaping @MainActor (Data?, String?) -> Void) { self.finish = finish }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            let finish = finish
            guard let provider = results.first?.itemProvider,
                  let type = provider.registeredTypeIdentifiers.compactMap(UTType.init)
                    .first(where: { $0.conforms(to: .rawImage) })
                    ?? provider.registeredTypeIdentifiers.compactMap(UTType.init)
                        .first(where: { $0.conforms(to: .image) })
            else {
                picker.dismiss(animated: true) { finish(nil, nil) }
                return
            }
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                Task { @MainActor in
                    picker.dismiss(animated: true) { finish(data, type.identifier) }
                }
            }
        }
    }

    private final class FilesDelegate: NSObject, UIDocumentPickerDelegate {
        private let finish: @MainActor (URL?) -> Void
        init(finish: @escaping @MainActor (URL?) -> Void) { self.finish = finish }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            finish(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            finish(nil)
        }
    }
}

/// A flag a render reads between bands, set from the main thread.
private final class RenderCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// One labelled slider; a tap on its value puts it back to zero.
private final class ScanSliderRow: UIStackView {
    private let slider = UISlider()
    private let valueLabel = UIButton(type: .system)
    private let onChange: (Float) -> Void

    var value: Float {
        get { slider.value }
        set { slider.value = newValue; showValue() }
    }

    init(title: String, range: ClosedRange<Float>, onChange: @escaping (Float) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        axis = .vertical
        spacing = 2
        let label = UILabel()
        label.text = title
        label.font = .preferredFont(forTextStyle: .subheadline)
        valueLabel.titleLabel?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        valueLabel.tintColor = .secondaryLabel
        valueLabel.accessibilityHint = "Resets \(title)"
        valueLabel.addAction(UIAction { [weak self] _ in
            self?.value = 0
            self?.onChange(0)
        }, for: .touchUpInside)
        let header = UIStackView(arrangedSubviews: [label, UIView(), valueLabel])
        header.axis = .horizontal
        slider.minimumValue = range.lowerBound
        slider.maximumValue = range.upperBound
        slider.accessibilityLabel = title
        slider.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            showValue()
            onChange(slider.value)
        }, for: .valueChanged)
        addArrangedSubview(header)
        addArrangedSubview(slider)
        showValue()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func showValue() {
        valueLabel.setTitle(String(format: "%+.2f", slider.value), for: .normal)
    }
}

/// Draws and edits the crop, and takes the tap that samples the film border.
private final class ScanOverlayView: UIView {
    enum Mode { case none, crop, border }

    var mode = Mode.none {
        didSet {
            isUserInteractionEnabled = mode != .none
            setNeedsDisplay()
        }
    }
    /// Where the picture sits in this view.
    var imageRect = CGRect.zero { didSet { setNeedsDisplay() } }
    /// Unit rectangles in the shown picture.
    var crop = NegativeScanRecipe.Area.full { didSet { setNeedsDisplay() } }
    var border: NegativeScanRecipe.Area? { didSet { setNeedsDisplay() } }
    var onCropChanged: ((NegativeScanRecipe.Area) -> Void)?
    var onPick: ((CGPoint) -> Void)?

    private enum Grip { case move, corner(Int) }
    private var grip: Grip?
    private var startCrop = NegativeScanRecipe.Area.full

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:))))
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap(_:))))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func rect(_ area: NegativeScanRecipe.Area) -> CGRect {
        CGRect(x: imageRect.minX + area.x * imageRect.width,
               y: imageRect.minY + area.y * imageRect.height,
               width: area.width * imageRect.width, height: area.height * imageRect.height)
    }

    override func draw(_ dirty: CGRect) {
        guard imageRect.width > 0, let context = UIGraphicsGetCurrentContext() else { return }
        if mode == .crop {
            let kept = rect(crop)
            context.setFillColor(UIColor.black.withAlphaComponent(0.55).cgColor)
            context.addRect(imageRect)
            context.addRect(kept)
            context.fillPath(using: .evenOdd)
            context.setStrokeColor(UIColor.white.cgColor)
            context.setLineWidth(1.5)
            context.stroke(kept)
            context.setLineWidth(4)
            for corner in corners(of: kept) {
                context.stroke(CGRect(x: corner.x - 8, y: corner.y - 8, width: 16, height: 16))
            }
        }
        if mode != .none, let border {
            context.setStrokeColor(UIColor.systemYellow.cgColor)
            context.setLineWidth(2)
            context.stroke(rect(border).insetBy(dx: -3, dy: -3))
        }
    }

    private func corners(of r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }

    @objc private func tap(_ gesture: UITapGestureRecognizer) {
        guard mode == .border, imageRect.width > 0 else { return }
        let p = gesture.location(in: self)
        guard imageRect.contains(p) else { return }
        onPick?(CGPoint(x: (p.x - imageRect.minX) / imageRect.width,
                        y: (p.y - imageRect.minY) / imageRect.height))
    }

    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        guard mode == .crop, imageRect.width > 0 else { return }
        switch gesture.state {
        case .began:
            let p = gesture.location(in: self)
            startCrop = crop
            let kept = rect(crop)
            if let index = corners(of: kept).firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) < 36 }) {
                grip = .corner(index)
            } else {
                grip = kept.contains(p) ? .move : nil
            }
        case .changed:
            guard let grip else { return }
            let t = gesture.translation(in: self)
            let dx = Double(t.x / imageRect.width), dy = Double(t.y / imageRect.height)
            var next = startCrop
            switch grip {
            case .move:
                next.x += dx
                next.y += dy
            case let .corner(index):
                let left = index == 0 || index == 3, top = index == 0 || index == 1
                var x0 = startCrop.x, y0 = startCrop.y
                var x1 = startCrop.x + startCrop.width, y1 = startCrop.y + startCrop.height
                if left { x0 = min(max(0, x0 + dx), x1 - 0.05) } else { x1 = max(min(1, x1 + dx), x0 + 0.05) }
                if top { y0 = min(max(0, y0 + dy), y1 - 0.05) } else { y1 = max(min(1, y1 + dy), y0 + 0.05) }
                next = .init(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
            }
            crop = next.clamped()
        case .ended, .cancelled:
            if grip != nil { onCropChanged?(crop) }
            grip = nil
        default:
            break
        }
    }
}
#endif
