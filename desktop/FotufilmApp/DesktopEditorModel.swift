import AVFoundation
#if canImport(FotufilmImaging)
import FotufilmImaging
#endif
import CoreGraphics
import CoreImage
import CryptoKit
import ImageIO
import Observation
import UniformTypeIdentifiers

#if canImport(FotufilmCore)
import FotufilmCore
#endif

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
@Observable
final class DesktopEditorModel {
    private final class SourceLease {
        let url: URL
        private let securityScoped: Bool
        private let removesFile: Bool

        init(url: URL, securityScoped: Bool, removesFile: Bool) {
            self.url = url
            self.securityScoped = securityScoped
            self.removesFile = removesFile
        }

        deinit {
            if securityScoped { url.stopAccessingSecurityScopedResource() }
            if removesFile { try? FileManager.default.removeItem(at: url) }
        }
    }

    private enum EditorAsset {
        case photo(PhotoSource)
        case video(AVAsset, lease: SourceLease?)
    }

    let editSession = EditSession()

    var edit: EditState {
        get { editSession.edit }
        set { editSession.edit = newValue }
    }

    private var asset: EditorAsset?

    var photoSource: PhotoSource? {
        guard case .photo(let source) = asset else { return nil }
        return source
    }

    var videoAsset: AVAsset? {
        guard case .video(let video, _) = asset else { return nil }
        return video
    }

    /// The frame the open photograph was exposed on, where its file measured it. The gauge follows
    /// this until the picker is used, so the picker asks for it to say what it is following — read
    /// once as the photograph opens, because reading it means parsing the file's own record.
    var sensorFrame: SensorFrame? { photoSource?.sensorFrame }

    private(set) var original: PlatformImage?
    private(set) var processed: PlatformImage?
    private(set) var isProcessing = false
    private(set) var isExporting = false

    private(set) var previewSource: PhotoSource?

    /// Film cadence for the video export; nil keeps the source timing.
    var videoFrameRate: Int?
    /// How the clip's pixels are read.
    var sourceEncoding = VideoSourceEncoding.standard
    private(set) var videoProgress = 0.0
    private(set) var videoFrame = 0
    private(set) var videoTotalFrames = 0
    private(set) var developingFrame: PlatformImage?
    private var exportCancel: VideoPipeline.CancelFlag?

    /// What a finished export produced, where the destination is asked for afterwards.
    var exportResult: ExportResult? {
        didSet {
            guard let old = oldValue, old.url != exportResult?.url else { return }
            try? FileManager.default.removeItem(at: old.url)
        }
    }
    var errorMessage: String?

    // MARK: - The selection

    /// Active local selection and grade. This editor-only state is not persisted in exports.
    var selective = SelectiveState() {
        didSet {
            guard selective != oldValue, isSelectiveMode,
                  !isResettingSelection else { return }
            // A selection change re-composites but does not touch the edit, so it does not go
            // through `editChanged` and has to ask for the render itself.
            pending = (edit, editSession.isContinuousEditActive)
            isProcessing = true
            drain()
        }
    }

    /// Whether the selective panel is up. The composite costs a second develop of every frame, so
    /// it is only paid for while the panel that shows it is on screen.
    var isSelectiveMode = false {
        didSet {
            guard isSelectiveMode != oldValue else { return }
            if isSelectiveMode, !selective.seeded {
                // Opens changing nothing: the selection's develop starts as the photograph's.
                selective.edit = edit
                selective.seeded = true
            }
            if isSelectiveMode { startSubjectDetection() }
            pending = (edit, false)
            isProcessing = true
            drain()
        }
    }

    /// Whether the canvas shows the mask itself — the selection painted white over the dimmed
    /// photograph — rather than the two develops blended. It is the only way to see what a range
    /// and a softness are actually selecting.
    var showsSelectionMask = false {
        didSet {
            guard showsSelectionMask != oldValue, isSelectiveMode,
                  !isResettingSelection else { return }
            pending = (edit, false)
            isProcessing = true
            drain()
        }
    }

    /// Whether a click on the picture will sample rather than compare.
    var isSamplingSelection = false

    private var isResettingSelection = false

    private var selectionSource: (key: FilmRender.SceneKey, image: CGImage)?

    /// The develop that produces it: no film, and every control at rest.
    nonisolated private static let restingDevelop: EditState = {
        var state = EditState()
        state.stockID = StockPreset.noFilmID
        return state
    }()

    /// What the detector found in this photograph, once.
    private(set) var subjectReading: SubjectMask.Reading?
    private(set) var subjectsSettled = false
    private var subjectTask: Task<Void, Never>?

    /// Whether the selection has anything to select by yet.
    var hasSelection: Bool {
        selective.kind == .subject
            ? (subjectReading != nil)
            : (selective.samplePoint != nil)
    }

    /// Whether the composite is what the canvas is showing.
    var isCompositing: Bool {
        isSelectiveMode && (hasSelection || showsSelectionMask)
    }

