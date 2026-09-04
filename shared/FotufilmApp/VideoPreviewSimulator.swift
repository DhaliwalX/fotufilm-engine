import AVFoundation
import Accelerate
import Combine
import CoreGraphics
import Foundation
import Metal
import QuartzCore

#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmMetal)
import FotufilmMetal
#endif
#if canImport(FotufilmImaging)
import FotufilmImaging
#endif

/// Live film-simulated playback: playback and scrubbing pull reduced-resolution frames out of the
/// AVPlayer through an AVPlayerItemVideoOutput, develop each through the same fused Halide Metal
/// schedule the stills and the export use, and publish the print as a Metal texture for the preview
/// to draw.
final class VideoPreviewSimulator: NSObject, ObservableObject, @unchecked Sendable {
    /// Latest developed frame, exchanged with the preview under a lock.
    final class FrameStore {
        private let lock = NSLock()
        private var texture: MTLTexture?
        func publish(_ new: MTLTexture) {
            lock.lock(); texture = new; lock.unlock()
        }
        func latest() -> MTLTexture? {
            lock.lock(); defer { lock.unlock() }
            return texture
        }
    }
    let frames = FrameStore()

    @Published private(set) var hasFrame = false

    private(set) var displayOrientation = CGImagePropertyOrientation.up

    /// Live develop resolution, user selectable.
    enum Quality: String, CaseIterable, Identifiable {
        case draft, standard, fine, full

        var id: String { rawValue }

        /// What a quality menu offers.
        static var selectable: [Quality] {
            #if os(macOS)
            allCases
            #else
            [.draft, .standard, .fine]
            #endif
        }

        var title: String {
            switch self {
            case .draft: return "Draft"
            case .standard: return "Standard"
            case .fine: return "Fine"
            case .full: return "Full · 4K"
            }
        }

        var icon: String {
            switch self {
            case .draft: return "dial.low.fill"
            case .standard: return "dial.medium.fill"
            case .fine: return "dial.high.fill"
            case .full: return "4k.tv.fill"
            }
        }

        /// Long side of the frames requested from the video output.
        var longSide: Double {
            switch self {
            case .draft: return 640
            case .standard: return 1280
            case .fine: return 1920
            case .full: return 3840
            }
        }
    }

    private let queue = DispatchQueue(label: "fotufilm.video.preview")
    private var videoOutput: AVPlayerItemVideoOutput?
    /// The attached item and its frame geometry, kept so a quality change can swap the frame tap
    /// without reloading the track.
    private weak var item: AVPlayerItem?
    private var frameSize = CGSize.zero
    private var sourceEncoding = VideoSourceEncoding.standard
    private var attachGeneration: UInt64 = 0
    private var deepTap = false
    private var inFlight = false

    private struct Develop {
        var engine = HalideMetalFilmRenderer.shared
        var device = MTLCreateSystemDefaultDevice()
        var commandQueue: MTLCommandQueue?
        var input: MTLBuffer?
        var output: MTLBuffer?
        /// Where the deep path's print is encoded for the screen.
        var encoded: MTLBuffer?
        var textures: [MTLTexture] = []
        var nextTexture = 0
        var width = 0
        var height = 0
        var frameIndex: UInt64 = 0
        /// Stock, format and frame size of every schedule already prepared
        /// for this resource generation.
        var preparedKeys: Set<String> = []
        var stock: FilmStock?
        var stockID = ""
        var formatID = ""
        var options = FotufilmEngine.Options()
        /// Whether `input` still holds a decoded frame, so a stock or
        /// character change while paused can redevelop it in place.
        var hasSourceFrame = false
        /// How arriving frames are to be read; log encodings run through a
        /// converter sized to the current tap resolution.
        var encoding = VideoSourceEncoding.standard
        /// Tagged standard-video color. Explicit camera encodings use their own converter.
        var sourceColor = VideoSourceColor.colorManagedSDR
        /// One exposure placement for processed standard HDR. The pixels remain scene-linear.
        var sourceExposureGain: Float = 1
        var logConverter: LogConverter?
        /// The clip's stated body and white balance, read once at attach for the log
        /// converter's profile correction; nil when the file says nothing, which leaves the
        /// conversion untouched.
        var camera: CameraIdentity?
        var sceneCCT: Float?
        /// Which path this clip's frames take through the engine, asked of `VideoDecodeDepth`
        /// exactly as the export asks it — the depth of the decode and the schedule that develops
        /// it.
        var road = VideoDecodeDepth.Road(deepInput: false,
                                         realtimeSchedule: true)
        /// Whether the frames actually arriving are the deep container.
        var deep = false
        /// Whether the source frame is published in place of the print, for
        /// as long as the canvas is held down.
        var showsSource = false
        /// Which attach these facts came from. Two attaches commit in order on the main actor,
        /// but the blocks that tell the develop about them are enqueued from separate tasks and
        /// can arrive the other way round; this drops the loser rather than letting it describe
        /// a reading the tap is no longer watching.
        var attachGeneration: UInt64 = 0

