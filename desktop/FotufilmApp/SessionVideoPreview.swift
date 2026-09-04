import AVFoundation
import Combine
import CoreGraphics
import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// The video half of the window: live film-simulated playback with a scrubber underneath.
///
/// Three pictures can be on screen here, and only ever one of them: the live simulated playback,
/// the paused playhead frame developed at full resolution, and — while an export runs — whichever
/// frame the developer last returned.
final class VideoPreviewViewController: SessionViewController {
    private let asset: AVAsset
    private let previewState: VideoPreviewState
    private let simulator = VideoPreviewSimulator()
    private var playbackQuality: VideoPreviewSimulator.Quality {
        didSet {
            UserDefaults.standard.set(playbackQuality.rawValue,
                                      forKey: Self.qualityKey)
        }
    }
    private static let qualityKey = "videoPlaybackQuality"

    private lazy var playback = PlaybackSurfaceView(simulator: simulator)
    private let posterView = CrossfadingImageView()
    private let lockedView = CrossfadingImageView()
    private let pausedCanvas = SessionCanvasView()
    private let spinner = SessionSpinner()
    private let scrubber = GlassPanelView(radius: 26)

    private var playButton: IconButton!
    private let qualityButton = SessionPopUp(description: "Playback quality")
    private let elapsed = makeLabel("0:00", size: 11, monospacedDigits: true)
    private let total = makeLabel("0:00", size: 11, monospacedDigits: true)
    private let playhead = SessionSlider(range: 0 ... 0.01)
    private let summaryLabel = makeLabel("", size: 10, color: .secondaryText,
                                         monospacedDigits: true)

    private var stock: FilmStock?
    private var stockID = ""
    private var formatID = ""
    private var options = FotufilmEngine.Options()
    private var sourceEncoding = VideoSourceEncoding.standard
    private var locked = false

    private var surfaceLeadings: [NSLayoutConstraint] = []
    private var surfaceTrailings: [NSLayoutConstraint] = []
    private var surfaceTops: [NSLayoutConstraint] = []
    private var surfaceBottoms: [NSLayoutConstraint] = []
    private var scrubberCentre: NSLayoutConstraint?
    private var scrubberLeading: NSLayoutConstraint?
    private var spinnerCentre: NSLayoutConstraint?

    private var previewTime = 0.0
    private var pausedFrame: PlatformImage?
    private var pausedOriginal: PlatformImage?
    private var overlayCurrent = false
    private var isScrubbing = false
    private var previewPending = false
    private var refreshTask: Task<Void, Never>?
    private var lastPreviewRequest: PreviewRequest?
    private var lastSimulatorRequest: SimulatorRequest?
    private var observers: [AnyCancellable] = []

    var onHistogramSample: (([[Int]]) -> Void)? {
        get { playback.onHistogramSample }
        set { playback.onHistogramSample = newValue }
    }

    var currentDisplayImage: PlatformImage? {
        if locked { return lockedView.image }
        if !pausedCanvas.isHidden, let pausedFrame { return pausedFrame }
        return posterView.image
    }

    init(asset: AVAsset) {
        self.asset = asset
        previewState = VideoPreviewState(asset: asset)
        playbackQuality = UserDefaults.standard.string(forKey: Self.qualityKey)
            .flatMap(VideoPreviewSimulator.Quality.init(rawValue:)) ?? .fine
        super.init()
        playButton = IconButton(symbol: "play.fill",
                                description: "Play preview") { [weak self] in
            self?.togglePlayback()
        }
    }

    deinit {
        refreshTask?.cancel()
    }

