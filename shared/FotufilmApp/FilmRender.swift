import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmMetal)
import FotufilmMetal
#endif
#if canImport(FotufilmImaging)
import FotufilmImaging
#endif

/// The scene-referred still pipeline.
enum FilmRender {
    /// One measured step of a render, for the progress UI.
    enum Stage: String, CaseIterable, Identifiable, Sendable {
        case decode, geometry, rasterize, glare, develop, encode
        var id: String { rawValue }

        var title: String {
            switch self {
            case .decode: return "Preparing"
            case .geometry: return "Sizing"
            case .rasterize: return "Applying Film"
            case .glare: return "Adding Glow"
            case .develop: return "Developing"
            case .encode: return "Finishing"
            }
        }
    }

    enum Event: Sendable {
        case began(Stage, detail: String)
        case advanced(Stage, fraction: Double, detail: String)
        case finished(Stage, duration: TimeInterval)
    }

    typealias Reporter = @Sendable (Event) -> Void

    private static let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
    fileprivate static let outputSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    /// BT.2020 with the HLG transfer.
    static let hdrSpace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)

    private static let context = CIContext(options: [
        .workingColorSpace: linearSpace,
        .workingFormat: CIFormat.RGBAf,
        .cacheIntermediates: false,
    ])

    /// Resident footprint and remaining allowance, for the progress rows.
    static func memoryNote() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return "" }
        let used = Double(info.phys_footprint) / 1e6
        #if os(iOS)
        let free = Double(os_proc_available_memory()) / 1e6
        return String(format: "%.0f MB used · %.0f MB free", used, free)
        #else
        return String(format: "%.0f MB used", used)
        #endif
    }

    /// Everything a scene buffer depends on.
    struct SceneKey: Equatable {
        var rotation: Int
        var flipH: Bool
        var straighten: Double
        var perspectiveV: Double
        var perspectiveH: Double
        var crop: CGRect?
        var longEdge: Int?
        var viewport: PreviewViewport? = nil
        var sourceInterpretation: FilmSourceInterpretation
        /// Camera RAW is decoded at the same fixed illuminant as its live/video acquisition.
        var captureIlluminantKelvin: Double?
        /// The scene carries the film's light with it, so a change of it is a different scene.
        var filmLightKelvin: Double?
        /// Everything about the lens correction that changes the pixels. It belongs in the key
        /// because the correction happens on the way into the scene, so a cached scene made with a
        /// different one is the wrong picture rather than a stale-looking one.
        var lens: EditState.LensSettings

        init(state: EditState, longEdge: Int?,
             viewport: PreviewViewport? = nil) {
            rotation = state.rotation
            flipH = state.flipH
            straighten = state.straighten
            perspectiveV = state.perspectiveV
            perspectiveH = state.perspectiveH
            crop = state.crop
            self.longEdge = longEdge
            self.viewport = viewport
            sourceInterpretation = state.sourceInterpretation
            captureIlluminantKelvin = state.captureIlluminantKelvin
            filmLightKelvin = state.filmLightKelvin
            lens = state.lensSettings
        }
    }

    /// The photograph as the emulsion receives it: scene-linear, placed, and
    /// at the resolution it will be developed at.
    struct Scene: @unchecked Sendable {
        /// File-backed above a threshold, because this is both the largest thing a render holds and
        /// the longest-lived — it survives a whole slider drag — while the develop only ever reads
        /// a strip of it.
        var pixels: MappedBuffer
        var width: Int
        var height: Int
        var key: SceneKey
        /// How far the demosaic already moved the illuminant, in mired from
        /// the file's as-shot value.
        var bakedMired: Float?
        /// The light the film integrates against, in kelvin, when there is one to state — raw
        /// only: the camera's own named light, or failing that the file's as-shot record. Carried
        /// on the scene because the develop runs later, from here.
        var sceneKelvin: Float?
        /// The light the decode recovered above display white, as a multiple of it: above 1 exactly
        /// when a gain map was expanded (`.expandToHDR`), 1 for every SDR source — and for raw,
        /// whose above-white radiance has always been the negative's own path and is not rolled.
        var contentHeadroom: Float = 1
        /// How this scene was prepared for the engine. The policy itself lives in FotufilmCore so
        /// non-app clients can select a built-in converter or supply their own.
        var inputConversion: FilmInputConversion = .preserveHDR
        /// Fraction of the film frame's short edge these pixels span — under 1 exactly when the
        /// geometry cropped, so the develop can hold grain and the other millimetre-sized
        /// structures at film scale rather than buffer scale (`Options.frameCoverage`).
        var frameCoverage: Float = 1
        /// Regional preview geometry. Nil means this scene is the complete placed frame.
        var viewport: PreviewViewport?
        /// The frame the camera exposed, where the file measured it. Read once here, with the rest
        /// of what the file says about itself, because the develop settles the gauge from it and a
        /// develop runs many times over one scene.
        var sensorFrame: SensorFrame?
        /// Set only while the rasterise is still running behind this scene; nil once the pixels
        /// are all there, which is every scene the editor holds between renders.
        var ready: RowWatermark?

        /// Blocks until `rows` have been laid down. Free — not even a lock — on a settled scene.
        func waitForRows(through row: Int) {
            ready?.wait(through: row)
        }

        /// True when the temperature has moved away from what this scene was demosaiced for, so a
        /// render that wants to be right has to decode again rather than reuse it.
        func balanceIsStale(for state: EditState) -> Bool {
            guard let bakedMired else { return false }
            return bakedMired != FilmRender.balanceMired(state)
        }

        /// The scene as full-precision samples, whole: a scene still being
        /// laid down is waited for first, so no caller can read a row that has not been written.
        func withPixels<R>(_ body: (UnsafeBufferPointer<Float>) -> R) -> R {
            waitForRows(through: height)
            return withPixelsWhileFilling(body)
        }

        /// The same buffer without the wait, for the one caller that reads it in step with the
        /// rasterise and waits per strip for the rows it is about to touch.
        func withPixelsWhileFilling<R>(
            _ body: (UnsafeBufferPointer<Float>) -> R
        ) -> R {
            body(UnsafeBufferPointer(pixels.bound(to: Float.self)))
        }
    }

    /// Whole-frame tone and flare readings retained across settled viewport requests.
    struct DetailMeasurements: @unchecked Sendable {
        fileprivate let context: FilmFrameContext
    }

    /// Synchronizes top-to-bottom Core Image rasterization with striped film development.
    /// Readers wait only for the rows in their next strip; each row is complete before access.
    final class RowWatermark: @unchecked Sendable {
        private let condition = NSCondition()
        private var ready = 0
        private var finished = false

        /// Rows laid down so far.
        var rows: Int { condition.lock(); defer { condition.unlock() }; return ready }

        func publish(through row: Int) {
            condition.lock()
            ready = max(ready, row)
            condition.broadcast()
            condition.unlock()
        }

        /// Marks the rasterise done, so a waiter for rows that will never arrive gives up rather
        /// than hangs. Only reached when a band failed, which `context.render` does not report —
        /// it is the loop ending that publishes the last row.
        func finish() {
            condition.lock()
            finished = true
            condition.broadcast()
            condition.unlock()
        }

        /// Blocks until `row` rows exist, or the rasterise has stopped producing them.
        func wait(through row: Int) {
            condition.lock()
            while ready < row && !finished { condition.wait() }
            condition.unlock()
        }
    }

    /// The temperature control's displacement from neutral, in mired.
    static func balanceMired(_ state: EditState) -> Float {
        Float(state.temperatureMired)
            - WhiteBalance.kelvinToMired(WhiteBalance.neutralKelvin)
    }

    /// What is left for the film model to adapt once `scene` has been
    /// demosaiced for part of the correction.
    static func remainingBalance(for state: EditState, scene: Scene) -> WhiteBalance {
        RawDecode.remainingBalance(displacementMired: balanceMired(state),
                                   tint: Float(state.tint),
                                   bakedMired: scene.bakedMired)
    }

    static func detailMeasurements(
        of scene: Scene, state: EditState,
        negative: NegativeViewing? = nil
    ) -> DetailMeasurements? {
        guard let stock = state.stock,
              let engine = HalideMetalFilmRenderer.shared,
              let device = MTLCreateSystemDefaultDevice() else { return nil }
        var options = state.options(sensor: scene.sensorFrame)
        options.whiteBalance = remainingBalance(for: state, scene: scene)
        options.frameCoverage = scene.frameCoverage
        options.sceneIlluminantKelvin = scene.sceneKelvin
        options.sceneHeadroom = scene.inputConversion == .preserveHDR
            ? scene.contentHeadroom : 1
        options.paper = state.resolvedPaper
        if let negative { options.negativeViewing = negative }

        let count = scene.width * scene.height * 4
        guard let input = device.makeBuffer(
            length: count * MemoryLayout<Float>.size,
            options: .storageModeShared) else { return nil }
        scene.withPixels { source in
            let destination = UnsafeMutableBufferPointer(
                start: input.contents().assumingMemoryBound(to: Float.self),
                count: count)
            expand(source, rows: 0..<scene.height, width: scene.width,
                   into: destination,
                   inputConversion: scene.inputConversion)
        }
        return engine.makeLinearFloatFrameContext(
            input: input, width: scene.width, height: scene.height,
            stock: stock, options: options).map {
                DetailMeasurements(context: $0)
            }
    }

    /// Decodes, places and rasterises the photograph. Automatic interpretation follows source
    /// metadata; a document override chooses another conversion without changing app settings.
    ///
    /// `usesSourceFrame` is whether an unpicked gauge may follow the frame this file says its
    /// camera exposed. False on the camera's own path: the viewfinder has already shown this scene
    /// on the film's gauge, and a still that developed on a different one would not be the
    /// photograph the photographer was looking at when they pressed the button.
    static func scene(
        source: PhotoSource,
        state: EditState,
        longEdge: Int?,
        viewport requestedViewport: PreviewViewport? = nil,
        upright: Bool = true,
        usesSourceFrame: Bool = true,
        streaming: Bool = false,
        report: Reporter? = nil
    ) -> Scene? {
        func time<T>(_ stage: Stage, _ detail: String = "", _ body: () -> T) -> T {
            report?(.began(stage, detail: detail))
            let start = Date()
            let value = body()
            let note = memoryNote()
            if !note.isEmpty {
                report?(.advanced(stage, fraction: 1,
                                  detail: detail.isEmpty ? note : "\(detail) · \(note)"))
            }
            report?(.finished(stage, duration: Date().timeIntervalSince(start)))
            return value
        }

        let decodeLongEdge = state.crop == nil && requestedViewport == nil
            ? longEdge : nil
        let fixedCaptureIlluminant = source.isRaw
            ? state.captureIlluminantKelvin.map(Float.init) : nil
        let placement: RawDecode.Placement?
        if let fixedCaptureIlluminant {
            // Camera video is normalized by this same device lock. Ask CIRAWFilter for that
            // neutralization explicitly and leave no digital RGB remainder for the film head.
            placement = RawDecode.Placement(
                neutralKelvin: fixedCaptureIlluminant, bakedMired: 0)
        } else {
            placement = source.asShotMired.map {
                RawDecode.placement(
                    displacementMired: balanceMired(state), asShotMired: $0)
            }
        }
        let bakedMired = placement?.bakedMired
        let neutralKelvin = placement?.neutralKelvin ?? nil

        // Settled before the decode rather than after it, because whether this app has a measurement
        // of the lens decides whether the decoder should apply its own.
        let lens = state.lensPlan(for: source.lensShot, dng: source.originalDNGData)
        // Read once: the probe opens the file, and the answer is wanted three times below.
        let declaredHeadroom = source.isRaw ? nil : source.declaredHeadroom
        let inputConversion = state.sourceInterpretation.resolvedConversion(
            isRaw: source.isRaw)
        let decodeMode: PhotoSource.DecodeMode
        switch inputConversion {
        case .platformToneMap: decodeMode = .coreImageToneMappedSDR
        case .preserveHDR, .engineLinearToneMap: decodeMode = .expandedHDR
        }
        guard var decoded = time(.decode, source.detail, {
            source.decoded(longEdge: decodeLongEdge, neutralKelvin: neutralKelvin,
                           upright: upright,
                           decodeMode: decodeMode,
                           correctingLens: lens.supersedesDecoder ? false : nil)
        }) else { return nil }

        // Adaptive-HDR stills are processed alternate renditions, not calibrated camera
        // radiometry. Keep the expanded, linear pixels and their above-white ratios, but remove
        // the rendition's global exposure lift using the companion SDR rendering as one scalar
        // reference. No tone-mapped reference pixel enters the scene buffer.
        if inputConversion != .platformToneMap,
           ProcessedHDRExposure.isEligible(
               isRaw: source.isRaw, declaredHeadroom: declaredHeadroom) {
            let gain = processedHDRExposureGain(
                source: source, upright: upright)
            decoded = ProcessedHDRExposure.applying(gain, to: decoded)
        }

        var contentHeadroom: Float = 1
        if !source.isRaw {
            if inputConversion == .platformToneMap {
                // The pixels are now SDR, but the source fact remains available to the editor so
                // another interpretation can be chosen without losing the metadata signal. It is
                // the file's own ceiling, not the container's: a phone's gain map runs anywhere
                // from about 2.4x to 5.8x, and standing in one number for all of them meters the
                // recovery against a range the picture never had.
                contentHeadroom = declaredHeadroom ?? 1
            } else if #available(iOS 18.0, macOS 15.0, *) {
                contentHeadroom = max(1, decoded.contentHeadroom)
            }
            // Some ImageIO builds expand a gain map but still report neutral headroom on the
            // resulting CIImage. The file metadata remains authoritative for automatic handling,
            // and it states the ceiling as well as the fact of it.
            if contentHeadroom <= 1, let declared = declaredHeadroom {
                contentHeadroom = declared
            }
        }

        // The lens is undone first, on the frame as the camera drew it. Every step after this one
        // moves the optical centre or throws part of the frame away, and a radial correction applied
        // to a rotated crop would be centred on the wrong place.
        var frameCoverage: Float = 1
        var viewport: PreviewViewport?
        let placed = time(.geometry, longEdge.map { "long edge \($0) px" } ?? "native") {
            () -> CIImage in
            let corrected = LensCorrectionFilter.apply(decoded, stack: lens.stack)
            let framed = geometry(corrected, state: state)
            // How much of the frame's short edge the geometry kept. Cropping and
            // straightening throw film away; the engine scales every millimetre-sized
            // structure by the enlargement that implies, so the fraction is measured
            // here where both extents exist and rides the scene to the develop.
            let full = min(corrected.extent.width, corrected.extent.height)
            if full > 0 {
                frameCoverage = Float(
                    min(framed.extent.width, framed.extent.height) / full)
            }
            guard let requestedViewport else {
                return resample(framed, longEdge: longEdge)
            }

            var prepared = requestedViewport
            let coverage = requestedViewport.frameCoverage(
                composedWith: frameCoverage)
            if let stock = state.stock {
                var options = state.options(
                    sensor: usesSourceFrame ? source.sensorFrame : nil)
                options.frameCoverage = coverage
                let density = requestedViewport.densityReferencePixelSize
                let invocation = FilmEngineInvocation(
                    stock: stock, options: options,
                    width: max(1, Int(density.width)),
                    height: max(1, Int(density.height)))
                prepared = requestedViewport.addingSpatialSupport(
                    invocation.spatialSupport)
            }
            viewport = prepared
            frameCoverage = coverage
            let unit = UnitCropCoordinates.verticallyFlipped(
                prepared.renderUnitRect)
            let extent = framed.extent
            let region = CGRect(
                x: extent.minX + unit.minX * extent.width,
                y: extent.minY + unit.minY * extent.height,
                width: unit.width * extent.width,
                height: unit.height * extent.height).intersection(extent)
            let cropped = atOrigin(framed.cropped(to: region))
            return resample(cropped, pixelSize: prepared.renderPixelSize)
        }
        let extent = placed.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0 else { return nil }

        // The illuminant-aware profile delta, applied where the scene-linear working samples are
        // laid down so every consumer — develop, metering, auto adjust — sees the same light.
        // Decoded stills are already colorimetric under the file's white balance, so only the
        // delta against the profile's daylight anchor is valid; when the camera is unknown, the
        // temperature unstated, or the interpolated profile is exactly its daylight anchor,
        // nothing runs and the buffer stays bit-identical. It is pointwise, so it goes on band by
        // band with the rasterise rather than as a second walk over the finished frame.
        let decodeKelvin = source.isRaw
            ? fixedCaptureIlluminant
                ?? source.asShotMired.map(WhiteBalance.miredToKelvin)
            : nil
        // The profile delta belongs to the decode: it interpolates the camera's own matrices at
        // the light the file was neutralized against. The film's light is a separate statement,
        // and only it decides which spectral exposure table the emulsion integrates.
        let profileDelta = source.isRaw
            ? CameraProfileCorrection.resolve(
                camera: source.camera,
                sceneKelvin: decodeKelvin)
            : nil
        // A camera capture names its light whether or not it kept the raw: the processed frame
        // left the ISP under the same acquisition lock the decode reproduces.
        let sceneKelvin = state.filmLightKelvin.map(Float.init)
            ?? (source.isRaw ? decodeKelvin : nil)
        let rowBytes = width * MemoryLayout<Float>.size * 4
        guard let buffer = MappedBuffer(byteCount: rowBytes * height) else {
            return nil
        }
        /// One band of scene, finished: rendered, colour-corrected and flushed, in that order,
        /// exactly as the whole-frame version did it.
        func rasterizeBand(_ rows: Range<Int>, into destination: UnsafeMutableRawPointer) {
            if let profileDelta {
                let base = destination.assumingMemoryBound(to: Float.self)
                CameraProfileCorrection.apply(
                    profileDelta.matrix,
                    toRGBA: UnsafeMutableBufferPointer(
                        start: base, count: rows.count * width * 4))
            }
            buffer.flush(byteOffset: rows.lowerBound * rowBytes,
                         byteCount: rows.count * rowBytes)
        }
        if let profileDelta { CameraProfileCorrection.trace(profileDelta) }

        let pixels = buffer
        var watermark: RowWatermark?
        if streaming {
            let ready = RowWatermark()
            watermark = ready
            report?(.began(
                .rasterize,
                detail: "\(width) × \(height) px, float, streaming"))
            let rasterizeStart = Date()
            rasterizeQueue.async {
                ImageResampling.rasterizeLinearFloat(
                    placed, into: pixels.baseAddress,
                    width: width, height: height,
                    context: context, colorSpace: linearSpace,
                    flush: { byteOffset, byteCount in
                        let first = byteOffset / rowBytes
                        let count = byteCount / rowBytes
                        rasterizeBand(
                            first..<(first + count),
                            into: pixels.baseAddress.advanced(by: byteOffset))
                        ready.publish(through: first + count)
                    })
                ready.publish(through: height)
                ready.finish()
                report?(.finished(
                    .rasterize,
                    duration: Date().timeIntervalSince(rasterizeStart)))
            }
        } else {
            time(.rasterize, "\(width) × \(height) px, float") {
                ImageResampling.rasterizeLinearFloat(
                    placed, into: pixels.baseAddress,
                    width: width, height: height,
                    context: context, colorSpace: linearSpace,
                    flush: { byteOffset, byteCount in
                        let first = byteOffset / rowBytes
                        let count = byteCount / rowBytes
                        rasterizeBand(
                            first..<(first + count),
                            into: pixels.baseAddress.advanced(by: byteOffset))
                    })
            }
        }
        return Scene(pixels: pixels, width: width, height: height,
                     key: SceneKey(state: state, longEdge: longEdge,
                                   viewport: viewport),
                     bakedMired: bakedMired,
                     sceneKelvin: sceneKelvin,
                     contentHeadroom: contentHeadroom,
                     inputConversion: inputConversion,
                     frameCoverage: frameCoverage,
                     viewport: viewport,
                     sensorFrame: usesSourceFrame ? source.sensorFrame : nil,
                     ready: watermark)
    }

    /// Measure the original renditions so preview size and crop cannot change exposure placement.
    private static func processedHDRExposureGain(
        source: PhotoSource, upright: Bool
    ) -> Float {
        guard let reference = source.decoded(
                upright: upright,
                decodeMode: .coreImageToneMappedSDR),
              let hdr = source.decoded(
                upright: upright,
                decodeMode: .expandedHDR)
        else { return 1 }
        return ProcessedHDRExposure.referenceGain(
            expandedHDR: hdr, sdrReference: reference, context: context)
    }

    /// `FOTUFILM_EXPORT_SERIAL=1` puts the export back on the path it took before its stages were
    /// allowed to run beside each other: the rasterise finishes before the develop starts, and
    /// each strip is written out before the next is developed. It is the seam the proof is taken
    /// across — one build, two schedules, a digest of the print from each — because a claim that
    /// scheduling left every pixel alone is worth more when the two runs being compared cannot
    /// differ in anything else.
    static let serialExport =
        ProcessInfo.processInfo.environment["FOTUFILM_EXPORT_SERIAL"] == "1"

    /// The scene's half of that seam on its own, so the two overlaps can be told apart. Letting
    /// the rasterise run beside the develop and letting a strip's print encode run beside the
    /// next strip's kernel are separate bargains with separate answers: the first trades one
    /// piece of the GPU's work against another, the second trades the host's against the
    /// device's, and only a measurement that can switch them independently says which paid.
    static let serialScene = serialExport
        || ProcessInfo.processInfo.environment["FOTUFILM_SERIAL_SCENE"] == "1"

    private static let rasterizeQueue = DispatchQueue(
        label: "fotufilm.scene.rasterize", qos: .userInitiated)

    /// Halves a scene by averaging 2x2 blocks, for the draft render that runs
    /// while a control is being dragged.
    static func halved(_ scene: Scene) -> Scene {
        let width = max(1, scene.width / 2), height = max(1, scene.height / 2)
        let rowBytes = width * MemoryLayout<Float>.size * 4
        guard let pixels = MappedBuffer(byteCount: rowBytes * height) else {
            return scene
        }
        let destination = pixels.bound(to: Float.self)
        scene.withPixels { source in
            for y in 0..<height {
                let top = (2 * y) * scene.width * 4
                let bottom = min(2 * y + 1, scene.height - 1) * scene.width * 4
                for x in 0..<width {
                    let left = 2 * x * 4
                    let right = min(2 * x + 1, scene.width - 1) * 4
                    for channel in 0..<4 {
                        let sum = Float(source[top + left + channel])
                                + Float(source[top + right + channel])
                                + Float(source[bottom + left + channel])
                                + Float(source[bottom + right + channel])
                        destination[(y * width + x) * 4 + channel] = sum / 4
                    }
                }
            }
        }
        var key = scene.key
        key.longEdge = max(width, height)
        pixels.flush(byteOffset: 0, byteCount: rowBytes * height)
        return Scene(pixels: pixels, width: width, height: height, key: key,
                     bakedMired: scene.bakedMired,
                     sceneKelvin: scene.sceneKelvin,
                     contentHeadroom: scene.contentHeadroom,
                     inputConversion: scene.inputConversion,
                     frameCoverage: scene.frameCoverage,
                     viewport: scene.viewport,
                     sensorFrame: scene.sensorFrame)
    }

    /// Develops `source` under `state`, resampled so its long edge is
    /// `longEdge` (nil keeps the source's own resolution).
    static func render(
        source: PhotoSource,
        state: EditState,
        longEdge: Int?,
        hdr: Bool = false,
        dynamicRange: AppSettings.DynamicRange = AppSettings.storedStillDynamicRange,
        exact: Bool = false,
        upright: Bool = true,
        usesSourceFrame: Bool = true,
        negative: NegativeViewing? = nil,
        report: Reporter? = nil
    ) -> Rendered? {
        // The develop reads the frame top-down in strips and the rasterise lays it down top-down
        // in bands, so the two need not take turns: the scene comes back as soon as its geometry
        // is settled and the film model waits per strip for the rows it is about to read.
        guard let scene = scene(source: source, state: state,
                                longEdge: longEdge, upright: upright,
                                usesSourceFrame: usesSourceFrame,
                                streaming: !serialScene,
                                report: report) else { return nil }
        guard var rendered = develop(
            scene, state: state, hdr: hdr, dynamicRange: dynamicRange,
            exact: exact, negative: negative, report: report
        )?.image else { return nil }
        rendered.metadata = source.captureMetadata
        rendered.orientation = upright ? .up : source.orientation
        return rendered
    }

    /// Runs the film model over an already-decoded scene.
    static func develop(
        _ scene: Scene,
        state: EditState,
        detailMeasurements: DetailMeasurements? = nil,
        collectHistogram: Bool = false,
        hdr: Bool = false,
        dynamicRange: AppSettings.DynamicRange = AppSettings.storedStillDynamicRange,
        exact: Bool = false,
        stock stockOverride: FilmStock? = nil,
        negative: NegativeViewing? = nil,
        report: Reporter? = nil,
        shouldContinue: (() -> Bool)? = nil
    ) -> (image: Rendered, histogram: [[Float]]?,
          hdrHistogram: [[Float]]?)? {
        func time<T>(_ stage: Stage, _ detail: String = "", _ body: () -> T) -> T {
            report?(.began(stage, detail: detail))
            let start = Date()
            let value = body()
            let note = memoryNote()
            if !note.isEmpty {
                report?(.advanced(stage, fraction: 1,
                                  detail: detail.isEmpty ? note : "\(detail) · \(note)"))
            }
            report?(.finished(stage, duration: Date().timeIntervalSince(start)))
            return value
        }

        let width = scene.width, height = scene.height
        guard width > 0, height > 0, shouldContinue?() != false else { return nil }
        // Taken before `withPixels` shadows the name. Nil for a scene that is already whole,
        // which is every scene the editor holds between renders.
        let sceneReady = scene.ready
        let entryTime = Date()
        var setupSeconds = 0.0
        // Which of the two develops this is. A photograph on no film goes without the emulsion and
        // so without the engine; one on a film the pack no longer carries, or with no engine to run
        // it, has nothing to develop with at all.
        let stillTimings = ProcessInfo.processInfo
            .environment["FOTUFILM_STILL_TIMINGS"] != nil
        let film: (stock: FilmStock, engine: HalideMetalFilmRenderer)?
        if let stock = stockOverride ?? state.stock {
            guard let engine = HalideMetalFilmRenderer.shared else {
                if stillTimings { print("  develop: no Metal engine") }
                return nil
            }
            film = (stock, engine)
        } else {
            guard StockPreset.isNoFilm(state.stockID) else {
                if stillTimings {
                    print("  develop: film \(state.stockID) is not installed")
                }
                return nil
            }
            film = nil
        }
        // A film-free develop is a kernel too — `FilmEngineFeature.noFilm`, which is
        // `PlainDevelop` expressed in the shared Halide source. It names `FilmStock.noFilm`
        // because the configuration is built from a stock and reads nothing that stock filled.
        // Nil where there is no Metal at all, and then the Swift path below still runs it.
        let plainEngine = film == nil ? HalideMetalFilmRenderer.shared : nil
        let stock = film?.stock
        // Resolve automatic gauge from the scene's captured sensor frame.
        var options = state.options(sensor: scene.sensorFrame)
        options.whiteBalance = remainingBalance(for: state, scene: scene)
        // The film the geometry kept, measured when the scene was placed: a cropped
        // picture is an enlargement, and the engine scales grain and the other
        // millimetre-sized structures to match.
        options.frameCoverage = scene.frameCoverage
        // The film-side scene light, from the same as-shot record the profile delta used at
        // rasterize time. The gate inside the engine decides whether it does anything.
        options.sceneIlluminantKelvin = scene.sceneKelvin
        // The recorded range above diffuse white, so an HDR source's highlights are metered
        // into the film's latitude instead of printing to paper white. Only when the decode
        // kept that light: a tone-mapped scene still carries the metadata fact in
        // `contentHeadroom` for the editor's sake, but its pixels are already SDR and there
        // is nothing left to place.
        options.sceneHeadroom = scene.inputConversion == .preserveHDR
            ? scene.contentHeadroom : 1
        if stock != nil { options.paper = state.resolvedPaper }
        // The requested delivery range is independent of the source. Negative film keeps the
        // source's full exposure range through development, but only direct-positive film and the
        // no-film path may be delivered above display white.
        let supportsHDR = stock.map {
            options.paper(for: $0).supportsHDRDelivery(for: $0)
        } ?? true
        let wantsHDR = hdr && dynamicRange == .hdr && supportsHDR
        let inputConversion = scene.inputConversion
        if let negative {
            options.negativeViewing = negative
        }
        let active = stock.map {
            activeStages(stock: $0, options: options, width: width, height: height)
        } ?? "no film"
        var bins = [[Float]](repeating: [Float](repeating: 0, count: 64), count: 3)
        var hdrBins = [[Float]](repeating: [Float](repeating: 0, count: 64),
                                count: 3)

        if stillTimings {
            setupSeconds = Date().timeIntervalSince(entryTime)
            print(String(format: "  %-10@ %8.1f ms",
                         "options" as NSString, setupSeconds * 1000))
        }
        let allocateStart = Date()
        guard let output = MappedBuffer(byteCount: width * height * 8) else {
            if stillTimings {
                print("  develop: no \((width * height * 8) >> 20) MB output buffer")
            }
            return nil
        }
        if stillTimings {
            print(String(format: "  %-10@ %8.1f ms", "allocate" as NSString,
                         Date().timeIntervalSince(allocateStart) * 1000))
        }

        let hdrOutput = wantsHDR ? MappedBuffer(byteCount: width * height * 8) : nil
        if wantsHDR, hdrOutput == nil { return nil }

        var glareStart: Date?
        var developStart: Date?
        /// How much of `develop` is the host widening the scene and encoding the print, rather than
        /// the engine. Both are full passes over the frame and neither shows up as its own stage.
        final class HandoverClock {
            var read = 0.0, write = 0.0
            /// Time a strip spent waiting for the rasterise to reach its rows — what is left of
            /// the scene's own cost once it runs beside the develop instead of before it.
            var wait = 0.0
            /// `write` minus the flush: the encode is arithmetic per pixel and the flush is the
            /// kernel starting writeback on a mapped page, and only one of them is worth trying
            /// to overlap with the engine.
            var encode = 0.0
        }
        let handoverClock = HandoverClock()
        let printed = output.bound(to: UInt16.self)
        let hdrPrinted = hdrOutput?.bound(to: UInt16.self)
        // Still delivery has one portable conversion contract. ImageIO only packs and tags the
        // resulting normalized values; it does not choose another transfer implementation.
        let sdrConversion: AnyFilmOutputConverter = film == nil
            ? AnyFilmOutputConverter(FilmOutputConversion.displayP3)
            : AnyFilmOutputConverter(FilmDisplayP3SDRConversion(
                shoulderKnee: FilmSDRDelivery.shoulderKnee(
                    isReversal: stock?.isReversal == true)))
        // The same delivery, named so the engine can take it in the producing kernel instead of
        // handing back display-linear light for the host to walk. Three things have to hold: the
        // engine's streaming path is the one developing (the film-free and viewport paths do
        // their own banding), the frame is not also being delivered as HDR — the HLG conversion
        // below reads the same rows and needs them still linear — and a variant that carries the
        // encode exists for this frame. `carriesOutputTransform` answers the last one before the
        // first strip, which is the only time it can be asked: a streaming render has already
        // written rows by the time it could return a refusal.
        let wantsKernelDelivery = hdrPrinted == nil
            && !(scene.viewport != nil && detailMeasurements != nil)
        // The film develop's transform, and the film-free one's. They differ only in the
        // shoulder, which is the difference between the two converters above.
        var outputTransform: FilmOutputTransform? = nil
        var plainTransform: FilmOutputTransform? = nil
        if wantsKernelDelivery, let film,
           film.engine.carriesOutputTransform(
               stock: film.stock, options: options, width: width,
               height: height, exactMath: exact) {
            outputTransform = .displayP3(shoulderKnee: FilmSDRDelivery.shoulderKnee(
                isReversal: stock?.isReversal == true))
        }
        if wantsKernelDelivery, let plainEngine,
           plainEngine.carriesOutputTransform(
               stock: .noFilm, options: options, width: width,
               height: height, exactMath: exact, noFilm: true) {
            plainTransform = .displayP3()
        }
        let deliveredByKernel = outputTransform != nil || plainTransform != nil
        // Writes one band of completed output.
        func writeRows(_ rows: Range<Int>, _ from: UnsafeBufferPointer<Float>) {
            let encodeStart = stillTimings ? Date() : Date.distantPast
            if deliveredByKernel {
                PrintEncoding.packRows(from, rows: rows, width: width,
                                       into: printed)
            } else {
                PrintEncoding.encodeRows(from, rows: rows, width: width,
                                         into: printed,
                                         converter: sdrConversion)
            }
            if stillTimings {
                handoverClock.encode += Date().timeIntervalSince(encodeStart)
            }
            if let hdrPrinted, let hdrOutput {
                PrintEncoding.encodeRows(from, rows: rows, width: width,
                                         into: hdrPrinted,
                                         converter: FilmOutputConversion.rec2020HLG)
                hdrOutput.flush(byteOffset: rows.lowerBound * width * 8,
                                byteCount: rows.count * width * 8)
            }
            output.flush(byteOffset: rows.lowerBound * width * 8,
                         byteCount: rows.count * width * 8)
            // The finished print, keyed by the row the band starts at, so the proof does not
            // depend on the order the engine happens to hand its strips back in.
            if ExportProof.isEnabled, let base = printed.baseAddress {
                ExportProof.add(key: rows.lowerBound,
                                UnsafeRawPointer(base + rows.lowerBound * width * 4),
                                count: rows.count * width * 8)
            }
            guard collectHistogram else { return }
            let base = rows.lowerBound * width * 4
            for index in stride(from: 0, to: rows.count * width * 4, by: 4) {
                for channel in 0..<3 {
                    bins[channel][Int(printed[base + index + channel]) >> 10] += 1
                }
            }
            guard let hdrPrinted else { return }
            for index in stride(from: 0, to: rows.count * width * 4, by: 4) {
                for channel in 0..<3 {
                    hdrBins[channel][Int(hdrPrinted[base + index + channel]) >> 10] += 1
                }
            }
        }

        /// One band's worth of progress, said the way the engine says it.
        func advance(band index: Int, of count: Int) {
            if let started = glareStart {
                glareStart = nil
                report?(.finished(.glare,
                                  duration: Date().timeIntervalSince(started)))
            }
            if developStart == nil {
                developStart = Date()
                report?(.began(.develop, detail: active))
            }
            let detail = count > 1 ? "strip \(index + 1) of \(count)" : active
            report?(.advanced(.develop, fraction: Double(index) / Double(count),
                              detail: detail))
        }

        // Source interpretation decides what reaches the film. Output range remains an independent
        // decision in `writeRows`.
        let streamStart = Date()
        let ok = scene.withPixelsWhileFilling { scenePixels -> Bool in
            guard let film else {
                // No strips on this path: it bands the frame itself, from the top, but it also
                // measures the whole frame first, so there is nothing to be gained by letting it
                // start early.
                sceneReady?.wait(through: height)
                if let plainEngine {
                    advance(band: 0, of: 1)
                    var transform = plainTransform
                    let developed = plainEngine.developStreaming(
                        width: width, height: height, stock: .noFilm,
                        options: options, outputTransform: &transform,
                        exactMath: exact, noFilm: true,
                        overlapsWriteback: !serialExport,
                        shouldContinue: shouldContinue,
                        readRows: { rows, into in
                            expand(scenePixels, rows: rows, width: width, into: into,
                                   inputConversion: inputConversion)
                        },
                        writeRows: writeRows)
                    // What the develop decided, back where the guard after it can read it.
                    plainTransform = transform
                    return developed
                }
                return developPlain(scenePixels, width: width, height: height,
                                    options: options,
                                    inputConversion: inputConversion,
                                    shouldContinue: shouldContinue,
                                    progress: advance, writeRows: writeRows)
            }
            if let viewport = scene.viewport, let detailMeasurements {
                sceneReady?.wait(through: height)
                advance(band: 0, of: 1)
                return developRegion(
                    scenePixels, width: width, height: height,
                    measurements: detailMeasurements,
                    viewport: viewport, film: film,
                    options: options,
                    inputConversion: inputConversion,
                    writeRows: writeRows)
            }
            return film.engine.developStreaming(
                width: width, height: height, stock: film.stock, options: options,
                outputTransform: &outputTransform,
                exactMath: exact,
                // This `writeRows` is `PrintEncoding` over a buffer the app owns, so it does not
                // care which thread calls it — and it is a full pass over the strip in float,
                // which is exactly the kind of host work worth hiding behind the next strip's
                // kernel.
                overlapsWriteback: !serialExport,
                progress: { phase in
                    switch phase {
                    case .measuringGlare:
                        glareStart = Date()
                        report?(.began(.glare, detail: "whole-frame mean"))
                    case .developing(let index, let count):
                        advance(band: index, of: count)
                    }
                },
                shouldContinue: shouldContinue,
                readRows: { rows, into in
                    let t0 = Date()
                    // Only the rows this strip is about to expand, and only when the rasterise
                    // is still behind them.
                    sceneReady?.wait(through: rows.upperBound)
                    handoverClock.wait += Date().timeIntervalSince(t0)
                    let t1 = Date()
                    expand(scenePixels, rows: rows, width: width, into: into,
                           inputConversion: inputConversion)
                    handoverClock.read += Date().timeIntervalSince(t1)
                },
                writeRows: { rows, from in
                    let t0 = Date()
                    writeRows(rows, from)
                    handoverClock.write += Date().timeIntervalSince(t0)
                })
        }
        if stillTimings {
            let streamed = Date().timeIntervalSince(streamStart)
            print(String(format: "  %-10@ %8.1f ms", "stream" as NSString,
                         streamed * 1000))
            print(String(format: "  %-10@ %8.1f ms", "scenewait" as NSString,
                         handoverClock.wait * 1000))
            print(String(format: "  %-10@ %8.1f ms", "expand" as NSString,
                         handoverClock.read * 1000))
            print(String(format: "  %-10@ %8.1f ms (encode %.1f, flush %.1f)",
                         "printenc" as NSString, handoverClock.write * 1000,
                         handoverClock.encode * 1000,
                         (handoverClock.write - handoverClock.encode) * 1000))
        }
        if let started = developStart {
            let note = memoryNote()
            if !note.isEmpty {
                report?(.advanced(.develop, fraction: 1, detail: "\(active) · \(note)"))
            }
            report?(.finished(.develop, duration: Date().timeIntervalSince(started)))
        }
        guard ok, shouldContinue?() != false else { return nil }
        // `carriesOutputTransform` asked the same question the develop call answers for itself,
        // so the two agree or the build is inconsistent. They cannot be allowed to disagree
        // silently: `writeRows` has already packed every row as delivered pixels, and a refusal
        // here means those rows were display-linear light.
        guard deliveredByKernel == (outputTransform != nil || plainTransform != nil)
        else { return nil }

        let image = time(.encode, wantsHDR ? "16-bit sRGB + HLG" : "16-bit sRGB") {
            PrintEncoding.makeImage(takingOwnershipOf: output, width: width,
                                    height: height,
                                    colorSpace: PrintEncoding.colorSpace(
                                        for: sdrConversion.colorSpace) ?? outputSpace)
        }
        guard let image else { return nil }
        let hdrImage = hdrOutput.flatMap { buffer in
            PrintEncoding.colorSpace(
                for: FilmOutputConversion.rec2020HLG.colorSpace
            ).flatMap {
                PrintEncoding.makeImage(takingOwnershipOf: buffer, width: width,
                                        height: height, colorSpace: $0)
            }
        }
        let rendered = Rendered(image: image, hdrImage: hdrImage)
        guard collectHistogram else { return (rendered, nil, nil) }
        func normalized(_ bins: [[Float]]) -> [[Float]] {
            let peak = max(1, bins.flatMap { $0 }.max() ?? 1)
            return bins.map { channel in channel.map { $0 / peak } }
        }
        return (rendered, normalized(bins),
                hdrImage == nil ? nil : normalized(hdrBins))
    }

    private static func developPlain(
        _ scene: UnsafeBufferPointer<Float>,
        width: Int, height: Int, options: FotufilmEngine.Options,
        inputConversion: FilmInputConversion,
        shouldContinue: (() -> Bool)?,
        progress: (_ band: Int, _ count: Int) -> Void,
        writeRows: (Range<Int>, UnsafeBufferPointer<Float>) -> Void
    ) -> Bool {
        var plain = PlainDevelop(options: options)
        // The same band the neutral metering walks in, sized so a band is about a megabyte.
        let bandRows = max(1, 262_144 / width)
        var scratch = [Float](repeating: 0,
                              count: min(bandRows, height) * width * 4)

        func bands(
            _ body: (Range<Int>, UnsafeMutableBufferPointer<Float>) -> Void
        ) -> Bool {
            var row = 0
            while row < height {
                if shouldContinue?() == false { return false }
                let upper = min(height, row + bandRows)
                scratch.withUnsafeMutableBufferPointer { buffer in
                    expand(scene, rows: row..<upper, width: width, into: buffer,
                           inputConversion: inputConversion)
                    body(row..<upper, buffer)
                }
                row = upper
            }
            return true
        }

        if plain.needsToneBase {
            var measurement = plain.toneBaseMeasurement(frameWidth: width,
                                                        frameHeight: height)
            guard bands({ rows, buffer in
                measurement.add(linearRGBA: buffer.baseAddress!, rows: rows)
            }) else { return false }
            plain.setToneBase(measurement)
        }

        let count = (height + bandRows - 1) / bandRows
        var band = 0
        return bands { rows, buffer in
            progress(band, count)
            plain.apply(linearRGBA: buffer, rows: rows, width: width)
            writeRows(rows, UnsafeBufferPointer(buffer))
            band += 1
        }
    }

    /// Develops one apron-bearing preview tile against measurements from its whole placed frame.
    private static func developRegion(
        _ scene: UnsafeBufferPointer<Float>,
        width: Int, height: Int,
        measurements: DetailMeasurements,
        viewport: PreviewViewport,
        film: (stock: FilmStock, engine: HalideMetalFilmRenderer),
        options: FotufilmEngine.Options,
        inputConversion: FilmInputConversion,
        writeRows: (Range<Int>, UnsafeBufferPointer<Float>) -> Void
    ) -> Bool {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        let regionCount = width * height * 4
        guard let regionInput = device.makeBuffer(
                length: regionCount * MemoryLayout<Float>.size,
                options: .storageModeShared),
              let regionOutput = device.makeBuffer(
                length: regionCount * MemoryLayout<Float>.size,
                options: .storageModeShared)
        else { return false }

        let regionDestination = UnsafeMutableBufferPointer(
            start: regionInput.contents().assumingMemoryBound(to: Float.self),
            count: regionCount)
        expand(scene, rows: 0..<height, width: width,
               into: regionDestination, inputConversion: inputConversion)

        let density = viewport.densityReferencePixelSize
        guard let context = film.engine.makeLinearFloatVirtualFrameContext(
            measurements: measurements.context,
            densityWidth: max(1, Int(density.width)),
            densityHeight: max(1, Int(density.height)),
            frameWidth: Int(viewport.virtualFrameSize.width),
            frameHeight: Int(viewport.virtualFrameSize.height),
            stock: film.stock, options: options),
              film.engine.processLinearFloatRegion(
                input: regionInput, output: regionOutput,
                regionWidth: width, regionHeight: height,
                originX: Int(viewport.origin.x),
                originY: Int(viewport.origin.y), context: context)
        else { return false }

        writeRows(0..<height, UnsafeBufferPointer(
            start: regionOutput.contents().assumingMemoryBound(to: Float.self),
            count: regionCount))
        return true
    }

    /// Full-precision scene-linear rows copied to the strip buffer the kernel owns.
    static func expand(_ scene: UnsafeBufferPointer<Float>,
                       rows: Range<Int>, width: Int,
                       into destination: UnsafeMutableBufferPointer<Float>,
                       inputConversion: FilmInputConversion = .preserveHDR) {
        let start = rows.lowerBound * width * 4
        let count = rows.count * width * 4
        SceneLinearInput.prepare(scene, from: start, count: count,
                                 into: destination,
                                 using: inputConversion)
    }

    /// Regional log-luminance statistics of a decoded scene, metered
    /// neutrally (balance 1, gain 1) — what the auto adjustment solves from.
    static func regionStops(of scene: Scene) -> [Float] {
        guard scene.width > 0, scene.height > 0 else { return [] }
        var measurement = ToneBaseMeasurement(
            frameWidth: scene.width, frameHeight: scene.height,
            balance: SIMD3(1, 1, 1), exposureGain: 1)
        let bandRows = max(1, 262_144 / scene.width)
        var scratch = [Float](repeating: 0,
                              count: min(bandRows, scene.height) * scene.width * 4)
        scene.withPixels { pixels in
            var row = 0
            while row < scene.height {
                let upper = min(scene.height, row + bandRows)
                scratch.withUnsafeMutableBufferPointer { buffer in
                    expand(pixels, rows: row..<upper, width: scene.width,
                           into: buffer,
                           inputConversion: scene.inputConversion)
                    measurement.add(linearRGBA: buffer.baseAddress!,
                                    rows: row..<upper)
                }
                row = upper
            }
        }
        return measurement.regionStops()
    }


    /// Names the physical stages this stock and these options actually switch on, so the progress
    /// UI describes the real pipeline rather than a fixed list.
    static func activeStages(stock: FilmStock, options: FotufilmEngine.Options,
                             width: Int, height: Int) -> String {
        let invocation = FilmEngineInvocation(
            stock: stock, options: options, width: width, height: height)
        var names = ["Spectral exposure"]
        let mask = invocation.featureMask
        if mask & FilmEngineFeature.flare != 0 { names.append("veiling glare") }
        if mask & FilmEngineFeature.mtf != 0 { names.append("emulsion diffusion") }
        if mask & FilmEngineFeature.halation != 0 { names.append("halation") }
        if mask & FilmEngineFeature.couplers != 0 { names.append("DIR couplers") }
        if mask & FilmEngineFeature.adjacency != 0 { names.append("adjacency") }
        names.append("H&D development")
        if mask & FilmEngineFeature.grain != 0 { names.append("grain") }
        names.append(stock.isReversal ? "transparency" : "RA-4 print")
        return names.joined(separator: " · ")
    }

    private static func geometry(_ image: CIImage, state: EditState) -> CIImage {
        var working = image
        switch (state.rotation % 4 + 4) % 4 {
        case 1: working = working.oriented(.right)
        case 2: working = working.oriented(.down)
        case 3: working = working.oriented(.left)
        default: break
        }
        if state.flipH { working = working.oriented(.upMirrored) }
        working = atOrigin(working)

        if abs(state.straighten) > 0.001,
           let filter = CIFilter(name: "CIStraightenFilter") {
            filter.setValue(working, forKey: kCIInputImageKey)
            filter.setValue(state.straighten * .pi / 180, forKey: kCIInputAngleKey)
            if let output = filter.outputImage { working = atOrigin(output) }
        }

        if abs(state.perspectiveV) > 0.001 || abs(state.perspectiveH) > 0.001,
           let filter = CIFilter(name: "CIPerspectiveTransform") {
            let extent = working.extent
            let corners = planeProjectedCorners(
                of: extent, tiltV: state.perspectiveV,
                tiltH: state.perspectiveH)
            filter.setValue(working, forKey: kCIInputImageKey)
            filter.setValue(CIVector(cgPoint: corners.topLeft),
                            forKey: "inputTopLeft")
            filter.setValue(CIVector(cgPoint: corners.topRight),
                            forKey: "inputTopRight")
            filter.setValue(CIVector(cgPoint: corners.bottomRight),
                            forKey: "inputBottomRight")
            filter.setValue(CIVector(cgPoint: corners.bottomLeft),
                            forKey: "inputBottomLeft")
            if let output = filter.outputImage {
                working = atOrigin(output.cropped(to: extent))
            }
        }

        if let crop = state.crop {
            let extent = working.extent
            let rect = CGRect(
                x: extent.minX + crop.minX * extent.width,
                y: extent.minY + crop.minY * extent.height,
                width: crop.width * extent.width,
                height: crop.height * extent.height
            ).integral.intersection(extent)
            if rect.width >= 8, rect.height >= 8 {
                working = atOrigin(working.cropped(to: rect))
            }
        }
        return working
    }

    private static func resample(_ image: CIImage, longEdge: Int?) -> CIImage {
        guard let longEdge else { return image }
        return atOrigin(downsample(image, longEdge: longEdge))
    }

    /// Resamples to an exact regional lattice. The viewport math keeps the aspect equal; the
    /// aspect parameter below only absorbs integral crop rounding.
    private static func resample(_ image: CIImage, pixelSize: CGSize) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0,
              pixelSize.width > 0, pixelSize.height > 0,
              let filter = CIFilter(name: "CILanczosScaleTransform") else {
            return image
        }
        let scale = pixelSize.height / extent.height
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(pixelSize.width / (extent.width * scale),
                        forKey: kCIInputAspectRatioKey)
        let resized = atOrigin(filter.outputImage ?? image)
        return resized.cropped(to: CGRect(origin: .zero, size: pixelSize))
    }

    /// Band-limited reduction.
    static func displayProxy(of source: PhotoSource,
                             longEdge: Int) -> CGImage? {
        guard let decoded = source.decoded(longEdge: longEdge,
                                           decodeMode: .expandedHDR)
        else { return nil }
        return context.createCGImage(decoded, from: decoded.extent,
                                     format: .RGBA8, colorSpace: outputSpace)
    }

    static func downsample(_ image: CIImage, longEdge: Int) -> CIImage {
        ImageResampling.downsample(image, longEdge: longEdge)
    }

    private static func atOrigin(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(
            translationX: -image.extent.minX, y: -image.extent.minY))
    }

    /// Where the frame's corners land once the picture plane tilts.
    static func planeProjectedCorners(
        of rect: CGRect, tiltV: Double, tiltH: Double
    ) -> (topLeft: CGPoint, topRight: CGPoint,
          bottomRight: CGPoint, bottomLeft: CGPoint) {
        let cx = Double(rect.midX), cy = Double(rect.midY)
        let focal = 1.3 * Double(max(rect.width, rect.height))
        let v = tiltV * .pi / 180, h = tiltH * .pi / 180

        func project(_ px: Double, _ py: Double) -> CGPoint {
            let dx = px - cx, dy = py - cy
            let y = dy * cos(v)
            var z = dy * sin(v)
            let x = dx * cos(h) - z * sin(h)
            z = dx * sin(h) + z * cos(h)
            let s = focal / (focal + z)
            return CGPoint(x: cx + x * s, y: cy + y * s)
        }

        var quad = [
            project(Double(rect.minX), Double(rect.maxY)),
            project(Double(rect.maxX), Double(rect.maxY)),
            project(Double(rect.maxX), Double(rect.minY)),
            project(Double(rect.minX), Double(rect.minY)),
        ]

        var scale = 1.0
        let rectCorners = [
            (Double(rect.minX), Double(rect.maxY)),
            (Double(rect.maxX), Double(rect.maxY)),
            (Double(rect.maxX), Double(rect.minY)),
            (Double(rect.minX), Double(rect.minY)),
        ]
        for (rx, ry) in rectCorners {
            let dx = rx - cx, dy = ry - cy
            var reach = Double.infinity
            for i in 0..<4 {
                let a = quad[i], b = quad[(i + 1) % 4]
                let ex = Double(b.x - a.x), ey = Double(b.y - a.y)
                let denominator = dx * ey - dy * ex
                guard abs(denominator) > 1e-9 else { continue }
                let ax = Double(a.x) - cx, ay = Double(a.y) - cy
                let u = (ax * ey - ay * ex) / denominator
                let w = (ax * dy - ay * dx) / denominator
                if u > 0, w >= -1e-6, w <= 1 + 1e-6 { reach = min(reach, u) }
            }
            if reach.isFinite, reach > 0 { scale = max(scale, 1 / reach) }
        }
        if scale > 1 {
            quad = quad.map {
                CGPoint(x: cx + (Double($0.x) - cx) * scale,
                        y: cy + (Double($0.y) - cy) * scale)
            }
        }
        return (quad[0], quad[1], quad[2], quad[3])
    }

}

