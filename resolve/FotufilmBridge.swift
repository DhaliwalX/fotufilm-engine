import Foundation

@_silgen_name("fotufilm_halide_metal_context_create")
private func createMetalContext() -> UnsafeMutableRawPointer?
@_silgen_name("fotufilm_halide_metal_context_destroy")
private func destroyMetalContext(_ context: UnsafeMutableRawPointer?)
@_silgen_name("fotufilm_halide_metal_context_bind")
private func bindMetalContext(_ context: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
@_silgen_name("fotufilm_halide_metal_context_restore")
private func restoreMetalContext(_ context: UnsafeMutableRawPointer?)

/// Loading mutates the process-wide stock registry once. Rendering does not take this lock: each
/// effect instance owns its mutable Metal arguments and LUT cache in the context below.
private let initializationLock = NSLock()
nonisolated(unsafe) private var initializationError = ""

/// Stock ids in the engine's display order.
nonisolated(unsafe) private var stockIDs: [String] = []

/// Everything mutable that belongs to one OFX effect instance. The OFX instance-safe contract
/// prevents two renders from entering the same context concurrently; the lock also keeps sequence
/// warm-up and error reads from racing a render action.
private final class BridgeContext {
    let lock = NSLock()
    let metalContext: UnsafeMutableRawPointer
    var lastError: String
    var frameStaging: FilmFrameStaging?
    var outputQuery: OutputTransformQuery?

    init?(lastError: String) {
        guard let metalContext = createMetalContext() else { return nil }
        self.metalContext = metalContext
        self.lastError = lastError
    }

    func releaseStaging() {
        guard let staging = frameStaging else { return }
        frameStaging = nil
        HalideMetalFilmRenderer.shared?.recycleFrameStaging(staging)
    }

    func withMetalContext<Result>(_ body: () -> Result) -> Result {
        let previous = bindMetalContext(metalContext)
        defer { restoreMetalContext(previous) }
        return body()
    }

    deinit {
        releaseStaging()
        destroyMetalContext(metalContext)
    }
}

/// Cache key for output-variant availability. Seed and frame number are excluded because they do
/// not affect the feature mask. Whether the frame is staged is part of it: a staged render may
/// ask for the kernel that measures its own glare and a striped one never does.
private struct OutputTransformQueryKey: Equatable {
    let stock: Int32
    let format: Int32
    let paper: Int32
    let width: Int32
    let height: Int32
    let interactive: Int32
    let staged: Bool
    let parameters: [Float]
}

private struct OutputTransformQuery {
    let key: OutputTransformQueryKey
    let answer: Int32
}

private func context(_ opaque: UnsafeMutableRawPointer?) -> BridgeContext? {
    guard let opaque else { return nil }
    return Unmanaged<BridgeContext>.fromOpaque(opaque).takeUnretainedValue()
}

private func currentInitializationError() -> String {
    initializationLock.lock()
    defer { initializationLock.unlock() }
    return initializationError
}

private func licenseAllowsDevelopment(_ context: BridgeContext) -> Bool {
    guard FotufilmLicense.status().isActive else {
        context.lastError = FotufilmLicense.inactiveMessage
        return false
    }
    return true
}

/// The Resolve realtime schedule is the shipped default. Setting `FOTUFILM_REALTIME=0` before
/// Resolve starts restores the reference decode, film arithmetic, glare measurement, and output
/// encode for comparison without requiring a different plugin build.
nonisolated(unsafe) private var realtimeRenderingEnabled = true

/// Indices into the flat parameter array the host sends.
private enum Parameter {
    static let exposureEV = 0
    static let temperature = 1
    static let tint = 2
    static let highlights = 3
    static let shadows = 4
    static let saturation = 5
    static let vibrance = 6
    static let grainScale = 7
    static let halationScale = 8
    static let couplerScale = 9
    static let printCorrection = 10
    static let localTone = 11
    static let pushPull = 12
    static let bleachBypass = 13
    static let expiredYears = 14
    static let printLight = 15
    static let stage = 16
    static let textureStages = 17
    static let flareScale = 18
    static let estimatedHalation = 19
    static let halationColour = 20
    static let lensFilter1 = 21
    static let lensFilter2 = 22
    static let lensFilter3 = 23
    static let metering = 24
    static let diffusionFamily = 25
    static let diffusionGrade = 26
    static let focalLength = 27
    static let negativeViewing = 28
    static let mottleOverride = 29
    static let mottleShare = 30
    static let couplerReach = 31
    static let couplerSelf = 32
    static let sceneIlluminant = 33
    static let halation400 = 34
    static let halation450 = 35
    static let halation500 = 36
    static let halation550 = 37
    static let halation600 = 38
    static let halation650 = 39
    static let halation700 = 40
    static let filterCoating = 41
    static let frameCoverage = 42
    static let grainModel = 43
    static let shutterSeconds = 44
    static let renderMode = 45
    static let grainFrozen = 46
    static let couplerRedGreen = 47
    static let couplerGreenBlue = 48
    static let count = 49
}

/// The filter drawer, in the order a host's menu indexes it. The catalogue is the engine's, so
/// the host's menu is the engine's list plus a "None" the plugin owns.
private let lensFilters = LensFilter.catalogue

/// How the exposure was set behind that glass, and the two halves of a diffusion filter, each in
/// the enum's own `allCases` order.
private let meterings = LensFilterCompensation.allCases
private let diffusionFamilies = DiffusionFilter.Family.allCases
private let diffusionGrades = DiffusionFilter.Grade.allCases

/// The grade the engine's command line takes when none is named, published so the two sides
/// cannot disagree about which entry a host should land its menu on.
private let defaultDiffusionGrade = DiffusionFilter.Grade.quarter

/// How a developed negative is read.
private let negativeViewings = NegativeViewing.allCases

/// The spans, in the order the host's menu indexes them.
private let stages = PipelineStage.allCases

/// The spatial stages the texture span can be asked for, in the order the host lists them.
private let textureStages = TextureStages.ordered

/// Copies `value` into the caller's buffer as a NUL-terminated C string,
/// returning the length written.
private func copyOut(_ value: String, _ out: UnsafeMutablePointer<CChar>?,
                     _ capacity: Int32) -> Int32 {
    guard let out, capacity > 0 else { return -1 }
    let bytes = Array(value.utf8)
    guard bytes.count + 1 <= Int(capacity) else { return -1 }
    for (i, byte) in bytes.enumerated() { out[i] = CChar(bitPattern: byte) }
    out[bytes.count] = 0
    return Int32(bytes.count)
}

/// The output media the host can choose between, in a fixed order the host's choice indexes into.
private let papers = PrintPaper.allCases

/// A float slot read as the small non-negative integer it is carrying. Saturating rather than
/// trapping: the host's parameter array is checked for finiteness on its own side, and a bridge
/// that crashed the host over a bad float would be the worse failure.
private func whole(_ value: Float) -> Int32 {
    guard value.isFinite, value > 0 else { return 0 }
    return Int32(min(value, Float(Int16.max)))
}

/// The span the parameter array names, or nil when it names one this build does not have.
///
/// Returns nil for unsupported spans. Falling back to `full` could cause a developed negative to
/// be printed twice by the node graph.
private func stage(of parameters: UnsafePointer<Float>?) -> PipelineStage? {
    guard let parameters else { return .full }
    return PipelineStage(ordinal: whole(parameters[Parameter.stage]))
}

/// Reads the flat parameter array back into the options the engine takes.
private func options(_ parameters: UnsafePointer<Float>?,
                     format: Int32, stockIndex: Int32, paper: Int32,
                     seed: UInt32) -> FotufilmEngine.Options {
    var result = FotufilmEngine.Options()

    // Chosen before the early return, because the paper is not carried in the float array and a
    // host that sends no parameters still prints on something.
    if papers.indices.contains(Int(paper)) {
        result.paper = papers[Int(paper)]
    }
    // A medium the stock cannot reach — a reversal stock has only its own direct positive — is
    // substituted by the engine, which resolves `options.paper` against the stock it is handed.

    guard let parameters else { return result }
    func value(_ index: Int) -> Float { parameters[index] }

    result.exposureEV = value(Parameter.exposureEV)
    let kelvin = clamp(value(Parameter.temperature),
                       WhiteBalance.kelvinRange.lowerBound,
                       WhiteBalance.kelvinRange.upperBound)
    let tint = clamp(value(Parameter.tint),
                     WhiteBalance.tintRange.lowerBound,
                     WhiteBalance.tintRange.upperBound)
    result.whiteBalance = WhiteBalance(kelvin: kelvin, tint: tint)
    result.highlights = clamp(value(Parameter.highlights), -1, 1)
    result.shadows = clamp(value(Parameter.shadows), -1, 1)
    result.localTone = value(Parameter.localTone) != 0
    result.saturation = max(0, value(Parameter.saturation))
    result.vibrance = clamp(value(Parameter.vibrance), -1, 1)
    result.grainScale = max(0, value(Parameter.grainScale))
    result.halationScale = max(0, value(Parameter.halationScale))
    result.couplerScale = max(0, value(Parameter.couplerScale))
    result.printCorrection = max(0, value(Parameter.printCorrection))
    result.developmentEV = value(Parameter.pushPull)
    result.bleachBypass = clamp(value(Parameter.bleachBypass), 0, 1)
    result.expiredYears = max(0, value(Parameter.expiredYears))
    // Zero is each lever's off position, so a slot the host never filled
    // renders exactly as before the lever existed.
    let printLight = value(Parameter.printLight)
    if printLight > 0 { result.printViewingKelvin = printLight }
    // Validated by `stage(of:)` before any render, so an index this build does not have has
    // already been refused by the time this reads it.
    if let chosen = stage(of: parameters) { result.stage = chosen }
    result.textureStages = TextureStages(
        rawValue: whole(value(Parameter.textureStages)) & TextureStages.all.rawValue)
    // Off is this lever's zero too, so a host that never filled the slot renders
    // exactly what it rendered before the lever existed.
    result.flareScale = max(0, value(Parameter.flareScale))
    // And this one's: 0 is the legacy halation model, so a project saved before the
    // checkbox existed renders the halo it always had.
    result.useEstimatedHalationProfile = value(Parameter.estimatedHalation) != 0
    // And this one's: 0 is the film's layered red ring, so a project saved before the
    // slider existed renders the halo it always had.
    result.halationSourceColour = clamp(value(Parameter.halationColour), 0, 1)

    // The lens, in the order the light meets it: what is screwed onto the front, how the
    // exposure was set behind it, and the focal length the scattering is imaged through. The
    // mapping is the command line's, slot for flag: `--filter`, `--metering`, `--diffusion`,
    // `--diffusion-grade`, `--focal`.
    //
    // Each slot's zero is its off position. Three empty threads, no mist and no stated focal
    // length are what every render made before these existed, so a host that never filled the
    // block develops exactly the frame it always did.
    let coating: FilterCoating = value(Parameter.filterCoating) == 1 ? .singleLayer
        : (value(Parameter.filterCoating) == 2 ? .uncoated : .multiCoated)
    var fitted: [LensFilter] = []
    for slot in [Parameter.lensFilter1, Parameter.lensFilter2, Parameter.lensFilter3] {
        let choice = Int(whole(value(slot))) - 1
        guard lensFilters.indices.contains(choice) else { continue }
        var filter = lensFilters[choice]
        // Zero retains the multicoated glass used by every existing project.
        filter.coating = coating
        fitted.append(filter)
    }
    if !fitted.isEmpty {
        // Zero is the engine's own default rather than the first entry, because an unfilled slot
        // has to mean "as before" and the compensation the engine defaults to is through-the-lens.
        let choice = Int(whole(value(Parameter.metering))) - 1
        result.lensFilters = LensFilterStack(
            fitted,
            compensation: meterings.indices.contains(choice) ? meterings[choice] : .throughTheLens)
    }
    let family = Int(whole(value(Parameter.diffusionFamily))) - 1
    if diffusionFamilies.indices.contains(family) {
        // The grade is a bare index, so it needs the family to gate it; on its own, zero would be
        // 1/8 rather than off.
        let grade = Int(whole(value(Parameter.diffusionGrade)))
        result.diffusionFilter = DiffusionFilter.preset(
            diffusionFamilies[family],
            grade: diffusionGrades.indices.contains(grade)
                ? diffusionGrades[grade] : defaultDiffusionGrade,
            coating: coating)
    }
    if value(Parameter.mottleOverride) != 0 {
        result.grainMottleShare = clamp(value(Parameter.mottleShare), 0, 0.9)
        result.completeDeliveryMottle()
    }
    result.couplerRangeScale = clamp(1 + value(Parameter.couplerReach), 0, 3)
    if value(Parameter.couplerRedGreen) != 0 || value(Parameter.couplerGreenBlue) != 0 {
        result.couplerGapReachScales = [Parameter.couplerRedGreen, Parameter.couplerGreenBlue]
            .map { clamp(1 + value($0), 0, 3) * result.couplerRangeScale }
    }
    result.couplerSelfScale = clamp(1 + value(Parameter.couplerSelf), 0, 3)
    let sceneLight = value(Parameter.sceneIlluminant)
    if sceneLight > 0 { result.sceneIlluminantKelvin = sceneLight }
    result.halationReturnGain = HalationSpectrum.resampled(
        (Parameter.halation400...Parameter.halation700).map { value($0) })
    result.frameCoverage = clamp(1 + value(Parameter.frameCoverage), 0.05, 1)
    result.grainModel = value(Parameter.grainModel) == 1 ? .discs : .clumpField
    let shutter = value(Parameter.shutterSeconds)
    if shutter > 0 { result.shutterSeconds = shutter }
    let focal = value(Parameter.focalLength)
    if focal > 0 { result.focalLengthMM = focal }
    // Only where the negative medium was named. A stated viewing mode is the engine's instruction
    // to show the developed negative, whatever medium was asked for, so carrying this slot into a
    // print render would quietly replace the print with the film. Match Film leaves `paper` nil
    // and is not the negative being asked for.
    let viewing = Int(whole(value(Parameter.negativeViewing))) - 1
    if result.paper?.isNegative == true, negativeViewings.indices.contains(viewing) {
        result.negativeViewing = negativeViewings[viewing]
    }

    let formats = FilmFormat.presets
    if formats.indices.contains(Int(format)) {
        result.format = formats[Int(format)].format
    } else if stockIDs.indices.contains(Int(stockIndex)) {
        result.format = FilmFormat.native(forStockID: stockIDs[Int(stockIndex)])
    }
    result.seed = UInt64(seed)
    return result
}

/// `struct FotufilmOutputTransform` as this side sees it: two int32 fields — transfer shape and
/// premultiplication — then a row-major 3x3 and six transfer coefficients, tightly packed.
/// Spelled out field by field because this side of the bridge does not see the plugin's C
/// header, so the two declarations have to be kept beside each other.
private enum OutputTransformField {
    static let transfer = 0
    static let premultiplied = 1
    static let matrix = 0
    static let coefficients = 9
    static let firstFloat = 2 * MemoryLayout<Int32>.size
}

/// `struct FotufilmInputTransform` as this side sees it, laid out exactly as the output transform
/// is and spelled out here for the same reason: this side does not see the plugin's C header.
private enum InputTransformField {
    static let transfer = 0
    static let premultiplied = 1
    static let matrix = 0
    static let coefficients = 9
    static let firstFloat = 2 * MemoryLayout<Int32>.size
}

private func inputTransform(_ pointer: UnsafeRawPointer?) -> FilmInputTransform? {
    guard let pointer else { return nil }
    let flags = pointer.assumingMemoryBound(to: Int32.self)
    let floats = (pointer + InputTransformField.firstFloat)
        .assumingMemoryBound(to: Float.self)
    guard let transfer = FilmInputTransform.Transfer(
        rawValue: flags[InputTransformField.transfer]) else { return nil }
    let matrix = InputTransformField.matrix
    let coefficients = InputTransformField.coefficients
    return FilmInputTransform(
        matrix: (matrix..<(matrix + 9)).map { floats[$0] },
        transfer: transfer,
        coefficients: (coefficients..<(coefficients + 6)).map { floats[$0] },
        premultiplied: flags[InputTransformField.premultiplied] != 0)
}

private func outputTransform(_ pointer: UnsafeRawPointer?) -> FilmOutputTransform? {
    guard let pointer else { return nil }
    let flags = pointer.assumingMemoryBound(to: Int32.self)
    let floats = (pointer + OutputTransformField.firstFloat)
        .assumingMemoryBound(to: Float.self)
    guard let transfer = FilmOutputTransform.Transfer(
        rawValue: flags[OutputTransformField.transfer]) else { return nil }
    let matrix = OutputTransformField.matrix
    let coefficients = OutputTransformField.coefficients
    return FilmOutputTransform(
        matrix: (matrix..<(matrix + 9)).map { floats[$0] },
        transfer: transfer,
        coefficients: (coefficients..<(coefficients + 6)).map { floats[$0] },
        premultiplied: flags[OutputTransformField.premultiplied] != 0)
}

/// The stock an index names, or nil when the pack has changed under the host.
private func stock(at index: Int32) -> FilmStock? {
    guard stockIDs.indices.contains(Int(index)) else { return nil }
    return FilmStock.named(stockIDs[Int(index)])
}

private func validateDevelopment(_ settings: FotufilmEngine.Options,
                                 stock: FilmStock, context: BridgeContext) -> Bool {
    do {
        _ = try stock.pushed(stops: settings.developmentEV)
        return true
    } catch {
        context.lastError = "\(error)"
        return false
    }
}

/// Open whatever sealed packs sit beside the plugin in its own bundle.
///
/// The app gets this for free: its packs are in `Bundle.main` and its key material is compiled in.
/// A plugin has neither — `Bundle.main` is DaVinci Resolve — so it has to name its own Resources
/// directory as the trusted vault location and register the vault key itself. Without the key the
/// pack is an unreadable blob; without the trust it is refused as "a vault pack outside the
/// application bundle". Both are needed, and only the build that owns the file may do either.
private func openSealedPacks(in directory: String) {
    let resources = URL(fileURLWithPath: directory, isDirectory: true)
    let entries = (try? FileManager.default.contentsOfDirectory(
        at: resources, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    let packs = entries.filter {
        $0.pathExtension.lowercased() == FilmStockPack.sealedPathExtension
    }
    guard !packs.isEmpty else { return }

    let keyring = FilmPackKeyring.shared
    if let vault = try? FilmPackKey(bytes: FilmPackKeyMaterial.vaultKey) {
        keyring.register(vault, kind: .vault, id: FilmPackKeyMaterial.vaultKeyID)
    }
    if let community = try? FilmPackKey(bytes: FilmPackKeyMaterial.communityKey) {
        keyring.register(community, kind: .community, id: FilmPackKeyMaterial.communityKeyID)
    }

    FilmStockPack.embeddedSealedPackURLs = packs
    FilmStockPack.reload()
}

@_cdecl("fotufilm_bridge_context_create")
func fotufilm_bridge_context_create() -> UnsafeMutableRawPointer? {
    guard let context = BridgeContext(lastError: currentInitializationError()) else { return nil }
    return Unmanaged.passRetained(context).toOpaque()
}

@_cdecl("fotufilm_bridge_context_destroy")
func fotufilm_bridge_context_destroy(_ opaque: UnsafeMutableRawPointer?) {
    guard let opaque else { return }
    Unmanaged<BridgeContext>.fromOpaque(opaque).release()
}

@_cdecl("fotufilm_bridge_initialize")
func fotufilm_bridge_initialize(_ resources: UnsafePointer<CChar>?) -> Int32 {
    initializationLock.lock()
    defer { initializationLock.unlock() }

    let environment = ProcessInfo.processInfo.environment
    realtimeRenderingEnabled = environment["FOTUFILM_REALTIME"] != "0"

    guard FotufilmLicense.status().isActive else {
        initializationError = FotufilmLicense.inactiveMessage
        stockIDs = []
        return -1
    }

    if let resources {
        let directory = String(cString: resources)
        if environment["FOTUFILM_RESOURCES"] == nil {
            setenv("FOTUFILM_RESOURCES", directory, 1)
        }
        // The plugin's own stocks are the sealed packs beside it, opened below; nothing is added
        // to the engine's plain-JSON search path, so `FOTUFILM_STOCKS` is the engine's business
        // and is left exactly as the host's environment set it.
        openSealedPacks(in: directory)
    }

    if let error = FilmStockPack.loadError {
        initializationError = "\(error)"
        return -1
    }
    initializationError = ""
    stockIDs = FilmStock.presetIDs
    return Int32(stockIDs.count)
}

@_cdecl("fotufilm_bridge_available")
func fotufilm_bridge_available() -> Int32 {
    HalideMetalFilmRenderer.shared != nil ? 1 : 0
}

@_cdecl("fotufilm_bridge_realtime_enabled")
func fotufilm_bridge_realtime_enabled() -> Int32 {
    initializationLock.lock()
    defer { initializationLock.unlock() }
    return realtimeRenderingEnabled ? 1 : 0
}

@_cdecl("fotufilm_bridge_stock_count")
func fotufilm_bridge_stock_count() -> Int32 { Int32(stockIDs.count) }

@_cdecl("fotufilm_bridge_stock_id")
func fotufilm_bridge_stock_id(_ index: Int32, _ out: UnsafeMutablePointer<CChar>?,
                             _ capacity: Int32) -> Int32 {
    guard stockIDs.indices.contains(Int(index)) else { return -1 }
    return copyOut(stockIDs[Int(index)], out, capacity)
}

@_cdecl("fotufilm_bridge_stock_name")
func fotufilm_bridge_stock_name(_ index: Int32, _ out: UnsafeMutablePointer<CChar>?,
                               _ capacity: Int32) -> Int32 {
    guard stockIDs.indices.contains(Int(index)),
          let definition = FilmStock.presetDefinitions[stockIDs[Int(index)]]
    else { return -1 }
    return copyOut(definition.name, out, capacity)
}

@_cdecl("fotufilm_bridge_paper_count")
func fotufilm_bridge_paper_count() -> Int32 { Int32(papers.count) }

@_cdecl("fotufilm_bridge_paper_id")
func fotufilm_bridge_paper_id(_ index: Int32, _ out: UnsafeMutablePointer<CChar>?,
                             _ capacity: Int32) -> Int32 {
    guard papers.indices.contains(Int(index)) else { return -1 }
    return copyOut(papers[Int(index)].id, out, capacity)
}

@_cdecl("fotufilm_bridge_paper_name")
func fotufilm_bridge_paper_name(_ index: Int32, _ out: UnsafeMutablePointer<CChar>?,
                               _ capacity: Int32) -> Int32 {
    guard papers.indices.contains(Int(index)) else { return -1 }
    return copyOut(papers[Int(index)].name, out, capacity)
}

@_cdecl("fotufilm_bridge_paper_is_negative")
func fotufilm_bridge_paper_is_negative(_ index: Int32) -> Int32 {
    guard papers.indices.contains(Int(index)) else { return 0 }
    return papers[Int(index)].isNegative ? 1 : 0
}

@_cdecl("fotufilm_bridge_lens_filter_count")
func fotufilm_bridge_lens_filter_count() -> Int32 { Int32(lensFilters.count) }

@_cdecl("fotufilm_bridge_lens_filter_id")
func fotufilm_bridge_lens_filter_id(_ index: Int32, _ out: UnsafeMutablePointer<CChar>?,
                                   _ capacity: Int32) -> Int32 {
    guard lensFilters.indices.contains(Int(index)) else { return -1 }
    return copyOut(lensFilters[Int(index)].id, out, capacity)
}

@_cdecl("fotufilm_bridge_lens_filter_name")
func fotufilm_bridge_lens_filter_name(_ index: Int32, _ out: UnsafeMutablePointer<CChar>?,
                                     _ capacity: Int32) -> Int32 {
    guard lensFilters.indices.contains(Int(index)) else { return -1 }
    return copyOut(lensFilters[Int(index)].name, out, capacity)
}

@_cdecl("fotufilm_bridge_metering_count")
func fotufilm_bridge_metering_count() -> Int32 { Int32(meterings.count) }

@_cdecl("fotufilm_bridge_metering_id")
func fotufilm_bridge_metering_id(_ index: Int32, _ out: UnsafeMutablePointer<CChar>?,
                                _ capacity: Int32) -> Int32 {
    guard meterings.indices.contains(Int(index)) else { return -1 }
    return copyOut(meterings[Int(index)].rawValue, out, capacity)
}

@_cdecl("fotufilm_bridge_metering_name")
func fotufilm_bridge_metering_name(_ index: Int32, _ out: UnsafeMutablePointer<CChar>?,
                                  _ capacity: Int32) -> Int32 {
    guard meterings.indices.contains(Int(index)) else { return -1 }
    return copyOut(meterings[Int(index)].label, out, capacity)
}

@_cdecl("fotufilm_bridge_diffusion_family_count")
func fotufilm_bridge_diffusion_family_count() -> Int32 { Int32(diffusionFamilies.count) }

@_cdecl("fotufilm_bridge_diffusion_family_id")
func fotufilm_bridge_diffusion_family_id(_ index: Int32, _ out: UnsafeMutablePointer<CChar>?,
                                        _ capacity: Int32) -> Int32 {
    guard diffusionFamilies.indices.contains(Int(index)) else { return -1 }
    return copyOut(diffusionFamilies[Int(index)].rawValue, out, capacity)
}

@_cdecl("fotufilm_bridge_diffusion_family_name")
func fotufilm_bridge_diffusion_family_name(_ index: Int32, _ out: UnsafeMutablePointer<CChar>?,
                                          _ capacity: Int32) -> Int32 {
    guard diffusionFamilies.indices.contains(Int(index)) else { return -1 }
    return copyOut(diffusionFamilies[Int(index)].label, out, capacity)
}

@_cdecl("fotufilm_bridge_diffusion_grade_count")
func fotufilm_bridge_diffusion_grade_count() -> Int32 { Int32(diffusionGrades.count) }

@_cdecl("fotufilm_bridge_diffusion_grade_id")
func fotufilm_bridge_diffusion_grade_id(_ index: Int32, _ out: UnsafeMutablePointer<CChar>?,
                                       _ capacity: Int32) -> Int32 {
    guard diffusionGrades.indices.contains(Int(index)) else { return -1 }
    return copyOut(diffusionGrades[Int(index)].rawValue, out, capacity)
}

/// The grade's name is its id: 1/8 is what the ring says and what the engine takes.
@_cdecl("fotufilm_bridge_diffusion_grade_name")
func fotufilm_bridge_diffusion_grade_name(_ index: Int32, _ out: UnsafeMutablePointer<CChar>?,
                                         _ capacity: Int32) -> Int32 {
    guard diffusionGrades.indices.contains(Int(index)) else { return -1 }
    return copyOut(diffusionGrades[Int(index)].rawValue, out, capacity)
}

@_cdecl("fotufilm_bridge_diffusion_default_grade")
func fotufilm_bridge_diffusion_default_grade() -> Int32 {
    Int32(diffusionGrades.firstIndex(of: defaultDiffusionGrade) ?? 0)
}

@_cdecl("fotufilm_bridge_negative_viewing_count")
func fotufilm_bridge_negative_viewing_count() -> Int32 { Int32(negativeViewings.count) }

@_cdecl("fotufilm_bridge_negative_viewing_id")
func fotufilm_bridge_negative_viewing_id(_ index: Int32, _ out: UnsafeMutablePointer<CChar>?,
                                        _ capacity: Int32) -> Int32 {
    guard negativeViewings.indices.contains(Int(index)) else { return -1 }
    return copyOut(negativeViewings[Int(index)].id, out, capacity)
}

@_cdecl("fotufilm_bridge_negative_viewing_name")
func fotufilm_bridge_negative_viewing_name(_ index: Int32, _ out: UnsafeMutablePointer<CChar>?,
                                          _ capacity: Int32) -> Int32 {
    guard negativeViewings.indices.contains(Int(index)) else { return -1 }
    return copyOut(negativeViewings[Int(index)].name, out, capacity)
}

@_cdecl("fotufilm_bridge_stage_count")
func fotufilm_bridge_stage_count() -> Int32 { Int32(stages.count) }

@_cdecl("fotufilm_bridge_stage_id")
func fotufilm_bridge_stage_id(_ index: Int32, _ out: UnsafeMutablePointer<CChar>?,
                             _ capacity: Int32) -> Int32 {
    guard stages.indices.contains(Int(index)) else { return -1 }
    return copyOut(stages[Int(index)].id, out, capacity)
}

@_cdecl("fotufilm_bridge_stage_name")
func fotufilm_bridge_stage_name(_ index: Int32, _ out: UnsafeMutablePointer<CChar>?,
                               _ capacity: Int32) -> Int32 {
    guard stages.indices.contains(Int(index)) else { return -1 }
    return copyOut(stages[Int(index)].name, out, capacity)
}

@_cdecl("fotufilm_bridge_texture_stage_count")
func fotufilm_bridge_texture_stage_count() -> Int32 { Int32(textureStages.count) }

@_cdecl("fotufilm_bridge_texture_stage_id")
func fotufilm_bridge_texture_stage_id(_ index: Int32, _ out: UnsafeMutablePointer<CChar>?,
                                     _ capacity: Int32) -> Int32 {
    guard textureStages.indices.contains(Int(index)) else { return -1 }
    return copyOut(textureStages[Int(index)].id, out, capacity)
}

@_cdecl("fotufilm_bridge_texture_stage_name")
func fotufilm_bridge_texture_stage_name(_ index: Int32, _ out: UnsafeMutablePointer<CChar>?,
                                       _ capacity: Int32) -> Int32 {
    guard textureStages.indices.contains(Int(index)) else { return -1 }
    return copyOut(textureStages[Int(index)].name, out, capacity)
}

@_cdecl("fotufilm_bridge_texture_stage_mask")
func fotufilm_bridge_texture_stage_mask(_ index: Int32) -> Int32 {
    guard textureStages.indices.contains(Int(index)) else { return 0 }
    return textureStages[Int(index)].value.rawValue
}

@_cdecl("fotufilm_bridge_texture_stage_available")
func fotufilm_bridge_texture_stage_available(_ stockIndex: Int32, _ index: Int32) -> Int32 {
    guard textureStages.indices.contains(Int(index)),
          let stock = stock(at: stockIndex) else { return 0 }
    return TextureStages.offered(by: stock).contains(textureStages[Int(index)].value) ? 1 : 0
}

@_cdecl("fotufilm_bridge_stock_prints")
func fotufilm_bridge_stock_prints(_ stockIndex: Int32) -> Int32 {
    guard let stock = stock(at: stockIndex) else { return 0 }
    return stock.isReversal ? 0 : 1
}

@_cdecl("fotufilm_bridge_control_capabilities")
func fotufilm_bridge_control_capabilities(_ stockIndex: Int32, _ paperIndex: Int32) -> Int32 {
    guard let stock = stock(at: stockIndex) else { return 0 }
    let paper = resolvedPaper(stock: stock, index: paperIndex)
    var flags: Int32 = 0
    if !stock.isMonochrome && !stock.isReversal { flags |= 1 }
    if stock.couplerGeometry != nil { flags |= 2 }
    if stock.grainDensityLaw == .silver { flags |= 32 }
    if stock.couplerInhibition.contains(where: { $0.contains(where: { $0 != 0 }) })
        || stock.adjacencyStrength > 0 {
        flags |= 64
    }
    if stock.reciprocityFailure != nil { flags |= 4 }
    if paper.acceptsViewingIlluminant && !stock.isReversal { flags |= 8 }
    if paper.acceptsPrintCorrection && !stock.isMonochrome && !stock.isReversal { flags |= 16 }
    return flags
}

private func resolvedPaper(stock: FilmStock, index: Int32) -> PrintPaper {
    let requested = papers.indices.contains(Int(index)) ? papers[Int(index)] : nil
    return requested?.resolved(for: stock) ?? PrintPaper.default(for: stock)
}

@_cdecl("fotufilm_bridge_resolved_format")
func fotufilm_bridge_resolved_format(_ stockIndex: Int32, _ format: Int32,
                                   _ out: UnsafeMutablePointer<CChar>?, _ capacity: Int32) -> Int32 {
    guard stockIDs.indices.contains(Int(stockIndex)) else { return -1 }
    let presets = FilmFormat.presets
    let resolved = presets.indices.contains(Int(format)) ? presets[Int(format)].format
        : FilmFormat.native(forStockID: stockIDs[Int(stockIndex)])
    return copyOut(resolved.name, out, capacity)
}

@_cdecl("fotufilm_bridge_resolved_paper")
func fotufilm_bridge_resolved_paper(_ stockIndex: Int32, _ paperIndex: Int32,
                                  _ out: UnsafeMutablePointer<CChar>?, _ capacity: Int32) -> Int32 {
    guard let stock = stock(at: stockIndex) else { return -1 }
    return copyOut(resolvedPaper(stock: stock, index: paperIndex).name, out, capacity)
}

@_cdecl("fotufilm_bridge_development_count")
func fotufilm_bridge_development_count(_ stockIndex: Int32) -> Int32 {
    guard let stock = stock(at: stockIndex) else { return 0 }
    return Int32(stock.supportedDevelopmentStops.count + 1)
}

@_cdecl("fotufilm_bridge_development_stop")
func fotufilm_bridge_development_stop(_ stockIndex: Int32, _ index: Int32) -> Float {
    guard let stock = stock(at: stockIndex) else { return .nan }
    let stops = ([Float(0)] + stock.supportedDevelopmentStops).sorted()
    return stops.indices.contains(Int(index)) ? stops[Int(index)] : .nan
}

/// Disc grain cannot run in the realtime family. This policy is also queried by the OFX
/// decoder, so a per-node override changes every pass together, including striped frames.
@_cdecl("fotufilm_bridge_effective_realtime")
func fotufilm_bridge_effective_realtime(_ parameters: UnsafePointer<Float>?) -> Int32 {
    if parameters?[Parameter.grainModel] == 1 { return 0 }
    switch whole(parameters?[Parameter.renderMode] ?? 0) {
    case 1: return 1
    case 2: return 0
    default: return realtimeRenderingEnabled ? 1 : 0
    }
}

@_cdecl("fotufilm_bridge_stock_pushes")
func fotufilm_bridge_stock_pushes(_ stockIndex: Int32) -> Int32 {
    guard let stock = stock(at: stockIndex) else { return 0 }
    return stock.hasMeasuredDevelopmentResponse ? 1 : 0
}

/// Keep the persisted numeric development condition on the stock's measurements. The visible
/// OFX menu is derived from these conditions; the number preserves older projects.
@_cdecl("fotufilm_bridge_stock_snap_push")
func fotufilm_bridge_stock_snap_push(_ stockIndex: Int32, _ requested: Float) -> Float {
    guard requested.isFinite, let stock = stock(at: stockIndex) else { return 0 }
    return ([Float(0)] + stock.supportedDevelopmentStops).min { lhs, rhs in
        let lhsDistance = abs(lhs - requested)
        let rhsDistance = abs(rhs - requested)
        if lhsDistance == rhsDistance { return abs(lhs) < abs(rhs) }
        return lhsDistance < rhsDistance
    } ?? 0
}

@_cdecl("fotufilm_bridge_format_count")
func fotufilm_bridge_format_count() -> Int32 { Int32(FilmFormat.presets.count) }

@_cdecl("fotufilm_bridge_format_id")
func fotufilm_bridge_format_id(_ index: Int32, _ out: UnsafeMutablePointer<CChar>?,
                              _ capacity: Int32) -> Int32 {
    let presets = FilmFormat.presets
    guard presets.indices.contains(Int(index)) else { return -1 }
    return copyOut(presets[Int(index)].id, out, capacity)
}

@_cdecl("fotufilm_bridge_format_name")
func fotufilm_bridge_format_name(_ index: Int32, _ out: UnsafeMutablePointer<CChar>?,
                                _ capacity: Int32) -> Int32 {
    let presets = FilmFormat.presets
    guard presets.indices.contains(Int(index)) else { return -1 }
    return copyOut(presets[Int(index)].format.name, out, capacity)
}

@_cdecl("fotufilm_bridge_last_error")
func fotufilm_bridge_last_error(_ opaque: UnsafeMutableRawPointer?,
                               _ out: UnsafeMutablePointer<CChar>?,
                               _ capacity: Int32) -> Int32 {
    guard let context = context(opaque) else {
        return copyOut(currentInitializationError(), out, capacity)
    }
    context.lock.lock()
    defer { context.lock.unlock() }
    return copyOut(context.lastError, out, capacity)
}

@_cdecl("fotufilm_bridge_prepare")
func fotufilm_bridge_prepare(_ opaque: UnsafeMutableRawPointer?,
                            _ stockIndex: Int32, _ format: Int32, _ paper: Int32,
                            _ parameters: UnsafePointer<Float>?,
                            _ width: Int32, _ height: Int32) -> Int32 {
    guard let context = context(opaque) else { return 0 }
    context.lock.lock()
    defer { context.lock.unlock() }

    guard licenseAllowsDevelopment(context) else { return 0 }
    guard let renderer = HalideMetalFilmRenderer.shared else {
        context.lastError = "no Metal device the Halide engine can use"
        return 0
    }
    guard let stock = stock(at: stockIndex) else {
        context.lastError = "no film stock at index \(stockIndex)"
        return 0
    }
    guard stage(of: parameters) != nil else {
        context.lastError =
            "no pipeline stage at index \(whole(parameters?[Parameter.stage] ?? 0))"
        return 0
    }
    guard width > 0, height > 0 else { return 0 }
    let settings = options(parameters, format: format,
                           stockIndex: stockIndex, paper: paper, seed: 0)
    guard validateDevelopment(settings, stock: stock, context: context) else { return 0 }
    return context.withMetalContext {
        renderer.prepare(stock: stock, options: settings,
                         frameWidth: Int(width), frameHeight: Int(height)) ? 1 : 0
    }
}

@_cdecl("fotufilm_bridge_encodes_output")
func fotufilm_bridge_encodes_output(_ opaque: UnsafeMutableRawPointer?,
                                   _ stockIndex: Int32, _ format: Int32, _ paper: Int32,
                                   _ parameters: UnsafePointer<Float>?,
                                   _ width: Int32, _ height: Int32,
                                   _ interactive: Int32) -> Int32 {
    guard let context = context(opaque) else { return 0 }
    context.lock.lock()
    defer { context.lock.unlock() }

    let values = parameters.map {
        Array(UnsafeBufferPointer(start: $0, count: Parameter.count))
    } ?? []
    // The road the frame will take is the staging this context holds: `fotufilm_bridge_render_staged`
    // refuses a frame with none claimed, and `fotufilm_bridge_render` never measures glare in the
    // kernel. So the question is asked exactly as the render will be — with the on-device
    // measurement only for a staged frame, on the same terms `fotufilm_bridge_render_staged` uses —
    // and the host has to claim or be refused staging before it asks.
    let staged = context.frameStaging.map { $0.capacityPixels >= Int(width) * Int(height) }
        ?? false
    let key = OutputTransformQueryKey(
        stock: stockIndex, format: format, paper: paper, width: width, height: height,
        interactive: interactive, staged: staged, parameters: values)
    if let cached = context.outputQuery, cached.key == key { return cached.answer }

    guard let renderer = HalideMetalFilmRenderer.shared,
          let stock = stock(at: stockIndex), stage(of: parameters) != nil,
          width > 0, height > 0 else { return 0 }
    let settings = options(parameters, format: format,
                           stockIndex: stockIndex, paper: paper, seed: 0)
    guard validateDevelopment(settings, stock: stock, context: context) else { return 0 }
    let answer: Int32 = renderer.carriesOutputTransform(
        stock: stock, options: settings, width: Int(width), height: Int(height),
        realtime: fotufilm_bridge_effective_realtime(parameters) != 0,
        measuresGlareOnDevice: staged && (fotufilm_bridge_effective_realtime(parameters) != 0 || interactive != 0)) ? 1 : 0
    context.outputQuery = OutputTransformQuery(key: key, answer: answer)
    return answer
}

@_cdecl("fotufilm_bridge_frame_staging")
func fotufilm_bridge_frame_staging(
    _ opaque: UnsafeMutableRawPointer?,
    _ width: Int32, _ height: Int32,
    _ input: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?,
    _ output: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?
) -> Int32 {
    guard let context = context(opaque) else { return 0 }
    context.lock.lock()
    defer { context.lock.unlock() }
    // A render aborted between claiming staging and developing it leaves the prior claim here.
    // Return it before the next frame borrows a pair.
    context.releaseStaging()

    guard let input, let output, width > 0, height > 0,
          let renderer = HalideMetalFilmRenderer.shared,
          HalideMetalFilmRenderer.developsInOnePass(width: Int(width),
                                                    height: Int(height))
    else { return 0 }

    let pixels = Int(width) * Int(height)
    guard let staging = renderer.borrowFrameStaging(pixels: pixels) else { return 0 }
    context.frameStaging = staging
    input.pointee = staging.scenePixels
    output.pointee = staging.developedPixels
    return 1
}

@_cdecl("fotufilm_bridge_release_staging")
func fotufilm_bridge_release_staging(_ opaque: UnsafeMutableRawPointer?) {
    guard let context = context(opaque) else { return }
    context.lock.lock()
    context.releaseStaging()
    context.lock.unlock()
}

@_cdecl("fotufilm_bridge_decode_staged")
func fotufilm_bridge_decode_staged(
    _ opaque: UnsafeMutableRawPointer?,
    _ width: Int32, _ height: Int32,
    _ transformIn: UnsafeRawPointer?,
    _ peak: UnsafeMutablePointer<Float>?,
    _ repaired: UnsafeMutablePointer<Int32>?,
    _ realtime: Int32
) -> Int32 {
    guard let context = context(opaque) else { return 0 }
    context.lock.lock()
    defer { context.lock.unlock() }

    guard width > 0, height > 0,
          let renderer = HalideMetalFilmRenderer.shared,
          let transform = inputTransform(transformIn),
          let staging = context.frameStaging,
          staging.capacityPixels >= Int(width) * Int(height)
    else { return 0 }
    guard let report = context.withMetalContext({
        renderer.decodeStaged(
            staging, width: Int(width), height: Int(height), transform: transform,
            realtime: realtime != 0)
    }) else { return 0 }

    peak?.pointee = report.peak
    repaired?.pointee = report.repaired ? 1 : 0
    return 1
}

@_cdecl("fotufilm_bridge_decode_rows")
func fotufilm_bridge_decode_rows(
    _ input: UnsafePointer<Float>?, _ output: UnsafeMutablePointer<Float>?,
    _ width: Int32, _ rows: Int32,
    _ transformIn: UnsafeRawPointer?,
    _ peak: UnsafeMutablePointer<Float>?,
    _ repaired: UnsafeMutablePointer<Int32>?,
    _ realtime: Int32
) -> Int32 {
    guard width > 0, rows > 0, let input, let output,
          let renderer = HalideMetalFilmRenderer.shared,
          let transform = inputTransform(transformIn),
          let report = renderer.decodeRows(input, into: output, width: Int(width),
                                           rows: Int(rows), transform: transform,
                                           realtime: realtime != 0)
    else { return 0 }

    peak?.pointee = report.peak
    repaired?.pointee = report.repaired ? 1 : 0
    return 1
}

@_cdecl("fotufilm_bridge_render_staged")
func fotufilm_bridge_render_staged(
    _ opaque: UnsafeMutableRawPointer?,
    _ stockIndex: Int32, _ format: Int32, _ paper: Int32,
    _ parameters: UnsafePointer<Float>?, _ seed: UInt32,
    _ width: Int32, _ height: Int32, _ frame: UInt64,
    _ interactive: Int32,
    _ outputTransformIn: UnsafeMutableRawPointer?,
    _ shouldContinue: (@convention(c) (UnsafeMutableRawPointer?) -> Int32)?,
    _ abortContext: UnsafeMutableRawPointer?
) -> Int32 {
    guard let context = context(opaque) else { return 0 }
    context.lock.lock()
    defer { context.lock.unlock() }

    guard licenseAllowsDevelopment(context) else { return 0 }
    guard let renderer = HalideMetalFilmRenderer.shared else {
        context.lastError = "no Metal device the Halide engine can use"
        return 0
    }
    guard let stock = stock(at: stockIndex) else {
        context.lastError = "no film stock at index \(stockIndex)"
        return 0
    }
    guard let chosen = stage(of: parameters) else {
        context.lastError =
            "no pipeline stage at index \(whole(parameters?[Parameter.stage] ?? 0))"
        return 0
    }
    guard width > 0, height > 0, let staging = context.frameStaging,
          staging.capacityPixels >= Int(width) * Int(height) else {
        context.lastError = "no frame staging claimed for a \(width)x\(height) frame"
        return 0
    }

    let settings = options(parameters, format: format,
                           stockIndex: stockIndex, paper: paper, seed: seed)
    guard validateDevelopment(settings, stock: stock, context: context) else { return 0 }
    // This pointwise check has the same result for a strip or a full frame. Output transforms are
    // invalid for stages that produce densities; see the stage contract in the header.
    if outputTransformIn != nil && !chosen.writesEncodableLight {
        context.lastError =
            "\(chosen.name) hands back data, which the host's transfer cannot encode"
        return 0
    }
    let wanted = outputTransformIn != nil
    var transform = outputTransform(outputTransformIn)
    let ok = context.withMetalContext {
        renderer.developStaged(
            staging, width: Int(width), height: Int(height), stock: stock,
            options: settings,
            outputTransform: &transform,
            frameIndex: parameters?[Parameter.grainFrozen] == 1 ? 0 : frame,
            realtime: fotufilm_bridge_effective_realtime(parameters) != 0,
            // The realtime output variant carries this reduction in the same schedule. Reference
            // rendering retains the earlier rule: only disposable viewer frames accept its
            // sub-LSB reduction difference, while deliveries use the host measurement.
            measuresGlareOnDevice: fotufilm_bridge_effective_realtime(parameters) != 0 || interactive != 0,
            shouldContinue: shouldContinue.map { keepGoing in
                { keepGoing(abortContext) != 0 }
            })
    }
    // The host reads the frame on what `fotufilm_bridge_encodes_output` told it, so a render that
    // could not keep that promise fails rather than return light the host would write out
    // under the timeline's label. The query mirrors this call's kernel choice — staging held,
    // same `interactive` — so this is reachable only through a host that asked before claiming
    // staging, or asked with a different flag than it rendered with.
    if ok && wanted && transform == nil {
        context.lastError = "the engine has no kernel that carries the output transform for this frame"
        return 0
    }

    if !ok {
        // The same distinction `fotufilm_bridge_render` draws: the host changing its mind is not
        // a failure, and leaves no error behind.
        if let shouldContinue, shouldContinue(abortContext) == 0 { return -1 }
        context.lastError = "the engine could not develop a \(width)x\(height) frame"
        return 0
    }
    return 1
}

@_cdecl("fotufilm_bridge_render")
func fotufilm_bridge_render(_ opaque: UnsafeMutableRawPointer?,
                           _ stockIndex: Int32, _ format: Int32, _ paper: Int32,
                           _ parameters: UnsafePointer<Float>?, _ seed: UInt32,
                           _ input: UnsafePointer<Float>?,
                           _ width: Int32, _ height: Int32,
                           _ frame: UInt64,
                           _ writeRows: (@convention(c) (
                               UnsafeMutableRawPointer?, Int32, Int32,
                               UnsafePointer<Float>?) -> Void)?,
                           _ writeContext: UnsafeMutableRawPointer?,
                           _ outputTransformIn: UnsafeMutableRawPointer?,
                           _ shouldContinue: (@convention(c) (
                               UnsafeMutableRawPointer?) -> Int32)?,
                           _ abortContext: UnsafeMutableRawPointer?) -> Int32 {
    guard let context = context(opaque) else { return 0 }
    context.lock.lock()
    defer { context.lock.unlock() }

    guard licenseAllowsDevelopment(context) else { return 0 }
    guard let renderer = HalideMetalFilmRenderer.shared else {
        context.lastError = "no Metal device the Halide engine can use"
        return 0
    }
    guard let stock = stock(at: stockIndex) else {
        context.lastError = "no film stock at index \(stockIndex)"
        return 0
    }
    guard let chosen = stage(of: parameters) else {
        context.lastError =
            "no pipeline stage at index \(whole(parameters?[Parameter.stage] ?? 0))"
        return 0
    }
    guard let input, let writeRows, width > 0, height > 0 else {
        context.lastError = "empty frame"
        return 0
    }

    let settings = options(parameters, format: format,
                           stockIndex: stockIndex, paper: paper, seed: seed)
    guard validateDevelopment(settings, stock: stock, context: context) else { return 0 }
    let rowFloats = Int(width) * 4

    // Match the staged path so memory-dependent path selection does not change output. Output
    // transforms are invalid for stages that produce densities.
    if outputTransformIn != nil && !chosen.writesEncodableLight {
        context.lastError =
            "\(chosen.name) hands back data, which the host's transfer cannot encode"
        return 0
    }
    let wanted = outputTransformIn != nil
    var transform = outputTransform(outputTransformIn)
    let ok = context.withMetalContext {
        renderer.developStreaming(
            width: Int(width), height: Int(height), stock: stock, options: settings,
            outputTransform: &transform,
            frameIndex: parameters?[Parameter.grainFrozen] == 1 ? 0 : frame,
            realtime: fotufilm_bridge_effective_realtime(parameters) != 0,
            shouldContinue: shouldContinue.map { keepGoing in
                { keepGoing(abortContext) != 0 }
            },
            readRows: { rows, into in
                into.baseAddress!.update(from: input + rows.lowerBound * rowFloats,
                                         count: rows.count * rowFloats)
            },
            writeRows: { rows, from in
                writeRows(writeContext, Int32(rows.lowerBound),
                      Int32(rows.upperBound), from.baseAddress)
            })
    }
    // As on the staged path — except that here the rows are already gone, which is the whole
    // reason the host has to have asked beforehand. This road never measures glare in the
    // kernel, and the query knows that from the staging the context does not hold; so this is
    // reachable only through a host that asked while it still held staging for the frame.
    if ok && wanted && transform == nil {
        context.lastError = "the engine has no kernel that carries the output transform for this frame"
        return 0
    }

    if !ok {
        // Distinguish the host changing its mind from the engine failing; only the
        // latter deserves an error the host might show.
        if let shouldContinue, shouldContinue(abortContext) == 0 { return -1 }
        context.lastError = "the engine could not develop a \(width)x\(height) frame"
        return 0
    }
    return 1
}
