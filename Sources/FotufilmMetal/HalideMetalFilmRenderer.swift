#if canImport(Metal)
import Foundation
import Metal
#if canImport(FotufilmCore)
import FotufilmCore
#endif
import FotufilmHalide

private func outputTransferFeature(
    _ transfer: FilmOutputTransform.Transfer, realtime: Bool
) -> Int32 {
    guard realtime else { return 0 }
    switch transfer {
    case .linear: return FilmEngineFeature.outputLinear
    case .powerLaw: return FilmEngineFeature.outputPower
    case .logarithmic: return FilmEngineFeature.outputLog
    }
}

/// What the engine is doing during a scene-referred render, for a progress UI.
public enum FilmRenderPhase: Sendable, Equatable {
    /// Measuring the whole-frame veiling-glare mean.
    case measuringGlare
    case developing(index: Int, count: Int)
}

/// One frame of scene-linear staging the engine lends its caller: a pair of shared MTLBuffers the
/// CPU writes and reads directly and Halide reads and writes in place.
///
/// A caller that has to traverse the frame anyway — the OFX plugin decodes the timeline's colour
/// space on the way in and encodes it on the way out — writes into `scenePixels` and reads back
/// from `developedPixels`, and the frame never crosses the host/device boundary at all. Handing
/// the same pixels to `developStreaming` as plain host pointers instead has Halide copy the whole
/// frame onto the device and the whole result back off it, which at UHD is a third of the frame
/// time and more than the film model itself costs.
public final class FilmFrameStaging {
    fileprivate let input: MTLBuffer
    fileprivate let output: MTLBuffer
    /// Frames up to this many pixels fit; a larger one needs a new staging.
    public let capacityPixels: Int

    fileprivate init?(device: MTLDevice, pixels: Int) {
        guard pixels > 0,
              let input = device.makeBuffer(length: pixels * 16,
                                            options: .storageModeShared),
              let output = device.makeBuffer(length: pixels * 16,
                                             options: .storageModeShared)
        else { return nil }
        self.input = input
        self.output = output
        self.capacityPixels = pixels
    }

    /// Where the caller writes the frame: interleaved scene-linear Rec.2020 RGBA — the
    /// engine's working space — tightly packed, top row first, the layout `developStreaming`
    /// reads through `readRows`.
    public var scenePixels: UnsafeMutablePointer<Float> {
        input.contents().assumingMemoryBound(to: Float.self)
    }

    /// Where the developed frame lands, in that same layout.
    ///
    /// Also the staging's scratch until the render fills it, which is what `decodeStaged` uses it
    /// as: a caller decoding on the device lays the host's own encoded frame here and is handed
    /// scene-linear light in `scenePixels`. Nothing written here survives a render.
    public var developedPixels: UnsafeMutablePointer<Float> {
        output.contents().assumingMemoryBound(to: Float.self)
    }

    fileprivate var inputHandle: UInt64 {
        UInt64(UInt(bitPattern: Unmanaged.passUnretained(input as AnyObject).toOpaque()))
    }

    fileprivate var outputHandle: UInt64 {
        UInt64(UInt(bitPattern: Unmanaged.passUnretained(output as AnyObject).toOpaque()))
    }
}

/// The strip buffers one streaming render works in: the strip's input, and the schedule's result.
/// Borrowed for the length of a render and returned, because sizing them per call meant
/// allocating and zero-filling 265 MB on every UHD frame — storage whose every byte is overwritten
/// before it is read.
///
/// The two are sized apart: the input spans the strip and both aprons, while the result holds
/// only the delivered rows — the cropped kernel never writes an apron row, so allocating for one
/// would buy 2 x apron rows of nothing.
private final class StripBuffers {
    let input: UnsafeMutablePointer<Float>
    /// Two results in flight: the kernel writes one strip while the host is still encoding the
    /// last one out of the other. A single scratch made the two stages take turns, and on a 33 MP
    /// still the encode is a third of the time the kernel takes — a third of the device's work
    /// spent watching a core convert floats. The second buffer is one strip of float RGBA, an
    /// eighth of what a strip already costs the budget.
    private let scratches: [UnsafeMutablePointer<Float>]
    let capacity: Int
    let scratchCapacity: Int

    var scratchCount: Int { scratches.count }

    func scratch(at index: Int) -> UnsafeMutablePointer<Float> {
        scratches[index % scratches.count]
    }

    /// The single-scratch spelling, for the paths that hand a strip back before starting another.
    var scratch: UnsafeMutablePointer<Float> { scratches[0] }

    init(capacity: Int, scratchCapacity: Int, scratchCount: Int = 1) {
        self.capacity = capacity
        self.scratchCapacity = scratchCapacity
        input = .allocate(capacity: capacity)
        scratches = (0..<max(1, scratchCount)).map { _ in
            UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity)
        }
    }

    deinit {
        input.deallocate()
        for scratch in scratches { scratch.deallocate() }
    }
}

/// Whole-frame measurements required to render a crop exactly as part of that frame.
public struct FilmFrameContext {
    fileprivate enum Encoding: Equatable {
        case encodedDisplayP3
        case linearRec2020
    }

    fileprivate var invocation: FilmEngineInvocation
    fileprivate let width: Int
    fileprivate let height: Int
    fileprivate let encoding: Encoding
}

/// Halide's Metal-targeted implementation of the complete spectral film
/// pipeline, optimized for a stream of tightly packed RGBA8 video frames.
public final class HalideMetalFilmRenderer {
    /// Shared renderer, or nil when Halide was not linked with a usable Metal runtime/device.
    public static let shared = HalideMetalFilmRenderer()

    public init?() {
        guard fotufilm_halide_metal_available() == 1 else { return nil }
    }

    /// Measures the global stages for an Apple video frame carrying transfer-encoded Display P3.
    public func makeRGBA8FrameContext(
        input: MTLBuffer, width: Int, height: Int,
        stock: FilmStock, options: FotufilmEngine.Options,
        frameIndex: UInt64 = 0, flareFrame: FilmFlareFrame? = nil
    ) -> FilmFrameContext? {
        let byteCount = width * height * 4
        precondition(width > 0 && height > 0)
        precondition(input.length >= byteCount)
        var invocation = FilmEngineInvocation(
            stock: stock, options: options, width: width,
            height: height, frameIndex: frameIndex)
        if invocation.localToneActive
            || invocation.featureMask & FilmEngineFeature.flare != 0 {
            guard input.storageMode == .shared else { return nil }
            let pixels = input.contents().assumingMemoryBound(to: UInt8.self)
            if invocation.localToneActive {
                invocation.measureToneBase(
                    encodedDisplayP3RGBA: pixels, width: width, height: height)
            }
            if invocation.featureMask & FilmEngineFeature.flare != 0 {
                if let flareFrame {
                    guard flareFrame.width == width, flareFrame.height == height else { return nil }
                    invocation.flareMean = invocation.measuredAreaWeightedFlareMean(flareFrame)
                } else {
                    invocation.flareMean = invocation.measuredAreaWeightedFlareMean(
                        encodedDisplayP3RGBA: pixels, width: width, height: height)
                }
            }
        }
        return FilmFrameContext(invocation: invocation, width: width, height: height,
                                encoding: .encodedDisplayP3)
    }

    /// Measures the global stages for a scene-referred frame already in the working space,
    /// linear Rec.2020.
    public func makeLinearFloatFrameContext(
        input: MTLBuffer, width: Int, height: Int,
        stock: FilmStock, options: FotufilmEngine.Options,
        frameIndex: UInt64 = 0, realtime: Bool = false,
        flareFrame: FilmFlareFrame? = nil
    ) -> FilmFrameContext? {
        let byteCount = width * height * 16
        precondition(width > 0 && height > 0)
        precondition(input.length >= byteCount)
        var invocation = FilmEngineInvocation(
            stock: stock, options: options, width: width,
            height: height, frameIndex: frameIndex)
        if realtime { invocation.featureMask |= FilmEngineFeature.realtime }
        if invocation.localToneActive
            || invocation.featureMask & FilmEngineFeature.flare != 0 {
            guard input.storageMode == .shared else { return nil }
            let pixels = input.contents().assumingMemoryBound(to: Float.self)
            if invocation.localToneActive {
                var measurement = invocation.toneBaseMeasurement()
                measurement.add(linearRGBA: pixels, rows: 0..<height)
                invocation.setToneBase(measurement)
            }
            if invocation.featureMask & FilmEngineFeature.flare != 0 {
                if let flareFrame {
                    guard flareFrame.width == width, flareFrame.height == height else { return nil }
                    invocation.flareMean = invocation.measuredAreaWeightedFlareMean(flareFrame)
                } else {
                    invocation.flareMean = invocation.measuredAreaWeightedFlareMean(
                        linearRGBA: pixels, width: width, height: height)
                }
            }
        }
        return FilmFrameContext(invocation: invocation, width: width, height: height,
                                encoding: .linearRec2020)
    }

    /// Builds a regional context at `frameWidth` × `frameHeight` while taking tone-base and
    /// veiling-glare measurements from a lower-density whole-frame buffer.
    ///
    /// `densityWidth` and `densityHeight` describe the visible region whose `frameCoverage` is in
    /// `options`. They size millimetre-based stages. The virtual dimensions only anchor spatial
    /// phases and the whole-frame tone grid; using them to size the stages as well would count the
    /// viewport enlargement twice.
    public func makeLinearFloatVirtualFrameContext(
        measurementInput: MTLBuffer,
        measurementWidth: Int, measurementHeight: Int,
        densityWidth: Int, densityHeight: Int,
        frameWidth: Int, frameHeight: Int,
        stock: FilmStock, options: FotufilmEngine.Options,
        frameIndex: UInt64 = 0, realtime: Bool = false
    ) -> FilmFrameContext? {
        precondition(measurementWidth > 0 && measurementHeight > 0)
        precondition(densityWidth > 0 && densityHeight > 0)
        precondition(frameWidth >= densityWidth && frameHeight >= densityHeight)
        precondition(measurementInput.length
                     >= measurementWidth * measurementHeight * 16)

        guard let measured = makeLinearFloatFrameContext(
            input: measurementInput,
            width: measurementWidth, height: measurementHeight,
            stock: stock, options: options,
            frameIndex: frameIndex, realtime: realtime)
        else { return nil }

        return makeLinearFloatVirtualFrameContext(
            measurements: measured,
            densityWidth: densityWidth, densityHeight: densityHeight,
            frameWidth: frameWidth, frameHeight: frameHeight,
            stock: stock, options: options,
            frameIndex: frameIndex, realtime: realtime)
    }

