import Combine
import Foundation

#if canImport(FotufilmCore)
import FotufilmCore
#endif

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Key {
        static let stock = "fotufilm.default-stock"
        static let format = "fotufilm.default-format"
        static let stillRange = "fotufilm.still-dynamic-range"
        static let videoRange = "fotufilm.video-dynamic-range"
        static let renderingMode = "fotufilm.rendering-mode"
        static let negativeViewing = "fotufilm.negative-viewing"
        static let couplerRange = "fotufilm.coupler-range"
        static let couplerSelf = "fotufilm.coupler-self"
        static let discGrain = "fotufilm.disc-grain"
        static let estimatedHalation = "fotufilm.estimated-halation"
        static let couplerBarrierRedGreen = "fotufilm.coupler-barrier-red-green"
        static let couplerBarrierGreenBlue = "fotufilm.coupler-barrier-green-blue"
        static let encodedGrade = "fotufilm.encoded-grade"
        static let videoDevelopQuality = "fotufilm.video-develop-quality"
        static let videoExportBitrate = "fotufilm.video-export-bitrate"
        static let autoStock = "fotufilm.auto-stock"
        static let cameraStock = "fotufilm.camera-stock"
        static let cameraPhotoFormat = "fotufilm.camera-photo-format"
        static let cameraVideoFormat = "fotufilm.camera-video-format"
        static let videoCaptureLog = "fotufilm.video-capture-log"
        static let debugInspector = "fotufilm.debug-inspector"
        static let videoStabilization = "fotufilm.video-stabilization"
        static let cameraGrain = "fotufilm.camera-grain"
        static let cameraFilmBalance = "fotufilm.camera-film-balance"
        static let flash = "fotufilm.flash"
        static let shareCrashReports = "fotufilm.share-crash-reports"
    }

    /// What the lamp does when the shutter opens.
    enum Flash: String, CaseIterable, Identifiable, Sendable {
        case off, auto, on

        var id: String { rawValue }

        var label: String {
            switch self {
            case .off: return "Off"
            case .auto: return "Auto"
            case .on: return "On"
            }
        }

        /// The menu's second line.
        var detail: String {
            switch self {
            case .off: return "Never fires"
            case .auto: return "Fires where the light is short"
            case .on: return "Fires on every frame"
            }
        }

        /// The mark that names this state, the way every camera draws it.
        var symbol: String {
            switch self {
            case .off: return "bolt.slash.fill"
            case .auto: return "bolt.badge.automatic.fill"
            case .on: return "bolt.fill"
            }
        }
    }

    /// Off by house choice: a flash puts light in the room that this film was never metered for, and
    /// a camera that lit a scene without being asked would be changing the photograph rather than
    /// taking it.
    nonisolated static var storedFlash: Flash {
        UserDefaults.standard.string(forKey: Key.flash)
            .flatMap(Flash.init(rawValue:)) ?? .off
    }

    nonisolated static func rememberFlash(_ mode: Flash) {
        UserDefaults.standard.set(mode.rawValue, forKey: Key.flash)
    }

    /// Film selection retained for the next camera session, including no-film mode.
    nonisolated static var storedCameraStockID: String? {
        UserDefaults.standard.string(forKey: Key.cameraStock)
    }

    /// Written from the camera when the wall settles, not on every card it passes.
    nonisolated static func rememberCameraStock(_ id: String) {
        UserDefaults.standard.set(id, forKey: Key.cameraStock)
    }

    /// The negative the shutter takes — a size in pixels, or ProRAW.
    nonisolated static var storedCameraPhotoFormat: String? {
        UserDefaults.standard.string(forKey: Key.cameraPhotoFormat)
    }

    nonisolated static func rememberCameraPhotoFormat(_ id: String) {
        UserDefaults.standard.set(id, forKey: Key.cameraPhotoFormat)
    }

    /// The clip the camera records — a frame size and the rate it is shot at, held as the camera's
    /// own id for the same reason the negative's size is: the list belongs to the lens, and a phone
    /// with no 4K never offers it.
    nonisolated static var storedCameraVideoFormat: String? {
        UserDefaults.standard.string(forKey: Key.cameraVideoFormat)
    }

    nonisolated static func rememberCameraVideoFormat(_ id: String) {
        UserDefaults.standard.set(id, forKey: Key.cameraVideoFormat)
    }

    /// How much of the shake the camera takes out of a recording. Every mode above off is paid for
    /// in field of view, and the cinematic ones also hold frames back before releasing them, so it
    /// is a trade rather than a quality setting — and it is a camera choice, held next to the clip
    /// size, because which modes exist is the lens and its format answering, not this app.
    ///
    /// The AVFoundation mode behind each case lives on the camera, so this file — which the Mac
    /// compiles too — keeps no capture types.
    enum VideoStabilization: String, CaseIterable, Identifiable, Sendable {
        case off, standard, cinematic, cinematicExtended, enhanced

        var id: String { rawValue }

        var label: String {
            switch self {
            case .off: return "Off"
            case .standard: return "Standard"
            case .cinematic: return "Cinematic"
            case .cinematicExtended: return "Cinematic Extended"
            case .enhanced: return "Cinematic Enhanced"
            }
        }

        /// The menu's second line: what the mode costs to give what it gives.
        var detail: String {
            switch self {
            case .off: return "The whole frame, no added delay"
            case .standard: return "A little steadier, a little tighter"
            case .cinematic: return "Tighter still, and frames arrive later"
            case .cinematicExtended: return "Steadiest, at the most crop and delay"
            case .enhanced: return "Steadier than Extended for the same delay"
            }
        }
    }

    /// Disabled by default because stabilisation crops beyond the viewfinder framing.
    nonisolated static var storedVideoStabilization: VideoStabilization {
        UserDefaults.standard.string(forKey: Key.videoStabilization)
            .flatMap(VideoStabilization.init(rawValue:)) ?? .off
    }

    nonisolated static func rememberVideoStabilization(_ mode: VideoStabilization) {
        UserDefaults.standard.set(mode.rawValue, forKey: Key.videoStabilization)
    }

    /// Camera grain starts off so the full-resolution viewfinder can hold 60 fps. Turning it on
    /// is an explicit camera choice and caps capture at 30 fps, where the measured grain field has
    /// its complete frame budget.
    nonisolated static var storedCameraGrainEnabled: Bool {
        UserDefaults.standard.bool(forKey: Key.cameraGrain)
    }

    nonisolated static func rememberCameraGrainEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Key.cameraGrain)
    }

    /// The camera never runs automatic white balance. It assumes the illuminant the loaded
    /// emulsion was designed for, or the light the photographer names.
    enum CameraFilmBalance: String, CaseIterable, Identifiable, Sendable {
        case film, household, tungsten, mixed, daylight, overcast

        var id: String { rawValue }

        var label: String {
            switch self {
            case .film: return "DEFAULT"
            case .household: return "2856K"
            case .tungsten: return "3200K"
            case .mixed: return "4300K"
            case .daylight: return "5500K"
            case .overcast: return "6500K"
            }
        }

        var fixedKelvin: Float? {
            switch self {
            case .film: return nil
            case .household: return 2856
            case .tungsten: return 3200
            case .mixed: return 4300
            case .daylight: return 5500
            case .overcast: return 6500
            }
        }

        func kelvin(filmReference: Float?) -> Float {
            fixedKelvin ?? filmReference ?? 5500
        }
    }

    /// Follow Film is the physical default: expose a daylight stock under 5500 K and a tungsten
    /// stock under 3200 K until the photographer explicitly names the other lighting condition.
    nonisolated static var storedCameraFilmBalance: CameraFilmBalance {
        UserDefaults.standard.string(forKey: Key.cameraFilmBalance)
            .flatMap(CameraFilmBalance.init(rawValue:)) ?? .film
    }

    nonisolated static func rememberCameraFilmBalance(_ balance: CameraFilmBalance) {
        UserDefaults.standard.set(balance.rawValue, forKey: Key.cameraFilmBalance)
    }

    /// The gauge, pinned from the camera or the editor alike.
    nonisolated static func rememberFormat(_ id: String?) {
        if let id {
            UserDefaults.standard.set(id, forKey: Key.format)
        } else {
            UserDefaults.standard.removeObject(forKey: Key.format)
        }
    }

    /// How an export evaluates the film's transcendentals.
    enum RenderingMode: String, CaseIterable, Identifiable, Sendable {
        case accurate, fast

        var id: String { rawValue }

        var label: String {
            switch self {
            case .accurate: return "Accurate"
            case .fast: return "Fast"
            }
        }
    }

    /// Accurate is free on the Mac's bandwidth-bound GPU and costs a phone its thermal budget.
    nonisolated static var defaultRenderingMode: RenderingMode {
        #if os(macOS)
        return .accurate
        #else
        return .fast
        #endif
    }

    /// Whether a clip develops at its own resolution or at the fast path's internal 1080p.
    enum VideoDevelopQuality: String, CaseIterable, Identifiable, Sendable {
        case full, fast

        var id: String { rawValue }

        var label: String {
            switch self {
            case .full: return "Full"
            case .fast: return "Fast"
            }
        }

        /// The internal long edge the fast path develops at, nil for full.
        var developLongEdge: Int? {
            guard self == .fast else { return nil }
            return ProcessInfo.processInfo.environment["FOTUFILM_FAST_EDGE"]
                .flatMap(Int.init) ?? 1920
        }
    }

    nonisolated static var storedVideoDevelopQuality: VideoDevelopQuality {
        UserDefaults.standard.string(forKey: Key.videoDevelopQuality)
            .flatMap(VideoDevelopQuality.init(rawValue:)) ?? .full
    }

    /// What a developed clip is allowed to spend per pixel.
    enum VideoExportBitrate: String, CaseIterable, Identifiable, Sendable {
        case automatic, smaller, higher, maximum

        var id: String { rawValue }

        var label: String {
            switch self {
            case .automatic: return "Automatic"
            case .smaller: return "Smaller Files"
            case .higher: return "Higher Quality"
            case .maximum: return "Maximum"
            }
        }

        /// Bits per pixel per frame, nil to leave the rate to VideoToolbox.
        func bitsPerPixel(hdr: Bool) -> Double? {
            switch self {
            case .automatic: return nil
            case .smaller:   return hdr ? 0.18 : 0.12
            case .higher:    return hdr ? 0.36 : 0.24
            case .maximum:   return hdr ? 0.54 : 0.36
            }
        }
    }

    nonisolated static var storedVideoExportBitrate: VideoExportBitrate {
        UserDefaults.standard.string(forKey: Key.videoExportBitrate)
            .flatMap(VideoExportBitrate.init(rawValue:)) ?? .automatic
    }

    /// Only ever about the last mile: the film develops highlights above display white either way,
    /// and this decides whether they are rolled into paper white or given the room a modern screen
    /// has.
    enum DynamicRange: String, CaseIterable, Identifiable, Sendable {
        case sdr, hdr

        var id: String { rawValue }

        var label: String {
            switch self {
            case .sdr: return "SDR"
            case .hdr: return "HDR"
            }
        }
    }

    /// The `stored*` readers are `nonisolated` because `EditState`, the camera and the shutter
    /// resolve them during initialisation — off the main actor, from value types with no business
    /// knowing about an observable object.
    nonisolated static var storedStillDynamicRange: DynamicRange {
        UserDefaults.standard.string(forKey: Key.stillRange)
            .flatMap(DynamicRange.init(rawValue:)) ?? .sdr
    }

    nonisolated static var storedVideoDynamicRange: DynamicRange {
        UserDefaults.standard.string(forKey: Key.videoRange)
            .flatMap(DynamicRange.init(rawValue:)) ?? .sdr
    }

    /// Falls back wherever the stored choice is one this device cannot write;
    /// `stillHDRContainer` below is where that is decided.
    nonisolated static func rememberDynamicRange(_ range: DynamicRange,
                                                 forVideo: Bool) {
        UserDefaults.standard.set(range.rawValue,
                                  forKey: forVideo ? Key.videoRange
                                                   : Key.stillRange)
    }

    /// Photographs take the gain map wherever it can be written, since it is the one that survives
    /// being looked at on an SDR screen.
    nonisolated static var stillHDRContainer: Rendered.HDRContainer {
        Rendered.HDRContainer.gainMap.isAvailable ? .gainMap : .hlg
    }

    nonisolated static var storedNegativeViewing: NegativeViewing {
        UserDefaults.standard.string(forKey: Key.negativeViewing)
            .flatMap(NegativeViewing.init(rawValue:)) ?? .lightBox
    }

    nonisolated static var storedRenderingMode: RenderingMode {
        UserDefaults.standard.string(forKey: Key.renderingMode)
            .flatMap(RenderingMode.init(rawValue:)) ?? defaultRenderingMode
    }

    nonisolated static var storedStockID: String? {
        UserDefaults.standard.string(forKey: Key.stock)
    }

    /// Nil — the house choice — starts each photograph on the gauge its film is known on.
    nonisolated static var storedFormatID: String? {
        UserDefaults.standard.string(forKey: Key.format)
    }

    @Published var stockID: String {
        didSet { UserDefaults.standard.set(stockID, forKey: Key.stock) }
    }

    @Published var formatID: String? {
        didSet {
            if let formatID {
                UserDefaults.standard.set(formatID, forKey: Key.format)
            } else {
                UserDefaults.standard.removeObject(forKey: Key.format)
            }
        }
    }

    /// Each screen holds its own `AppSettings`, so a published property reaches only the settings
    /// screen that moved it — an editor standing open needs telling.
    nonisolated static let stillDynamicRangeChanged =
        Notification.Name("fotufilm.stillDynamicRangeChanged")

    @Published var stillDynamicRange: DynamicRange {
        didSet {
            UserDefaults.standard.set(stillDynamicRange.rawValue,
                                      forKey: Key.stillRange)
            NotificationCenter.default.post(
                name: Self.stillDynamicRangeChanged, object: nil)
        }
    }

    nonisolated static let videoDynamicRangeChanged =
        Notification.Name("fotufilm.videoDynamicRangeChanged")

    @Published var videoDynamicRange: DynamicRange {
        didSet {
            UserDefaults.standard.set(videoDynamicRange.rawValue,
                                      forKey: Key.videoRange)
            NotificationCenter.default.post(
                name: Self.videoDynamicRangeChanged, object: nil)
        }
    }

    @Published var renderingMode: RenderingMode {
        didSet {
            UserDefaults.standard.set(renderingMode.rawValue,
                                      forKey: Key.renderingMode)
        }
    }

    @Published var videoDevelopQuality: VideoDevelopQuality {
        didSet {
            UserDefaults.standard.set(videoDevelopQuality.rawValue,
                                      forKey: Key.videoDevelopQuality)
        }
    }

    @Published var videoExportBitrate: VideoExportBitrate {
        didSet {
            UserDefaults.standard.set(videoExportBitrate.rawValue,
                                      forKey: Key.videoExportBitrate)
        }
    }

    @Published var negativeViewing: NegativeViewing {
        didSet {
            UserDefaults.standard.set(negativeViewing.rawValue,
                                      forKey: Key.negativeViewing)
        }
    }

    /// Whether HDR recording takes the sensor's log signal rather than the
    /// ISP's finished HLG picture.
    nonisolated static var storedVideoCaptureLog: Bool {
        UserDefaults.standard.object(forKey: Key.videoCaptureLog) as? Bool
            ?? true
    }

    nonisolated static let videoCaptureLogChanged =
        Notification.Name("fotufilm.videoCaptureLogChanged")

    @Published var videoCaptureLog: Bool {
        didSet {
            UserDefaults.standard.set(videoCaptureLog,
                                      forKey: Key.videoCaptureLog)
            NotificationCenter.default.post(
                name: Self.videoCaptureLogChanged, object: nil)
        }
    }

    nonisolated static let filmModelChanged =
        Notification.Name("fotufilm.filmModelChanged")

    /// How far the released development inhibitor reaches through the layer
    /// stack, as a multiple of what each film's pack states. Applies to both
    /// interlayers together unless one of them has been set on its own.
    @Published var couplerRange: Double {
        didSet {
            UserDefaults.standard.set(Self.clampCoupler(couplerRange),
                                      forKey: Key.couplerRange)
            NotificationCenter.default.post(
                name: Self.filmModelChanged, object: nil)
        }
    }

    /// The same reach through one interlayer only — the red–green scavenger interlayer, and the
    /// green–blue yellow filter layer. Each is stored only once it has been moved; while both are
    /// unset the two are linked and `couplerRange` drives them, which is what a single reach has
    /// always meant. So there is no mode to persist and nothing to migrate.
    @Published var couplerBarrierRedGreen: Double {
        didSet {
            UserDefaults.standard.set(Self.clampCoupler(couplerBarrierRedGreen),
                                      forKey: Key.couplerBarrierRedGreen)
            NotificationCenter.default.post(
                name: Self.filmModelChanged, object: nil)
        }
    }

    @Published var couplerBarrierGreenBlue: Double {
        didSet {
            UserDefaults.standard.set(Self.clampCoupler(couplerBarrierGreenBlue),
                                      forKey: Key.couplerBarrierGreenBlue)
            NotificationCenter.default.post(
                name: Self.filmModelChanged, object: nil)
        }
    }

    /// How much of a layer's inhibition of *itself* is carried separately.
    @Published var couplerSelf: Double {
        didSet {
            UserDefaults.standard.set(Self.clampCoupler(couplerSelf),
                                      forKey: Key.couplerSelf)
            NotificationCenter.default.post(
                name: Self.filmModelChanged, object: nil)
        }
    }

    /// Whether the editor's diagnostic light-path overlay is enabled.
    nonisolated static var storedDebugInspector: Bool {
        UserDefaults.standard.bool(forKey: Key.debugInspector)
    }

    nonisolated static let debugInspectorChanged =
        Notification.Name("fotufilm.debugInspectorChanged")

    /// Crash sharing is a separate, explicit consent. It starts off and is never inferred from
    /// Apple's system-wide analytics choice.
    nonisolated static var storedShareCrashReports: Bool {
        UserDefaults.standard.bool(forKey: Key.shareCrashReports)
    }

    nonisolated static let crashReportSharingChanged =
        Notification.Name("fotufilm.crashReportSharingChanged")

    @Published var shareCrashReports: Bool {
        didSet {
            UserDefaults.standard.set(shareCrashReports,
                                      forKey: Key.shareCrashReports)
            NotificationCenter.default.post(
                name: Self.crashReportSharingChanged, object: nil)
        }
    }

    @Published var debugInspector: Bool {
        didSet {
            UserDefaults.standard.set(debugInspector, forKey: Key.debugInspector)
            NotificationCenter.default.post(
                name: Self.debugInspectorChanged, object: nil)
        }
    }

    /// Uses the resolved-grain Boolean model when a stock's grains cover at least one output
    /// pixel. Below that scale the two models converge, so the engine keeps the calibrated clump
    /// field rather than paying for indistinguishable discs.
    nonisolated static var storedDiscGrainEnabled: Bool {
        UserDefaults.standard.bool(forKey: Key.discGrain)
    }

    @Published var discGrainEnabled: Bool {
        didSet {
            UserDefaults.standard.set(discGrainEnabled, forKey: Key.discGrain)
            NotificationCenter.default.post(name: Self.filmModelChanged, object: nil)
        }
    }

    /// Default estimated-halation setting derived from the stored 1080p30 capability measurement.
    nonisolated static var defaultEstimatedHalationEnabled: Bool {
        HalationCapability.capableDefault
    }

    nonisolated static var storedEstimatedHalationEnabled: Bool {
        if UserDefaults.standard.object(forKey: Key.estimatedHalation) != nil {
            return UserDefaults.standard.bool(forKey: Key.estimatedHalation)
        }
        return defaultEstimatedHalationEnabled
    }

    @Published var estimatedHalationEnabled: Bool {
        didSet {
            if !adoptingEstimatedHalationDefault {
                UserDefaults.standard.set(estimatedHalationEnabled,
                                          forKey: Key.estimatedHalation)
            }
            NotificationCenter.default.post(name: Self.filmModelChanged, object: nil)
        }
    }

    private var adoptingEstimatedHalationDefault = false

    /// Re-reads the estimated-halation default after the capability probe lands, without
    /// recording it as the user's own choice — a later device or OS may earn a different
    /// verdict, and an untouched switch should follow it.
    func adoptEstimatedHalationDefault() {
        guard UserDefaults.standard.object(forKey: Key.estimatedHalation) == nil,
              estimatedHalationEnabled != Self.defaultEstimatedHalationEnabled
        else { return }
        adoptingEstimatedHalationDefault = true
        estimatedHalationEnabled = Self.defaultEstimatedHalationEnabled
        adoptingEstimatedHalationDefault = false
    }

    /// 0…3×.
    nonisolated static func clampCoupler(_ value: Double) -> Double {
        min(max(value, 0), 3)
    }

    /// Probed, not read — `double(forKey:)` cannot tell an unset key from a stored zero, and zero
    /// is a legitimate setting here whose wrong answer is silently another film.
    nonisolated static var storedCouplerRange: Double {
        guard UserDefaults.standard.object(forKey: Key.couplerRange) != nil
        else { return 1 }
        return clampCoupler(UserDefaults.standard.double(forKey: Key.couplerRange))
    }

    nonisolated static var storedCouplerSelf: Double {
        guard UserDefaults.standard.object(forKey: Key.couplerSelf) != nil
        else { return 1 }
        return clampCoupler(UserDefaults.standard.double(forKey: Key.couplerSelf))
    }

    /// Falls back to the linked reach while a gap has never been set on its own, so an install that
    /// predates the per-gap controls keeps rendering exactly what it rendered.
    nonisolated static func storedCouplerBarrier(_ key: String) -> Double {
        guard UserDefaults.standard.object(forKey: key) != nil
        else { return storedCouplerRange }
        return clampCoupler(UserDefaults.standard.double(forKey: key))
    }

    nonisolated static var storedCouplerBarrierRedGreen: Double {
        storedCouplerBarrier(Key.couplerBarrierRedGreen)
    }

    nonisolated static var storedCouplerBarrierGreenBlue: Double {
        storedCouplerBarrier(Key.couplerBarrierGreenBlue)
    }

    /// Back to the pack's own film model. One method rather than four assignments, because clearing
    /// the per-gap keys has to happen after they are written, and a screen that got the order wrong
    /// would leave a gap pinned at 1 instead of following the linked reach.
    func resetCouplerGeometry() {
        couplerRange = 1
        couplerSelf = 1
        couplerBarrierRedGreen = 1
        couplerBarrierGreenBlue = 1
        UserDefaults.standard.removeObject(forKey: Key.couplerBarrierRedGreen)
        UserDefaults.standard.removeObject(forKey: Key.couplerBarrierGreenBlue)
    }

    nonisolated static var isCouplerGeometryAdjusted: Bool {
        storedCouplerRange != 1 || storedCouplerSelf != 1
            || storedCouplerBarrierRedGreen != 1
            || storedCouplerBarrierGreenBlue != 1
    }

    nonisolated static var isFilmModelAdjusted: Bool {
        isCouplerGeometryAdjusted || storedDiscGrainEnabled
            || storedEstimatedHalationEnabled != defaultEstimatedHalationEnabled
    }

    /// Whether three-way grading operates on the sRGB-encoded signal instead of display-linear light.
    /// Disabled by default to preserve existing non-neutral grades. Neutral grades are unchanged.
    nonisolated static var storedGradeSpace: ColorGrade.Space {
        UserDefaults.standard.bool(forKey: Key.encodedGrade) ? .encoded : .linear
    }

    /// Low Power Mode is the user saying the phone is in no state for exact arithmetic; a serious
    /// thermal state is the phone saying it.
    nonisolated static var isUnderPowerPressure: Bool {
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled { return true }
        switch info.thermalState {
        case .serious, .critical: return true
        default: return false
        }
    }

    /// The mode a develop runs in, as opposed to the one the user picked.
    nonisolated static var effectiveRenderingMode: RenderingMode {
        let chosen = storedRenderingMode
        #if os(iOS)
        if chosen == .accurate, isUnderPowerPressure { return .fast }
        #endif
        return chosen
    }

    /// Whether a photograph opened for the first time picks its own film.
    nonisolated static var storedAutoStock: Bool {
        UserDefaults.standard.bool(forKey: Key.autoStock)
    }

    @Published var autoStock: Bool {
        didSet {
            UserDefaults.standard.set(autoStock, forKey: Key.autoStock)
        }
    }

    private init() {
        autoStock = Self.storedAutoStock
        stockID = Self.storedStockID ?? StockPreset.houseDefaultID
        formatID = Self.storedFormatID
        stillDynamicRange = Self.storedStillDynamicRange
        videoDynamicRange = Self.storedVideoDynamicRange
        videoCaptureLog = Self.storedVideoCaptureLog
        renderingMode = Self.storedRenderingMode
        videoDevelopQuality = Self.storedVideoDevelopQuality
        videoExportBitrate = Self.storedVideoExportBitrate
        negativeViewing = Self.storedNegativeViewing
        couplerRange = Self.storedCouplerRange
        couplerSelf = Self.storedCouplerSelf
        discGrainEnabled = Self.storedDiscGrainEnabled
        estimatedHalationEnabled = Self.storedEstimatedHalationEnabled
        couplerBarrierRedGreen = Self.storedCouplerBarrierRedGreen
        couplerBarrierGreenBlue = Self.storedCouplerBarrierGreenBlue
        shareCrashReports = Self.storedShareCrashReports
        debugInspector = Self.storedDebugInspector
        HalationCapability.probeSoon()
    }

    /// Back to the house choices.
    func reset() {
        stockID = StockPreset.houseDefaultID
        autoStock = false
        formatID = nil
        stillDynamicRange = .sdr
        videoDynamicRange = .sdr
        videoCaptureLog = true
        renderingMode = Self.defaultRenderingMode
        videoDevelopQuality = .full
        videoExportBitrate = .automatic
        negativeViewing = .lightBox
        resetCouplerGeometry()
        discGrainEnabled = false
        estimatedHalationEnabled = Self.defaultEstimatedHalationEnabled
        shareCrashReports = false
        debugInspector = false
    }
}