    override func loadView() {
        let root = SessionView()
        root.backingLayer.backgroundColor = PlatformColor.black.cgColor

        for surface in [posterView, lockedView] {
            surface.fitProportionally()
            surface.translatesAutoresizingMaskIntoConstraints = false
            surface.isHidden = true
            root.addSubview(surface)
        }
        playback.isHidden = false
        root.addSubview(playback)
        // The live surface never takes a click: the picture under the pointer is the paused frame's
        // when there is one, and nothing when there is not.
        playback.setAXLabel(nil)

        pausedCanvas.translatesAutoresizingMaskIntoConstraints = false
        pausedCanvas.isHidden = true
        pausedCanvas.opacity = 0
        root.addSubview(pausedCanvas)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(spinner)

        scrubber.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrubber)
        buildScrubber()

        let spinnerCentre = spinner.centerXAnchor.constraint(
            equalTo: root.centerXAnchor)
        let scrubberCentre = scrubber.centerXAnchor.constraint(
            equalTo: root.centerXAnchor)
        let scrubberLeading = scrubber.leadingAnchor.constraint(
            greaterThanOrEqualTo: root.leadingAnchor, constant: 20)
        self.spinnerCentre = spinnerCentre
        self.scrubberCentre = scrubberCentre
        self.scrubberLeading = scrubberLeading
        NSLayoutConstraint.activate([
            pausedCanvas.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pausedCanvas.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pausedCanvas.topAnchor.constraint(equalTo: root.topAnchor),
            pausedCanvas.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            spinnerCentre,
            spinner.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            scrubberCentre,
            scrubber.bottomAnchor.constraint(
                equalTo: root.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            scrubber.widthAnchor.constraint(lessThanOrEqualToConstant: 720),
            scrubberLeading,
        ])
        // The playing surfaces are held off the columns the way the still canvas holds its picture
        // off them, and by the same amounts: the fitted clip and the fitted print are the same
        // rectangle, so opening a panel slides the film out from under it too.
        for surface in [playback, posterView, lockedView] as [PlatformView] {
            let leading = surface.leadingAnchor.constraint(
                equalTo: root.leadingAnchor)
            let trailing = root.trailingAnchor.constraint(
                equalTo: surface.trailingAnchor)
            let top = surface.topAnchor.constraint(equalTo: root.topAnchor)
            let bottom = root.bottomAnchor.constraint(
                equalTo: surface.bottomAnchor)
            surfaceLeadings.append(leading)
            surfaceTrailings.append(trailing)
            surfaceTops.append(top)
            surfaceBottoms.append(bottom)
            NSLayoutConstraint.activate([leading, trailing, top, bottom])
        }
        view = root
    }

    /// What the fitted clip keeps clear of — the columns and the toolbar. Animated, because the
    /// panels that decided it are animating too and the film should travel with them.
    func setInsets(_ insets: PlatformEdgeInsets, animated: Bool) {
        pausedCanvas.setInsets(insets, animated: animated)
        guard animated else {
            Motion.immediate { applyInsets(insets, animated: false) }
            return
        }
        Motion.run(Motion.panel, curve: Motion.smooth) {
            self.applyInsets(insets, animated: true)
            self.view.animated.layoutNow()
        }
    }

    private func applyInsets(_ insets: PlatformEdgeInsets, animated: Bool) {
        var targets: [(NSLayoutConstraint, CGFloat)] = []
        for constraint in surfaceLeadings { targets.append((constraint, insets.left)) }
        for constraint in surfaceTrailings { targets.append((constraint, insets.right)) }
        for constraint in surfaceTops { targets.append((constraint, insets.top)) }
        for constraint in surfaceBottoms { targets.append((constraint, insets.bottom)) }
        // The middle of the clip, told to the chrome that sits on it.
        let centre = (insets.left - insets.right) / 2
        if let scrubberCentre { targets.append((scrubberCentre, centre)) }
        if let spinnerCentre { targets.append((spinnerCentre, centre)) }
        if let scrubberLeading { targets.append((scrubberLeading, insets.left + 20)) }
        for (constraint, value) in targets {
            #if canImport(UIKit)
            constraint.constant = value
            #else
            if animated {
                constraint.animator().constant = value
            } else {
                constraint.constant = value
            }
            #endif
        }
    }