    /// Reuses previously-computed whole-frame measurements for another virtual regional context.
    public func makeLinearFloatVirtualFrameContext(
        measurements measured: FilmFrameContext,
        densityWidth: Int, densityHeight: Int,
        frameWidth: Int, frameHeight: Int,
        stock: FilmStock, options: FotufilmEngine.Options,
        frameIndex: UInt64 = 0, realtime: Bool = false
    ) -> FilmFrameContext? {
        precondition(densityWidth > 0 && densityHeight > 0)
        precondition(frameWidth >= densityWidth && frameHeight >= densityHeight)
        guard measured.encoding == .linearRec2020 else { return nil }
        var invocation = FilmEngineInvocation(
            stock: stock, options: options,
            width: densityWidth, height: densityHeight,
            frameIndex: frameIndex)
        if realtime { invocation.featureMask |= FilmEngineFeature.realtime }

        if invocation.localToneActive {
            let measuredWidth = Int(measured.invocation.configuration[
                FilmEngineInvocation.toneGridSizeOffset])
            let measuredHeight = Int(measured.invocation.configuration[
                FilmEngineInvocation.toneGridSizeOffset + 1])
            let virtualGrid = ToneBaseMeasurement(
                frameWidth: frameWidth, frameHeight: frameHeight,
                balance: SIMD3<Float>(repeating: 1), exposureGain: 1)
            let agrees = measuredWidth == virtualGrid.gridWidth
                && measuredHeight == virtualGrid.gridHeight
            assert(agrees, "base and virtual tone grids must have the same aspect")
            guard agrees else { return nil }

            invocation.configuration[FilmEngineInvocation.toneGridSizeOffset]
                = Float(measuredWidth)
            invocation.configuration[FilmEngineInvocation.toneGridSizeOffset + 1]
                = Float(measuredHeight)
            for index in 0..<FilmEngineInvocation.toneGridCells {
                invocation.configuration[FilmEngineInvocation.toneGridAOffset + index]
                    = measured.invocation.configuration[
                        FilmEngineInvocation.toneGridAOffset + index]
                invocation.configuration[FilmEngineInvocation.toneGridBOffset + index]
                    = measured.invocation.configuration[
                        FilmEngineInvocation.toneGridBOffset + index]
            }
        }
        if invocation.featureMask & FilmEngineFeature.flare != 0 {
            invocation.flareMean = measured.invocation.flareMean
        }

        invocation.configuration[FilmEngineInvocation.frameSizeOffset]
            = Float(frameWidth)
        invocation.configuration[FilmEngineInvocation.frameSizeOffset + 1]
            = Float(frameHeight)
        return FilmFrameContext(invocation: invocation,
                                width: frameWidth, height: frameHeight,
                                encoding: .linearRec2020)
    }

    @discardableResult
    public func prepare(stock: FilmStock, options: FotufilmEngine.Options,
                        frameWidth: Int, frameHeight: Int) -> Bool {
        guard frameWidth > 0, frameHeight > 0 else { return false }
        let invocation = FilmEngineInvocation(
            stock: stock, options: options, width: frameWidth, height: frameHeight)
        return invocation.withSpectralPointers { exposure, film, paper in
            fotufilm_halide_metal_prepare(
                invocation.featureMask, exposure, film, paper,
                Int32(invocation.spectral.exposure.dimension),
                invocation.spectralCacheID) == 0
        }
    }

    @discardableResult
    public func prepare(stock: FilmStock, options: FotufilmEngine.Options,
                        frameHeight: Int) -> Bool {
        prepare(stock: stock, options: options,
                frameWidth: frameHeight, frameHeight: frameHeight)
    }

