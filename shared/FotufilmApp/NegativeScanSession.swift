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

/// Where a scan comes from.
enum NegativeScanSource {
    /// A scan just picked, not yet on the shelf.
    case picked(Data, typeHint: String?)
    /// A scan already on the shelf.
    case stored(id: String)
}

/// One scan open for conversion, and everything an editor of it needs whatever it looks like: the
/// recipe and its history, previews that give way to newer ones, the shelf entry the recipe is kept
/// in, and the delivered file. The phone's editor and the iPad's session both stand on it.
@MainActor
final class NegativeScanSession {
    /// How the scan is read, as the reading menus offer it.
    enum Reading: Equatable {
        case automatic(monochrome: Bool)
        case film(String)

        var name: String {
            switch self {
            case .automatic(false): return "Automatic"
            case .automatic(true): return "Automatic B&W"
            case let .film(id): return NegativeScan.films.first { $0.id == id }?.name ?? "Film"
            }
        }
    }

    /// A stream of previews in which each new one stops the one before it.
    final class Lane {
        fileprivate var generation = 0
        fileprivate var flag: RenderCancel?

        /// Stops the preview in flight, and keeps it from being delivered.
        func cancel() {
            generation += 1
            flag?.cancel()
        }
    }

    let source: NegativeScanSource
    private(set) var scan: NegativeScan?
    private(set) var recipe = NegativeScanRecipe()

    /// Said after every change to the recipe: an edit, an undo or a redo.
    var onChange: (() -> Void)?

    init(source: NegativeScanSource) {
        self.source = source
    }

    /// Reads the scan and, for one on the shelf, the recipe it was left with.
    func open() async throws {
        let (data, typeHint, stored): (Data, String?, NegativeScanRecipe?)
        switch source {
        case let .picked(bytes, hint):
            (data, typeHint, stored) = (bytes, hint, nil)
        case let .stored(id):
            guard let entry = await EditLibrary.shared.loadScan(id: id) else {
                throw NegativeScanImport.Failure.unreadable
            }
            (data, typeHint, stored) = (entry.original, entry.rawTypeHint, entry.recipe)
            entryID = id
        }
        scan = try await Task.detached(priority: .userInitiated) {
            try NegativeScan(data: data, typeHint: typeHint)
        }.value
        if let stored { recipe = stored }
        if !Self.films.contains(where: { $0.id == recipe.stockID }), let first = Self.films.first {
            recipe.stockID = first.id
        }
        onChange?()
    }

    // MARK: - Reading

    static var films: [StockPreset] { NegativeScan.films }

    var reading: Reading {
        recipe.conversion == .automatic ? .automatic(monochrome: recipe.monochrome)
                                        : .film(recipe.stockID)
    }

    func read(as reading: Reading) {
        edit {
            switch reading {
            case let .automatic(monochrome):
                $0.conversion = .automatic
                $0.monochrome = monochrome
            case let .film(id):
                $0.conversion = .film
                $0.stockID = id
            }
        }
    }

    /// The film of a film reading.
    var stock: FilmStock? {
        recipe.conversion == .film ? try? NegativeScan.film(recipe.stockID) : nil
    }

    /// The receivers a film reading can print on; none for an automatic one.
    var papers: [PrintPaper] { stock.map(NegativeScanRecipe.papers(for:)) ?? [] }

    var paper: PrintPaper? { stock.map(recipe.paper(for:)) }

    /// Whether the positive carries colour, and so whether warmth and tint mean anything.
    var carriesColour: Bool { NegativeScan.carriesColour(recipe) }

    var borderIsSampled: Bool { recipe.border != nil }

    /// Whether the light, tone and colour have moved off where the conversion puts them.
    var isAdjusted: Bool {
        let r = recipe
        return r.exposure != 0 || r.warmth != 0 || r.tint != 0 || !r.tone.isNeutral
    }

    // MARK: - Editing

    private var undoStack: [NegativeScanRecipe] = []
    private var redoStack: [NegativeScanRecipe] = []
    private var strokeBase: NegativeScanRecipe?

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// The one way an editor writes to the recipe.
    func edit(_ change: (inout NegativeScanRecipe) -> Void) {
        var next = recipe
        change(&next)
        guard next != recipe else { return }
        if strokeBase == nil { remember(recipe) }
        recipe = next
        changed()
    }