    /// Reads a colour out of the photograph at a point in unit image coordinates, origin top
    /// left — a click on the canvas, or a check driving one.
    ///
    /// Only ever from `selectionSource`, and never from the decoded file as a fallback: the two
    /// are the same picture only while nothing has been cropped, and a sample taken from the
    /// wrong one names a colour the photographer did not click on. Until the source is developed
    /// — which is the render the panel asks for as it opens — the click is left unspent and the
    /// sampler stays armed, so the next one lands.
    func sampleSelection(atUnit point: CGPoint) {
        guard let source = selectionSource?.image else { return }
        let x = min(max(point.x, 0), 1) * Double(source.width - 1)
        let y = min(max(point.y, 0), 1) * Double(source.height - 1)
        guard let colour = Self.patch(of: source, x: Int(x), y: Int(y))
        else { return }
        var next = selective
        next.samplePoint = point
        next.sampleRed = colour.x
        next.sampleGreen = colour.y
        next.sampleBlue = colour.z
        selective = next
        isSamplingSelection = false
    }

    /// Back to no selection, with the selection's own develop reseeded from the photograph's.
    func clearSelection() {
        var next = SelectiveState()
        next.edit = edit
        next.seeded = true
        next.kind = selective.kind
        selective = next
    }

    private func startSubjectDetection() {
        guard !subjectsSettled, subjectTask == nil,
              let frame = original.flatMap(Self.cgImage) else { return }
        let session = renderSession
        subjectTask = Task { [weak self] in
            let reading = await Task.detached(priority: .userInitiated) {
                SubjectMask.detect(in: frame)
            }.value
            guard let self, self.renderSession == session else { return }
            self.subjectReading = reading
            self.subjectsSettled = true
            self.subjectTask = nil
            if self.isSelectiveMode, self.selective.kind == .subject {
                self.pending = (self.edit, false)
                self.isProcessing = true
                self.drain()
            }
        }
    }

    private func forgetSubjects() {
        subjectTask?.cancel()
        subjectTask = nil
        subjectReading = nil
        subjectsSettled = false
    }

    nonisolated private static func cgImage(_ image: PlatformImage) -> CGImage? {
        #if canImport(UIKit)
        return image.cgImage
        #else
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #endif
    }