/// A picked photo, decoded on demand at whatever resolution is asked for.
struct PhotoSource: @unchecked Sendable {
    enum Kind: Sendable {
        case raw
        case raster
        case bitmap
    }

    enum DecodeMode: Sendable {
        case expandedHDR
        case coreImageToneMappedSDR
    }

    enum Payload {
        case file(Data)
        case bitmap(CGImage)
    }

    /// Facts discovered once when the source enters the app. Rendering reads this value instead of
    /// repeatedly reopening ImageIO and RAW containers during every preview and export.
    struct Descriptor {
        let kind: Kind
        let contentType: UTType?
        let originalName: String?
        let pixelSize: CGSize
        let orientation: CGImagePropertyOrientation
        let asShotMired: Float?
        let camera: CameraIdentity?
        let captureMetadata: [String: Any]?
        let lensShot: LensShot?
        let sensorFrame: SensorFrame?
        let declaredHeadroom: Float?
        let sourceColorProfile: String?
    }

    struct OriginalFile: @unchecked Sendable {
        let data: Data
        let contentType: UTType?
        let name: String?

        var fileExtension: String {
            if let name {
                let suffix = (name as NSString).pathExtension
                if !suffix.isEmpty { return suffix.lowercased() }
            }
            return contentType?.preferredFilenameExtension ?? "raw"
        }
    }