    /// A drag's run of edits is one step of history.
    func beginStroke() { strokeBase = recipe }

    func endStroke() {
        guard let base = strokeBase else { return }
        strokeBase = nil
        if base != recipe { remember(base) }
        onChange?()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(recipe)
        recipe = previous
        changed()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(recipe)
        recipe = next
        changed()
    }

    func resetAdjustments() {
        edit {
            $0.exposure = 0
            $0.warmth = 0
            $0.tint = 0
            $0.contrast = 0
            $0.highlights = 0
            $0.shadows = 0
        }
    }

    private func remember(_ recipe: NegativeScanRecipe) {
        undoStack.append(recipe)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func changed() {
        scheduleSave()
        onChange?()
    }

    // MARK: - Film border

    /// Samples clear film at `point`, a unit point in the picture as shown: cropped when
    /// `cropped` is true, the whole oriented frame otherwise.
    func pickBorder(at point: CGPoint, cropped: Bool = true) throws {
        guard let scan else { return }
        var full = point
        if cropped {
            let crop = recipe.crop.clamped()
            full = CGPoint(x: crop.x + point.x * crop.width, y: crop.y + point.y * crop.height)
        }
        let picked = try scan.sampleBorder(at: full, recipe: recipe)
        edit {
            $0.border = picked.border
            $0.borderArea = picked.area
        }
    }

    /// Goes back to the border the scan's thinnest film suggests.
    func measureBorderAutomatically() {
        edit {
            $0.border = nil
            $0.borderArea = nil
        }
    }

    // MARK: - Framing

    /// Where the exposed picture stands out from the rebate and the holder, as a crop of the
    /// draft's frame; nil when there is nothing to crop.
    func detectFrame(for draft: NegativeScanRecipe? = nil) async -> NegativeScanRecipe.Area? {
        guard let scan else { return nil }
        let recipe = draft ?? recipe
        return await Task.detached(priority: .userInitiated) {
            try? scan.detectedFrame(recipe)
        }.value
    }

    /// A shown picture straightened as the scan's frame would be, for a live ruler.
    func straightened(_ picture: CGImage, degrees: Double) async -> CGImage? {
        guard let scan else { return nil }
        return await Task.detached(priority: .userInitiated) {
            scan.straightened(picture, degrees: degrees)
        }.value
    }

    // MARK: - The roll

    var lightFrames: [NegativeScanRoll.LightFrame] { NegativeScanRoll.lightFrames() }

    func useLightFrame(_ id: String?) {
        edit { $0.lightFrameID = id }
    }

    /// Measures a photograph of the bare light source and evens this scan out by it.
    func addLightFrame(from source: NegativeScanSource) async throws {
        guard case let .picked(data, typeHint) = source else { return }
        let frame = try await Task.detached(priority: .userInitiated) {
            try NegativeScanRoll.addLightFrame(data: data, typeHint: typeHint)
        }.value
        useLightFrame(frame.id)
    }

    func copyConversion() { NegativeScanRoll.copy(recipe) }

    var canPasteConversion: Bool { NegativeScanRoll.copied != nil }

    func pasteConversion() {
        guard let copied = NegativeScanRoll.copied else { return }
        edit { $0.adoptConversion(of: copied) }
    }

    // MARK: - Previews

    /// The positive at `longEdge`, or nil when a newer preview on the same lane took over first.
    /// `draft` previews a recipe not yet committed, such as a crop still being framed.
    func preview(on lane: Lane, longEdge: Int, cropped: Bool = true,
                 draft: NegativeScanRecipe? = nil) async -> Result<CGImage, Error>? {
        guard let scan else { return nil }
        lane.cancel()
        let generation = lane.generation
        let flag = RenderCancel()
        lane.flag = flag
        let recipe = draft ?? recipe
        let result = await Task.detached(priority: .userInitiated) {
            Result { try scan.develop(recipe, longEdge: longEdge, cropped: cropped,
                                      shouldContinue: { !flag.isCancelled }) }
        }.value
        guard generation == lane.generation else { return nil }
        if cropped, draft == nil, case let .success(print) = result {
            lastPrint = print
            Task { await keepOnShelf() }
        }
        return result
    }

    /// The negative as the recipe frames it.
    func negative(longEdge: Int, cropped: Bool = true,
                  draft: NegativeScanRecipe? = nil) async -> CGImage? {
        guard let scan else { return nil }
        let recipe = draft ?? recipe
        return await Task.detached(priority: .userInitiated) {
            scan.negative(recipe, longEdge: longEdge, cropped: cropped)
        }.value
    }

    // MARK: - The shelf

    private var entryID: String?
    private var creating = false
    private var saveTask: Task<Void, Never>?
    /// Whether the recipe has changed since it was last written.
    private var unsaved = false
    /// The last cropped preview, for the shelf's thumbnail.
    private var lastPrint: CGImage?

    /// A picked scan joins the shelf once it has printed; a stored one refreshes its thumbnail.
    private func keepOnShelf() async {
        if entryID == nil, !creating, case let .picked(data, typeHint) = source {
            creating = true
            entryID = await EditLibrary.shared.create(scan: data, rawTypeHint: typeHint,
                                                      recipe: recipe)
            creating = false
        }
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
        guard unsaved, let entryID else { return }
        unsaved = false
        await EditLibrary.shared.save(id: entryID, scan: recipe)
        await saveThumbnail()
    }

    private func saveThumbnail() async {
        guard let entryID, let lastPrint else { return }
        await EditLibrary.shared.saveThumbnail(id: entryID, image: lastPrint)
    }

    /// Writes what is pending; the editor is going.
    func close() async {
        saveTask?.cancel()
        await saveNow()
    }

    // MARK: - Delivery

    static let exportName = "Negative"

    /// The film an export is gated on: none for an automatic reading.
    var exportStockID: String {
        recipe.conversion == .film ? recipe.stockID : StockPreset.noFilmID
    }

    /// Writes the full-resolution positive to `url`. Throws `CancellationError` when stopped.
    func export(as format: NegativeScan.Format, to url: URL, lane: Lane) async throws {
        guard let scan else { throw NegativeScan.Failure.render }
        lane.cancel()
        let flag = RenderCancel()
        lane.flag = flag
        let recipe = recipe
        try await Task.detached(priority: .userInitiated) {
            try scan.export(recipe, as: format, to: url, shouldContinue: { !flag.isCancelled })
        }.value
        if flag.isCancelled { throw CancellationError() }
    }
}

/// Picks a scan from Photos or Files. The phone's gallery and the iPad session both offer it, and
/// each opens the scan in its own editor.
@MainActor
enum NegativeScanOpening {
    /// The delegate of the picker on screen, which the picker itself does not keep.
    private static var pending: NSObject?