    /// Convenience allocating form.
    public func processSRGB8(
        _ pixels: [UInt8], width: Int, height: Int,
        stock: FilmStock, options: FotufilmEngine.Options,
        frameIndex: UInt64 = 0
    ) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: width * height * 4)
        return processSRGB8(
            pixels, into: &output, width: width, height: height,
            stock: stock, options: options, frameIndex: frameIndex
        ) ? output : nil
    }

    @discardableResult
    public func processSRGB8(
        _ pixels: [UInt8], into output: inout [UInt8],
        width: Int, height: Int,
        stock: FilmStock, options: FotufilmEngine.Options,
        frameIndex: UInt64 = 0
    ) -> Bool {
        let byteCount = width * height * 4
        precondition(width > 0 && height > 0)
        precondition(pixels.count >= byteCount)
        if output.count != byteCount {
            output = [UInt8](repeating: 0, count: byteCount)
        }
        var invocation = FilmEngineInvocation(
            stock: stock, options: options, width: width,
            height: height, frameIndex: frameIndex)
        pixels.withUnsafeBufferPointer { input in
            if invocation.localToneActive {
                invocation.measureToneBase(srgbRGBA: input.baseAddress!,
                                           width: width, height: height)
            }
            if invocation.featureMask & FilmEngineFeature.flare != 0 {
                invocation.flareMean = invocation.measuredAreaWeightedFlareMean(
                    srgbRGBA: input.baseAddress!, width: width, height: height)
            }
        }
        var workingInput = [UInt8](repeating: 0, count: byteCount)
        var workingOutput = [UInt8](repeating: 0, count: byteCount)
        Self.convertSRGBToEncodedDisplayP3(pixels, into: &workingInput)
        let rendered = workingInput.withUnsafeBufferPointer { input in
            workingOutput.withUnsafeMutableBufferPointer { output in
                invocation.configuration.withUnsafeBufferPointer { configuration in
                    invocation.withSpectralPointers { exposure, film, paper in
                        fotufilm_halide_metal_process_srgb8(
                            input.baseAddress, output.baseAddress,
                            Int32(width), Int32(height), configuration.baseAddress,
                            exposure, film, paper,
                            Int32(invocation.spectral.exposure.dimension),
                            invocation.spectralCacheID, invocation.featureMask,
                            invocation.seed) == 0
                    }
                }
            }
        }
        guard rendered else { return false }
        Self.convertEncodedDisplayP3ToSRGB(workingOutput, into: &output)
        return true
    }

    @discardableResult
    public func processLinearFloat(
        _ pixels: [Float], into output: inout [Float],
        width: Int, height: Int,
        stock: FilmStock, options: FotufilmEngine.Options,
        frameIndex: UInt64 = 0,
        memoryBudget: Int? = nil,
        apronScale: Double = 1,
        progress: ((FilmRenderPhase) -> Void)? = nil
    ) -> Bool {
        let count = width * height * 4
        precondition(width > 0 && height > 0)
        precondition(pixels.count >= count)
        if output.count != count { output = [Float](repeating: 0, count: count) }
        return pixels.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                developStreaming(
                    width: width, height: height, stock: stock, options: options,
                    frameIndex: frameIndex, memoryBudget: memoryBudget,
                    apronScale: apronScale, progress: progress,
                    readRows: { rows, into in
                        into.baseAddress!.update(
                            from: source.baseAddress! + rows.lowerBound * width * 4,
                            count: rows.count * width * 4)
                    },
                    writeRows: { rows, from in
                        destination.baseAddress!
                            .advanced(by: rows.lowerBound * width * 4)
                            .update(from: from.baseAddress!,
                                    count: rows.count * width * 4)
                    })
            }
        }
    }

    /// Develops the frame a strip at a time, for callers with no use for the transform. See the
    /// overload below for what that parameter is; a caller passing nothing is handed the light.
    @discardableResult
    public func developStreaming(
        width: Int, height: Int,
        stock: FilmStock, options: FotufilmEngine.Options,
        frameIndex: UInt64 = 0,
        memoryBudget: Int? = nil,
        apronScale: Double = 1,
        realtime: Bool = false,
        exactMath: Bool = false,
        overlapsWriteback: Bool = false,
        progress: ((FilmRenderPhase) -> Void)? = nil,
        shouldContinue: (() -> Bool)? = nil,
        readRows: (_ rows: Range<Int>, _ into: UnsafeMutableBufferPointer<Float>) -> Void,
        writeRows: (_ rows: Range<Int>, _ from: UnsafeBufferPointer<Float>) -> Void
    ) -> Bool {
        var none: FilmOutputTransform? = nil
        return developStreaming(
            width: width, height: height, stock: stock, options: options,
            outputTransform: &none, frameIndex: frameIndex, memoryBudget: memoryBudget,
            apronScale: apronScale, realtime: realtime, exactMath: exactMath,
            overlapsWriteback: overlapsWriteback, progress: progress,
            shouldContinue: shouldContinue, readRows: readRows, writeRows: writeRows)
    }

    /// Applies `outputTransform` in the producing kernel so `writeRows` receives host-encoded
    /// pixels. Unsupported variants clear it to nil. The pointwise transform is identical for
    /// staged and striped paths, preventing memory-dependent output differences.
    @discardableResult
    public func developStreaming(
        width: Int, height: Int,
        stock: FilmStock, options: FotufilmEngine.Options,
        outputTransform: inout FilmOutputTransform?,
        frameIndex: UInt64 = 0,
        memoryBudget: Int? = nil,
        apronScale: Double = 1,
        realtime: Bool = false,
        exactMath: Bool = false,
        /// Develops with nothing in the gate: the creative controls, the delivery basis and the
        /// grade. `stock` is still named because the configuration is built from one, and still
        /// unread — see `FilmEngineFeature.noFilm`.
        noFilm: Bool = false,
        /// Whether `writeRows` may run on an engine-selected thread while the next kernel executes.
        /// Writes remain ordered and serialized. Disabled by default because host callbacks may
        /// require their calling thread; the app's still exporter opts in.
        overlapsWriteback: Bool = false,
        progress: ((FilmRenderPhase) -> Void)? = nil,
        shouldContinue: (() -> Bool)? = nil,
        readRows: (_ rows: Range<Int>, _ into: UnsafeMutableBufferPointer<Float>) -> Void,
        writeRows: (_ rows: Range<Int>, _ from: UnsafeBufferPointer<Float>) -> Void
    ) -> Bool {
        precondition(width > 0 && height > 0)
        // Use staged development when both the default and caller-provided budgets permit it.
        // Staging uses the same schedule without repeated aprons or host-device frame copies.
        // Respecting both budgets lets tests force striped rendering and prevents dispatch to a
        // staged call that will reject the frame.
        let onePassBudget = memoryBudget ?? Self.defaultMemoryBudget()
        if Self.developsInOnePass(width: width, height: height),
           height <= onePassBudget / Self.stripBytesPerRow(width: width),
           let staging = borrowStaging(pixels: width * height) {
            defer { Self.returnStaging(staging) }
            readRows(0..<height, UnsafeMutableBufferPointer(
                start: staging.scenePixels, count: width * height * 4))
            guard developStaged(
                staging, width: width, height: height, stock: stock, options: options,
                outputTransform: &outputTransform, frameIndex: frameIndex,
                realtime: realtime, exactMath: exactMath, measuresGlareOnDevice: false,
                noFilm: noFilm,
                progress: progress, shouldContinue: shouldContinue)
            else { return false }
            writeRows(0..<height, UnsafeBufferPointer(
                start: staging.developedPixels, count: width * height * 4))
            return true
        }
        // Poll between bands and strips so cancellation never interrupts a dispatch. Return false
        // when cancelled.
        let cancelled = { shouldContinue.map { !$0() } ?? false }
        let invocationStart = Date()
        var invocation = FilmEngineInvocation(
            stock: stock, options: options, width: width,
            height: height, frameIndex: frameIndex, noFilm: noFilm)
        if getenv("FOTUFILM_STILL_TIMINGS") != nil {
            print(String(format: "  %-10@ %8.1f ms", "invoke" as NSString,
                         Date().timeIntervalSince(invocationStart) * 1000))
        }
        invocation.featureMask |= FilmEngineFeature.floatIO
        if realtime { invocation.featureMask |= FilmEngineFeature.realtime }
        if exactMath { invocation.featureMask |= FilmEngineFeature.exactMath }
        if let wanted = outputTransform, Self.encodesOutput(invocation.featureMask) {
            let encodeMask = FilmEngineFeature.encodeOut
                | outputTransferFeature(wanted.transfer, realtime: realtime)
            if fotufilm_halide_metal_variant_exists(
                invocation.featureMask | encodeMask) == 1 {
                invocation.featureMask |= encodeMask
                invocation.setOutputTransform(wanted)
            } else {
                outputTransform = nil
            }
        } else {
            outputTransform = nil
        }

        let timings = getenv("FOTUFILM_STILL_TIMINGS") != nil
        let apron = max(1, Int(Double(invocation.spatialSupport) * apronScale))
        let budget = memoryBudget ?? Self.defaultMemoryBudget()
        let fieldsStart = Date()
        let fieldsDeveloped = developStreamingFields(
            invocation: &invocation, width: width, height: height,
            budget: budget, apronScale: apronScale, timings: timings,
            cancelled: cancelled, progress: progress,
            readRows: readRows, writeRows: writeRows)
        if timings, fieldsDeveloped == nil {
            print(String(format: "  %-10@ %8.1f ms (road refused)",
                         "fields" as NSString,
                         Date().timeIntervalSince(fieldsStart) * 1000))
        }
        if let fieldsDeveloped { return fieldsDeveloped }
        let floor = min(height, 2 * apron) * Self.apronBytesPerRow(
            width: width, exactMath: exactMath)
            + min(max(height - 2 * apron, 0), 1) * Self.stripBytesPerRow(width: width)
        guard floor <= budget else {
            if timings {
                print("  striped \(width)x\(height): refused, apron \(apron) "
                      + "needs \(floor >> 20) MB against a \(budget >> 20) MB "
                      + "budget")
            }
            return false
        }
        let rows = Self.stripRows(width: width, height: height, apron: apron,
                                  budget: budget, exactMath: exactMath)
        let strips = (height + rows - 1) / rows
        // The strip loop hands `writeRows` to a work item so it can run beside the next kernel.
        // It is joined before the loop returns — every path out of it, the early ones included —
        // so nothing outlives the call; the escape is only lexical.
        return withoutActuallyEscaping(writeRows) { writeRows in
            developStripped(
                invocation: &invocation, width: width, height: height,
                rows: rows, strips: strips, apron: apron, timings: timings,
                overlapsWriteback: overlapsWriteback,
                cancelled: cancelled, progress: progress,
                readRows: readRows, writeRows: writeRows)
        }
    }

    /// The classic single-pass striped path, once its geometry is settled.
    private func developStripped(
        invocation: inout FilmEngineInvocation,
        width: Int, height: Int, rows: Int, strips: Int, apron: Int,
        timings: Bool, overlapsWriteback: Bool,
        cancelled: () -> Bool,
        progress: ((FilmRenderPhase) -> Void)?,
        readRows: (_ rows: Range<Int>, _ into: UnsafeMutableBufferPointer<Float>) -> Void,
        writeRows: @escaping (_ rows: Range<Int>, _ from: UnsafeBufferPointer<Float>) -> Void
    ) -> Bool {
        let maxStripHeight = min(height, rows + 2 * apron)
        let scratchBytes = width * min(rows, height) * 16
        // Allocate a second scratch outside the geometry budget so overlap does not change strip
        // height or apron boundaries. Require additional available memory before enabling it.
        let wantsOverlap = overlapsWriteback && strips > 1
            && scratchBytes * 4 < Self.availableBytes()
            && getenv("FOTUFILM_EXPORT_SERIAL") == nil
        let buffers = Self.borrowStripBuffers(
            capacity: width * maxStripHeight * 4,
            scratchCapacity: width * min(rows, height) * 4,
            scratchCount: wantsOverlap ? 2 : 1)
        defer { Self.returnStripBuffers(buffers) }
        // The pool may return extra capacity. Enable overlap only when this render requested it.
        let overlapping = wantsOverlap && buffers.scratchCount >= 2
        let input = buffers.input
        let measureStart = Date()
        guard measureWholeFrame(
            &invocation, width: width, height: height, bandRows: maxStripHeight,
            cancelled: cancelled, progress: progress,
            band: { rows in
                readRows(rows, UnsafeMutableBufferPointer(
                    start: input, count: rows.count * width * 4))
                return UnsafePointer(input)
            })
        else { return false }
        let measureSeconds = Date().timeIntervalSince(measureStart)

        var readSeconds = 0.0
        var engineSeconds = 0.0
        var writeSeconds = 0.0
        var writeWaitSeconds = 0.0
        // The host's half of the previous strip, still running. `writeRows` is the caller's
        // encode — on a still, a full pass over the strip in float and out in sixteen-bit — and
        // nothing the kernel does next reads what it is reading, so it rides the next strip's
        // kernel rather than delaying it. The strips are still handed over in order: this is one
        // outstanding write, joined before the buffer it holds is reused.
        let writeQueue = DispatchQueue(label: "fotufilm.strip.write",
                                       qos: .userInitiated)
        var outstandingWrite: DispatchWorkItem?
        func joinWrite() {
            guard let item = outstandingWrite else { return }
            let waitStart = Date()
            item.wait()
            writeWaitSeconds += Date().timeIntervalSince(waitStart)
            outstandingWrite = nil
        }
        defer { joinWrite() }
        for strip in 0..<strips {
            if cancelled() { return false }
            progress?(.developing(index: strip, count: strips))
            let top = strip * rows
            let bottom = min(height, top + rows)
            let from = max(0, top - apron)
            let to = min(height, bottom + apron)
            let stripHeight = to - from
            let scratch = buffers.scratch(at: overlapping ? strip : 0)

            let readStart = Date()
            readRows(from..<to, UnsafeMutableBufferPointer(
                start: input, count: stripHeight * width * 4))
            readSeconds += Date().timeIntervalSince(readStart)
            // Two scratch buffers allow the previous host write to overlap this kernel dispatch.
            // A single scratch must be joined before reuse.
            if !overlapping { joinWrite() }
            let engineStart = Date()
            let ok = invocation.configuration.withUnsafeBufferPointer { configuration in
                invocation.withSpectralPointers { exposure, film, paper in
                    fotufilm_halide_metal_process_linear_float_rows(
                        input, scratch,
                        Int32(width), Int32(stripHeight),
                        Int32(top - from), Int32(bottom - top), 0, Int32(from),
                        configuration.baseAddress, exposure, film, paper,
                        Int32(invocation.spectral.exposure.dimension),
                        invocation.spectralCacheID, invocation.featureMask,
                        invocation.seed) == 0
                }
            }
            engineSeconds += Date().timeIntervalSince(engineStart)
            guard ok else { return false }
            // Complete the previous write before submitting the next to preserve strip order.
            joinWrite()
            let writeStart = Date()
            let item = DispatchWorkItem {
                writeRows(top..<bottom, UnsafeBufferPointer(
                    start: scratch, count: (bottom - top) * width * 4))
            }
            if strip == strips - 1 {
                item.perform()
                writeSeconds += Date().timeIntervalSince(writeStart)
            } else {
                outstandingWrite = item
                writeQueue.async(execute: item)
            }
        }
        joinWrite()
        if timings {
            let developed = height + (strips - 1) * 2 * apron
            print(String(
                format: "  striped %dx%d: %d strip(s) of %d rows, apron %d "
                    + "(%.2fx rows), measure %.1f ms, read %.1f ms, "
                    + "engine %.1f ms, write %.1f ms (last strip), "
                    + "write wait %.1f ms",
                width, height, strips, rows, apron,
                Double(developed) / Double(height),
                measureSeconds * 1000, readSeconds * 1000,
                engineSeconds * 1000, writeSeconds * 1000,
                writeWaitSeconds * 1000))
        }
        return true
    }

    /// Two-pass striped rendering for frames dominated by halation support. The first pass writes
    /// post-MTF light to a file-backed float frame, the full-frame halation pyramid is built
    /// from it, and the second pass applies remaining fine-support stages. Stored field values match
    /// the staged renderer.
    ///
    /// Returns nil when the path is not taken — halation absent or small against the fine apron,
    /// a mask the generated variants cannot serve, or no memory for the light — and the caller
    /// falls through to the classic single-pass striping. `FOTUFILM_FORCE_FIELDS` takes it
    /// whenever it can be taken (the parity tests' seam); `FOTUFILM_NO_FIELDS` never takes it.
    private func developStreamingFields(
        invocation: inout FilmEngineInvocation,
        width: Int, height: Int, budget: Int, apronScale: Double,
        timings: Bool,
        cancelled: () -> Bool,
        progress: ((FilmRenderPhase) -> Void)?,
        readRows: (_ rows: Range<Int>, _ into: UnsafeMutableBufferPointer<Float>) -> Void,
        writeRows: (_ rows: Range<Int>, _ from: UnsafeBufferPointer<Float>) -> Void
    ) -> Bool? {
        guard getenv("FOTUFILM_NO_FIELDS") == nil else { return nil }
        let mask = invocation.featureMask
        guard mask & FilmEngineFeature.halation != 0,
              mask & FilmEngineFeature.exactMath == 0,
              mask & FilmEngineFeature.realtime == 0,
              mask & FilmEngineFeature.encodeOut == 0,
              mask & FilmEngineFeature.flareMeasure == 0 else { return nil }
        let fine = max(1, Int(Double(invocation.spatialSupportSansHalation)
                              * apronScale))
        let forced = getenv("FOTUFILM_FORCE_FIELDS") != nil
        guard invocation.halationSupport > 0 else { return nil }
        // Worth a second sweep only when the classic path's strips have collapsed against their
        // halation-sized apron: the cropped kernel already prices apron rows at the light chain,
        // so moderate redundancy is cheaper developed once than developed as light and again as
        // film. Measured on device at 48 MP (3x redundancy, classic wins by 2 s) and 100 MP
        // (9.4x, fields wins by 5 s); the boundary sits near four rows of apron per row kept.
        let classicApron = max(1, Int(Double(invocation.spatialSupport) * apronScale))
        let classicRows = Self.stripRows(width: width, height: height,
                                         apron: classicApron, budget: budget)
        guard forced || (classicRows < height
                         && 2 * classicApron > 3 * classicRows) else { return nil }
        let lightMask = (mask & (FilmEngineFeature.flare | FilmEngineFeature.mtf
            | FilmEngineFeature.mtfLuma | FilmEngineFeature.monochrome
            | FilmEngineFeature.reversal)) | FilmEngineFeature.floatIO
        guard fotufilm_halide_metal_variant_exists(
                lightMask | FilmEngineFeature.lightOut) == 1,
              fotufilm_halide_metal_variant_exists(
                mask | FilmEngineFeature.floatIO
                    | FilmEngineFeature.fieldsIn) == 1 else { return nil }
        let radii = invocation.halationPixelRadii
        let fieldsFloats = radii.withUnsafeBufferPointer {
            fotufilm_halide_metal_halation_fields_floats(
                Int32(width), Int32(height), $0.baseAddress)
        }
        guard fieldsFloats > 11 else { return nil }

        // Both sweeps' strip shapes, priced by the same model as the classic path: a light strip
        // carries float rows in and out plus the light chain; a develop strip carries
        // the full stack over its delivered rows and the fine apron above and below.
        let lightApron = max(1, invocation.lightSupport)
        let lightBytesPerRow = max(1, width * (32 + Self.apronBytesPerPixel))
        let lightRows = max(1, min(height,
                                   budget / lightBytesPerRow - 2 * lightApron))
        let lightStrips = (height + lightRows - 1) / lightRows
        let maxLightStrip = min(height, lightRows + 2 * lightApron)
        let fineFloor = min(height, 2 * fine) * Self.apronBytesPerRow(width: width)
            + min(max(height - 2 * fine, 0), 1) * Self.stripBytesPerRow(width: width)
        guard fineFloor <= budget else { return nil }
        let rows = Self.stripRows(width: width, height: height, apron: fine,
                                  budget: budget)
        let strips = (height + rows - 1) / rows
        let maxStripHeight = min(height, rows + 2 * fine)

        // The light frame: floats, file-backed above the mapping threshold, flushed as it
        // fills so the pages stay clean.
        let lightRowBytes = width * MemoryLayout<Float>.size * 4
        guard let light = MappedBuffer(byteCount: lightRowBytes * height) else {
            return nil
        }
        let lightPixels = light.bound(to: Float.self)
        guard let lightBase = lightPixels.baseAddress else { return nil }

        let bandRows = max(maxLightStrip, maxStripHeight)
        let buffers = Self.borrowStripBuffers(
            capacity: width * bandRows * 4,
            scratchCapacity: width * min(rows, height) * 4)
        defer { Self.returnStripBuffers(buffers) }
        let input = buffers.input
        let scratch = buffers.scratch

        let measureStart = Date()
        guard measureWholeFrame(
            &invocation, width: width, height: height, bandRows: bandRows,
            cancelled: cancelled, progress: progress,
            band: { rows in
                readRows(rows, UnsafeMutableBufferPointer(
                    start: input, count: rows.count * width * 4))
                return UnsafePointer(input)
            })
        else { return false }
        let measureSeconds = Date().timeIntervalSince(measureStart)

        var readSeconds = 0.0
        var lightSeconds = 0.0
        let totalStrips = lightStrips + strips
        for strip in 0..<lightStrips {
            if cancelled() { return false }
            progress?(.developing(index: strip, count: totalStrips))
            let top = strip * lightRows
            let bottom = min(height, top + lightRows)
            let from = max(0, top - lightApron)
            let to = min(height, bottom + lightApron)
            let readStart = Date()
            readRows(from..<to, UnsafeMutableBufferPointer(
                start: input, count: (to - from) * width * 4))
            readSeconds += Date().timeIntervalSince(readStart)
            let lightStart = Date()
            let ok = invocation.configuration.withUnsafeBufferPointer { configuration in
                invocation.withSpectralPointers { exposure, film, paper in
                    fotufilm_halide_metal_process_light_rows(
                        input, lightBase + top * width * 4,
                        Int32(width), Int32(to - from),
                        Int32(top - from), Int32(bottom - top), 0, Int32(from),
                        configuration.baseAddress, exposure, film, paper,
                        Int32(invocation.spectral.exposure.dimension),
                        invocation.spectralCacheID, lightMask,
                        invocation.seed) == 0
                }
            }
            lightSeconds += Date().timeIntervalSince(lightStart)
            guard ok else { return nil }
            light.flush(byteOffset: top * lightRowBytes,
                        byteCount: (bottom - top) * lightRowBytes)
        }

        if cancelled() { return false }
        let fieldsStart = Date()
        var fields = [Float](repeating: 0, count: Int(fieldsFloats))
        let built = radii.withUnsafeBufferPointer { radii in
            fields.withUnsafeMutableBufferPointer { fields in
                fotufilm_halide_metal_halation_fields(
                    lightBase, Int32(width), Int32(height),
                    radii.baseAddress, fields.baseAddress,
                    fieldsFloats) == 0
            }
        }
        guard built else { return nil }
        let fieldsSeconds = Date().timeIntervalSince(fieldsStart)
        let fieldsID = mach_absolute_time()

        var engineSeconds = 0.0
        var writeSeconds = 0.0
        for strip in 0..<strips {
            if cancelled() { return false }
            progress?(.developing(index: lightStrips + strip, count: totalStrips))
            let top = strip * rows
            let bottom = min(height, top + rows)
            let from = max(0, top - fine)
            let to = min(height, bottom + fine)
            let readStart = Date()
            readRows(from..<to, UnsafeMutableBufferPointer(
                start: input, count: (to - from) * width * 4))
            readSeconds += Date().timeIntervalSince(readStart)
            let engineStart = Date()
            let ok = invocation.configuration.withUnsafeBufferPointer { configuration in
                invocation.withSpectralPointers { exposure, film, paper in
                    fields.withUnsafeBufferPointer { fields in
                        fotufilm_halide_metal_process_linear_float_fields_rows(
                            input, scratch,
                            Int32(width), Int32(to - from),
                            Int32(top - from), Int32(bottom - top),
                            0, Int32(from),
                            configuration.baseAddress,
                            fields.baseAddress, fieldsFloats, fieldsID,
                            exposure, film, paper,
                            Int32(invocation.spectral.exposure.dimension),
                            invocation.spectralCacheID, invocation.featureMask,
                            invocation.seed) == 0
                    }
                }
            }
            engineSeconds += Date().timeIntervalSince(engineStart)
            guard ok else { return false }
            let writeStart = Date()
            writeRows(top..<bottom, UnsafeBufferPointer(
                start: scratch, count: (bottom - top) * width * 4))
            writeSeconds += Date().timeIntervalSince(writeStart)
        }
        if timings {
            print(String(
                format: "  fielded %dx%d: %d light strip(s) of %d rows "
                    + "(apron %d), %d develop strip(s) of %d rows (apron %d), "
                    + "measure %.1f ms, light %.1f ms, fields %.1f ms, "
                    + "read %.1f ms, engine %.1f ms, write %.1f ms",
                width, height, lightStrips, lightRows, lightApron,
                strips, rows, fine,
                measureSeconds * 1000, lightSeconds * 1000,
                fieldsSeconds * 1000, readSeconds * 1000,
                engineSeconds * 1000, writeSeconds * 1000))
        }
        return true
    }

    /// Develops `staging.scenePixels` into `staging.developedPixels` without host-device copies.
    /// `measuresGlareOnDevice` avoids a host measurement pass but can differ from the double-precision
    /// host reduction by about 1.3×10⁻⁵; disable it for staged/striped bit parity.
    /// `outputTransform` performs the final matrix, transfer, and premultiplication in-kernel. It is
    /// cleared to nil when the required kernel variant is unavailable.
    @discardableResult
    public func developStaged(
        _ staging: FilmFrameStaging, width: Int, height: Int,
        stock: FilmStock, options: FotufilmEngine.Options,
        outputTransform: inout FilmOutputTransform?,
        frameIndex: UInt64 = 0,
        realtime: Bool = false,
        exactMath: Bool = false,
        measuresGlareOnDevice: Bool = false,
        noFilm: Bool = false,
        progress: ((FilmRenderPhase) -> Void)? = nil,
        shouldContinue: (() -> Bool)? = nil
    ) -> Bool {
        precondition(width > 0 && height > 0)
        guard staging.capacityPixels >= width * height,
              Self.developsInOnePass(width: width, height: height) else { return false }
        let cancelled = { shouldContinue.map { !$0() } ?? false }
        var invocation = FilmEngineInvocation(
            stock: stock, options: options, width: width,
            height: height, frameIndex: frameIndex, noFilm: noFilm)
        invocation.featureMask |= FilmEngineFeature.floatIO
        if realtime { invocation.featureMask |= FilmEngineFeature.realtime }
        if exactMath { invocation.featureMask |= FilmEngineFeature.exactMath }
        // A staged frame is whole and already on the device, so the kernel can average its own
        // first stage rather than have the host run that stage a second time over every pixel.
        // Asked rather than assumed: the measuring variants are generated for the float schedules,
        // and a build without the one this frame needs still has to be measured here.
        // Only when there is glare to measure: the stage is opt-in, and a frame without it
        // has no mean to average and no variant worth asking for.
        if measuresGlareOnDevice, invocation.featureMask & FilmEngineFeature.flare != 0 {
            var measureMask = invocation.featureMask | FilmEngineFeature.flareMeasure
            if let wanted = outputTransform {
                measureMask |= FilmEngineFeature.encodeOut
                    | outputTransferFeature(wanted.transfer, realtime: realtime)
            }
            if fotufilm_halide_metal_variant_exists(measureMask) == 1 {
                invocation.featureMask |= FilmEngineFeature.flareMeasure
            }
        }
        // Asked for on the same terms as the measurement above, but answered back rather than
        // silently dropped: a build without the encoding variant this frame needs returns
        // light, and the caller has to know that to read the frame correctly.
        if let wanted = outputTransform, Self.encodesOutput(invocation.featureMask) {
            let encodeMask = FilmEngineFeature.encodeOut
                | outputTransferFeature(wanted.transfer, realtime: realtime)
            if fotufilm_halide_metal_variant_exists(
                invocation.featureMask | encodeMask) == 1 {
                invocation.featureMask |= encodeMask
                invocation.setOutputTransform(wanted)
            } else {
                outputTransform = nil
            }
        } else {
            outputTransform = nil
        }

        let scene = staging.scenePixels
        let inputHandle = staging.inputHandle
        guard measureWholeFrame(
            &invocation, width: width, height: height, bandRows: height,
            cancelled: cancelled, progress: progress,
            band: { rows in UnsafePointer(scene + rows.lowerBound * width * 4) },
            // One band, the whole frame, already on the device: the measure kernel reads the
            // buffer develop is about to read. The host pointer above is the fallback for a build
            // or a machine with no Metal to measure on.
            deviceBand: { _ in inputHandle })
        else { return false }
        if cancelled() { return false }
        progress?(.developing(index: 0, count: 1))

        let outputHandle = staging.outputHandle
        return invocation.configuration.withUnsafeBufferPointer { configuration in
            invocation.withSpectralPointers { exposure, film, paper in
                fotufilm_halide_metal_process_buffers_float(
                    inputHandle, outputHandle, Int32(width), Int32(height), 0, 0,
                    configuration.baseAddress, exposure, film, paper,
                    Int32(invocation.spectral.exposure.dimension),
                    invocation.spectralCacheID, invocation.featureMask,
                    invocation.seed) == 0
            }
        }
    }

    /// Decodes host pixels from `staging.developedPixels` into scene-linear
    /// `staging.scenePixels`. The operation order matches the host decode: non-finite repair,
    /// un-premultiplication, transfer, and matrix. Returns nil when Metal or sufficient staging is
    /// unavailable, or when the kernel fails.
    public func decodeStaged(
        _ staging: FilmFrameStaging, width: Int, height: Int,
        transform: FilmInputTransform, realtime: Bool = false
    ) -> FilmDecodeReport? {
        precondition(width > 0 && height > 0)
        guard staging.capacityPixels >= width * height else { return nil }
        return decoded(width: width, rows: height, transform: transform) { report, parameters in
            let decode = realtime ? fotufilm_halide_metal_decode_rows_realtime
                                  : fotufilm_halide_metal_decode_rows
            return decode(
                staging.outputHandle, nil, staging.inputHandle, nil, report,
                Int32(width), Int32(height), parameters)
        }
    }

    /// Applies the staged decode kernel to a band of tightly packed, top-first RGBA rows.
    /// Input and output must not overlap. Pointwise processing and per-row reporting keep results
    /// independent of band size.
    public func decodeRows(
        _ input: UnsafePointer<Float>, into output: UnsafeMutablePointer<Float>,
        width: Int, rows: Int, transform: FilmInputTransform,
        realtime: Bool = false
    ) -> FilmDecodeReport? {
        precondition(width > 0 && rows > 0)
        return decoded(width: width, rows: rows, transform: transform) { report, parameters in
            let decode = realtime ? fotufilm_halide_metal_decode_rows_realtime
                                  : fotufilm_halide_metal_decode_rows
            return decode(
                0, input, 0, output, report, Int32(width), Int32(rows), parameters)
        }
    }

    /// One decode call and the fold of its per-row report, shared so the two spellings above
    /// cannot drift into combining the same rows differently.
    private func decoded(
        width: Int, rows: Int, transform: FilmInputTransform,
        run: (UnsafeMutablePointer<Float>?, UnsafePointer<Float>?) -> Int32
    ) -> FilmDecodeReport? {
        var report = [Float](repeating: 0, count: 2 * rows)
        let ran = transform.parameters.withUnsafeBufferPointer { parameters in
            report.withUnsafeMutableBufferPointer { report in
                run(report.baseAddress, parameters.baseAddress) == 0
            }
        }
        guard ran else { return nil }
        var peak: Float = 0
        var repaired = false
        for row in 0..<rows {
            peak = max(peak, report[2 * row])
            if report[2 * row + 1] != 0 { repaired = true }
        }
        return FilmDecodeReport(peak: peak, repaired: repaired)
    }

    /// Staging for a frame of `pixels`, or nil when the device will not give up the memory. The
    /// caller keeps it between frames: allocating a pair of frame-sized buffers per frame would
    /// return the cost the staged path exists to remove.
    public func makeFrameStaging(pixels: Int) -> FilmFrameStaging? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        return FilmFrameStaging(device: device, pixels: pixels)
    }

    /// Borrows one frame pair from the renderer-wide pool. Each caller owns the returned staging
    /// until it calls `recycleFrameStaging`; concurrent callers therefore receive distinct buffers
    /// while sequential frames avoid allocating and zero-filling hundreds of megabytes each time.
    public func borrowFrameStaging(pixels: Int) -> FilmFrameStaging? {
        borrowStaging(pixels: pixels)
    }

    /// Returns staging obtained from `borrowFrameStaging` after its consumer has finished reading
    /// the developed pixels. The pool retains at most one idle pair; extra concurrent pairs are
    /// released normally.
    public func recycleFrameStaging(_ staging: FilmFrameStaging) {
        Self.returnStaging(staging)
    }

    /// Whether this build has a kernel that can carry an `outputTransform` for this frame — the
    /// same question the two develop calls answer for themselves, asked before the render instead
    /// of after it.
    ///
    /// A streaming render hands its rows to `writeRows` as it develops them, so a caller that
    /// waited for the return value would already have written the frame out under the wrong
    /// reading. The develop calls still nil the transform out when they cannot carry it, so a
    /// caller that skipped this and got it wrong is told; this is how not to have to be told.
    ///
    /// Costs one invocation's setup and touches no pixel. `measuresGlareOnDevice` and `exactMath`
    /// have to be what the render will be given: both change which kernel the frame asks for.
    public func carriesOutputTransform(
        stock: FilmStock, options: FotufilmEngine.Options, width: Int, height: Int,
        frameIndex: UInt64 = 0, realtime: Bool = false, exactMath: Bool = false,
        measuresGlareOnDevice: Bool = false, noFilm: Bool = false
    ) -> Bool {
        var mask = FilmEngineInvocation(
            stock: stock, options: options, width: width, height: height,
            frameIndex: frameIndex, noFilm: noFilm).featureMask
        mask |= FilmEngineFeature.floatIO
        if realtime { mask |= FilmEngineFeature.realtime }
        if exactMath { mask |= FilmEngineFeature.exactMath }
        guard Self.encodesOutput(mask) else { return false }
        let encodeMask = FilmEngineFeature.encodeOut
            | (realtime ? FilmEngineFeature.outputLinear : 0)
        if measuresGlareOnDevice, fotufilm_halide_metal_variant_exists(
            mask | FilmEngineFeature.flareMeasure | encodeMask) == 1 {
            mask |= FilmEngineFeature.flareMeasure
        }
        return fotufilm_halide_metal_variant_exists(mask | encodeMask) == 1
    }

    /// Returns false for density output because host colour transforms apply only to light.
    static func encodesOutput(_ mask: Int32) -> Bool {
        mask & FilmEngineFeature.densityOut == 0
    }

    /// Whether a frame this size develops in a single pass — the condition `developStaged` needs.
    public static func developsInOnePass(width: Int, height: Int) -> Bool {
        width > 0 && height > 0
            && height <= defaultMemoryBudget() / stripBytesPerRow(width: width)
    }

    /// The whole-frame measurements a scene-referred render makes before its first strip: the
    /// regional tone base, then the exact veiling-glare mean. Both walk the frame in bands of at
    /// most `bandRows` rows, each lent by `band` — a streaming render fills a strip buffer and
    /// returns its base, a staged render returns a window onto the frame it already holds
    /// and pays nothing. Shared so the two paths cannot drift into measuring different numbers.
    /// Returns false only when the caller cancelled.
    private func measureWholeFrame(
        _ invocation: inout FilmEngineInvocation,
        width: Int, height: Int, bandRows: Int,
        cancelled: () -> Bool,
        progress: ((FilmRenderPhase) -> Void)?,
        band: (Range<Int>) -> UnsafePointer<Float>,
        deviceBand: ((Range<Int>) -> UInt64)? = nil
    ) -> Bool {
        // Which side of the boundary a band is handed across. A staged render's frame is already
        // in a device buffer and is lent whole; a striped render fills host rows and lets the
        // measure kernel take them across. Same kernel, so the two agree; and where there is no
        // device at all the walk below is the host's own.
        func measured(_ rows: Range<Int>, _ run: (UInt64, UnsafePointer<Float>?) -> Int32) -> Bool {
            if let deviceBand { return run(deviceBand(rows), nil) == 0 }
            return run(0, band(rows)) == 0
        }

        if invocation.localToneActive {
            var measurement = invocation.toneBaseMeasurement()
            let gridWidth = measurement.gridWidth
            var cellSums = [Float](repeating: 0, count: bandRows * gridWidth)
            var row = 0
            while row < height {
                if cancelled() { return false }
                let upper = min(height, row + bandRows)
                let onDevice = cellSums.withUnsafeMutableBufferPointer { out in
                    measured(row..<upper) { handle, host in
                        invocation.configuration.withUnsafeBufferPointer { configuration in
                            fotufilm_halide_metal_measure_tone_rows(
                                handle, host, out.baseAddress,
                                Int32(gridWidth), Int32(width),
                                Int32(upper - row), configuration.baseAddress)
                        }
                    }
                }
                if onDevice {
                    cellSums.withUnsafeBufferPointer {
                        measurement.add(cellRowSums: $0.baseAddress!, rows: row..<upper)
                    }
                } else {
                    measurement.add(linearRGBA: band(row..<upper), rows: row..<upper)
                }
                row = upper
            }
            invocation.setToneBase(measurement)
        }

        // Nothing to do when the kernel is going to measure the frame itself, and it must not be
        // done anyway: the mean written here would be the one the kernel then overwrites, so the
        // work would be invisible as well as wasted.
        guard invocation.featureMask & FilmEngineFeature.flareMeasure == 0 else { return true }
        guard invocation.featureMask & FilmEngineFeature.flare != 0 else { return true }
        progress?(.measuringGlare)
        // The kernel's row sums are float32 and three to a row; the host's are double. They land
        // in the same array because what follows — totalling the rows in double, then dividing by
        // the pixel count — is the same walk either way, and it is the walk that has to be the
        // same for a banded frame to measure like a whole one.
        var rowSums = [SIMD3<Double>](repeating: .zero, count: height)
        var kernelRows = [Float](repeating: 0, count: bandRows * 3)
        var stopped = false
        rowSums.withUnsafeMutableBufferPointer { sums in
            var row = 0
            while row < height {
                if cancelled() { stopped = true; return }
                let upper = min(height, row + bandRows)
                let onDevice = kernelRows.withUnsafeMutableBufferPointer { out in
                    measured(row..<upper) { handle, host in
                        invocation.configuration.withUnsafeBufferPointer { configuration in
                            invocation.withSpectralPointers { exposure, film, paper in
                                fotufilm_halide_metal_measure_flare_rows(
                                    handle, host, out.baseAddress,
                                    Int32(width), Int32(upper - row), Int32(row),
                                    configuration.baseAddress, exposure, film, paper,
                                    Int32(invocation.spectral.exposure.dimension),
                                    invocation.spectralCacheID,
                                    invocation.featureMask)
                            }
                        }
                    }
                }
                if onDevice {
                    for local in 0..<(upper - row) {
                        sums[row + local] = SIMD3(
                            Double(kernelRows[local * 3]),
                            Double(kernelRows[local * 3 + 1]),
                            Double(kernelRows[local * 3 + 2]))
                    }
                } else {
                    let into = UnsafeMutableBufferPointer(
                        start: sums.baseAddress! + row, count: upper - row)
                    invocation.flareExposureRowSums(
                        linearRGBA: band(row..<upper), width: width,
                        rows: upper - row, startingAt: row, into: into)
                }
                row = upper
            }
        }
        if stopped { return false }
        var total = SIMD3<Double>.zero
        for row in rowSums { total += row }
        let mean = total / Double(width * height)
        invocation.flareMean = SIMD3(Float(mean.x), Float(mean.y), Float(mean.z))
        return true
    }

    /// Takes the idle pair when it is large enough and allocates otherwise, so two renders in
    /// flight at once each get their own and never share.
    private static func borrowStripBuffers(capacity: Int,
                                           scratchCapacity: Int,
                                           scratchCount: Int = 1) -> StripBuffers {
        stripBufferLock.lock()
        if let idle = idleStripBuffers, idle.capacity >= capacity,
           idle.scratchCapacity >= scratchCapacity,
           idle.scratchCount >= scratchCount {
            idleStripBuffers = nil
            stripBufferLock.unlock()
            return idle
        }
        stripBufferLock.unlock()
        return StripBuffers(capacity: capacity, scratchCapacity: scratchCapacity,
                            scratchCount: scratchCount)
    }

    private static func returnStripBuffers(_ buffers: StripBuffers) {
        stripBufferLock.lock()
        if (idleStripBuffers?.capacity ?? 0) <= buffers.capacity {
            idleStripBuffers = buffers
        }
        stripBufferLock.unlock()
    }

    private static let stripBufferLock = NSLock()
    nonisolated(unsafe) private static var idleStripBuffers: StripBuffers?

    /// Borrows a per-render staging pair. A 33 MP staged frame uses about 1 GB, so pooling avoids
    /// repeated allocation without sharing buffers between concurrent renders.
    private func borrowStaging(pixels: Int) -> FilmFrameStaging? {
        _ = Self.stagingPressure
        Self.stagingLock.lock()
        if let idle = Self.idleStaging, idle.capacityPixels >= pixels {
            Self.idleStaging = nil
            Self.stagingLock.unlock()
            return idle
        }
        Self.stagingLock.unlock()
        return makeFrameStaging(pixels: pixels)
    }

    /// Retains the largest staging allocation. Reusing a 33 MP pair measured 157 ms per render
    /// versus 485 ms with repeated allocation. `stagingPressure` releases retained memory when needed.
    private static func returnStaging(_ staging: FilmFrameStaging) {
        stagingLock.lock()
        if (idleStaging?.capacityPixels ?? 0) <= staging.capacityPixels {
            idleStaging = staging
        }
        stagingLock.unlock()
    }

    /// Releases only idle staging storage on memory pressure; in-flight buffers remain owned by
    /// their render.
    private static let stagingPressure: DispatchSourceMemoryPressure = {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler {
            stagingLock.lock()
            idleStaging = nil
            stagingLock.unlock()
        }
        source.resume()
        return source
    }()

    private static let stagingLock = NSLock()
    nonisolated(unsafe) private static var idleStaging: FilmFrameStaging?

    /// Allocating form of `processLinearFloat(_:into:...)`.
    public func processLinearFloat(
        _ pixels: [Float], width: Int, height: Int,
        stock: FilmStock, options: FotufilmEngine.Options,
        frameIndex: UInt64 = 0,
        memoryBudget: Int? = nil,
        apronScale: Double = 1,
        progress: ((FilmRenderPhase) -> Void)? = nil
    ) -> [Float]? {
        var output = [Float](repeating: 0, count: width * height * 4)
        return processLinearFloat(
            pixels, into: &output, width: width, height: height, stock: stock,
            options: options, frameIndex: frameIndex, memoryBudget: memoryBudget,
            apronScale: apronScale, progress: progress) ? output : nil
    }

    /// Peak footprint per pixel of frame area, measured across the whole
    /// pipeline at several resolutions.
    public static let developBytesPerPixel = 96

    /// What one row of a strip costs while that strip is in flight: the strip's input and its
    /// result in float, plus the schedule's own working set.
    static func stripBytesPerRow(width: Int) -> Int {
        max(1, width * (16 * 2 + developBytesPerPixel))
    }

    /// What one *apron* row costs. The cropped kernel walks an apron row through the stages a
    /// delivered pixel reads it from — the light chain feeding halation's reach — not the whole
    /// pipeline. Float scene paths retain full precision in that chain, so price an apron row as
    /// a delivered row rather than relying on the former half-store discount.
    static func apronBytesPerRow(width: Int,
                                 exactMath: Bool = false) -> Int {
        stripBytesPerRow(width: width)
    }

    /// Conservative per-pixel working allowance for the two-pass light sweep, excluding its
    /// 16-byte input and 16-byte output rows. The single-pass apron uses the full row estimate.
    static let apronBytesPerPixel = 28

    static func stripRows(width: Int, height: Int, apron: Int, budget: Int,
                          exactMath: Bool = false) -> Int {
        if height <= budget / stripBytesPerRow(width: width) { return height }
        let apronCost = 2 * apron * apronBytesPerRow(
            width: width, exactMath: exactMath)
        let affordable = (budget - apronCost) / stripBytesPerRow(width: width)
        return max(1, min(height, affordable))
    }

    /// Smallest peak an end-to-end export of this frame can be made to run in.
    public static func minimumPeakBytes(width: Int, height: Int,
                                        stock: FilmStock,
                                        options: FotufilmEngine.Options,
                                        exactMath: Bool = false) -> Int {
        let invocation = FilmEngineInvocation(
            stock: stock, options: options, width: width, height: height)
        let apron = invocation.spatialSupport
        let pixels = width * height
        let frames = MappedBuffer.residentBytes(pixels * 16)
            + MappedBuffer.residentBytes(pixels * 8)
        let apronRows = min(height, 2 * apron)
        let strip = min(height - apronRows, 1) * stripBytesPerRow(width: width)
            + apronRows * apronBytesPerRow(width: width, exactMath: exactMath)
        return frames + strip
    }

    /// Bytes this process may still allocate before the system kills it.
    public static func availableBytes() -> Int {
        #if os(iOS)
        let available = Int(os_proc_available_memory())
        return available > 0 ? available : 512 << 20
        #else
        return 8 << 30
        #endif
    }

    /// Whether a frame this large can be developed and encoded with enough
    /// headroom left for the rest of the app.
    public static func canRender(width: Int, height: Int, stock: FilmStock,
                                 options: FotufilmEngine.Options,
                                 budget: Int? = nil,
                                 exactMath: Bool = false) -> Bool {
        let ceiling = budget ?? min(availableBytes() * 3 / 5,
                                    defaultMemoryBudget())
        return minimumPeakBytes(width: width, height: height, stock: stock,
                                options: options,
                                exactMath: exactMath) <= ceiling
    }

    /// What the schedule's own intermediates may use.
    ///
    /// `FOTUFILM_STRIP_BUDGET` overrides it in bytes. That is a test seam rather than a control:
    /// striping only happens on frames too large to check by hand, so the OFX harness lowers the
    /// budget instead, and holds the striped fallback to the staged path's pixels on a frame small
    /// enough to compare.
    static func defaultMemoryBudget() -> Int {
        if let raw = getenv("FOTUFILM_STRIP_BUDGET"),
           let override = Int(String(cString: raw)), override > 0 {
            return override
        }
        #if os(iOS)
        // Half of what the process may still allocate, rounded *down to a power of two*. The
        // strip working set *is* the budget, so giving it half leaves the other half for the
        // decode's bands, the print encode, and slack under pressure — and the peak this admits
        // was walked on a device at 100 MP without a jetsam. The quarter this replaces stranded
        // large frames: an apron's rows alone outgrew it, and the export refused before the
        // first strip.
        //
        // Strip boundaries can affect finite-apron results. Quantize the memory budget to a power
        // of two so ordinary available-memory jitter does not change strip count between exports.
        // Genuine memory pressure can still select a lower budget.
        let half = max(128 << 20, availableBytes() / 2)
        return 1 << (Int.bitWidth - 1 - half.leadingZeroBitCount)
        #else
        // A quarter of the machine, between 2 and 8 GiB. The fixed 2 GiB this replaced decided
        // that no stills frame above about 16 MP developed in one pass, which on a machine with
        // the memory to hold one cost twice the time: a striped 33 MP frame develops half as many
        // rows again as it has, and copies itself onto the device and back once per strip. The
        // floor keeps the smallest Macs on exactly the behaviour they had.
        let quarter = Int(ProcessInfo.processInfo.physicalMemory / 4)
        return min(8 << 30, max(2 << 30, quarter))
        #endif
    }

    /// Where a frame's develop went, split at the boundary that matters for scheduling: the
    /// whole-frame measurements are a host pass over the input, the kernel is the device's.
    /// `FOTUFILM_VIDEO_TIMINGS=1` turns it on; otherwise every entry point returns on a `let`.
    public enum FrameClock {
        public static let isEnabled =
            ProcessInfo.processInfo.environment["FOTUFILM_VIDEO_TIMINGS"] == "1"
        nonisolated(unsafe) private static var measureSeconds = 0.0
        nonisolated(unsafe) private static var kernelSeconds = 0.0
        private static let lock = NSLock()
        static func charge(measure: Double, kernel: Double) {
            guard isEnabled else { return }
            lock.lock()
            measureSeconds += measure
            kernelSeconds += kernel
            lock.unlock()
        }
        /// Seconds spent measuring and in the kernel since the last `take()`, and zeroes them.
        public static func take() -> (measure: Double, kernel: Double) {
            lock.lock(); defer { lock.unlock() }
            let taken = (measureSeconds, kernelSeconds)
            measureSeconds = 0
            kernelSeconds = 0
            return taken
        }
    }

    @discardableResult
    public func processRGBA8(
        input: MTLBuffer, output: MTLBuffer,
        width: Int, height: Int,
        stock: FilmStock, options: FotufilmEngine.Options,
        frameIndex: UInt64 = 0
    ) -> Bool {
        let byteCount = width * height * 4
        precondition(width > 0 && height > 0)
        precondition(input.length >= byteCount && output.length >= byteCount)
        let measureStart = FrameClock.isEnabled ? Date() : Date.distantPast
        guard let context = makeRGBA8FrameContext(
            input: input, width: width, height: height,
            stock: stock, options: options, frameIndex: frameIndex)
        else { return false }
        let measured = FrameClock.isEnabled
            ? Date().timeIntervalSince(measureStart) : 0
        defer { FrameClock.charge(measure: measured, kernel: 0) }
        let kernelStart = FrameClock.isEnabled ? Date() : Date.distantPast
        defer {
            FrameClock.charge(
                measure: 0,
                kernel: FrameClock.isEnabled
                    ? Date().timeIntervalSince(kernelStart) : 0)
        }
        let invocation = context.invocation
        let inputHandle = UInt64(UInt(bitPattern:
            Unmanaged.passUnretained(input as AnyObject).toOpaque()))
        let outputHandle = UInt64(UInt(bitPattern:
            Unmanaged.passUnretained(output as AnyObject).toOpaque()))
        return invocation.configuration.withUnsafeBufferPointer { configuration in
            invocation.withSpectralPointers { exposure, film, paper in
                fotufilm_halide_metal_process_buffers(
                    inputHandle, outputHandle, Int32(width), Int32(height),
                    0, 0,
                    configuration.baseAddress, exposure, film, paper,
                    Int32(invocation.spectral.exposure.dimension),
                    invocation.spectralCacheID, invocation.featureMask,
                    invocation.seed) == 0
            }
        }
    }

    @discardableResult
    public func processRGBA8Region(
        input: MTLBuffer, output: MTLBuffer,
        regionWidth: Int, regionHeight: Int,
        originX: Int, originY: Int,
        frameWidth: Int, frameHeight: Int,
        stock: FilmStock, options: FotufilmEngine.Options,
        frameIndex: UInt64 = 0
    ) -> Bool {
        let byteCount = regionWidth * regionHeight * 4
        precondition(regionWidth > 0 && regionHeight > 0)
        precondition(frameWidth >= regionWidth && frameHeight >= regionHeight)
        precondition(originX >= 0 && originY >= 0)
        precondition(originX + regionWidth <= frameWidth)
        precondition(originY + regionHeight <= frameHeight)
        precondition(input.length >= byteCount && output.length >= byteCount)
        let invocation = FilmEngineInvocation(
            stock: stock, options: options, width: frameWidth,
            height: frameHeight, frameIndex: frameIndex)
        guard !invocation.localToneActive,
              invocation.featureMask & FilmEngineFeature.flare == 0 else { return false }
        let inputHandle = UInt64(UInt(bitPattern:
            Unmanaged.passUnretained(input as AnyObject).toOpaque()))
        let outputHandle = UInt64(UInt(bitPattern:
            Unmanaged.passUnretained(output as AnyObject).toOpaque()))
        return invocation.configuration.withUnsafeBufferPointer { configuration in
            invocation.withSpectralPointers { exposure, film, paper in
                fotufilm_halide_metal_process_buffers(
                    inputHandle, outputHandle,
                    Int32(regionWidth), Int32(regionHeight),
                    Int32(originX), Int32(originY),
                    configuration.baseAddress, exposure, film, paper,
                    Int32(invocation.spectral.exposure.dimension),
                    invocation.spectralCacheID, invocation.featureMask,
                    invocation.seed) == 0
            }
        }
    }

    /// Renders a crop using tone and glare measurements made from its complete source frame.
    @discardableResult
    public func processRGBA8Region(
        input: MTLBuffer, output: MTLBuffer,
        regionWidth: Int, regionHeight: Int,
        originX: Int, originY: Int,
        context: FilmFrameContext
    ) -> Bool {
        let byteCount = regionWidth * regionHeight * 4
        precondition(regionWidth > 0 && regionHeight > 0)
        precondition(context.encoding == .encodedDisplayP3)
        precondition(context.width >= regionWidth && context.height >= regionHeight)
        precondition(originX >= 0 && originY >= 0)
        precondition(originX + regionWidth <= context.width)
        precondition(originY + regionHeight <= context.height)
        precondition(input.length >= byteCount && output.length >= byteCount)
        let invocation = context.invocation
        let inputHandle = UInt64(UInt(bitPattern:
            Unmanaged.passUnretained(input as AnyObject).toOpaque()))
        let outputHandle = UInt64(UInt(bitPattern:
            Unmanaged.passUnretained(output as AnyObject).toOpaque()))
        return invocation.configuration.withUnsafeBufferPointer { configuration in
            invocation.withSpectralPointers { exposure, film, paper in
                fotufilm_halide_metal_process_buffers(
                    inputHandle, outputHandle,
                    Int32(regionWidth), Int32(regionHeight),
                    Int32(originX), Int32(originY),
                    configuration.baseAddress, exposure, film, paper,
                    Int32(invocation.spectral.exposure.dimension),
                    invocation.spectralCacheID, invocation.featureMask,
                    invocation.seed) == 0
            }
        }
    }

    @discardableResult
    public func processRGBA8Head(
        input: MTLBuffer, density: MTLBuffer,
        width: Int, height: Int,
        stock: FilmStock, options: FotufilmEngine.Options,
        frameIndex: UInt64 = 0
    ) -> Bool {
        precondition(width > 0 && height > 0)
        precondition(input.length >= width * height * 4)
        precondition(density.length >= width * height * 8)
        guard let context = makeRGBA8FrameContext(
            input: input, width: width, height: height,
            stock: stock, options: options, frameIndex: frameIndex)
        else { return false }
        let invocation = context.invocation
        let inputHandle = UInt64(UInt(bitPattern:
            Unmanaged.passUnretained(input as AnyObject).toOpaque()))
        let densityHandle = UInt64(UInt(bitPattern:
            Unmanaged.passUnretained(density as AnyObject).toOpaque()))
        return invocation.configuration.withUnsafeBufferPointer { configuration in
            invocation.withSpectralPointers { exposure, film, paper in
                fotufilm_halide_metal_process_buffers_head(
                    inputHandle, densityHandle, Int32(width), Int32(height),
                    0, 0,
                    configuration.baseAddress, exposure, film, paper,
                    Int32(invocation.spectral.exposure.dimension),
                    invocation.spectralCacheID, invocation.featureMask,
                    invocation.seed) == 0
            }
        }
    }

    @discardableResult
    public func processRGBA8Tail(
        density: MTLBuffer, output: MTLBuffer,
        width: Int, height: Int,
        densityWidth: Int = 0, densityHeight: Int = 0,
        stock: FilmStock, options: FotufilmEngine.Options,
        frameIndex: UInt64 = 0
    ) -> Bool {
        let inWidth = densityWidth > 0 ? densityWidth : width
        let inHeight = densityHeight > 0 ? densityHeight : height
        precondition(width > 0 && height > 0)
        precondition(density.length >= inWidth * inHeight * 8)
        precondition(output.length >= width * height * 4)
        let invocation = FilmEngineInvocation(
            stock: stock, options: options, width: width,
            height: height, frameIndex: frameIndex)
        let densityHandle = UInt64(UInt(bitPattern:
            Unmanaged.passUnretained(density as AnyObject).toOpaque()))
        let outputHandle = UInt64(UInt(bitPattern:
            Unmanaged.passUnretained(output as AnyObject).toOpaque()))
        return invocation.configuration.withUnsafeBufferPointer { configuration in
            invocation.withSpectralPointers { exposure, film, paper in
                fotufilm_halide_metal_process_buffers_tail(
                    densityHandle, outputHandle, Int32(width), Int32(height),
                    Int32(inWidth), Int32(inHeight),
                    0, 0,
                    configuration.baseAddress, exposure, film, paper,
                    Int32(invocation.spectral.exposure.dimension),
                    invocation.spectralCacheID, invocation.featureMask,
                    invocation.seed) == 0
            }
        }
    }

    @discardableResult
    public func processLinearFloat(
        input: MTLBuffer, output: MTLBuffer,
        width: Int, height: Int,
        stock: FilmStock, options: FotufilmEngine.Options,
        frameIndex: UInt64 = 0,
        realtime: Bool = false
    ) -> Bool {
        let byteCount = width * height * 16
        precondition(width > 0 && height > 0)
        precondition(input.length >= byteCount && output.length >= byteCount)
        guard let context = makeLinearFloatFrameContext(
            input: input, width: width, height: height,
            stock: stock, options: options, frameIndex: frameIndex,
            realtime: realtime)
        else { return false }
        let invocation = context.invocation
        let inputHandle = UInt64(UInt(bitPattern:
            Unmanaged.passUnretained(input as AnyObject).toOpaque()))
        let outputHandle = UInt64(UInt(bitPattern:
            Unmanaged.passUnretained(output as AnyObject).toOpaque()))
        return invocation.configuration.withUnsafeBufferPointer { configuration in
            invocation.withSpectralPointers { exposure, film, paper in
                fotufilm_halide_metal_process_buffers_float(
                    inputHandle, outputHandle, Int32(width), Int32(height),
                    0, 0,
                    configuration.baseAddress, exposure, film, paper,
                    Int32(invocation.spectral.exposure.dimension),
                    invocation.spectralCacheID, invocation.featureMask,
                    invocation.seed) == 0
            }
        }
    }

    @discardableResult
    public func processLinearFloatRegion(
        input: MTLBuffer, output: MTLBuffer,
        regionWidth: Int, regionHeight: Int,
        originX: Int, originY: Int,
        frameWidth: Int, frameHeight: Int,
        stock: FilmStock, options: FotufilmEngine.Options,
        frameIndex: UInt64 = 0,
        realtime: Bool = false
    ) -> Bool {
        let byteCount = regionWidth * regionHeight * 16
        precondition(regionWidth > 0 && regionHeight > 0)
        precondition(input.length >= byteCount && output.length >= byteCount)
        var invocation = FilmEngineInvocation(
            stock: stock, options: options, width: frameWidth,
            height: frameHeight, frameIndex: frameIndex)
        if realtime { invocation.featureMask |= FilmEngineFeature.realtime }
        guard !invocation.localToneActive,
              invocation.featureMask & FilmEngineFeature.flare == 0 else { return false }
        let inputHandle = UInt64(UInt(bitPattern:
            Unmanaged.passUnretained(input as AnyObject).toOpaque()))
        let outputHandle = UInt64(UInt(bitPattern:
            Unmanaged.passUnretained(output as AnyObject).toOpaque()))
        return invocation.configuration.withUnsafeBufferPointer { configuration in
            invocation.withSpectralPointers { exposure, film, paper in
                fotufilm_halide_metal_process_buffers_float(
                    inputHandle, outputHandle,
                    Int32(regionWidth), Int32(regionHeight),
                    Int32(originX), Int32(originY),
                    configuration.baseAddress, exposure, film, paper,
                    Int32(invocation.spectral.exposure.dimension),
                    invocation.spectralCacheID, invocation.featureMask,
                    invocation.seed) == 0
            }
        }
    }

    /// Renders a scene-referred crop using measurements made from its complete source frame.
    @discardableResult
    public func processLinearFloatRegion(
        input: MTLBuffer, output: MTLBuffer,
        regionWidth: Int, regionHeight: Int,
        originX: Int, originY: Int,
        context: FilmFrameContext
    ) -> Bool {
        let byteCount = regionWidth * regionHeight * 16
        precondition(regionWidth > 0 && regionHeight > 0)
        precondition(context.encoding == .linearRec2020)
        precondition(context.width >= regionWidth && context.height >= regionHeight)
        precondition(originX >= 0 && originY >= 0)
        precondition(originX + regionWidth <= context.width)
        precondition(originY + regionHeight <= context.height)
        precondition(input.length >= byteCount && output.length >= byteCount)
        let invocation = context.invocation
        let inputHandle = UInt64(UInt(bitPattern:
            Unmanaged.passUnretained(input as AnyObject).toOpaque()))
        let outputHandle = UInt64(UInt(bitPattern:
            Unmanaged.passUnretained(output as AnyObject).toOpaque()))
        return invocation.configuration.withUnsafeBufferPointer { configuration in
            invocation.withSpectralPointers { exposure, film, paper in
                fotufilm_halide_metal_process_buffers_float(
                    inputHandle, outputHandle,
                    Int32(regionWidth), Int32(regionHeight),
                    Int32(originX), Int32(originY),
                    configuration.baseAddress, exposure, film, paper,
                    Int32(invocation.spectral.exposure.dimension),
                    invocation.spectralCacheID, invocation.featureMask,
                    invocation.seed) == 0
            }
        }
    }

    private static func convertSRGBToEncodedDisplayP3(
        _ input: [UInt8], into output: inout [UInt8]
    ) {
        precondition(input.count == output.count && input.count.isMultiple(of: 4))
        let decode = byteDecodeTable
        for offset in stride(from: 0, to: input.count, by: 4) {
            let alpha = input[offset + 3]
            let denominator = alpha > 0 && alpha < 255 ? Float(alpha) : 255
            let srgb = SIMD3<Float>(
                alpha == 0 || alpha == 255
                    ? decode[Int(input[offset])]
                    : ColorScience.srgbToLinear(min(Float(input[offset]) / denominator, 1)),
                alpha == 0 || alpha == 255
                    ? decode[Int(input[offset + 1])]
                    : ColorScience.srgbToLinear(min(Float(input[offset + 1]) / denominator, 1)),
                alpha == 0 || alpha == 255
                    ? decode[Int(input[offset + 2])]
                    : ColorScience.srgbToLinear(min(Float(input[offset + 2]) / denominator, 1)))
            let displayP3 = ColorScience.linearSRGBToDisplayP3(srgb)
            let scale = alpha > 0 && alpha < 255 ? Float(alpha) : 255
            for channel in 0..<3 {
                let encoded = encodeTransfer(displayP3[channel])
                output[offset + channel] = UInt8(
                    min(max((encoded * scale).rounded(), 0), 255))
            }
            output[offset + 3] = alpha
        }
    }

    private static func convertEncodedDisplayP3ToSRGB(
        _ input: [UInt8], into output: inout [UInt8]
    ) {
        precondition(input.count == output.count && input.count.isMultiple(of: 4))
        let decode = byteDecodeTable
        for offset in stride(from: 0, to: input.count, by: 4) {
            let displayP3 = SIMD3<Float>(
                decode[Int(input[offset])], decode[Int(input[offset + 1])],
                decode[Int(input[offset + 2])])
            let srgb = ColorScience.linearDisplayP3ToSRGB(displayP3)
            for channel in 0..<3 {
                let encoded = encodeTransfer(srgb[channel])
                output[offset + channel] = UInt8(
                    min(max((encoded * 255).rounded(), 0), 255))
            }
            output[offset + 3] = input[offset + 3]
        }
    }

    private static let byteDecodeTable: [Float] = (0..<256).map {
        ColorScience.srgbToLinear(Float($0) / 255)
    }

    private static let encodeTable: [Float] = (0...4096).map {
        ColorScience.linearToSrgb(Float($0) / 4096)
    }

    private static func encodeTransfer(_ linear: Float) -> Float {
        let scaled = min(max(linear, 0), 1) * 4096
        let lower = min(Int(scaled), 4095)
        let fraction = scaled - Float(lower)
        return encodeTable[lower] + fraction * (encodeTable[lower + 1] - encodeTable[lower])
    }

}
#endif