    let payload: Payload
    let descriptor: Descriptor
    /// A concrete RAW UTI when the container cannot identify itself from its bytes.
    let rawHint: String?

    var data: Data? {
        guard case .file(let data) = payload else { return nil }
        return data
    }
    var isRaw: Bool { descriptor.kind == .raw }
    var asShotMired: Float? { descriptor.asShotMired }
    var camera: CameraIdentity? { descriptor.camera }
    var orientation: CGImagePropertyOrientation { descriptor.orientation }
    var pixelSize: CGSize { descriptor.pixelSize }
    var captureMetadata: [String: Any]? { descriptor.captureMetadata }
    var lensShot: LensShot? { descriptor.lensShot }
    var sensorFrame: SensorFrame? { descriptor.sensorFrame }
    var declaredHeadroom: Float? { descriptor.declaredHeadroom }
    var originalFile: OriginalFile? {
        guard let data else { return nil }
        return OriginalFile(data: data, contentType: descriptor.contentType,
                            name: descriptor.originalName)
    }
    var originalRaw: OriginalFile? { isRaw ? originalFile : nil }

    /// Opens raw bytes, or returns nil if they are not camera raw.
    static func raw(data: Data, hint: String?, name: String? = nil) -> PhotoSource? {
        guard let raw = RawDecode.metadata(data: data, identifierHint: hint)
        else { return nil }
        let properties = imageProperties(data)
        let contentType = resolvedContentType(data: data, hint: hint)
        let capture = captureMetadata(from: properties)
        return PhotoSource(
            payload: .file(data),
            descriptor: Descriptor(
                kind: .raw, contentType: contentType, originalName: name,
                pixelSize: raw.pixelSize, orientation: .up,
                asShotMired: raw.asShotMired, camera: raw.camera,
                captureMetadata: capture, lensShot: lensShot(from: capture),
                sensorFrame: SensorFrame.read(data: data), declaredHeadroom: nil,
                sourceColorProfile: properties?[kCGImagePropertyProfileName as String]
                    as? String),
            rawHint: contentType?.identifier ?? hint)
    }