    private func buildScrubber() {
        let content = scrubber.content

        playhead.onChange = { [weak self] _ in self?.seek() }
        playhead.began = { [weak self] in self?.scrubbingBegan() }
        playhead.ended = { [weak self] in self?.scrubbingEnded() }
        playhead.setAXLabel("Video playhead")

        qualityButton.setOptions(
            VideoPreviewSimulator.Quality.selectable.map(\.title))
        if let index = VideoPreviewSimulator.Quality.selectable
            .firstIndex(of: playbackQuality) {
            qualityButton.selectedIndex = index
        }
        qualityButton.onPick = { [weak self] _ in self?.qualityChanged() }
        qualityButton.setHelp("Playback develops at this quality; the paused "
            + "frame always develops at full resolution.")

        let transport = makeStack(.horizontal, spacing: 12, alignment: .center)
        for control in [playButton, elapsed, playhead, total, qualityButton]
            as [PlatformView] {
            transport.addArrangedSubview(control)
        }

        let column = makeStack(.vertical, spacing: 6, alignment: .center)
        column.addArrangedSubview(transport)
        column.addArrangedSubview(summaryLabel)
        content.addSubview(column)

        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor,
                                            constant: 14),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor,
                                             constant: -14),
            column.topAnchor.constraint(equalTo: content.topAnchor,
                                        constant: 9),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor,
                                           constant: -9),
            transport.widthAnchor.constraint(equalTo: column.widthAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 30),
            playButton.heightAnchor.constraint(equalToConstant: 30),
            playhead.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        previewState.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.playbackChanged() }
            .store(in: &observers)
        simulator.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateSurfaces() }
            .store(in: &observers)

        Task { [weak self] in
            guard let self else { return }
            let poster = await VideoDeveloper.posterFrame(of: asset)
            posterView.setImage(poster)
            if let poster { onHistogramSample?(SessionHistogramPanelView.count(poster)) }
            updateSurfaces()
            if let summary = await loadSummary() {
                summaryLabel.textValue = [
                    "\(summary.width) × \(summary.height)",
                    frameRateString(summary.frameRate),
                    summary.hasAudio ? "audio" : "",
                ].filter { !$0.isEmpty }.joined(separator: "   ")
            }
        }
        Task { [weak self] in
            guard let self else { return }
            await simulator.attach(to: previewState.player, asset: asset,
                                   quality: playbackQuality,
                                   encoding: sourceEncoding)
        }
    }

    #if canImport(UIKit)
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        leaving()
    }
    #else
    override func viewWillDisappear() {
        super.viewWillDisappear()
        leaving()
    }
    #endif

    private func leaving() {
        previewState.pause()
        refreshTask?.cancel()
    }

    /// The window hands the session down: everything the develop depends on, plus whether an export
    /// has the engine.
    func configure(stock: FilmStock?, stockID: String, formatID: String,
                   options: FotufilmEngine.Options,
                   sourceEncoding: VideoSourceEncoding,
                   locked: Bool, exportFrame: PlatformImage?) {
        let encodingChanged = sourceEncoding != self.sourceEncoding
        self.stock = stock
        self.stockID = stockID
        self.formatID = formatID
        self.options = options
        self.sourceEncoding = sourceEncoding
        if locked != self.locked {
            self.locked = locked
            if locked { previewState.pause() }
            updateScrubberEnabled()
        }
        lockedView.setImage(exportFrame ?? pausedFrame ?? posterView.image)

        if encodingChanged {
            Task { [weak self] in
                guard let self else { return }
                await simulator.attach(to: previewState.player, asset: asset,
                                       quality: playbackQuality,
                                       encoding: sourceEncoding)
            }
        }

        let simulatorRequest = SimulatorRequest(stockID: stockID,
                                                formatID: formatID,
                                                options: OptionsKey(options),
                                                locked: locked)
        if simulatorRequest != lastSimulatorRequest {
            lastSimulatorRequest = simulatorRequest
            if !locked, let stock {
                simulator.update(stock: stock, stockID: stockID,
                                 formatID: formatID, options: options)
            }
        }
        updateSurfaces()
        scheduleFullResolutionPass()
    }

    // MARK: - Playback

    /// Whether the clip is running, and whether it can be asked to — a clip being exported is held
    /// still, and the menu reports it rather than doing nothing.
    var isPlaying: Bool { previewState.isPlaying }
    var canPlay: Bool { !locked }

    /// Also the menu bar's, and the space bar's: the button under the clip is one way to ask, not
    /// the only one.
    func togglePlayback() {
        guard !locked else { return }
        if previewState.isPlaying {
            previewState.pause()
            previewTime = previewState.currentTime
        } else {
            previewState.togglePlayback()
        }
        playbackChanged()
    }

    private func seek() {
        previewState.seek(to: playhead.value)
        previewTime = playhead.value
        updateClock()
    }

    private func scrubbingBegan() {
        isScrubbing = true
        previewState.pause()
        updateSurfaces()
    }

    private func scrubbingEnded() {
        isScrubbing = false
        previewTime = previewState.currentTime
        scheduleFullResolutionPass()
    }

    private func qualityChanged() {
        let selectable = VideoPreviewSimulator.Quality.selectable
        let index = qualityButton.selectedIndex
        guard selectable.indices.contains(index) else { return }
        playbackQuality = selectable[index]
        simulator.setQuality(playbackQuality)
        previewState.seek(to: previewState.currentTime)
    }

    private func playbackChanged() {
        if !previewState.isPlaying { previewTime = previewState.currentTime }
        playButton.setSymbol(
            previewState.isPlaying ? "pause.fill" : "play.fill",
            description: previewState.isPlaying
                ? "Pause preview" : "Play preview")
        updateClock()
        updateSurfaces()
        scheduleFullResolutionPass()
    }

    private func updateClock() {
        let duration = max(previewState.duration, 0.01)
        if playhead.range.upperBound != duration {
            playhead.range = 0 ... duration
        }
        if !playhead.isTracking {
            playhead.value = min(previewState.currentTime, duration)
        }
        elapsed.textValue = clockString(previewState.currentTime)
        total.textValue = clockString(previewState.duration)
    }

    private func updateScrubberEnabled() {
        playButton.isEnabled = !locked
        playhead.isEnabled = !locked
        qualityButton.isEnabled = !locked
        Motion.run(Motion.quick) { [scrubber] in
            scrubber.animated.opacity = self.locked ? 0.4 : 1
        }
    }

    private func updateSurfaces() {
        let showPaused = !locked && !previewState.isPlaying && !isScrubbing
            && overlayCurrent && pausedFrame != nil
        let showPoster = !locked && !simulator.hasFrame
            && posterView.image != nil && !showPaused
        let showLocked = locked && lockedView.image != nil

        lockedView.isHidden = !showLocked
        posterView.isHidden = !showPoster
        playback.isHidden = locked

        if showPaused != !pausedCanvas.isHidden {
            if showPaused { pausedCanvas.isHidden = false }
            Motion.run(Motion.crossfade) { [pausedCanvas] in
                pausedCanvas.animated.opacity = showPaused ? 1 : 0
            } completion: { [pausedCanvas] in
                if !showPaused { pausedCanvas.isHidden = true }
            }
        }

        spinner.isSpinning = previewPending && !previewState.isPlaying
            && !isScrubbing && !locked
    }

    // MARK: - The paused frame

    private struct OptionsKey: Hashable {
        let exposure, kelvin, tint, highlights, shadows: Float
        let saturation, vibrance, grain, halation, couplers, print: Float
        let discGrain: Bool
        let estimatedHalation: Bool
        let localTone: Bool
        let seed: UInt64

        init(_ options: FotufilmEngine.Options) {
            exposure = options.exposureEV
            kelvin = options.whiteBalance.kelvin
            tint = options.whiteBalance.tint
            highlights = options.highlights
            shadows = options.shadows
            saturation = options.saturation
            vibrance = options.vibrance
            grain = options.grainScale
            switch options.grainModel {
            case .clumpField: discGrain = false
            case .discs: discGrain = true
            }
            halation = options.halationScale
            estimatedHalation = options.useEstimatedHalationProfile
            couplers = options.couplerScale
            print = options.printCorrection
            localTone = options.localTone
            seed = options.seed
        }
    }

    private struct PreviewRequest: Hashable {
        let stockID: String
        let formatID: String
        let options: OptionsKey
        let timeTick: Int
        /// Included so the full-resolution pass re-fires when the playhead settles, not just when
        /// it moves.
        let playing: Bool
        let scrubbing: Bool
        let locked: Bool
        let encoding: String
    }

    private struct SimulatorRequest: Hashable {
        let stockID: String
        let formatID: String
        let options: OptionsKey
        let locked: Bool
    }

    private var previewRequest: PreviewRequest {
        PreviewRequest(stockID: stockID, formatID: formatID,
                       options: OptionsKey(options),
                       timeTick: Int((previewTime * 10).rounded()),
                       playing: previewState.isPlaying,
                       scrubbing: isScrubbing, locked: locked,
                       encoding: sourceEncoding.rawValue)
    }

    private func scheduleFullResolutionPass() {
        let request = previewRequest
        guard request != lastPreviewRequest else { return }
        lastPreviewRequest = request
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.refreshPausedFrame(request)
        }
    }

    private func refreshPausedFrame(_ request: PreviewRequest) async {
        guard !locked, let stock else { return }
        guard !previewState.isPlaying, !isScrubbing else {
            overlayCurrent = false
            previewPending = false
            updateSurfaces()
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(110))
        } catch {
            return
        }
        guard !Task.isCancelled, !previewState.isPlaying, !isScrubbing else {
            return
        }

        previewPending = true
        updateSurfaces()
        let seconds = Double(request.timeTick) / 10
        let frameIndex = UInt64(max(0, request.timeTick))
        // Deep and HDR clips develop from the decoder's scene-linear values, the same ones playback
        // feeds the emulsion; shallow SDR still arrives as a colour-managed image.
        let developed: (print: PlatformImage, original: PlatformImage)?
        if let scene = await VideoDeveloper.sceneLinearFrame(
            of: asset, at: seconds, longestSide: 4096,
            encoding: sourceEncoding) {
            developed = await simulator.developFullResolution(
                scene, stock: stock, options: options, frameIndex: frameIndex)
        } else if let frame = await VideoDeveloper.sourceFrame(
            of: asset, at: seconds, longestSide: 4096,
            encoding: sourceEncoding) {
            developed = await simulator.developFullResolution(
                frame, stock: stock, options: options, frameIndex: frameIndex)
        } else {
            previewPending = false
            updateSurfaces()
            return
        }
        guard !Task.isCancelled, previewRequest == request else { return }
        pausedFrame = developed?.print
        pausedOriginal = developed?.original
        overlayCurrent = developed != nil
        previewPending = false
        if let developed {
            pausedCanvas.show(image: developed.print,
                              original: developed.original)
            onHistogramSample?(SessionHistogramPanelView.count(developed.print))
        }
        updateSurfaces()
    }

    private struct ClipSummary: Equatable {
        let duration: TimeInterval
        let width: Int
        let height: Int
        let frameRate: Double
        let hasAudio: Bool
    }

    private func loadSummary() async -> ClipSummary? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform),
              let duration = try? await asset.load(.duration)
        else { return nil }
        let rate = (try? await track.load(.nominalFrameRate)) ?? 0
        let audio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        let transformed = size.applying(transform)
        return ClipSummary(
            duration: duration.seconds,
            width: Int(abs(transformed.width).rounded()),
            height: Int(abs(transformed.height).rounded()),
            frameRate: Double(max(0, rate)),
            hasAudio: !audio.isEmpty)
    }
}
