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

/// The buffers one tiled render works in: the tile's input, and the schedule's results. Shared
/// MTLBuffers, so the host writes the tile where the kernel reads it and reads the result where
/// the kernel wrote it, and nothing is copied across the bus — a copy each way was a third of a
/// strip's bytes. Borrowed for the length of a render and returned, because sizing them per
/// call meant allocating and zero-filling hundreds of megabytes on every frame.
///
/// The input spans the tile and its apron on every side; a result holds only the delivered
/// pixels — the cropped kernel never writes an apron pixel, so allocating for one would buy
/// nothing. Two results in flight: the kernel writes one tile while the host is still encoding
/// the last one out of the other. A single result made the two stages take turns, and on a
/// still the encode is a third of the time the kernel takes.
private final class TileStaging {
    let input: MTLBuffer
    private let outputs: [MTLBuffer]
    let inputPixels: Int
    let outputPixels: Int

    var outputCount: Int { outputs.count }

    init?(device: MTLDevice, inputPixels: Int, outputPixels: Int, outputCount: Int) {
        guard inputPixels > 0, outputPixels > 0,
              let input = device.makeBuffer(length: inputPixels * 16,
                                            options: .storageModeShared)
        else { return nil }
        var outputs: [MTLBuffer] = []
        for _ in 0..<max(1, outputCount) {
            guard let output = device.makeBuffer(length: outputPixels * 16,
                                                 options: .storageModeShared)
            else { return nil }
            outputs.append(output)
        }
        self.input = input
        self.outputs = outputs
        self.inputPixels = inputPixels
        self.outputPixels = outputPixels
    }

    var inputPointer: UnsafeMutablePointer<Float> {
        input.contents().assumingMemoryBound(to: Float.self)
    }

    var inputHandle: UInt64 {
        UInt64(UInt(bitPattern: Unmanaged.passUnretained(input as AnyObject).toOpaque()))
    }

    func output(at index: Int) -> MTLBuffer { outputs[index % outputs.count] }

    func outputPointer(at index: Int) -> UnsafeMutablePointer<Float> {
        output(at: index).contents().assumingMemoryBound(to: Float.self)
    }