        var sceneHeadroom: Float {
            encoding.cameraEncoding?.declaredHeadroom
                ?? (encoding == .standard ? sourceColor.sceneHeadroom : 1)
        }
    }
    private var develop = Develop()

    /// Attaches the reduced-resolution frame tap to the player's item. The depth it asks for is
    /// `VideoDecodeDepth`'s verdict on the source, which is the same call the export makes about
    /// the same file.
    ///
    /// Re-entrant on the encoding, because everything the tap is built from follows from it: the
    /// pixel format, the depth, the colour-managed composition and the range the container
    /// declares. Choosing a different reading of a loaded clip rebuilds the tap; asking again for
    /// the reading already attached does nothing.
    func attach(to player: AVPlayer, asset: AVAsset, quality: Quality,
                encoding: VideoSourceEncoding = .standard) async {
        guard VideoPreviewAttachment.rebuilds(
                attached: videoOutput != nil, previousReading: sourceEncoding,
                reading: encoding),
              let track = try? await asset.loadTracks(withMediaType: .video).first,
              let loadedSize = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform)
        else { return }
        let size = CGSize(width: abs(loadedSize.width),
                          height: abs(loadedSize.height))
        guard size.width > 0, size.height > 0 else { return }
        let orientation = VideoPipeline.orientation(for: transform)
        // `hdr: false` because this surface is an SDR one, so the depth here
        // is the source's alone.
        let formats = (try? await track.load(.formatDescriptions)) ?? []
        let sourceColor = encoding.requiresExplicitDecode
            ? VideoSourceColor.colorManagedSDR
            : VideoSourceColor.tagged(in: formats)
        let road = VideoDecodeDepth.road(
            hdr: false, log: encoding.requiresExplicitDecode,
            sourceHDR: sourceColor.isHDR, sourceFormats: formats)
        #if targetEnvironment(simulator)
        let composition: AVMutableVideoComposition? = nil
        #else
        let composition = encoding.requiresExplicitDecode || sourceColor.isHDR
            ? nil : await Self.sdrComposition(for: asset)
        #endif
        let capture = encoding.requiresExplicitDecode
            ? await VideoPipeline.captureMetadata(of: asset)
            : VideoPipeline.VideoCaptureMetadata()
        let sourceExposureGain = encoding == .standard && sourceColor.isHDR
            ? await VideoPipeline.standardHDRExposureGain(
                of: asset, sourceColor: sourceColor)
            : 1
        // The tap is built first and the develop is told second, so a reading that never reaches
        // the player never reaches the engine either.
        let usable = composition.map {
            $0.renderSize.width > 0 && $0.renderSize.height > 0
        } ?? false
        // Everything the tap and the develop are built from, decided in one place.
        let plan = VideoPreviewAttachment.plan(
            attached: videoOutput != nil, previousReading: sourceEncoding,
            reading: encoding, composition: usable, deepInput: road.deepInput,
            declaredHeadroom: encoding.cameraEncoding?.declaredHeadroom
                ?? (sourceColor.isHDR ? sourceColor.sceneHeadroom : nil))
        let generation = await MainActor.run { () -> UInt64? in
            // Asked again under the actor, because two attaches can have passed the guard
            // above before either of them committed.
            guard VideoPreviewAttachment.rebuilds(
                    attached: videoOutput != nil, previousReading: sourceEncoding,
                    reading: encoding),
                  let item = player.currentItem else { return nil }
            // Whatever was watching the previous reading comes off with it: the tap's pixel
            // format and the item's composition both belong to that interpretation.
            if let videoOutput { self.item?.remove(videoOutput) }
            self.item = item
            self.sourceEncoding = encoding
            if plan.usesComposition, let composition {
                item.videoComposition = composition
                frameSize = composition.renderSize
                displayOrientation = .up
            } else {
                // The tap is handed the decoder's own frames on this path, so any composition a
                // previous reading left on the item is cleared, or they would arrive through it.
                item.videoComposition = nil
                frameSize = size
                displayOrientation = orientation
            }
            deepTap = plan.deepTap
            let output = Self.makeOutput(frameSize: frameSize, quality: quality,
                                         deep: deepTap)
            item.add(output)
            videoOutput = output
            attachGeneration &+= 1
            return attachGeneration
        }
        guard let generation else { return }
        queue.async {
            guard VideoPreviewAttachment.accepts(
                    generation: generation,
                    applied: self.develop.attachGeneration) else { return }
            self.develop.attachGeneration = generation
            self.develop.encoding = encoding
            self.develop.sourceColor = sourceColor
            self.develop.sourceExposureGain = sourceExposureGain
            self.develop.road = road
            self.develop.camera = capture.camera
            self.develop.sceneCCT = capture.sceneCCT
            // The frame in the input buffer was decoded under the reading being replaced, and
            // the converter that would decode the next one was built for it. Both go, along with
            // the schedules prepared for the path that is being left.
            self.develop.logConverter = nil
            self.develop.hasSourceFrame = false
            self.develop.preparedKeys.removeAll(keepingCapacity: true)
            // The film-side scene light rides the same capture fact; the engine's gate
            // decides whether it does anything.
            self.develop.options.sceneIlluminantKelvin = capture.sceneCCT
            // As does the range the container declares (HLG's bounded ceiling); a camera
            // log declares nothing and rides the negative's own path.
            self.develop.options.sceneHeadroom = plan.sceneHeadroom
        }
    }

    private static func sdrComposition(
        for asset: AVAsset
    ) async -> AVMutableVideoComposition? {
        guard let composition = try? await AVMutableVideoComposition
            .videoComposition(withPropertiesOf: asset) else { return nil }
        composition.colorPrimaries = AVVideoColorPrimaries_P3_D65
        composition.colorTransferFunction = VideoPipeline.sRGBTransferFunction
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        return composition
    }

    /// Swaps the frame tap for one at the new quality's resolution.
    func setQuality(_ quality: Quality) {
        guard let item, frameSize.width > 0 else { return }
        if let videoOutput { item.remove(videoOutput) }
        let output = Self.makeOutput(frameSize: frameSize, quality: quality,
                                     deep: deepTap)
        item.add(output)
        videoOutput = output
    }

    private static func makeOutput(
        frameSize: CGSize, quality: Quality, deep: Bool
    ) -> AVPlayerItemVideoOutput {
        let scale = min(1, quality.longSide / max(frameSize.width,
                                                 frameSize.height))
        return AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String:
                VideoPipeline.decodePixelFormat(deep: deep),
            kCVPixelBufferWidthKey as String:
                max(2, Int((frameSize.width * scale / 2).rounded()) * 2),
            kCVPixelBufferHeightKey as String:
                max(2, Int((frameSize.height * scale / 2).rounded()) * 2),
        ])
    }

    /// Publishes the source frame instead of the print — the clip as the camera gave it, on the
    /// same clock, for as long as the canvas is held down.
    func showSource(_ showing: Bool) {
        queue.async {
            guard self.develop.showsSource != showing else { return }
            self.develop.showsSource = showing
            self.renderCurrentInput()
        }
    }

    /// Points the develop at a new stock, format, or adjustment setting, and redevelops the frame
    /// already on the queue so a paused preview reacts without waiting for the (much slower)
    /// full-resolution pass.
    func update(stock: FilmStock, stockID: String, formatID: String,
                options: FotufilmEngine.Options) {
        queue.async {
            self.develop.stock = stock
            self.develop.stockID = stockID
            self.develop.formatID = formatID
            self.develop.options = options
            // An explicit mixture takes the delivery ratio, the same completion the
            // export and the paused frame apply.
            self.develop.options.completeDeliveryMottle()
            // The prepare identity is stock|format|size; an options change moves the
            // feature mask inside it, so the next develop must re-prepare.
            self.develop.preparedKeys.removeAll(keepingCapacity: true)
            // The caller's options are per-edit; the scene light and the declared range are
            // the clip's own facts, re-attached here so a settings change cannot shed them.
            self.develop.options.sceneIlluminantKelvin = self.develop.sceneCCT
            self.develop.options.sceneHeadroom = VideoPreviewAttachment
                .sceneHeadroom(declaredBy: self.develop.sceneHeadroom)
            self.renderCurrentInput()
        }
    }

    /// Called from the preview's draw loop.
    func poll() {
        guard let videoOutput, !inFlight else { return }
        let itemTime = videoOutput.itemTime(forHostTime: CACurrentMediaTime())
        guard itemTime.isValid,
              videoOutput.hasNewPixelBuffer(forItemTime: itemTime),
              let pixels = videoOutput.copyPixelBuffer(
                  forItemTime: itemTime, itemTimeForDisplay: nil)
        else { return }
        inFlight = true
        queue.async {
            self.developLive(pixels)
            DispatchQueue.main.async { self.inFlight = false }
        }
    }

    /// Develops the paused frame at full resolution on the same queue the live frames use, so the
    /// two never interleave inside the engine.
    func developFullResolutionImage(
        _ image: CGImage, stock: FilmStock,
        options: FotufilmEngine.Options, frameIndex: UInt64
    ) async -> (print: CGImage, source: CGImage)? {
        await withCheckedContinuation { continuation in
            queue.async {
                // The clip's own facts, exactly as the streaming develop attaches them.
                var options = options
                options.sceneIlluminantKelvin = self.develop.sceneCCT
                options.sceneHeadroom = VideoPreviewAttachment.sceneHeadroom(
                    declaredBy: self.develop.sceneHeadroom)
                // The same completion the streaming path applied, so the paused
                // frame is the playing one at either depth.
                options.completeDeliveryMottle()
                // A still that arrived deeper than eight bits took the deep decode.
                if image.bitsPerComponent > 8,
                   let developed = Self.developDeepStill(
                       image, stock: stock, options: options,
                       frameIndex: frameIndex) {
                    self.develop.preparedKeys.removeAll(keepingCapacity: true)
                    continuation.resume(returning: developed)
                    return
                }
                let developed = VideoPipeline.developPreview(
                    image, stock: stock, options: options,
                    frameIndex: frameIndex)
                self.develop.preparedKeys.removeAll(keepingCapacity: true)
                continuation.resume(returning: developed.map { ($0, image) })
            }
        }
    }

    private static func developDeepStill(
        _ image: CGImage, stock: FilmStock,
        options: FotufilmEngine.Options, frameIndex: UInt64
    ) -> (print: CGImage, source: CGImage)? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let engine = HalideMetalFilmRenderer.shared,
              let device = MTLCreateSystemDefaultDevice(),
              let p3 = CGColorSpace(name: CGColorSpace.displayP3)
        else { return nil }
        let components = width * height * 4

        let drawSpace = p3
        // 16-bit CoreGraphics carries alpha premultiplied or not at all; `noneSkipLast` simply
        // fails to build a context at this depth.
        var codes = [UInt16](repeating: 0, count: components)
        let drew = codes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(
                data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 16, bytesPerRow: width * 8, space: drawSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder16Little.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0,
                                           width: width, height: height))
            return true
        }
        guard drew,
              let input = device.makeBuffer(length: components * 4,
                                            options: .storageModeShared),
              let output = device.makeBuffer(length: components * 4,
                                             options: .storageModeShared)
        else { return nil }

        let linear = input.contents().assumingMemoryBound(to: Float.self)
        let filled = codes.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            let source = base.assumingMemoryBound(to: UInt16.self)
            VideoPipeline.unormToLinear.withUnsafeBufferPointer { table in
                let lut = table.baseAddress!
                let rows = VideoPipeline.conversionChunkRows
                let chunks = (height + rows - 1) / rows
                DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                    let first = chunk * rows
                    let last = min(height, first + rows)
                    for row in first..<last {
                        let codes = source + row * width * 4
                        let out = linear + row * width * 4
                        for x in 0..<width {
                            for channel in 0..<3 {
                                out[x * 4 + channel] =
                                    lut[Int(codes[x * 4 + channel])]
                            }
                            out[x * 4 + 3] = 1
                        }
                    }
                }
            }
            return true
        }
        guard filled else { return nil }

        engine.prepare(stock: stock, options: options,
                       frameWidth: width, frameHeight: height)
        // The reference schedule outright: this path is only taken for a deep source, and a deep
        // source's export runs the reference schedule.
        guard engine.processLinearFloat(
            input: input, output: output, width: width, height: height,
            stock: stock, options: options, frameIndex: frameIndex,
            realtime: false) else { return nil }

        // The print takes the paper's shoulder; the source held against it takes the plain curve,
        // being the clip and not a print — and it comes back from the same buffer the emulsion was
        // shown, so the compare is against what was actually developed.
        guard let printed = Self.encodeDeveloped(
                  output, width: width, height: height,
                  transfer: .shoulderedSRGB, colorSpace: p3,
                  shoulderKnee: FilmSDRDelivery.shoulderKnee(
                    isReversal: stock.isReversal)),
              let source = Self.encodeDeveloped(
                  input, width: width, height: height,
                  transfer: .srgb, colorSpace: p3) else { return nil }
        return (printed, source)
    }

    private static func encodeDeveloped(
        _ buffer: MTLBuffer, width: Int, height: Int,
        transfer: PrintEncoding.Transfer, colorSpace: CGColorSpace,
        shoulderKnee: Float = FilmSDRDelivery.standardShoulderKnee
    ) -> CGImage? {
        let components = width * height * 4
        let pixels = UnsafeMutableBufferPointer<UInt16>
            .allocate(capacity: components)
        pixels.initialize(repeating: 0)
        PrintEncoding.encodeRows(
            UnsafeBufferPointer(
                start: buffer.contents().assumingMemoryBound(to: Float.self),
                count: components),
            rows: 0..<height, width: width, into: pixels,
            transfer: transfer, shoulderKnee: shoulderKnee)
        return PrintEncoding.makeImage(takingOwnershipOf: pixels,
                                       width: width, height: height,
                                       colorSpace: colorSpace)
    }

    /// Develops a paused deep frame from the scene-linear signal the decoder gave up, on the same
    /// queue the live frames use. Explicit camera encodings and tagged HDR therefore avoid a
    /// display render, an eight-bit floor, and a gamut round trip before the emulsion.
    func developFullResolutionFrame(
        _ frame: VideoPipeline.SceneLinearFrame, stock: FilmStock,
        options: FotufilmEngine.Options, frameIndex: UInt64
    ) async -> (print: CGImage, source: CGImage)? {
        await withCheckedContinuation { continuation in
            queue.async {
                // The clip's own facts, exactly as the streaming develop attaches them.
                var options = options
                options.sceneIlluminantKelvin = self.develop.sceneCCT
                options.sceneHeadroom = self.develop.sceneHeadroom
                // The same completion the streaming path applied, so a held deep frame is the
                // playing one here too.
                options.completeDeliveryMottle()
                let developed = Self.developSceneLinearStill(
                    frame, stock: stock, options: options,
                    frameIndex: frameIndex)
                self.develop.preparedKeys.removeAll(keepingCapacity: true)
                continuation.resume(returning: developed)
            }
        }
    }

    private static func developSceneLinearStill(
        _ frame: VideoPipeline.SceneLinearFrame, stock: FilmStock,
        options: FotufilmEngine.Options, frameIndex: UInt64
    ) -> (print: CGImage, source: CGImage)? {
        let width = frame.width
        let height = frame.height
        let components = width * height * 4
        guard width > 0, height > 0, frame.pixels.count >= components,
              let engine = HalideMetalFilmRenderer.shared,
              let device = MTLCreateSystemDefaultDevice(),
              let p3 = CGColorSpace(name: CGColorSpace.displayP3),
              let input = device.makeBuffer(length: components * 4,
                                            options: .storageModeShared),
              let output = device.makeBuffer(length: components * 4,
                                             options: .storageModeShared)
        else { return nil }
        // Straight in: the decode already landed in the engine's float layout.
        frame.pixels.withUnsafeBytes { source in
            input.contents().copyMemory(from: source.baseAddress!,
                                        byteCount: components * 4)
        }

        engine.prepare(stock: stock, options: options,
                       frameWidth: width, frameHeight: height)
        // The reference schedule outright, as the deep still path runs it: a paused frame is not
        // paced to the clock, and its export would run the reference schedule too.
        guard engine.processLinearFloat(
            input: input, output: output, width: width, height: height,
            stock: stock, options: options, frameIndex: frameIndex,
            realtime: false) else { return nil }

        guard let printed = encodeDeveloped(
                  output, width: width, height: height,
                  transfer: .shoulderedSRGB, colorSpace: p3,
                  shoulderKnee: FilmSDRDelivery.shoulderKnee(
                    isReversal: stock.isReversal)),
              let source = encodeDeveloped(
                  input, width: width, height: height,
                  transfer: .srgb, colorSpace: p3) else { return nil }
        return (printed, source)
    }

    private func developLive(_ pixels: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        // What arrived, not what was asked for.
        let deep = CVPixelBufferGetPixelFormatType(pixels)
            == kCVPixelFormatType_128RGBAFloat
        guard ensureResources(width: width, height: height, deep: deep),
              let input = develop.input else { return }

        // The tap asks for full float (`makeOutput`), so the curve is evaluated per pixel rather
        // than through the 256-entry table.
        if develop.encoding.requiresExplicitDecode {
            if develop.logConverter?.width != width
                || develop.logConverter?.height != height {
                develop.logConverter = LogConverter(
                    encoding: develop.encoding, width: width, height: height,
                    camera: develop.camera, sceneCCT: develop.sceneCCT)
            }
            let deep = CVPixelBufferGetPixelFormatType(pixels)
                == kCVPixelFormatType_128RGBAFloat
            guard let converter = develop.logConverter,
                  deep ? converter.convertLinear(pixels, into: input)
                       : converter.convert(pixels, into: input) else { return }
            develop.hasSourceFrame = true
            renderCurrentInput()
            return
        }

        // A deep colour-managed frame is already RGBA in full float: the whole
        // conversion is the sRGB transfer decode.
        if deep {
            guard VideoPipeline.fillLinearFloatInput(
                pixels, into: input, width: width, height: height,
                sourceColor: develop.sourceColor,
                exposureGain: develop.sourceExposureGain) else { return }
            develop.hasSourceFrame = true
            renderCurrentInput()
            return
        }

        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        guard let base = CVPixelBufferGetBaseAddress(pixels) else {
            CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
            return
        }
        var source = vImage_Buffer(
            data: base,
            height: vImagePixelCount(height), width: vImagePixelCount(width),
            rowBytes: CVPixelBufferGetBytesPerRow(pixels))
        var destination = vImage_Buffer(
            data: input.contents(),
            height: vImagePixelCount(height), width: vImagePixelCount(width),
            rowBytes: width * 4)
        let toRGBA: [UInt8] = [2, 1, 0, 3]
        vImagePermuteChannels_ARGB8888(&source, &destination, toRGBA,
                                       vImage_Flags(kvImageNoFlags))
        CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
        develop.hasSourceFrame = true
        renderCurrentInput()
    }

    private func renderCurrentInput() {
        guard develop.hasSourceFrame,
              let engine = develop.engine, let stock = develop.stock,
              let input = develop.input, let output = develop.output,
              let commandQueue = develop.commandQueue else { return }
        let width = develop.width
        let height = develop.height
        let deep = develop.deep

        let bypassing = develop.showsSource
        if !bypassing {
            let options = develop.options
            prepareIfNeeded(engine, stock: stock, key: develop.stockID,
                            formatID: develop.formatID, options: options,
                            width: width, height: height)

            develop.frameIndex &+= 1
            // The schedule comes off the path, not off this surface: the two developments of one
            // clip — the one being scrubbed and the one being exported — have to be the same
            // develop, and it is the source that decides which.
            let developed = deep
                ? engine.processLinearFloat(
                    input: input, output: output,
                    width: width, height: height,
                    stock: stock, options: options,
                    frameIndex: develop.frameIndex,
                    realtime: develop.road.realtimeSchedule)
                : engine.processRGBA8(input: input, output: output,
                                      width: width, height: height,
                                      stock: stock, options: options,
                                      frameIndex: develop.frameIndex)
            guard developed else { return }
        }

        // What goes to the screen.
        let sourceBuffer: MTLBuffer
        let sourceBytesPerRow: Int
        if deep {
            guard let encoded = develop.encoded else { return }
            let components = width * height * 4
            PrintEncoding.encodeRows(
                UnsafeBufferPointer(
                    start: (bypassing ? input : output).contents()
                        .assumingMemoryBound(to: Float.self),
                    count: components),
                rows: 0..<height, width: width,
                into: UnsafeMutableBufferPointer(
                    start: encoded.contents()
                        .assumingMemoryBound(to: UInt16.self),
                    count: components),
                transfer: bypassing ? .srgb : .shoulderedSRGB)
            sourceBuffer = encoded
            sourceBytesPerRow = width * 8
        } else {
            sourceBuffer = bypassing ? input : output
            sourceBytesPerRow = width * 4
        }

        let texture = develop.textures[develop.nextTexture]
        develop.nextTexture = (develop.nextTexture + 1) % develop.textures.count
        guard let commands = commandQueue.makeCommandBuffer(),
              let blit = commands.makeBlitCommandEncoder() else { return }
        blit.copy(from: sourceBuffer, sourceOffset: 0,
                  sourceBytesPerRow: sourceBytesPerRow,
                  sourceBytesPerImage: sourceBytesPerRow * height,
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: texture, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        frames.publish(texture)
        publishFirstFrameIfNeeded()
    }

    private func publishFirstFrameIfNeeded() {
        guard !hasFrame else { return }
        DispatchQueue.main.async {
            if !self.hasFrame { self.hasFrame = true }
        }
    }

    private func prepareIfNeeded(_ engine: HalideMetalFilmRenderer,
                                 stock: FilmStock, key: String,
                                 formatID: String,
                                 options: FotufilmEngine.Options,
                                 width: Int, height: Int) {
        let identity = "\(key)|\(formatID)|\(width)x\(height)"
        guard develop.preparedKeys.insert(identity).inserted else { return }
        engine.prepare(stock: stock, options: options,
                       frameWidth: width, frameHeight: height)
    }

    private func ensureResources(width: Int, height: Int, deep: Bool) -> Bool {
        if develop.width == width, develop.height == height,
           develop.deep == deep, develop.input != nil { return true }
        guard let device = develop.device else { return false }
        let pixels = width * height
        let length = pixels * (deep ? 16 : 4)
        develop.commandQueue = develop.commandQueue ?? device.makeCommandQueue()
        develop.input = device.makeBuffer(length: length, options: .storageModeShared)
        develop.output = device.makeBuffer(length: length, options: .storageModeShared)
        develop.encoded = deep
            ? device.makeBuffer(length: pixels * 8, options: .storageModeShared)
            : nil
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: deep ? .rgba16Unorm : .rgba8Unorm,
            width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        develop.textures = (0..<2).compactMap { _ in
            device.makeTexture(descriptor: descriptor)
        }
        develop.width = width
        develop.height = height
        develop.deep = deep
        develop.preparedKeys.removeAll(keepingCapacity: true)
        develop.hasSourceFrame = false
        return develop.input != nil && develop.output != nil
            && (!deep || develop.encoded != nil)
            && develop.textures.count == 2
    }
}