    /// Opens anything else — a JPEG, a HEIC, a gain-map HDR photo.
    static func file(data: Data, name: String? = nil) -> PhotoSource {
        let properties = imageProperties(data)
        let orientation = (properties?[kCGImagePropertyOrientation as String]
            as? NSNumber).flatMap { CGImagePropertyOrientation(rawValue: $0.uint32Value) }
            ?? .up
        let extent = CIImage(data: data)?.extent.size ?? .zero
        let pixelSize: CGSize
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            pixelSize = CGSize(width: extent.height, height: extent.width)
        default:
            pixelSize = extent
        }
        let capture = captureMetadata(from: properties)
        return PhotoSource(
            payload: .file(data),
            descriptor: Descriptor(
                kind: .raster,
                contentType: resolvedContentType(data: data, hint: nil),
                originalName: name, pixelSize: pixelSize,
                orientation: orientation, asShotMired: nil, camera: nil,
                captureMetadata: capture, lensShot: lensShot(from: capture),
                sensorFrame: SensorFrame.read(data: data),
                declaredHeadroom: GainMapHeadroom.declared(data: data),
                sourceColorProfile: properties?[kCGImagePropertyProfileName as String]
                    as? String),
            rawHint: nil)
    }

    static func bitmap(_ image: CGImage) -> PhotoSource {
        PhotoSource(
            payload: .bitmap(image),
            descriptor: Descriptor(
                kind: .bitmap, contentType: nil, originalName: nil,
                pixelSize: CGSize(width: image.width, height: image.height),
                orientation: .up, asShotMired: nil, camera: nil,
                captureMetadata: nil, lensShot: nil, sensorFrame: nil,
                declaredHeadroom: nil,
                sourceColorProfile: image.colorSpace?.name.map { $0 as String }),
            rawHint: nil)
    }

    var detail: String {
        switch descriptor.kind {
        case .raw: return "camera raw"
        case .raster: return "image file"
        case .bitmap: return "bitmap"
        }
    }

    /// The untouched bytes when the source is specifically a DNG.
    var originalDNGData: Data? {
        guard let originalRaw,
              originalRaw.contentType?.preferredFilenameExtension?.lowercased() == "dng"
        else { return nil }
        return originalRaw.data
    }

    private static func resolvedContentType(data: Data, hint: String?) -> UTType? {
        let hinted = hint.flatMap(UTType.init)
        if hinted?.conforms(to: .rawImage) == true, hinted != .rawImage {
            return hinted
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source) as String?
        else { return hinted }
        return UTType(identifier) ?? hinted
    }

    private static func imageProperties(_ data: Data) -> [String: Any]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [String: Any] else { return nil }
        return properties
    }

    private static func captureMetadata(
        from properties: [String: Any]?
    ) -> [String: Any]? {
        guard let properties else { return nil }
        var kept: [String: Any] = [:]
        for key in [kCGImagePropertyExifDictionary,
                    kCGImagePropertyExifAuxDictionary,
                    kCGImagePropertyTIFFDictionary,
                    kCGImagePropertyGPSDictionary] {
            guard var dictionary = properties[key as String] as? [String: Any]
            else { continue }
            if key == kCGImagePropertyTIFFDictionary {
                dictionary[kCGImagePropertyTIFFOrientation as String] = nil
            }
            if key == kCGImagePropertyExifDictionary {
                dictionary[kCGImagePropertyExifPixelXDimension as String] = nil
                dictionary[kCGImagePropertyExifPixelYDimension as String] = nil
            }
            kept[key as String] = dictionary
        }
        return kept.isEmpty ? nil : kept
    }

    private static func lensShot(from metadata: [String: Any]?) -> LensShot? {
        guard let metadata,
              let exif = metadata[kCGImagePropertyExifDictionary as String]
                as? [String: Any] else { return nil }
        let auxiliary = metadata[kCGImagePropertyExifAuxDictionary as String]
            as? [String: Any]
        let tiff = metadata[kCGImagePropertyTIFFDictionary as String]
            as? [String: Any]
        // Apple writes the lens name into the auxiliary dictionary rather than the Exif one, so both
        // are asked before giving up.
        let model = (exif[kCGImagePropertyExifLensModel as String] as? String)
            ?? (auxiliary?["LensModel"] as? String)
        guard let model, !model.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return LensShot(
            lensModel: model,
            lensMaker: exif[kCGImagePropertyExifLensMake as String] as? String,
            cameraModel: tiff?[kCGImagePropertyTIFFModel as String] as? String,
            focalLength: (exif[kCGImagePropertyExifFocalLength as String]
                as? NSNumber)?.floatValue,
            aperture: (exif[kCGImagePropertyExifFNumber as String]
                as? NSNumber)?.floatValue)
    }

    /// Decodes to scene-linear, optionally capped at `longEdge` pixels. `neutralKelvin` names the
    /// illuminant a raw demosaic should balance for; `RawDecode` holds that reasoning, and every
    /// other decision the decode makes, so this path and the CLI's cannot drift apart.
    func decoded(longEdge: Int? = nil, neutralKelvin: Float? = nil,
                 upright: Bool = true,
                 decodeMode: DecodeMode = .expandedHDR,
                 correctingLens: Bool? = nil) -> CIImage? {
        var decoded: CIImage?
        if isRaw, let data {
            decoded = RawDecode.image(data: data, identifierHint: rawHint,
                                      recipe: RawDecode.Recipe(
                                        neutralKelvin: neutralKelvin,
                                        targetLongEdge: longEdge,
                                        correctsLens: correctingLens))
        } else if let data {
            switch decodeMode {
            case .coreImageToneMappedSDR:
                decoded = CIImage(data: data, options: [.toneMapHDRtoSDR: true])
            case .expandedHDR:
                decoded = CIImage(data: data, options: [.expandToHDR: true])
                    ?? CIImage(data: data)
            }
            if upright, orientation != .up {
                decoded = decoded?.oriented(orientation)
            }
        } else if case .bitmap(let image) = payload {
            decoded = CIImage(cgImage: image)
        }
        guard var output = decoded else { return nil }
        if let longEdge {
            output = FilmRender.downsample(output, longEdge: longEdge)
        }
        return output.transformed(by: CGAffineTransform(
            translationX: -output.extent.minX, y: -output.extent.minY))
    }
}