    static func menu(from presenter: @escaping () -> UIViewController?,
                     editor: @escaping (NegativeScanSource) -> UIViewController) -> UIMenu {
        UIMenu(title: "Convert Negative", children: [
            UIAction(title: "From Photos", image: UIImage(systemName: "photo.on.rectangle")) { _ in
                guard let presenter = presenter() else { return }
                pickFromPhotos(from: presenter) { open(editor($0), from: presenter) }
            },
            UIAction(title: "From Files", image: UIImage(systemName: "folder")) { _ in
                guard let presenter = presenter() else { return }
                pickFromFiles(from: presenter) { open(editor($0), from: presenter) }
            },
        ])
    }

    /// Presents over whatever is already up, so a shelf or widget open lands on top.
    static func open(_ editor: UIViewController, from presenter: UIViewController) {
        var top = presenter
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        editor.modalPresentationStyle = .fullScreen
        top.present(editor, animated: true)
    }

    static func pickFromPhotos(from presenter: UIViewController,
                               then open: @escaping (NegativeScanSource) -> Void) {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        let delegate = LibraryDelegate { data, hint in
            pending = nil
            guard let data else { return }
            open(.picked(data, typeHint: hint))
        }
        pending = delegate
        picker.delegate = delegate
        presenter.present(picker, animated: true)
    }

    static func pickFromFiles(from presenter: UIViewController,
                              then open: @escaping (NegativeScanSource) -> Void) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image], asCopy: true)
        picker.allowsMultipleSelection = false
        let delegate = FilesDelegate { url in
            pending = nil
            guard let url, let data = try? Data(contentsOf: url) else { return }
            let hint = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.identifier
            open(.picked(data, typeHint: hint))
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
#endif