    func outputHandle(at index: Int) -> UInt64 {
        UInt64(UInt(bitPattern: Unmanaged.passUnretained(output(at: index) as AnyObject).toOpaque()))
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
    fileprivate var layered: (stock: FilmStock, options: FotufilmEngine.Options, frameIndex: UInt64, pitch: Double)? = nil
    fileprivate var layeredResult: Data? = nil

    fileprivate func copyLayeredRegion(to output: MTLBuffer, width regionWidth: Int,
                                       height regionHeight: Int, x: Int, y: Int) -> Bool? {
        guard let result = layeredResult else { return nil }
        guard output.storageMode == .shared else { return false }
        let pixelBytes = encoding == .linearRec2020 ? 16 : 4
        result.withUnsafeBytes { source in
            for row in 0..<regionHeight {
                output.contents().advanced(by: row * regionWidth * pixelBytes).copyMemory(
                    from: source.baseAddress!.advanced(by: ((row + y) * width + x) * pixelBytes),
                    byteCount: regionWidth * pixelBytes)
            }
        }
        return true
    }
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
        guard var invocation = try? FilmEngineInvocation(
            validating: stock, options: options, width: width,
            height: height, frameIndex: frameIndex)
        else { return nil }
        if invocation.sceneMeteringActive
            || invocation.featureMask & FilmEngineFeature.flare != 0 {
            guard input.storageMode == .shared else { return nil }
            let pixels = input.contents().assumingMemoryBound(to: UInt8.self)
            if invocation.sceneMeteringActive {
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
        var context = FilmFrameContext(invocation: invocation, width: width, height: height,
                                       encoding: .encodedDisplayP3)
        if options.transportConstruction(for: stock) != nil {
            guard input.storageMode == .shared,
                  let result = layeredEncoded(Array(UnsafeBufferPointer(
                    start: input.contents().assumingMemoryBound(to: UInt8.self), count: byteCount)),
                    width: width, height: height, stock: stock, options: options,
                    frameIndex: frameIndex, srgb: false) else { return nil }
            context.layeredResult = Data(result)
        }
        return context
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
        guard var invocation = try? FilmEngineInvocation(
            validating: stock, options: options, width: width,
            height: height, frameIndex: frameIndex)
        else { return nil }
        if realtime { invocation.featureMask |= FilmEngineFeature.realtime }
        if invocation.sceneMeteringActive
            || invocation.featureMask & FilmEngineFeature.flare != 0 {
            guard input.storageMode == .shared else { return nil }
            let pixels = input.contents().assumingMemoryBound(to: Float.self)
            if invocation.sceneMeteringActive {
                // The frame is already on the device, so the measure kernel reads it there —
                // the same kernel, and so the same base, a still's tiles and strips meter with.
                // The host walk stays as the fallback for a build with no kernel to run.
                var walk = ToneBaseWalk(invocation, bandRows: height)
                walk.add(invocation, rows: 0..<height, bufferRow: 0, width: width,
                         handle: UInt64(UInt(bitPattern:
                            Unmanaged.passUnretained(input as AnyObject).toOpaque())),
                         host: UnsafePointer(pixels))
                invocation.setToneBase(walk.measurement)
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
        var context = FilmFrameContext(invocation: invocation, width: width, height: height,
                                       encoding: .linearRec2020)
        if options.transportConstruction(for: stock) != nil {
            guard input.storageMode == .shared,
                  let result = try? LayeredMetalTransport.process(Array(UnsafeBufferPointer(
                    start: input.contents().assumingMemoryBound(to: Float.self), count: width * height * 4)),
                    width: width, height: height, stock: stock, options: options, frameIndex: frameIndex)
            else { return nil }
            context.layeredResult = result.withUnsafeBytes { Data($0) }
        }
        return context
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
        frameIndex: UInt64 = 0, realtime: Bool = false, exactMath: Bool = false
    ) -> FilmFrameContext? {
        precondition(densityWidth > 0 && densityHeight > 0)
        precondition(frameWidth >= densityWidth && frameHeight >= densityHeight)
        guard measured.encoding == .linearRec2020 else { return nil }
        guard var invocation = try? FilmEngineInvocation(
            validating: stock, options: options,
            width: densityWidth, height: densityHeight,
            frameIndex: frameIndex)
        else { return nil }
        if realtime { invocation.featureMask |= FilmEngineFeature.realtime }
        if exactMath { invocation.featureMask |= FilmEngineFeature.exactMath }

        invocation.copyScreenLevels(from: measured.invocation)
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
        var context = FilmFrameContext(invocation: invocation,
                                       width: frameWidth, height: frameHeight,
                                       encoding: .linearRec2020)
        if options.transportConstruction(for: stock) != nil {
            let pitch = Double(options.format.frameHeightMM * min(max(options.frameCoverage, 0.05), 1))
                / Double(min(densityWidth, densityHeight))
            context.layered = (stock, options, frameIndex, pitch)
        }
        return context
    }

    @discardableResult
    public func prepare(stock: FilmStock, options: FotufilmEngine.Options,
                        frameWidth: Int, frameHeight: Int) -> Bool {
        guard frameWidth > 0, frameHeight > 0 else { return false }
        guard let invocation = try? FilmEngineInvocation(
            validating: stock, options: options, width: frameWidth, height: frameHeight)
        else { return false }
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

    /// Convenience allocating form: premultiplied sRGB RGBA in and out, preserving alpha.
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
        if options.transportConstruction(for: stock) != nil {
            guard let result = layeredEncoded(pixels, width: width, height: height,
                stock: stock, options: options, frameIndex: frameIndex, srgb: true) else { return false }
            output = result
            return true
        }
        guard var invocation = try? FilmEngineInvocation(
            validating: stock, options: options, width: width,
            height: height, frameIndex: frameIndex)
        else { return false }
        if invocation.sceneMeteringActive {
            pixels.withUnsafeBufferPointer { input in
                invocation.measureToneBase(srgbRGBA: input.baseAddress!,
                                           width: width, height: height)
            }
        }
        // The frame is whole, so the kernel averages its own first stage for the glare.
        if invocation.featureMask & FilmEngineFeature.flare != 0 {
            invocation.featureMask |= FilmEngineFeature.flareMeasure
        }
        // The kernel takes the bytes in sRGB and delivers them in sRGB; the basis is the
        // configuration's to say, so this is the Display P3 road with a different answer.
        invocation.configuration[FilmEngineInvocation.byteBasisOffset] = 1
        invocation.configuration[FilmEngineInvocation.byteBasisOffset + 1] = 1
        return pixels.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { output in
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
    /// staged and tiled paths, preventing memory-dependent output differences.
    ///
    /// The row form: every tile spans the frame's width, so a caller that can only hand rows
    /// over is served, at the price that a frame too wide to band within the budget is refused
    /// where the tile form below would cut it into tiles.
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
        developStreaming(
            width: width, height: height, stock: stock, options: options,
            outputTransform: &outputTransform, frameIndex: frameIndex,
            memoryBudget: memoryBudget, apronScale: apronScale, realtime: realtime,
            exactMath: exactMath, noFilm: noFilm, overlapsWriteback: overlapsWriteback,
            fullWidthTiles: true, progress: progress, shouldContinue: shouldContinue,
            readTile: { rows, columns, into in
                precondition(columns == 0..<width)
                readRows(rows, into)
            },
            writeTile: { rows, columns, from in
                precondition(columns == 0..<width)
                writeRows(rows, from)
            })
    }

    /// Develops the frame in tiles: `readTile` fills a dense `columns.count` x `rows.count`
    /// block of interleaved scene-linear float RGBA, `writeTile` takes the same block of the
    /// result. A frame small enough is developed whole, on the device; otherwise it is cut into
    /// tiles sized to the memory budget, each read with the apron the film's reach needs, and
    /// the delivered pixels are the whole frame's exactly — the same expressions over the same
    /// coordinates, whatever the cut. A frame whose halation reaches further than the budget
    /// can afford to repeat is developed in two passes instead: the light once, into the
    /// whole-frame halation grids, and then the tiles with only the emulsion's own apron, which
    /// again delivers the whole frame's pixels.
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
        noFilm: Bool = false,
        overlapsWriteback: Bool = false,
        /// Keeps every tile as wide as the frame, for callers that hand rows over.
        fullWidthTiles: Bool = false,
        progress: ((FilmRenderPhase) -> Void)? = nil,
        shouldContinue: (() -> Bool)? = nil,
        readTile: (_ rows: Range<Int>, _ columns: Range<Int>,
                   _ into: UnsafeMutableBufferPointer<Float>) -> Void,
        writeTile: (_ rows: Range<Int>, _ columns: Range<Int>,
                    _ from: UnsafeBufferPointer<Float>) -> Void
    ) -> Bool {
        if !noFilm, options.transportConstruction(for: stock) != nil {
            guard shouldContinue?() != false else { return false }
            var source = [Float](repeating: 0, count: width*height*4)
            source.withUnsafeMutableBufferPointer { readTile(0..<height, 0..<width, $0) }
            do {
                let result = try LayeredMetalTransport.process(source, width: width, height: height,
                    stock: stock, options: options, frameIndex: frameIndex)
                guard shouldContinue?() != false else { return false }
                outputTransform = nil // caller applies its requested delivery to the linear result
                result.withUnsafeBufferPointer { writeTile(0..<height, 0..<width, $0) }
                return true
            } catch { print(error.localizedDescription); return false }
        }
        precondition(width > 0 && height > 0)
        // Use staged development when both the default and caller-provided budgets permit it.
        // Staging uses the same schedule without repeated aprons or host-device frame copies.
        // Respecting both budgets lets tests force tiled rendering and prevents dispatch to a
        // staged call that will reject the frame.
        let onePassBudget = memoryBudget ?? Self.defaultMemoryBudget()
        if Self.developsInOnePass(width: width, height: height),
           height <= onePassBudget / Self.stripBytesPerRow(width: width),
           let staging = borrowStaging(pixels: width * height) {
            defer { Self.returnStaging(staging) }
            readTile(0..<height, 0..<width, UnsafeMutableBufferPointer(
                start: staging.scenePixels, count: width * height * 4))
            guard developStaged(
                staging, width: width, height: height, stock: stock, options: options,
                outputTransform: &outputTransform, frameIndex: frameIndex,
                realtime: realtime, exactMath: exactMath, measuresGlareOnDevice: false,
                noFilm: noFilm,
                progress: progress, shouldContinue: shouldContinue)
            else { return false }
            writeTile(0..<height, 0..<width, UnsafeBufferPointer(
                start: staging.developedPixels, count: width * height * 4))
            return true
        }
        // Poll between bands and tiles so cancellation never interrupts a dispatch. Return false
        // when cancelled.
        let cancelled = { shouldContinue.map { !$0() } ?? false }
        let invocationStart = Date()
        guard var invocation = try? FilmEngineInvocation(
            validating: stock, options: options, width: width,
            height: height, frameIndex: frameIndex, noFilm: noFilm)
        else { return false }
        let timings = getenv("FOTUFILM_STILL_TIMINGS") != nil
        if timings {
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

        let budget = memoryBudget ?? Self.defaultMemoryBudget()
        guard let plan = Self.planTiles(
            invocation: invocation, width: width, height: height, budget: budget,
            apronScale: apronScale, overlap: overlapsWriteback,
            fullWidth: fullWidthTiles)
        else {
            if timings {
                print("  tiled \(width)x\(height): refused, no tile of \(Self.minimumTile) "
                      + "pixels fits a \(budget >> 20) MB budget")
            }
            return false
        }
        // The tile loop hands `writeTile` to a work item so it can run beside the next kernel.
        // It is joined before the loop returns — every path out of it, the early ones included —
        // so nothing outlives the call; the escape is only lexical.
        return withoutActuallyEscaping(writeTile) { writeTile in
            developTiled(
                invocation: &invocation, width: width, height: height, plan: plan,
                timings: timings, cancelled: cancelled, progress: progress,
                readTile: readTile, writeTile: writeTile)
        }
    }

    /// Develops an already-metered region in bounded tiles. Coordinates passed to the callbacks
    /// are local to the region; kernel origins remain in the context's whole-frame lattice.
    /// The source must include the spatial apron needed by the pixels the caller will display.
    /// Layered transport owns a complete-frame solve and uses `processLinearFloatRegion` instead.
    @discardableResult
    public func developRegionStreaming(
        width: Int, height: Int, originX: Int, originY: Int,
        context: FilmFrameContext, memoryBudget: Int? = nil, exactMath: Bool = false,
        shouldContinue: (() -> Bool)? = nil,
        readTile: (_ rows: Range<Int>, _ columns: Range<Int>,
                   _ into: UnsafeMutableBufferPointer<Float>) -> Void,
        writeTile: (_ rows: Range<Int>, _ columns: Range<Int>,
                    _ from: UnsafeBufferPointer<Float>) -> Void
    ) -> Bool {
        guard width > 0, height > 0, originX >= 0, originY >= 0,
              context.encoding == .linearRec2020, context.layered == nil,
              width <= context.width, height <= context.height,
              originX <= context.width - width, originY <= context.height - height,
              shouldContinue?() != false else { return false }
        let availableBudget = Self.defaultMemoryBudget()
        let budget = min(memoryBudget ?? availableBudget, availableBudget)
        var invocation = context.invocation
        invocation.featureMask |= FilmEngineFeature.floatIO
        if exactMath { invocation.featureMask |= FilmEngineFeature.exactMath }
        let apron = invocation.spatialSupport
        guard let shape = Self.tileShape(
            width: width, height: height, apron: apron,
            fineApron: invocation.spatialSupportSansHalation,
            budget: budget, overlap: false, fullWidth: false) else { return false }
        // Regional previews reuse the whole-frame tone and flare readings. Building halation
        // fields from this crop would replace whole-frame coordinates with crop coordinates.
        let plan = TilePlan(tileWidth: shape.tileWidth, tileRows: shape.tileRows,
                            apron: apron, fields: false, lightRows: 0, lightApron: 0,
                            overlap: false, bytes: shape.bytes, work: shape.work)
        return withoutActuallyEscaping(writeTile) { writeTile in
            developTiled(invocation: &invocation, width: width, height: height, plan: plan,
                timings: getenv("FOTUFILM_STILL_TIMINGS") != nil,
                regionOrigin: SIMD2(originX, originY),
                cancelled: { shouldContinue?() == false }, progress: nil,
                readTile: readTile, writeTile: writeTile)
        }
    }

    /// How a frame too large for one pass is cut: the tiles, their apron, and whether halation
    /// is taken in a pass of its own first.
    struct TilePlan: Equatable {
        /// Delivered pixels per tile, in each axis. The input read for a tile spans `apron`
        /// more on every side, clipped to the frame.
        var tileWidth: Int
        var tileRows: Int
        var apron: Int
        /// Whether the halation grids are built whole-frame first (the fields road): the
        /// light pass reads the frame in bands of `lightRows` rows plus `lightApron`, kept on
        /// the finest grid's cell boundaries so every band delivers whole grid rows.
        var fields: Bool
        var lightRows: Int
        var lightApron: Int
        /// Whether a second result buffer lets the host encode one tile while the kernel
        /// develops the next.
        var overlap: Bool
        /// The peak this plan is priced at, in bytes.
        var bytes: Int
        /// Pixels developed per pixel delivered, the light pass included, as the road choice
        /// weighed it.
        var work: Double

        var tileColumns: Int { 0 }
    }

    /// The tile plan for a frame under `budget`, or nil when no tile of `minimumTile` pixels
    /// fits. Between the classic road — halation's pyramid built over every tile, so the apron
    /// is the whole reach of the film — and the fields road — the light developed once into
    /// whole-frame halation grids, then tiles with only the emulsion's own apron — the cheaper
    /// in pixels developed is taken. `FOTUFILM_FORCE_FIELDS` takes the fields road whenever it
    /// can be taken (the parity tests' seam); `FOTUFILM_NO_FIELDS` never takes it.
    static func planTiles(
        invocation: FilmEngineInvocation, width: Int, height: Int, budget: Int,
        apronScale: Double = 1, overlap: Bool = false, fullWidth: Bool = false
    ) -> TilePlan? {
        let mask = invocation.featureMask
        let classicApron = max(1, Int(Double(invocation.spatialSupport) * apronScale))
        let fineApron = max(1, Int(Double(invocation.spatialSupportSansHalation) * apronScale))
        var classic = tileShape(width: width, height: height, apron: classicApron,
                                fineApron: fineApron, budget: budget, overlap: overlap,
                                fullWidth: fullWidth)
            .map { shape in
                TilePlan(tileWidth: shape.tileWidth, tileRows: shape.tileRows,
                         apron: classicApron, fields: false, lightRows: 0, lightApron: 0,
                         overlap: overlap, bytes: shape.bytes, work: shape.work)
            }
        let forced = getenv("FOTUFILM_FORCE_FIELDS") != nil
        var fields: TilePlan? = nil
        if getenv("FOTUFILM_NO_FIELDS") == nil,
           mask & FilmEngineFeature.halation != 0,
           mask & FilmEngineFeature.exactMath == 0,
           mask & FilmEngineFeature.realtime == 0,
           mask & FilmEngineFeature.flareMeasure == 0,
           mask & FilmEngineFeature.texture == 0,
           invocation.halationSupport > 0,
           fotufilm_halide_metal_variant_exists(
               lightMask(mask) | FilmEngineFeature.lightOut) == 1,
           fotufilm_halide_metal_variant_exists(mask | FilmEngineFeature.fieldsIn) == 1 {
            let lightApron = max(1, Int(Double(invocation.lightSupport) * apronScale))
            let stride = Int(fotufilm_halation_stride(invocation.halationPixelRadii[0]))
            let gridFloats = invocation.halationPixelRadii.withUnsafeBufferPointer {
                Int(fotufilm_halide_metal_halation_fields_floats(
                    Int32(width), Int32(height), $0.baseAddress))
            }
            // The grids ride along for the whole develop, in the caller's blob and on the
            // device; the light pass runs before it and holds its own band, so the budget the
            // tiles have is what the grids leave.
            let gridBytes = 2 * gridFloats * 4
            let lightRowBytes = width * (16 + lightBytesPerPixel)
            // A band is a tile the frame wide, and pays the same page-fault toll past the
            // tile ceiling; its apron is a few rows, so it may be twice as tall as a tile.
            var lightRows = min((budget - gridBytes) / lightRowBytes - 2 * lightApron,
                                2 * maximumTilePixels / width)
            lightRows = min(height, max(stride, lightRows / stride * stride))
            if gridBytes > 0, lightRows >= stride,
               let shape = tileShape(width: width, height: height, apron: fineApron,
                                     fineApron: fineApron, budget: budget - gridBytes,
                                     overlap: overlap, fullWidth: fullWidth) {
                let lightWork = lightPassShare
                    * Double(min(height, lightRows + 2 * lightApron)) / Double(lightRows)
                    + Double((height + lightRows - 1) / lightRows) * tileOverhead
                fields = TilePlan(
                    tileWidth: shape.tileWidth, tileRows: shape.tileRows, apron: fineApron,
                    fields: true, lightRows: lightRows, lightApron: lightApron,
                    overlap: overlap, bytes: shape.bytes + gridBytes,
                    work: shape.work + lightWork)
            }
        }
        if forced, fields != nil { classic = nil }
        switch (classic, fields) {
        case (let classic?, let fields?): return fields.work < classic.work ? fields : classic
        case (let classic?, nil): return classic
        case (nil, let fields?): return fields
        case (nil, nil): return nil
        }
    }

    /// The largest tile of `apron` reach that fits `budget`, shaped to repeat the fewest pixels:
    /// as wide as the frame when that leaves rows enough, narrower when the frame is too wide
    /// to band, since a tile's apron costs its perimeter and a band's costs its whole width.
    /// `fineApron` is how far the stages past the light reach; the apron beyond it is walked
    /// by the light chain alone, which is what it is priced at.
    static func tileShape(
        width: Int, height: Int, apron: Int, fineApron: Int, budget: Int, overlap: Bool,
        fullWidth: Bool
    ) -> (tileWidth: Int, tileRows: Int, bytes: Int, work: Double)? {
        var best: (tileWidth: Int, tileRows: Int, bytes: Int, work: Double)? = nil
        var candidates = [width]
        if !fullWidth {
            var parts = 2
            while (width + parts - 1) / parts >= min(minimumTile, width) {
                candidates.append((width + parts - 1) / parts)
                parts += 1
            }
        }
        for tileWidth in candidates {
            guard let tileRows = tileRows(width: width, height: height, tileWidth: tileWidth,
                                          apron: apron, budget: budget, overlap: overlap,
                                          allowOversizedBand: fullWidth)
            else { continue }
            let bytes = tileBytes(width: width, height: height, tileWidth: tileWidth,
                                  tileRows: tileRows, apron: apron, overlap: overlap)
            let across = (width + tileWidth - 1) / tileWidth
            let down = (height + tileRows - 1) / tileRows
            // What the tiles develop, in frame-develops: every tile's input walks the light
            // chain, apron and all; the rest of the film only reaches `fineApron` past the
            // delivered pixels. A tile costs the host a callback and the device a launch per
            // stage besides.
            var light = 0, film = 0
            for row in 0..<down {
                let top = row * tileRows
                let rows = min(height, top + tileRows + apron) - max(0, top - apron)
                let fineRows = min(height, top + tileRows + fineApron)
                    - max(0, top - fineApron)
                for column in 0..<across {
                    let left = column * tileWidth
                    let columns = min(width, left + tileWidth + apron) - max(0, left - apron)
                    let fineColumns = min(width, left + tileWidth + fineApron)
                        - max(0, left - fineApron)
                    light += rows * columns
                    film += fineRows * fineColumns
                }
            }
            let work = (Double(light) * lightPassShare
                        + Double(film) * (1 - lightPassShare)) / Double(width * height)
                + Double(across * down) * tileOverhead
            if let current = best, work >= current.work { continue }
            best = (tileWidth, tileRows, bytes, work)
        }
        return best
    }

    /// The most rows a tile `tileWidth` wide can deliver under `budget` and `maximumTilePixels`,
    /// or nil when not even `minimumTile` rows fit. Row-only callers cannot narrow a band, so
    /// they may exceed the pixel ceiling to preserve that minimum, but never the memory budget.
    static func tileRows(width: Int, height: Int, tileWidth: Int, apron: Int, budget: Int,
                         overlap: Bool, allowOversizedBand: Bool = false) -> Int? {
        let floor = min(height, minimumTile)
        let pixelLimitedRows = maximumTilePixels / min(width, tileWidth)
        // Reject wide candidates instead of silently promoting their height past the pixel
        // ceiling. A 6000-pixel iPhone band otherwise starts at 1.5 MP, three times its cap.
        guard pixelLimitedRows >= floor || allowOversizedBand else { return nil }
        guard tileBytes(width: width, height: height, tileWidth: tileWidth, tileRows: floor,
                        apron: apron, overlap: overlap) <= budget else { return nil }
        var low = floor, high = max(floor, min(height, pixelLimitedRows))
        while low < high {
            let middle = (low + high + 1) / 2
            if tileBytes(width: width, height: height, tileWidth: tileWidth, tileRows: middle,
                         apron: apron, overlap: overlap) <= budget {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low
    }

    /// What one tile costs while it is in flight: its input with the apron on every side, in
    /// shared memory, and the light chain's working set over that; its results, and the
    /// emulsion and print's working set over the delivered pixels.
    static func tileBytes(width: Int, height: Int, tileWidth: Int, tileRows: Int, apron: Int,
                          overlap: Bool) -> Int {
        let inputArea = min(width, tileWidth + 2 * apron) * min(height, tileRows + 2 * apron)
        let outputArea = min(width, tileWidth) * min(height, tileRows)
        return inputArea * (16 + lightBytesPerPixel)
            + outputArea * (developBytesPerPixel + 16 * (overlap ? 2 : 1))
    }

    /// The stages a light pass runs: everything up to the light halation reads.
    static func lightMask(_ mask: Int32) -> Int32 {
        (mask & (FilmEngineFeature.flare | FilmEngineFeature.mtf | FilmEngineFeature.mtfLuma
                 | FilmEngineFeature.diffusion | FilmEngineFeature.monochrome
                 | FilmEngineFeature.reversal)) | FilmEngineFeature.floatIO
    }

    /// The smallest tile worth cutting, in delivered pixels on a side. Below this the apron
    /// outweighs the tile and the launches outweigh the work.
    public static let minimumTile = 256

    /// The largest tile worth cutting, in delivered pixels, whatever the budget allows. Every
    /// stage of a tile writes a fresh allocation, and past a point a tile spends more faulting
    /// those pages in than it saves in apron. On the Mac that point is a couple of megapixels:
    /// at 100 MP, 0.8 MP tiles developed the frame in 1.9 s where 23 MP tiles took 2.7 s. The
    /// phone faults far dearer: an iPhone 16 Pro developed 24 MP in 5.1 s as twelve 2 MP tiles
    /// and in 0.95 s as sixty of 0.4 MP.
    #if os(iOS)
    public static let maximumTilePixels = 512_000
    #else
    public static let maximumTilePixels = 2_000_000
    #endif

    /// The light chain's share of a develop's time per pixel — the exposure, the glare and the
    /// MTF against everything — as measured at 100 MP (a light pass of 0.66 s against a
    /// develop of 1.5 s): it is what a halation apron pixel costs, and what the fields road's
    /// first pass costs.
    static let lightPassShare = 0.4

    /// What one tile or band costs in launches and callbacks, in frame-develops: about a
    /// millisecond against a 24 MP frame's four hundred.
    static let tileOverhead = 0.003

    /// The tiled develop, once its geometry is settled: a light pass into the halation grids
    /// when the plan takes the fields road, then the tiles.
    private func developTiled(
        invocation: inout FilmEngineInvocation,
        width: Int, height: Int, plan: TilePlan,
        timings: Bool,
        regionOrigin: SIMD2<Int>? = nil,
        cancelled: () -> Bool,
        progress: ((FilmRenderPhase) -> Void)?,
        readTile: (_ rows: Range<Int>, _ columns: Range<Int>,
                   _ into: UnsafeMutableBufferPointer<Float>) -> Void,
        writeTile: @escaping (_ rows: Range<Int>, _ columns: Range<Int>,
                              _ from: UnsafeBufferPointer<Float>) -> Void
    ) -> Bool {
        let inputWidth = min(width, plan.tileWidth + 2 * plan.apron)
        let inputRows = min(height, plan.tileRows + 2 * plan.apron)
        let lightBand = plan.fields ? min(height, plan.lightRows + 2 * plan.lightApron) : 0
        // One input for every pass: a tile with its apron, or a light band — whichever is the
        // larger — and the whole-frame measurements' bands walk the frame through it too.
        let inputPixels = max(inputWidth * inputRows, width * lightBand)
        guard let staging = Self.borrowTileStaging(
            inputPixels: inputPixels,
            outputPixels: min(width, plan.tileWidth) * min(height, plan.tileRows),
            outputCount: plan.overlap ? 2 : 1)
        else { return false }
        defer { Self.returnTileStaging(staging) }
        let input = staging.inputPointer
        let inputHandle = staging.inputHandle

        let metersOnLightBands = Self.metersOnLightBands(invocation, fields: plan.fields)
        let measureStart = Date()
        let bandRows = max(1, min(height, staging.inputPixels / width))
        // The bands fill the tile input and are measured where they land, on the device; the
        // host pointer is the fallback for a build with no Metal to measure on.
        if regionOrigin == nil {
            let measured = withoutActuallyEscaping(readTile) { readTile in
                measureWholeFrame(
                    &invocation, width: width, height: height, bandRows: bandRows,
                    toneBase: !metersOnLightBands,
                    cancelled: cancelled, progress: progress,
                    band: { rows in
                        readTile(rows, 0..<width, UnsafeMutableBufferPointer(
                            start: input, count: rows.count * width * 4))
                        return UnsafePointer(input)
                    },
                    deviceBand: { rows in
                        readTile(rows, 0..<width, UnsafeMutableBufferPointer(
                            start: input, count: rows.count * width * 4))
                        return inputHandle
                    })
            }
            guard measured else { return false }
        }
        var measureSeconds = regionOrigin == nil ? Date().timeIntervalSince(measureStart) : 0

        let across = (width + plan.tileWidth - 1) / plan.tileWidth
        let down = (height + plan.tileRows - 1) / plan.tileRows
        let tiles = across * down
        let lightBands = plan.fields ? (height + plan.lightRows - 1) / plan.lightRows : 0
        let steps = lightBands + tiles

        // The fields road's first pass: the light of every band, decimated on the device into
        // the frame's finest halation grid, and that grid blurred into the three scales.
        // The grids ride behind the configuration in one blob, so the engine can read them in
        // place rather than keep a copy of its own; `release_fields` below is what lets the blob
        // go.
        let head = FilmEngineInvocation.configurationCount
        var extended: [Float] = []
        var fieldsID: UInt64 = 0
        var lightSeconds = 0.0, gridSeconds = 0.0, readSeconds = 0.0
        if plan.fields {
            let radii = invocation.halationPixelRadii
            let stride = Int(fotufilm_halation_stride(radii[0]))
            let gridWidth = (width + stride - 1) / stride
            let gridHeight = (height + stride - 1) / stride
            var grid = [Float](repeating: 0, count: gridWidth * gridHeight * 3)
            let lightMask = Self.lightMask(invocation.featureMask)
            var toneBase = metersOnLightBands
                ? ToneBaseWalk(invocation, bandRows: lightBand) : nil
            for band in 0..<lightBands {
                if cancelled() { return false }
                progress?(.developing(index: band, count: steps))
                let top = band * plan.lightRows
                let bottom = min(height, top + plan.lightRows)
                let from = max(0, top - plan.lightApron)
                let to = min(height, bottom + plan.lightApron)
                let readStart = Date()
                readTile(from..<to, 0..<width, UnsafeMutableBufferPointer(
                    start: input, count: (to - from) * width * 4))
                readSeconds += Date().timeIntervalSince(readStart)
                if toneBase != nil {
                    // The band's own rows, not its apron: each frame row is metered once.
                    let toneStart = Date()
                    toneBase!.add(invocation, rows: top..<bottom, bufferRow: from,
                                  width: width, handle: inputHandle,
                                  host: UnsafePointer(input))
                    measureSeconds += Date().timeIntervalSince(toneStart)
                }
                // The band's grid starts at the cell holding row `from - from % stride`; the
                // rows it delivers start at `top`, a whole number of cells further in.
                let phase = from % stride
                let firstCell = (top - (from - phase)) / stride
                let cells = (bottom - top + stride - 1) / stride
                let lightStart = Date()
                let ok = invocation.configuration.withUnsafeBufferPointer { configuration in
                    invocation.withSpectralPointers { exposure, film, paper in
                        grid.withUnsafeMutableBufferPointer { grid in
                            fotufilm_halide_metal_process_buffers_light_grid(
                                inputHandle,
                                grid.baseAddress! + (top / stride) * gridWidth * 3,
                                Int32(width), Int32(to - from),
                                Int32(firstCell), Int32(cells), 0, Int32(from),
                                configuration.baseAddress, exposure, film, paper,
                                Int32(invocation.spectral.exposure.dimension),
                                invocation.spectralCacheID, lightMask,
                                invocation.seed) == 0
                        }
                    }
                }
                lightSeconds += Date().timeIntervalSince(lightStart)
                guard ok else { return false }
            }
            if cancelled() { return false }
            // Before the extended configuration is taken: the tiles read the metered base.
            if let toneBase { invocation.setToneBase(toneBase.measurement) }
            let gridStart = Date()
            let fieldsFloats = radii.withUnsafeBufferPointer {
                fotufilm_halide_metal_halation_fields_floats(
                    Int32(width), Int32(height), $0.baseAddress)
            }
            guard fieldsFloats > 11 else { return false }
            extended = invocation.configuration
            extended.append(contentsOf: repeatElement(0, count: Int(fieldsFloats)))
            let built = radii.withUnsafeBufferPointer { radii in
                grid.withUnsafeBufferPointer { grid in
                    extended.withUnsafeMutableBufferPointer { extended in
                        fotufilm_halide_metal_halation_fields(
                            grid.baseAddress, Int32(width), Int32(height),
                            radii.baseAddress, extended.baseAddress! + head,
                            fieldsFloats) == 0
                    }
                }
            }
            guard built else { return false }
            grid = []
            gridSeconds = Date().timeIntervalSince(gridStart)
            fieldsID = mach_absolute_time()
        }
        defer { if plan.fields { fotufilm_halide_metal_release_fields() } }

        var engineSeconds = 0.0
        var writeSeconds = 0.0
        var writeWaitSeconds = 0.0
        var developed = 0
        // Where the footprint stands as the tiles go by, against what the plan was priced at,
        // for the timing line: the process's own reading, so it counts what the host holds —
        // the print's unwritten pages, the staging — as well as the schedule's.
        let footprintBefore = timings ? Self.footprintBytes() : 0
        var footprintPeak = 0
        // The host's half of the previous tile, still running. `writeTile` is the caller's
        // encode — on a still, a full pass over the tile in float and out in sixteen-bit — and
        // nothing the kernel does next reads what it is reading, so it rides the next tile's
        // kernel rather than delaying it. The tiles are still handed over in order: this is one
        // outstanding write, joined before the buffer it holds is reused.
        let writeQueue = DispatchQueue(label: "fotufilm.tile.write", qos: .userInitiated)
        var outstandingWrite: DispatchWorkItem?
        func joinWrite() {
            guard let item = outstandingWrite else { return }
            let waitStart = Date()
            item.wait()
            writeWaitSeconds += Date().timeIntervalSince(waitStart)
            outstandingWrite = nil
        }
        defer { joinWrite() }
        for index in 0..<tiles {
            if cancelled() { return false }
            progress?(.developing(index: lightBands + index, count: steps))
            let top = (index / across) * plan.tileRows
            let left = (index % across) * plan.tileWidth
            let bottom = min(height, top + plan.tileRows)
            let right = min(width, left + plan.tileWidth)
            let from = max(0, top - plan.apron), to = min(height, bottom + plan.apron)
            let first = max(0, left - plan.apron), last = min(width, right + plan.apron)
            let tileWidth = last - first, tileHeight = to - from
            developed += tileWidth * tileHeight

            let readStart = Date()
            readTile(from..<to, first..<last, UnsafeMutableBufferPointer(
                start: input, count: tileHeight * tileWidth * 4))
            readSeconds += Date().timeIntervalSince(readStart)
            // Two results let the previous host write overlap this kernel dispatch. A single
            // one must be joined before reuse.
            if !plan.overlap { joinWrite() }
            let engineStart = Date()
            let ok = invocation.configuration.withUnsafeBufferPointer { plain in
                invocation.withSpectralPointers { exposure, film, paper in
                    extended.withUnsafeBufferPointer { extended in
                        fotufilm_halide_metal_process_buffers_float_tile(
                            inputHandle, staging.outputHandle(at: index),
                            Int32(tileWidth), Int32(tileHeight),
                            Int32(left - first), Int32(right - left),
                            Int32(top - from), Int32(bottom - top),
                            Int32(first + (regionOrigin?.x ?? 0)),
                            Int32(from + (regionOrigin?.y ?? 0)),
                            plan.fields ? extended.baseAddress : plain.baseAddress,
                            plan.fields ? extended.baseAddress! + head : nil,
                            Int32(extended.count - head), fieldsID,
                            exposure, film, paper,
                            Int32(invocation.spectral.exposure.dimension),
                            invocation.spectralCacheID, invocation.featureMask,
                            invocation.seed) == 0
                    }
                }
            }
            engineSeconds += Date().timeIntervalSince(engineStart)
            guard ok else { return false }
            if timings { footprintPeak = max(footprintPeak, Self.footprintBytes()) }
            // Complete the previous write before submitting the next to preserve tile order.
            joinWrite()
            let writeStart = Date()
            let result = staging.outputPointer(at: index)
            let item = DispatchWorkItem {
                writeTile(top..<bottom, left..<right, UnsafeBufferPointer(
                    start: result, count: (bottom - top) * (right - left) * 4))
            }
            if index == tiles - 1 {
                item.perform()
                writeSeconds += Date().timeIntervalSince(writeStart)
            } else {
                outstandingWrite = item
                writeQueue.async(execute: item)
            }
        }
        joinWrite()
        if timings {
            print(String(
                format: "  tiled %dx%d: %d tile(s) of %dx%d, apron %d (%.2fx pixels)%@, "
                    + "measure %.1f ms, read %.1f ms, light %.1f ms, grids %.1f ms, "
                    + "engine %.1f ms, write %.1f ms (last tile), write wait %.1f ms",
                width, height, tiles, plan.tileWidth, plan.tileRows, plan.apron,
                Double(developed) / Double(width * height),
                (plan.fields
                    ? String(format: ", %d light band(s) of %d rows (apron %d)%@",
                             lightBands, plan.lightRows, plan.lightApron,
                             metersOnLightBands ? ", metered on the bands" : "")
                    : "") as NSString,
                measureSeconds * 1000, readSeconds * 1000, lightSeconds * 1000,
                gridSeconds * 1000, engineSeconds * 1000, writeSeconds * 1000,
                writeWaitSeconds * 1000))
            print(String(
                format: "  tiled: priced %d MB (grids %d MB), footprint %d MB before, "
                    + "+%d MB at most after a tile",
                plan.bytes >> 20, (plan.bytes - Self.tileBytes(
                    width: width, height: height, tileWidth: plan.tileWidth,
                    tileRows: plan.tileRows, apron: plan.apron, overlap: plan.overlap)) >> 20,
                footprintBefore >> 20, max(0, footprintPeak - footprintBefore) >> 20))
        }
        return true
    }

    /// The process's physical footprint — what the system holds it to.
    static func footprintBytes() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
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
        if !noFilm, options.transportConstruction(for: stock) != nil {
            guard shouldContinue?() != false else { return false }
            let source = Array(UnsafeBufferPointer(start: staging.scenePixels, count: width*height*4))
            do {
                let result = try LayeredMetalTransport.process(source, width: width, height: height,
                    stock: stock, options: options, frameIndex: frameIndex)
                guard shouldContinue?() != false else { return false }
                result.withUnsafeBufferPointer { staging.developedPixels.update(from: $0.baseAddress!, count: $0.count) }
                outputTransform = nil
                return true
            } catch { print(error.localizedDescription); return false }
        }
        let cancelled = { shouldContinue.map { !$0() } ?? false }
        guard var invocation = try? FilmEngineInvocation(
            validating: stock, options: options, width: width,
            height: height, frameIndex: frameIndex, noFilm: noFilm)
        else { return false }
        invocation.featureMask |= FilmEngineFeature.floatIO
        if realtime { invocation.featureMask |= FilmEngineFeature.realtime }
        if exactMath { invocation.featureMask |= FilmEngineFeature.exactMath }
        // A staged frame is whole and already on the device, so the kernel can average its own
        // first stage rather than have the host run that stage a second time over every pixel.
        // Only when there is glare to measure: the stage is opt-in, and a frame without it
        // has no mean to average.
        if measuresGlareOnDevice, invocation.featureMask & FilmEngineFeature.flare != 0 {
            invocation.featureMask |= FilmEngineFeature.flareMeasure
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
    /// Costs one invocation's setup and touches no pixel. `exactMath` has to be what the render
    /// will be given: it changes which kernel the frame asks for.
    public func carriesOutputTransform(
        stock: FilmStock, options: FotufilmEngine.Options, width: Int, height: Int,
        frameIndex: UInt64 = 0, realtime: Bool = false, exactMath: Bool = false,
        measuresGlareOnDevice: Bool = false, noFilm: Bool = false
    ) -> Bool {
        if !noFilm && options.transportConstruction(for: stock) != nil { return false }
        guard let invocation = try? FilmEngineInvocation(
            validating: stock, options: options, width: width, height: height,
            frameIndex: frameIndex, noFilm: noFilm)
        else { return false }
        var mask = invocation.featureMask
        mask |= FilmEngineFeature.floatIO
        if realtime { mask |= FilmEngineFeature.realtime }
        if exactMath { mask |= FilmEngineFeature.exactMath }
        guard Self.encodesOutput(mask) else { return false }
        let encodeMask = FilmEngineFeature.encodeOut
            | (realtime ? FilmEngineFeature.outputLinear : 0)
        if measuresGlareOnDevice { mask |= FilmEngineFeature.flareMeasure }
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

    /// Whether a tiled develop meters the tone base on the fields road's light bands rather than
    /// in a walk of its own. The road walks the whole frame for its light anyway, and the base
    /// can ride those bands when the light cannot read what the metering writes: the tone grid
    /// keys the highlight and shadow masks, which are at rest, and the screen levels land in the
    /// print stage. The glare mean is scene light and has to be in hand before the light is
    /// formed, so a host-measured flare keeps the separate walk — and meters on it, since the
    /// rows are going by regardless.
    static func metersOnLightBands(_ invocation: FilmEngineInvocation, fields: Bool) -> Bool {
        fields && invocation.sceneMeteringActive
            && !invocation.toneControlsActive
            && (invocation.featureMask & FilmEngineFeature.flare == 0
                || invocation.featureMask & FilmEngineFeature.flareMeasure != 0)
    }

    /// The regional tone base measured a band at a time: the kernel's per-row cell sums where
    /// there is a device to run it on, the host's own walk where there is not. A row's sums are
    /// complete before they leave the kernel and every row is added once, in order, so what the
    /// bands were — a measure walk's, or the fields road's light bands with their aprons — is
    /// invisible to the result.
    private struct ToneBaseWalk {
        private(set) var measurement: ToneBaseMeasurement
        private var cellSums: [Float]

        /// `bandRows` is the most rows one call will measure.
        init(_ invocation: FilmEngineInvocation, bandRows: Int) {
            measurement = invocation.toneBaseMeasurement()
            cellSums = [Float](repeating: 0, count: max(1, bandRows) * measurement.gridWidth)
        }

        /// Adds frame rows `rows` from a buffer whose first row is frame row `bufferRow`
        /// (`bufferRow <= rows.lowerBound`): a band with rows above it — a light band's apron —
        /// is measured from its top and the sums of the rows before `rows` are dropped. The
        /// kernel reads the device buffer `handle`, or takes the host rows at `host` across when
        /// there is none; the host rows are also the walk's own fallback when the kernel fails.
        /// Returns false when nothing could be measured.
        @discardableResult
        mutating func add(_ invocation: FilmEngineInvocation, rows: Range<Int>,
                          bufferRow: Int, width: Int,
                          handle: UInt64, host: UnsafePointer<Float>?) -> Bool {
            guard !rows.isEmpty else { return true }
            let gridWidth = measurement.gridWidth
            let skipped = rows.lowerBound - bufferRow
            let measuredRows = rows.upperBound - bufferRow
            precondition(skipped >= 0 && measuredRows * gridWidth <= cellSums.count)
            let onDevice = cellSums.withUnsafeMutableBufferPointer { out in
                invocation.configuration.withUnsafeBufferPointer { configuration in
                    fotufilm_halide_metal_measure_tone_rows(
                        handle, handle == 0 ? host : nil, out.baseAddress,
                        Int32(gridWidth), Int32(width),
                        Int32(measuredRows), configuration.baseAddress) == 0
                }
            }
            if onDevice {
                cellSums.withUnsafeBufferPointer {
                    measurement.add(cellRowSums: $0.baseAddress! + skipped * gridWidth,
                                    rows: rows)
                }
                return true
            }
            guard let host else { return false }
            measurement.add(linearRGBA: host + skipped * width * 4, rows: rows)
            return true
        }
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
        toneBase: Bool = true,
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

        if toneBase, invocation.sceneMeteringActive {
            var walk = ToneBaseWalk(invocation, bandRows: bandRows)
            var row = 0
            while row < height {
                if cancelled() { return false }
                let upper = min(height, row + bandRows)
                if let deviceBand, walk.add(invocation, rows: row..<upper, bufferRow: row,
                                            width: width, handle: deviceBand(row..<upper),
                                            host: nil) {
                    // Measured where the band landed, on the device.
                } else {
                    walk.add(invocation, rows: row..<upper, bufferRow: row,
                             width: width, handle: 0, host: band(row..<upper))
                }
                row = upper
            }
            invocation.setToneBase(walk.measurement)
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

    /// Takes the idle staging when it is large enough and allocates otherwise, so two renders
    /// in flight at once each get their own and never share.
    private static func borrowTileStaging(inputPixels: Int, outputPixels: Int,
                                          outputCount: Int) -> TileStaging? {
        _ = stagingPressure
        tileStagingLock.lock()
        if let idle = idleTileStaging, idle.inputPixels >= inputPixels,
           idle.outputPixels >= outputPixels, idle.outputCount >= outputCount {
            idleTileStaging = nil
            tileStagingLock.unlock()
            return idle
        }
        tileStagingLock.unlock()
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        return TileStaging(device: device, inputPixels: inputPixels,
                           outputPixels: outputPixels, outputCount: outputCount)
    }

    private static func returnTileStaging(_ staging: TileStaging) {
        tileStagingLock.lock()
        if (idleTileStaging?.inputPixels ?? 0) <= staging.inputPixels {
            idleTileStaging = staging
        }
        tileStagingLock.unlock()
    }

    private static let tileStagingLock = NSLock()
    nonisolated(unsafe) private static var idleTileStaging: TileStaging?

    /// Drops every idle buffer the renderer keeps between renders: a frame's staging, and the
    /// tile staging. For a host that wants its footprint back the moment an export ends —
    /// nothing a later render needs is lost, only the time to allocate it again.
    public static func releaseIdleBuffers() {
        stagingLock.lock()
        idleStaging = nil
        stagingLock.unlock()
        tileStagingLock.lock()
        idleTileStaging = nil
        tileStagingLock.unlock()
    }

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
        source.setEventHandler { releaseIdleBuffers() }
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

    /// Peak footprint per delivered pixel of the emulsion and print stages — everything past
    /// the light — measured over tiles from a quarter to five megapixels with the runtime's
    /// queue bounded (see `kMetalQueueDepth`), and rounded up: the footprint the process shows
    /// includes what the driver has not yet given back.
    public static let developBytesPerPixel = 144

    /// Peak footprint per input pixel of the light chain — the exposure, the glare, the lens
    /// diffusion and the MTF — which every apron pixel goes through.
    public static let lightBytesPerPixel = 48

    /// What one row of a frame-wide band costs while that band is in flight: the band's input
    /// and its result in shared memory, plus the schedule's own working set.
    static func stripBytesPerRow(width: Int) -> Int {
        max(1, width * (16 * 2 + lightBytesPerPixel + developBytesPerPixel))
    }

    /// Smallest peak an end-to-end export of this frame can be made to run in: the smallest
    /// tile worth cutting, with the apron of the cheaper road, and the halation grids that road
    /// keeps. Returns `nil` when the requested development condition is unsupported.
    public static func minimumPeakBytes(width: Int, height: Int,
                                        stock: FilmStock,
                                        options: FotufilmEngine.Options,
                                        exactMath: Bool = false) -> Int? {
        guard var invocation = try? FilmEngineInvocation(
            validating: stock, options: options, width: width, height: height)
        else { return nil }
        invocation.featureMask |= FilmEngineFeature.floatIO
        if exactMath { invocation.featureMask |= FilmEngineFeature.exactMath }
        let pixels = width * height
        let frames = MappedBuffer.residentBytes(pixels * 16)
            + MappedBuffer.residentBytes(pixels * 8)
        let tile = min(minimumTile, width, height)
        var least = tileBytes(width: width, height: height, tileWidth: tile, tileRows: tile,
                              apron: invocation.spatialSupport, overlap: false)
        let mask = invocation.featureMask
        if getenv("FOTUFILM_NO_FIELDS") == nil,
           mask & FilmEngineFeature.halation != 0, !exactMath,
           invocation.halationSupport > 0,
           fotufilm_halide_metal_variant_exists(
               lightMask(mask) | FilmEngineFeature.lightOut) == 1,
           fotufilm_halide_metal_variant_exists(mask | FilmEngineFeature.fieldsIn) == 1 {
            let gridBytes = 2 * invocation.halationPixelRadii.withUnsafeBufferPointer {
                Int(fotufilm_halide_metal_halation_fields_floats(
                    Int32(width), Int32(height), $0.baseAddress)) * 4
            }
            let stride = Int(fotufilm_halation_stride(invocation.halationPixelRadii[0]))
            let lightBand = min(height, stride + 2 * max(1, invocation.lightSupport))
            let fields = gridBytes + max(
                tileBytes(width: width, height: height, tileWidth: tile, tileRows: tile,
                          apron: invocation.spatialSupportSansHalation, overlap: false),
                width * lightBand * (16 + lightBytesPerPixel))
            if gridBytes > 0 { least = min(least, fields) }
        }
        return frames + least
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
        guard let minimum = minimumPeakBytes(width: width, height: height, stock: stock,
                                            options: options, exactMath: exactMath)
        else { return false }
        return minimum <= ceiling
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
        // Half of what the process may still allocate. The tile working set *is* the budget,
        // so giving it half leaves the other half for the decode's bands, the print encode, and
        // slack under pressure. It need not be quantized: a tile delivers the whole frame's
        // pixels whatever the cut, so available-memory jitter changes the tile count and
        // nothing else. Sixty-four megabytes is the floor a quarter-megapixel tile with a
        // hundred-pixel apron still fits.
        return max(64 << 20, availableBytes() / 2)
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
        if options.transportConstruction(for: stock) != nil {
            guard input.storageMode == .shared, output.storageMode == .shared else { return false }
            let source = Array(UnsafeBufferPointer(start: input.contents().assumingMemoryBound(to: UInt8.self), count: byteCount))
            guard let result = layeredEncoded(source, width: width, height: height,
                stock: stock, options: options, frameIndex: frameIndex, srgb: false) else { return false }
            result.withUnsafeBufferPointer { output.contents().copyMemory(from: $0.baseAddress!, byteCount: byteCount) }
            return true
        }
        let measureStart = FrameClock.isEnabled ? Date() : Date.distantPast
        guard var invocation = try? FilmEngineInvocation(
            validating: stock, options: options, width: width,
            height: height, frameIndex: frameIndex)
        else { return false }
        if invocation.sceneMeteringActive {
            guard input.storageMode == .shared else { return false }
            invocation.measureToneBase(
                encodedDisplayP3RGBA: input.contents().assumingMemoryBound(to: UInt8.self),
                width: width, height: height)
        }
        // The frame is whole, so the kernel averages its own first stage for the glare rather
        // than have the host walk the bytes; a crop rendered as part of a frame goes through
        // `makeRGBA8FrameContext`, which measures the whole frame it belongs to.
        if invocation.featureMask & FilmEngineFeature.flare != 0 {
            invocation.featureMask |= FilmEngineFeature.flareMeasure
        }
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
        guard options.transportConstruction(for: stock) == nil else { return false }
        let byteCount = regionWidth * regionHeight * 4
        precondition(regionWidth > 0 && regionHeight > 0)
        precondition(frameWidth >= regionWidth && frameHeight >= regionHeight)
        precondition(originX >= 0 && originY >= 0)
        precondition(originX + regionWidth <= frameWidth)
        precondition(originY + regionHeight <= frameHeight)
        precondition(input.length >= byteCount && output.length >= byteCount)
        guard let invocation = try? FilmEngineInvocation(
            validating: stock, options: options, width: frameWidth,
            height: frameHeight, frameIndex: frameIndex)
        else { return false }
        guard !invocation.sceneMeteringActive,
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
        if let copied = context.copyLayeredRegion(to: output, width: regionWidth,
            height: regionHeight, x: originX, y: originY) { return copied }
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
        guard options.transportConstruction(for: stock) == nil else { return false }
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
        guard let invocation = try? FilmEngineInvocation(
            validating: stock, options: options, width: width,
            height: height, frameIndex: frameIndex)
        else { return false }
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
        if options.transportConstruction(for: stock) != nil {
            guard input.storageMode == .shared, output.storageMode == .shared else { return false }
            let source = Array(UnsafeBufferPointer(start: input.contents().assumingMemoryBound(to: Float.self), count: width*height*4))
            do {
                let result = try LayeredMetalTransport.process(source, width: width, height: height,
                    stock: stock, options: options, frameIndex: frameIndex)
                result.withUnsafeBufferPointer { output.contents().copyMemory(from: $0.baseAddress!, byteCount: byteCount) }
                return true
            } catch { print(error.localizedDescription); return false }
        }
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
        guard options.transportConstruction(for: stock) == nil else { return false }
        let byteCount = regionWidth * regionHeight * 16
        precondition(regionWidth > 0 && regionHeight > 0)
        precondition(input.length >= byteCount && output.length >= byteCount)
        guard var invocation = try? FilmEngineInvocation(
            validating: stock, options: options, width: frameWidth,
            height: frameHeight, frameIndex: frameIndex)
        else { return false }
        if realtime { invocation.featureMask |= FilmEngineFeature.realtime }
        guard !invocation.sceneMeteringActive,
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
        if let copied = context.copyLayeredRegion(to: output, width: regionWidth,
            height: regionHeight, x: originX, y: originY) { return copied }
        if let layered = context.layered {
            guard originX == 0, originY == 0, regionWidth == context.width,
                  regionHeight == context.height, input.storageMode == .shared,
                  output.storageMode == .shared,
                  let result = try? LayeredMetalTransport.process(Array(UnsafeBufferPointer(
                    start: input.contents().assumingMemoryBound(to: Float.self), count: regionWidth * regionHeight * 4)),
                    width: regionWidth, height: regionHeight, stock: layered.stock,
                    options: layered.options, frameIndex: layered.frameIndex,
                    invocation: context.invocation, pixelPitchMM: layered.pitch) else { return false }
            result.withUnsafeBytes { output.contents().copyMemory(from: $0.baseAddress!, byteCount: byteCount) }
            return true
        }
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

    private func layeredEncoded(_ pixels: [UInt8], width: Int, height: Int,
                                stock: FilmStock, options: FotufilmEngine.Options,
                                frameIndex: UInt64, srgb: Bool) -> [UInt8]? {
        var linear = [Float](repeating: 1, count: width*height*4)
        for i in 0..<width*height {
            let alpha = Float(pixels[i*4+3])/255
            let divisor: Float = alpha > 0 ? alpha*255 : 255
            let rgb = SIMD3<Float>((0..<3).map { ColorScience.srgbToLinear(Float(pixels[i*4+$0])/divisor) })
            let scene = srgb ? ColorScience.linearSRGBToRec2020(rgb) : ColorScience.linearDisplayP3ToRec2020(rgb)
            for c in 0..<3 { linear[4*i+c] = scene[c] }; linear[4*i+3] = alpha
        }
        do {
            let developed = try LayeredMetalTransport.process(linear, width: width, height: height,
                stock: stock, options: options, frameIndex: frameIndex)
            var bytes = pixels
            for i in 0..<width*height {
                var rgb = SIMD3(developed[4*i], developed[4*i+1], developed[4*i+2])
                if options.stage == .texture { rgb = ColorScience.linearRec2020ToDisplayP3(rgb) }
                if srgb { rgb = ColorScience.linearDisplayP3ToSRGB(rgb) }
                let alpha = Float(pixels[i*4+3])/255
                for c in 0..<3 {
                    let value = ColorScience.linearToSrgb(ColorScience.displayShoulder(
                        rgb[c], knee: options.sdrShoulderKnee(for: stock))) * alpha
                    bytes[4*i+c] = UInt8(min(max((255*value).rounded(),0),255))
                }
            }
            return bytes
        } catch { print(error.localizedDescription); return nil }
    }
}
#endif