/// A finished render.
struct Rendered {
    let image: CGImage

    /// The same print encoded with the HDR shoulder and HLG, when one was asked for.
    var hdrImage: CGImage?

    /// The negative's own record — camera, lens, exposure, place — carried
    /// from the source file into whatever the writers below produce.
    var metadata: [String: Any]? = nil

    /// Which way the print's rows stand, written into the file the way the
    /// camera's own photographs carry it.
    var orientation = CGImagePropertyOrientation.up

    var pixelSize: CGSize {
        CGSize(width: image.width, height: image.height)
    }

    /// A small copy for display, so a 33 MP export is never hosted by a view.
    func thumbnailImage(maxDimension: CGFloat) -> CGImage? {
        let longest = CGFloat(max(image.width, image.height))
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let width = Int((CGFloat(image.width) * scale).rounded())
        let height = Int((CGFloat(image.height) * scale).rounded())
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.displayP3)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// What an HDR photograph is written as.
    enum HDRContainer: String, Sendable {
        /// A 10-bit Display P3 SDR base plus a gain map derived from the pair, which is what the
        /// iPhone's own camera writes.
        case gainMap
        /// A single 10-bit HLG layer.
        case hlg

        /// Whether this device can write it at all.
        var isAvailable: Bool {
            switch self {
            case .gainMap:
                if #available(macOS 15, *) { return true }
                return false
            case .hlg:
                return true
            }
        }
    }