    /// The mean of a 5×5 patch, in the picture's own encoded values, 0…1.
    nonisolated private static func patch(of image: CGImage, x: Int,
                                          y: Int) -> SIMD3<Double>? {
        guard let data = image.dataProvider?.data as Data? else { return nil }
        let componentBytes = image.bitsPerComponent / 8
        guard componentBytes == 1 || componentBytes == 2 else { return nil }
        let pixelBytes = image.bitsPerPixel / 8
        let rowBytes = image.bytesPerRow
        var sum = SIMD3<Double>()
        var taken = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for dy in -2...2 {
                let py = min(max(y + dy, 0), image.height - 1)
                for dx in -2...2 {
                    let px = min(max(x + dx, 0), image.width - 1)
                    var pixel = SIMD3<Double>()
                    for channel in 0..<3 {
                        let offset = py * rowBytes + px * pixelBytes
                            + channel * componentBytes
                        guard offset + componentBytes <= raw.count else { return }
                        pixel[channel] = componentBytes == 2
                            ? Double(raw.loadUnaligned(fromByteOffset: offset,
                                                       as: UInt16.self)) / 65535
                            : Double(raw[offset]) / 255
                    }
                    sum += pixel
                    taken += 1
                }
            }
        }
        guard taken > 0 else { return nil }
        return sum / Double(taken)
    }

    /// Whether the canvas is temporarily showing the negative instead of the edit's positive
    /// output. Selecting Negative as the output medium is edit state and does not use this switch.
    private(set) var showsNegative = false

    /// Which reading of the negative, or nil when a positive output is wanted. A transparency is
    /// its own positive and has no negative to show, so the film and medium decide with the switch.
    var negativeViewing: NegativeViewing? {
        guard canRenderNegative,
              showsNegative || edit.resolvedPaper.isNegative else { return nil }
        return AppSettings.storedNegativeViewing
    }

    /// Whether showing the negative means anything for the film loaded — what the menu asks
    /// before offering it. A reversal stock reaches no negative, and neither does no film.
    var canShowNegative: Bool {
        canRenderNegative && !edit.resolvedPaper.isNegative
    }

    private var canRenderNegative: Bool {
        isOpen && edit.hasFilm && edit.stock?.isReversal == false
    }

    /// The canvas re-develops; nothing else about the edit moves. A clip picks the change up
    /// through `editorOptions` on the next refresh rather than through the still loop, which is
    /// why the render is only asked for where there is a photograph to render.
    func setShowsNegative(_ shown: Bool) {
        let wanted = shown && canShowNegative
        guard wanted != showsNegative else { return }
        showsNegative = wanted
        guard hasPhoto else { return }
        pending = (edit, false)
        isProcessing = true
        drain()
    }

    private(set) var documentName: String?
    private(set) var canvasResetToken = UUID()

    private var suppressRender = false

    private var previewLongEdge: CGFloat = 2048
    private var developedLongEdge = 0

    private var scene: FilmRender.Scene?
    private var draftScene: FilmRender.Scene?
    private var pending: (state: EditState, draft: Bool)?
    private var isRendering = false
    private var isInteracting = false
    private var settleTask: Task<Void, Never>?
    private var kickTask: Task<Void, Never>?
    private var renderSession = UUID()

    private var storeEntryID: String?
    private var sourceOriginID: String?
    private var lastPrint: CGImage?
    private var persistenceGeneration = 0

    init() {
        editSession.onApply = { [weak self] _, previous, restoring in
            self?.editChanged(from: previous, restoring: restoring)
        }
        editSession.persistence = EditSession.PersistenceSink(
            isReady: { [weak self] in self?.photoSource != nil },
            generation: { [weak self] in self?.persistenceGeneration ?? -1 },
            save: { [weak self] state in
                guard let self else { return false }
                return await self.persistNow(state)
            },
            flush: { [weak self] state in self?.writeEditNow(state) },
            reset: { [weak self] in
                self?.storeEntryID = nil
                self?.sourceOriginID = nil
                self?.lastPrint = nil
            })
    }

    var hasPhoto: Bool { photoSource != nil }
    var sourceInterpretationAvailable: Bool { photoSource?.isRaw == false }
    var hasVideo: Bool { videoAsset != nil }
    var isOpen: Bool { hasPhoto || hasVideo }
    var canExport: Bool { (processed != nil || videoAsset != nil) && !isExporting }
    var canReset: Bool { isOpen && edit != EditState.defaults }
    var canUndo: Bool { editSession.canUndo }
    var canRedo: Bool { editSession.canRedo }
    var history: [EditState] { editSession.history }
    var historyIndex: Int { editSession.historyIndex }
    var title: String { documentName ?? "Fotufilm" }
    /// Long edge the preview is currently developed at, for the readout over the canvas.
    var previewPixels: Int {
        developedLongEdge > 0 ? developedLongEdge : Int(previewLongEdge)
    }
    var sourcePixelSize: CGSize { photoSource?.pixelSize ?? .zero }
    var originalRAWAvailable: Bool { photoSource?.originalRaw != nil }

    /// The base name an export takes, stripped of anything a file system would rather not see.
    var exportBaseName: String {
        let stem = documentName.map { ($0 as NSString).deletingPathExtension }
            ?? "Fotufilm"
        let cleaned = stem.components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: "-")
        return "\(cleaned.isEmpty ? "Fotufilm" : cleaned)-\(edit.stockID)"
    }

    private func editChanged(from old: EditState, restoring: Bool) {
        if autoAdjustActive, !isApplyingAuto {
            let autoWindowChanged = old.stockID != edit.stockID
                || old.printCorrection != edit.printCorrection
            if autoWindowChanged, !restoring {
                // The film decides the window Auto solves inside, so a new film re-solves rather
                // than leaving the old film's answer standing.
                Task { @MainActor [weak self] in
                    self?.reapplyAutoAfterStockChange()
                }
            } else if old.exposure != edit.exposure
                || old.highlights != edit.highlights
                || old.shadows != edit.shadows {
                autoAdjustActive = false
            }
        }
        guard photoSource != nil, !suppressRender else { return }
        if isCropMode {
            var before = old, after = edit
            before.crop = nil
            after.crop = nil
            before.cornerCrop = nil
            after.cornerCrop = nil
            if before == after { return }
        }
        submit(draft: editSession.isContinuousEditActive)
    }

    /// Marks the start of a continuous change — a slider drag — so everything
    /// until `endContinuousEdit` collapses into one undo point.
    func beginContinuousEdit() {
        editSession.beginContinuousEdit()
    }

    func endContinuousEdit() {
        guard editSession.isContinuousEditActive else { return }
        editSession.endContinuousEdit()
        settleNow()
    }

    func undo() {
        editSession.undo()
    }

    func redo() {
        editSession.redo()
    }

    func goToHistory(_ index: Int) {
        editSession.goToHistory(index)
    }

    /// Back to the defaults.
    func reset() {
        guard canReset else { return }
        edit = EditState()
    }

    // MARK: - Auto

    /// Whether the Auto dial is engaged. Engaging solves the exposure and the two tone controls
    /// and applies them; disengaging leaves the solved values where they are, because they are
    /// ordinary slider positions and the photographer keeps arguing with the same controls
    /// either way. This is the phone's `toggleAutoAdjust`, on the same solve.
    private(set) var autoAdjustActive = false
    private var isApplyingAuto = false
    private var cachedRegionStops: (key: FilmRender.SceneKey, stops: [Float])?

    /// Whether there is anything for Auto to work on: a decoded photograph, and a film — or no
    /// film at all, where the print's own latitude stands in for the emulsion's.
    var canAutoAdjust: Bool {
        hasPhoto && (edit.stock != nil || !edit.hasFilm)
    }

    func toggleAutoAdjust() {
        if autoAdjustActive {
            autoAdjustActive = false
            return
        }
        if applyAutoAdjustment() { autoAdjustActive = true }
    }

    @discardableResult
    private func applyAutoAdjustment() -> Bool {
        guard let scene = scene ?? draftScene else { return false }
        // The window the scene has to land inside: the film's latitude, or — with no film — the
        // print's own, which has a shoulder to protect and no toe to lift out of.
        let window: (shadows: Float, highlights: Float)
        if let stock = edit.stock {
            window = AutoAdjustment.latitude(
                stock: stock, printCorrection: Float(edit.printCorrection))
        } else if !edit.hasFilm {
            window = PlainDevelop.latitude
        } else {
            return false
        }
        let stops: [Float]
        if let cached = cachedRegionStops, cached.key == scene.key {
            stops = cached.stops
        } else {
            stops = FilmRender.regionStops(of: scene)
            cachedRegionStops = (scene.key, stops)
        }
        guard let sceneStops = AutoAdjustment.SceneStops(regionStops: stops) else {
            return false
        }
        let solution = AutoAdjustment.solve(scene: sceneStops, window: window)
        var adjusted = edit
        adjusted.exposure = Double(min(max(solution.exposureEV, -3), 3))
        adjusted.highlights = Double(min(max(solution.highlights, -1), 1))
        adjusted.shadows = Double(min(max(solution.shadows, -1), 1))
        guard adjusted != edit else { return true }
        isApplyingAuto = true
        edit = adjusted
        isApplyingAuto = false
        return true
    }

    private func reapplyAutoAfterStockChange() {
        guard autoAdjustActive else { return }
        if !applyAutoAdjustment() { autoAdjustActive = false }
    }

    private func clearHistory() {
        editSession.clearHistory()
    }

    private func setEditWithoutHistory(_ state: EditState) {
        suppressRender = true
        editSession.restoreEdit(state)
        suppressRender = false
    }

    func load(url: URL) {
        noteRecent(url)
        if Self.isVideo(url) {
            loadVideo(url: url)
            return
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = "That file could not be read."
            return
        }
        let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        openPhoto(data: data,
                  name: url.lastPathComponent,
                  rawHint: (type?.conforms(to: .rawImage) ?? false) ? type?.identifier : nil)
    }

    private func noteRecent(_ url: URL) {
        #if !canImport(UIKit)
        guard url.isFileURL,
              !url.path.hasPrefix(FileManager.default.temporaryDirectory.path)
        else { return }
        RecentFiles.note(url)
        #endif
    }

    /// Opens photo bytes that may have come from anywhere — a file, the photo
    /// library, the bundled sample.
    func openPhoto(data: Data, name: String?, rawHint: String?,
                   initialEdit: EditState? = nil) {
        editSession.flushPersistence()
        closeVideo()
        resetRenderLoop()
        let source = PhotoSource.raw(data: data, hint: rawHint, name: name)
            ?? PhotoSource.file(data: data, name: name)
        asset = .photo(source)
        previewSource = source
        original = source.isRaw
            ? nil
            : PlatformImage(data: data).flatMap { $0.size == .zero ? nil : $0 }
        processed = nil
        documentName = name
        canvasResetToken = UUID()
        clearHistory()
        setEditWithoutHistory(initialEdit ?? EditState())
        cropAspect = .free
        rerender(debounce: true)

        let token = canvasResetToken
        Task { [weak self] in
            let origin = await Task.detached(priority: .userInitiated) {
                Self.contentOrigin(of: data)
            }.value
            await EditLibrary.shared.whenLoaded()
            guard let self, self.canvasResetToken == token else { return }
            self.sourceOriginID = origin
            if let entry = EditLibrary.shared.entry(forAsset: origin),
               let stored = await EditLibrary.shared.load(id: entry.id),
               self.canvasResetToken == token, self.edit == (initialEdit ?? EditState()) {
                self.storeEntryID = entry.id
                self.editSession.armPersistence()
                self.setEditWithoutHistory(stored.edit)
                self.rerender(debounce: true)
                return
            }
            if initialEdit == nil { self.beginAutoStock(source: source, token: token) }
        }

        if source.isRaw {
            let token = canvasResetToken
            let typeHint = rawHint
            Task.detached(priority: .userInitiated) { [weak self] in
                let rendition = Self.cameraRendition(of: data, typeHint: typeHint)
                await MainActor.run { [weak self] in
                    guard let self, self.canvasResetToken == token else { return }
                    self.original = rendition
                }
            }
        }
    }

    private(set) var autoStockRanking: StockSuggestion.Ranking?
    private var autoStockTask: Task<Void, Never>?

    private func beginAutoStock(source: PhotoSource, token: UUID) {
        autoStockTask?.cancel()
        autoStockRanking = nil
        guard AppSettings.storedAutoStock else { return }
        let state = edit
        let candidates = StockPreset.all.filter {
            ProAccess.allowsStock($0.id)
        }
        StockPreferenceStore.shared.load()
        let weights = StockPreferenceStore.shared.weights
        autoStockTask = Task { [weak self] in
            let ranking = await Task.detached(priority: .utility) {
                StockSuggestion.choose(source: source, state: state,
                                       candidates: candidates,
                                       weights: weights,
                                       isCancelled: { Task.isCancelled })
            }.value
            guard !Task.isCancelled, let self, self.canvasResetToken == token,
                  let ranking, let best = ranking.best else { return }
            self.autoStockTask = nil
            self.autoStockRanking = ranking
            guard self.edit.stockID == state.stockID,
                  state.stockID != best.id else { return }
            var chosen = self.edit
            chosen.stockID = best.id
            self.setEditWithoutHistory(chosen)
            self.rerender(debounce: true)
        }
    }

    /// The camera's own rendering of a raw file, for the hold-to-compare.
    nonisolated private static func cameraRendition(
        of data: Data, typeHint: String?
    ) -> PlatformImage? {
        let options = typeHint.map {
            [kCGImageSourceTypeIdentifierHint: $0] as CFDictionary
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 4096,
              ] as CFDictionary)
        else { return nil }
        return PlatformImage.from(image)
    }

    func loadSample() {
        guard let url = Bundle.main.url(forResource: "sample", withExtension: "png"),
              let data = try? Data(contentsOf: url) else { return }
        openPhoto(data: data, name: "sample.png", rawHint: nil)
    }

    private static func isVideo(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?
            .conforms(to: .movie) ?? false
    }

    /// Opens a video file.
    func loadVideo(url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        openVideo(asset: AVURLAsset(url: url), name: url.lastPathComponent,
                  scopedURL: accessing ? url : nil, temporaryURL: nil)
    }

    /// Opens a video however it arrived.
    func openVideo(asset: AVAsset, name: String,
                   scopedURL: URL?, temporaryURL: URL?) {
        editSession.flushPersistence()
        closeVideo()
        resetRenderLoop()
        original = nil
        processed = nil
        isProcessing = false
        documentName = name
        clearHistory()
        setEditWithoutHistory(EditState())
        cropAspect = .free
        sourceEncoding = .standard
        videoFrameRate = nil
        let leaseURL = scopedURL ?? temporaryURL
        let lease = leaseURL.map {
            SourceLease(url: $0, securityScoped: scopedURL != nil,
                        removesFile: temporaryURL != nil)
        }
        self.asset = .video(asset, lease: lease)
        previewSource = nil
        canvasResetToken = UUID()
        Task { [weak self] in
            guard let poster = await VideoPipeline.posterFrame(of: asset) else { return }
            guard let self, videoAsset === asset else { return }
            previewSource = PhotoSource.bitmap(poster)
        }
    }

    func closeVideo() {
        if case .video = asset { asset = nil }
        developingFrame = nil
    }

    /// Identity of the clip as the preview area is configured for it.
    var videoIdentity: String {
        let asset = videoAsset.map { ObjectIdentifier($0).debugDescription } ?? "none"
        return "\(asset)#\(sourceEncoding.rawValue)"
    }

    /// Puts the session back to nothing open, releasing the clip's file
    /// access and the full-size print with it.
    func close() {
        editSession.flushPersistence()
        resetRenderLoop()
        closeVideo()
        asset = nil
        previewSource = nil
        original = nil
        processed = nil
        documentName = nil
        isProcessing = false
        clearHistory()
        setEditWithoutHistory(EditState())
        cropAspect = .free
    }

    /// The aspect the crop tab has locked.
    var cropAspect = AspectOption.free

    private(set) var isCropMode = false

    func setCropMode(_ active: Bool) {
        guard active != isCropMode else { return }
        isCropMode = active
        guard photoSource != nil else { return }
        submit(draft: false)
    }

    /// A quarter turn counter-clockwise, the phone's way: the crop does not survive it, because a
    /// rect chosen for one orientation is not a choice about the other.
    func rotateLeft() {
        var next = edit
        next.rotation = (next.rotation + 3) % 4
        next.crop = nil
        next.cornerCrop = nil
        edit = next
        cropAspect = .free
    }

    func flipHorizontal() {
        var next = edit
        next.flipH.toggle()
        next.cornerCrop = nil
        edit = next
    }

    func resetGeometry() {
        guard edit.hasGeometryEdits else { return }
        var next = edit
        next.resetGeometry()
        edit = next
        cropAspect = .free
    }

    /// What the open photograph says it was taken with, if it says anything.
    var lensShot: LensShot? { photoSource?.lensShot }

    /// The profile in play for the open photograph.
    var matchedLensProfile: LensProfile? {
        guard hasPhoto else { return nil }
        return edit.resolvedLensProfile(for: lensShot)
    }

    /// What is correcting the open photograph, worked out the same way the renderer works it out.
    var lensPlan: LensPlan {
        guard hasPhoto else { return LensPlan() }
        return edit.lensPlan(for: lensShot, dng: photoSource?.originalDNGData)
    }

    /// Whether the lens panel has a measurement to show an Amount slider for.
    var hasLensMeasurement: Bool { lensPlan.hasMeasurement }

    /// What the lens panel says above the sliders.
    var lensCorrectionNote: String { lensPlan.note(for: lensShot) }

    var hasLensEdits: Bool { edit.hasLensEdits }

    func resetLensCorrection() {
        guard edit.hasLensEdits else { return }
        var next = edit
        next.resetLensCorrection()
        edit = next
    }

    /// Locks an aspect by cutting the largest centered crop that has it — the
    /// same arithmetic as the phone's crop panel.
    func applyAspect(_ option: AspectOption) {
        var next = edit
        next.cornerCrop = nil
        cropAspect = option
        var size = sourcePixelSize
        if edit.rotation % 2 == 1 {
            size = CGSize(width: size.height, height: size.width)
        }
        guard size.width > 0, size.height > 0,
              let ratio = option.ratio(for: size) else { edit = next; return }
        let imageRatio = size.width / size.height
        var w: CGFloat = 1, h: CGFloat = 1
        if ratio < imageRatio {
            w = ratio / imageRatio
        } else {
            h = imageRatio / ratio
        }
        next.crop = (w > 0.999 && h > 0.999) ? nil
            : CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
        edit = next
    }

    /// Sizes the moving-control proxy to the pixels it is actually displayed at
    /// (view size × display scale). A settled still is always developed at native resolution.
    func updatePreviewTarget(_ size: CGSize, scale: CGFloat) {
        let needed = max(size.width, size.height) * max(scale, 1)
        let bucket = min(4096, max(512, ceil(needed / 256) * 256))
        guard bucket != previewLongEdge else { return }
        previewLongEdge = bucket
    }

    /// Asks for a full render, coalesced with whatever else is pending.
    func rerender(debounce: Bool = true) {
        guard photoSource != nil else { return }
        kickTask?.cancel()
        guard debounce else {
            submit(draft: false)
            return
        }
        kickTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            self.submit(draft: false)
        }
    }

    private func submit(draft: Bool) {
        guard photoSource != nil, edit.stock != nil || !edit.hasFilm else { return }
        pending = (edit, draft)
        if draft {
            isInteracting = true
            scheduleSettle()
        }
        isProcessing = true
        drain()
    }

    private func scheduleSettle() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self else { return }
            self.settleNow()
        }
    }

    private func settleNow() {
        guard isInteracting else { return }
        isInteracting = false
        settleTask?.cancel()
        pending = (edit, false)
        isProcessing = true
        drain()
    }

    private func drain() {
        guard !isRendering, let source = photoSource, let next = pending
        else { return }
        pending = nil
        isRendering = true
        var stripped = next.state
        if isCropMode { stripped.crop = nil; stripped.cornerCrop = nil }
        let state = stripped
        let strip = isCropMode
        let draft = next.draft
        let draftTarget = max(1, Int(previewLongEdge) / 2)
        let session = renderSession

        let negative = negativeViewing
        // The selection's own develop, and the picture the mask is weighed against. Both nil
        // unless the selective panel is up, so an ordinary edit pays for exactly one develop.
        let selection = isCompositing ? selective : nil
        let subjects = subjectReading
        let showMask = showsSelectionMask
        let fullKey = FilmRender.SceneKey(state: state, longEdge: nil)
        let draftKey = FilmRender.SceneKey(state: state, longEdge: draftTarget)
        let renderKey = draft ? draftKey : fullKey
        // Wanted from the moment the panel opens, not from the first sample: it is what the
        // sampler reads a colour out of.
        let wantsSelectionSource = isSelectiveMode
        let cachedSelectionSource = selectionSource?.key == renderKey
            ? selectionSource?.image : nil
        let staleBalance = !draft && scene?.balanceIsStale(for: state) == true
        let cachedFull = (scene?.key == fullKey && !staleBalance) ? scene : nil
        let cachedDraft = draftScene?.key == draftKey ? draftScene : nil

        Task { [weak self] in
            let rendered = await Task.detached(priority: .userInitiated) {
                () -> (full: FilmRender.Scene?, draft: FilmRender.Scene?,
                       image: CGImage?, selectionSource: CGImage?)? in
                let renderScene: FilmRender.Scene
                if draft {
                    guard let reduced = cachedDraft ?? FilmRender.scene(
                        source: source, state: state, longEdge: draftTarget)
                    else { return nil }
                    renderScene = reduced
                } else {
                    guard let full = cachedFull ?? FilmRender.scene(
                        source: source, state: state, longEdge: nil)
                    else { return nil }
                    renderScene = full
                }
                guard renderScene.key == renderKey
                else { return nil }
                // The picture the emulsion receives, developed on no film through a resting
                // edit: geometry-exact against the print, and steady while the edit moves.
                let plain: CGImage? = wantsSelectionSource
                    ? (cachedSelectionSource
                        ?? FilmRender.develop(renderScene, state: Self.restingDevelop)?
                            .image.image)
                    : nil
                let maskSource = plain.map(CIImage.init(cgImage:))
                func print(_ scene: FilmRender.Scene) -> CGImage? {
                    let ground = FilmRender.develop(scene, state: state,
                                                    negative: negative)?
                        .image.image
                    guard let ground, let selection else { return ground }
                    // The second develop is the selection's own edit over the same scene; the two
                    // are then blended through the mask. Skipped where the mask itself is being
                    // shown, which needs the ground and the weights and nothing else.
                    let over = showMask ? nil
                        : FilmRender.develop(scene, state: selection.edit,
                                             negative: negative)?.image.image
                    return SelectiveMask.composite(
                        ground: ground, selection: over, scene: maskSource,
                        state: selection, subjects: subjects,
                        showMask: showMask, context: SelectiveRender.context,
                        colorSpace: SelectiveRender.space) ?? ground
                }
                if draft {
                    return (cachedFull, renderScene, print(renderScene), plain)
                }
                return (renderScene, cachedDraft, print(renderScene), plain)
            }.value
            guard let self else { return }
            if self.renderSession == session, let rendered {
                self.scene = rendered.full
                self.draftScene = rendered.draft
                if let source = rendered.selectionSource {
                    self.selectionSource = (renderKey, source)
                }
                if let image = rendered.image {
                    self.processed = PlatformImage.from(image)
                    self.developedLongEdge = max(image.width, image.height)
                    // The shelf's thumbnail is the print, never the negative the canvas may be
                    // showing instead.
                    if !draft, !strip, negative == nil, selection == nil {
                        self.lastPrint = image
                    }
                }
            }
            self.isRendering = false
            if self.pending != nil {
                self.drain()
            } else {
                self.isProcessing = false
            }
        }
    }

    private func resetRenderLoop() {
        renderSession = UUID()
        persistenceGeneration &+= 1
        kickTask?.cancel()
        settleTask?.cancel()
        autoStockTask?.cancel()
        autoStockTask = nil
        pending = nil
        isInteracting = false
        scene = nil
        draftScene = nil
        developedLongEdge = 0
        showsNegative = false
        autoAdjustActive = false
        cachedRegionStops = nil
        forgetSubjects()
        selectionSource = nil
        isResettingSelection = true
        selective = SelectiveState()
        showsSelectionMask = false
        isSamplingSelection = false
        isResettingSelection = false
    }

    private func persistNow(_ state: EditState) async -> Bool {
        guard let source = photoSource else { return false }
        let saved: Bool
        if storeEntryID == nil {
            guard let data = source.data else { return false }
            storeEntryID = await EditLibrary.shared.create(
                original: data, rawTypeHint: source.rawHint,
                assetIdentifier: sourceOriginID, edit: state)
            saved = storeEntryID != nil
        } else if let id = storeEntryID {
            saved = await EditLibrary.shared.save(id: id, edit: state)
        } else {
            saved = false
        }
        guard saved, let id = storeEntryID else { return false }
        noteFilmChoice(id: id, state: state)
        if let print = lastPrint {
            await EditLibrary.shared.saveThumbnail(id: id, image: print)
        }
        return true
    }

    private func noteFilmChoice(id: String, state: EditState) {
        StockPreferenceStore.shared.record(
            photoID: id, chosenFilmID: state.stockID,
            ranking: autoStockRanking,
            proposedFilmID: autoStockRanking?.best?.id)
    }

    private func writeEditNow(_ state: EditState) {
        guard let source = photoSource else { return }
        let print = lastPrint
        if let id = storeEntryID {
            noteFilmChoice(id: id, state: state)
            Task {
                await EditLibrary.shared.save(id: id, edit: state)
                if let print {
                    await EditLibrary.shared.saveThumbnail(id: id, image: print)
                }
            }
        } else if let data = source.data {
            let hint = source.rawHint
            let origin = sourceOriginID
            Task {
                guard let id = await EditLibrary.shared.create(
                    original: data, rawTypeHint: hint,
                    assetIdentifier: origin, edit: state)
                else { return }
                if let print {
                    await EditLibrary.shared.saveThumbnail(id: id, image: print)
                }
            }
        }
    }

    /// The shelf identity of a file's bytes.
    nonisolated private static func contentOrigin(of data: Data) -> String {
        "sha256:" + SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
    }

    func export(_ request: PhotoRenderRequest) {
        guard !isExporting, videoAsset == nil else { return }
        Task {
            await exportStill(request)
        }
    }

    func export(_ request: VideoRenderRequest) {
        guard !isExporting, videoAsset != nil else { return }
        videoFrameRate = request.frameRate
        Task { await exportVideo(request) }
    }

    private func exportStill(_ request: PhotoRenderRequest) async {
        guard let source = photoSource else { return }
        let outputType: UTType
        let preferredExtension: String?
        switch request {
        case .original:
            guard let original = source.originalRaw else { return }
            outputType = original.contentType ?? .rawImage
            preferredExtension = original.fileExtension
        case .developed(_, let delivery, _, _):
            guard edit.stock != nil || !edit.hasFilm else { return }
            outputType = delivery.format.contentType
            preferredExtension = nil
        }
        guard let output = await ExportDestination.url(
            named: exportBaseName, type: outputType,
            preferredExtension: preferredExtension) else { return }
        isExporting = true
        errorMessage = nil

        if case .original = request {
            let data = source.originalRaw?.data
            let written = await Task.detached(priority: .userInitiated) {
                guard let data else { return false }
                do {
                    try? FileManager.default.removeItem(at: output)
                    try data.write(to: output, options: .atomic)
                    return true
                } catch {
                    return false
                }
            }.value
            isExporting = false
            if written {
                if ExportDestination.asksAfterwards {
                    exportResult = ExportResult(url: output, isVideo: false,
                                                contentType: outputType,
                                                preview: original)
                }
            } else {
                errorMessage = "The original RAW file could not be exported."
            }
            return
        }

        guard case .developed(let longEdge, let delivery, let quality,
                              let metadata) = request else { return }
        let state = edit
        let exact = AppSettings.effectiveRenderingMode == .accurate
        let hdr = delivery.hdrContainer != nil
        let written = await Task.detached(priority: .userInitiated) { () -> Bool in
            guard let rendered = FilmRender.render(
                source: source, state: state, longEdge: longEdge,
                hdr: hdr, dynamicRange: hdr ? .hdr : .sdr,
                exact: exact)
            else { return false }
            if let hdrContainer = delivery.hdrContainer {
                return rendered.writeHDR(to: output, as: hdrContainer,
                                         metadata: metadata)
            }
            return rendered.write(to: output, format: delivery.format,
                                  quality: quality.compression,
                                  metadata: metadata)
        }.value
        isExporting = false
        if written {
            if ExportDestination.asksAfterwards {
                exportResult = ExportResult(url: output, isVideo: false,
                                            contentType: outputType,
                                            preview: processed)
            }
        } else {
            errorMessage = "The photo couldn’t be exported in that format."
        }
    }

    private func exportVideo(_ request: VideoRenderRequest) async {
        guard let asset = videoAsset, let stock = edit.stock,
              let output = await ExportDestination.url(
                named: exportBaseName, type: request.format.contentType)
        else { return }

        let options = edit.options
        let encoding = sourceEncoding
        let flag = VideoPipeline.CancelFlag()
        exportCancel = flag
        isExporting = true
        errorMessage = nil
        videoProgress = 0
        videoFrame = 0
        videoTotalFrames = 0
        developingFrame = nil
        idleTimer(disabled: true)
        do {
            try await VideoDeveloper.export(
                from: asset, to: output, stock: stock, options: options,
                longEdge: request.longEdge,
                frameRate: request.frameRate,
                fileType: request.format.fileType,
                codec: request.format.codec(hdr: request.hdr),
                sourceEncoding: encoding,
                hdr: request.hdr,
                fast: request.fast,
                includeAudio: request.includeAudio,
                progress: { [weak self] fraction, frame, total in
                    Task { @MainActor in
                        self?.videoProgress = fraction
                        self?.videoFrame = frame
                        self?.videoTotalFrames = total
                    }
                },
                preview: { [weak self] image in
                    Task { @MainActor in self?.developingFrame = image }
                },
                isCancelled: { flag.isCancelled })
            if ExportDestination.asksAfterwards {
                exportResult = ExportResult(url: output, isVideo: true,
                                            contentType: request.format.contentType,
                                            preview: developingFrame)
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            if case VideoDeveloper.Failure.cancelled = error {
            } else {
                errorMessage = error.localizedDescription
            }
        }
        idleTimer(disabled: false)
        isExporting = false
        developingFrame = nil
        exportCancel = nil
    }

    func cancelExport() {
        exportCancel?.cancel()
    }

    /// Closes the destination sheet; the file goes with it.
    func discardExportResult() {
        exportResult = nil
    }

    private func idleTimer(disabled: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }

    /// The `--open=` and `--demo` hooks, so a screenshot or a QA pass can reach a developed frame
    /// without driving the file importer.
    func handleLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        if let argument = arguments.first(where: { $0.hasPrefix("--open=") }) {
            load(url: URL(fileURLWithPath: String(argument.dropFirst("--open=".count))))
        } else if arguments.contains("--demo") {
            loadSample()
        }
        if let argument = arguments.first(where: { $0.hasPrefix("--stock=") }) {
            let id = String(argument.dropFirst("--stock=".count))
            if StockPreset.all.contains(where: { $0.id == id }) {
                edit.stockID = id
            }
        }
    }
}