    private static let hdrContext = CIContext(options: [.cacheIntermediates: false])

    @discardableResult
    func metadata(applying policy: ExportMetadataPolicy) -> [String: Any]? {
        guard var carried = metadata, policy != .strip else { return nil }
        if policy == .preserveWithoutLocation {
            carried[kCGImagePropertyGPSDictionary as String] = nil
        }
        return carried.isEmpty ? nil : carried
    }

    private func annotated(_ base: CIImage,
                           metadata policy: ExportMetadataPolicy) -> CIImage {
        var carried = metadata(applying: policy) ?? [:]
        if orientation != .up {
            carried[kCGImagePropertyOrientation as String] = orientation.rawValue
        }
        guard !carried.isEmpty else { return base }
        return base.settingProperties(
            base.properties.merging(carried) { _, kept in kept })
    }

    @discardableResult
    func writeHDR(to url: URL, as container: HDRContainer,
                  metadata policy: ExportMetadataPolicy) -> Bool {
        guard let hdrImage else { return false }
        try? FileManager.default.removeItem(at: url)
        let hdr = CIImage(cgImage: hdrImage)
        switch container {
        case .hlg:
            guard let space = FilmRender.hdrSpace else { return false }
            return (try? Self.hdrContext.writeHEIF10Representation(
                of: annotated(hdr, metadata: policy), to: url, colorSpace: space,
                options: [:])) != nil
        case .gainMap:
            guard #available(iOS 18, macOS 15, *) else { return false }
            let sdr = annotated(CIImage(cgImage: image), metadata: policy)
            return (try? Self.hdrContext.writeHEIFRepresentation(
                of: sdr, to: url, format: .RGB10,
                colorSpace: FilmRender.outputSpace,
                options: [.hdrImage: hdr, .hdrGainMapAsRGB: true])) != nil
        }
    }

}
