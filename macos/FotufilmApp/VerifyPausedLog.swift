import AVFoundation
import AppKit
import CoreGraphics
import Metal

#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmMetal)
import FotufilmMetal
#endif
#if canImport(FotufilmImaging)
import FotufilmImaging
#endif

/// Holds the paused develop of a log clip against the playing one on a synthesized S-Log3 ramp.
/// The two paths decode the same frame and must reach the emulsion with the same numbers: a held
/// frame that disagrees with the frame under the playhead is the bug this guards.
enum VerifyPausedLog {

    @discardableResult
    static func runIfRequested() -> Bool {
        guard ProcessInfo.processInfo.arguments.contains("--verify-paused-log")
        else { return false }
        Task {
            let encoding = VideoSourceEncoding.slog3
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("verify-paused-log.mov")
            try? FileManager.default.removeItem(at: url)
            guard await write(to: url) else {
                print("verify-paused-log: could not write the clip")
                exit(1)
            }
            let asset = AVURLAsset(url: url)
            let seconds = 0.2
            let edge: CGFloat = 1024
            guard let stockID = FilmStock.presetIDs.first,
                  let stock = FilmStock.named(stockID) else {
                print("verify-paused-log: no stock")
                exit(1)
            }
            var options = FotufilmEngine.Options()
            options.format = FilmFormat.native(forStockID: stockID)
            let simulator = VideoPreviewSimulator()

            // What playback feeds the emulsion, and what the new paused path feeds it.
            guard let scene = await VideoPipeline.sceneLinearFrame(
                of: asset, at: seconds, longestSide: edge, encoding: encoding)
            else {
                print("verify-paused-log: no scene-linear frame")
                exit(1)
            }
            // The schedule playback actually runs for this clip, asked the way the simulator asks.
            let formats = (try? await asset.loadTracks(withMediaType: .video)
                .first?.load(.formatDescriptions)) ?? []
            let sourceColor = encoding == .standard
                ? VideoSourceColor.tagged(in: formats)
                : VideoSourceColor.colorManagedSDR
            let road = VideoDecodeDepth.road(
                hdr: false, log: encoding.requiresExplicitDecode,
                sourceHDR: sourceColor.isHDR, sourceFormats: formats)
            print(String(format:
                "verify-paused-log: playback road deepInput %@ realtime %@",
                road.deepInput ? "yes" : "no",
                road.realtimeSchedule ? "yes" : "no"))
            guard let playing = playbackPrint(
                scene, stock: stock, options: options,
                realtime: road.realtimeSchedule) else {
                print("verify-paused-log: playback develop failed")
                exit(1)
            }
            // What the schedule is worth, so a future divergence is not mistaken for noise.
            if let otherSchedule = playbackPrint(
                scene, stock: stock, options: options,
                realtime: !road.realtimeSchedule) {
                let gap = compare(otherSchedule, playing)
                print(String(format:
                    "verify-paused-log: opposite schedule would shift it by "
                        + "max %.4f  mean %.5f", gap.max, gap.mean))
            }
            guard let paused = await simulator.developFullResolutionFrame(
                scene, stock: stock, options: options, frameIndex: 0) else {
                print("verify-paused-log: new paused develop failed")
                exit(1)
            }

            // Compare the previous paused-frame path: display-rendered, 8-bit, image-backed.
            guard let image = await VideoPipeline.sourceFrame(
                    of: asset, at: seconds, longestSide: edge,
                    encoding: encoding),
                  let old = await simulator.developFullResolutionImage(
                    image, stock: stock, options: options, frameIndex: 0)
            else {
                print("verify-paused-log: old paused develop failed")
                exit(1)
            }

            let new = compare(paused.print, playing)
            let was = compare(old.print, playing)
            print(String(format:
                "verify-paused-log: new paused vs playing  max %.4f  mean %.5f",
                new.max, new.mean))
            print(String(format:
                "verify-paused-log: old paused vs playing  max %.4f  mean %.5f",
                was.max, was.mean))

            // The same hold, for a clip carrying the Mottle control's mixture. The streaming
            // path completes an explicit share with the delivery ratio before it develops, so
            // a held frame that skips that completion lays the sheet's finer population and
            // parts from the frame under the playhead — grain the grade is judged on.
            var asked = options
            asked.grainMottleShare = 0.35
            var playingMix = asked
            playingMix.completeDeliveryMottle()
            var mottleHeld = false
            if let mixPlaying = playbackPrint(scene, stock: stock,
                                              options: playingMix,
                                              realtime: road.realtimeSchedule),
               let mixPaused = await simulator.developFullResolutionFrame(
                   scene, stock: stock, options: asked, frameIndex: 0) {
                let mix = compare(mixPaused.print, mixPlaying)
                print(String(format:
                    "verify-paused-log: mottled paused vs playing  max %.4f  mean %.5f",
                    mix.max, mix.mean))
                mottleHeld = mix.max <= 0.002
            } else {
                print("verify-paused-log: mottled develop failed")
            }

            // Deep playback and paused rendering must both use the reference schedule.
            let scheduleUnified = !road.realtimeSchedule
            if !scheduleUnified {
                print("verify-paused-log: playback wants the realtime schedule "
                    + "but the paused develop runs the reference one FAILED")
            }
            let turned = await checkOrientation(encoding: encoding, edge: edge)
            let ok = new.max <= 0.002 && was.max > 0.02 && turned
                && scheduleUnified && mottleHeld
            print(ok ? "verify-paused-log PASS" : "verify-paused-log FAIL")
            exit(ok ? 0 : 1)
        }
        return true
    }

    private static func checkOrientation(
        encoding: VideoSourceEncoding, edge: CGFloat
    ) async -> Bool {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("verify-paused-log-turned.mov")
        try? FileManager.default.removeItem(at: url)
        guard await write(to: url, marked: true,
                          transform: CGAffineTransform(rotationAngle: .pi / 2))
        else {
            print("verify-paused-log: could not write the rotated clip")
            return false
        }
        let asset = AVURLAsset(url: url)
        guard let scene = await VideoPipeline.sceneLinearFrame(
                of: asset, at: 0.2, longestSide: edge, encoding: encoding),
              let display = await VideoPipeline.sourceFrame(
                of: asset, at: 0.2, longestSide: edge, encoding: encoding),
              let displayBytes = bytes(of: display)
        else {
            print("verify-paused-log: rotated frames would not decode")
            return false
        }
        func centroid(_ value: (Int, Int) -> Double,
                      width: Int, height: Int) -> (x: Double, y: Double)? {
            var peak = 0.0
            for y in 0..<height {
                for x in 0..<width { peak = Swift.max(peak, value(x, y)) }
            }
            guard peak > 0 else { return nil }
            var sumX = 0.0, sumY = 0.0, weight = 0.0
            for y in 0..<height {
                for x in 0..<width where value(x, y) >= peak * 0.8 {
                    sumX += Double(x); sumY += Double(y); weight += 1
                }
            }
            guard weight > 0 else { return nil }
            return (sumX / weight / Double(width - 1),
                    sumY / weight / Double(height - 1))
        }
        guard let sceneMark = centroid({ x, y in
                  Double(scene.pixels[(y * scene.width + x) * 4])
              }, width: scene.width, height: scene.height),
              let displayMark = centroid({ x, y in
                  Double(displayBytes[(y * display.width + x) * 4])
              }, width: display.width, height: display.height)
        else {
            print("verify-paused-log: no marker found in the rotated frame")
            return false
        }
        let sameShape = scene.width == display.width
            && scene.height == display.height
        let drift = Swift.max(abs(sceneMark.x - displayMark.x),
                              abs(sceneMark.y - displayMark.y))
        let ok = sameShape && drift <= 0.05
        print(String(format:
            "verify-paused-log: rotated %dx%d vs %dx%d, marker (%.2f, %.2f) "
                + "vs (%.2f, %.2f) drift %.3f %@",
            scene.width, scene.height, display.width, display.height,
            sceneMark.x, sceneMark.y, displayMark.x, displayMark.y,
            drift, ok ? "ok" : "FAILED"))
        return ok
    }

    private static func playbackPrint(
        _ scene: VideoPipeline.SceneLinearFrame,
        stock: FilmStock, options: FotufilmEngine.Options,
        realtime: Bool
    ) -> CGImage? {
        let width = scene.width
        let height = scene.height
        let components = width * height * 4
        guard let engine = HalideMetalFilmRenderer.shared,
              let device = MTLCreateSystemDefaultDevice(),
              let p3 = CGColorSpace(name: CGColorSpace.displayP3),
              let input = device.makeBuffer(length: components * 4,
                                            options: .storageModeShared),
              let output = device.makeBuffer(length: components * 4,
                                             options: .storageModeShared)
        else { return nil }
        scene.pixels.withUnsafeBytes {
            input.contents().copyMemory(from: $0.baseAddress!,
                                        byteCount: components * 4)
        }
        engine.prepare(stock: stock, options: options,
                       frameWidth: width, frameHeight: height)
        guard engine.processLinearFloat(
            input: input, output: output, width: width, height: height,
            stock: stock, options: options, frameIndex: 0,
            realtime: realtime) else { return nil }
        let pixels = UnsafeMutableBufferPointer<UInt16>
            .allocate(capacity: components)
        pixels.initialize(repeating: 0)
        PrintEncoding.encodeRows(
            UnsafeBufferPointer(
                start: output.contents().assumingMemoryBound(to: Float.self),
                count: components),
            rows: 0..<height, width: width, into: pixels,
            transfer: .shoulderedSRGB)
        return PrintEncoding.makeImage(takingOwnershipOf: pixels,
                                       width: width, height: height,
                                       colorSpace: p3)
    }

    private static func compare(_ a: CGImage, _ b: CGImage)
        -> (max: Double, mean: Double) {
        guard let left = bytes(of: a), let right = bytes(of: b),
              left.count == right.count, !left.isEmpty else {
            return (1, 1)
        }
        var peak = 0.0
        var total = 0.0
        var counted = 0
        for index in 0..<left.count where index % 4 != 3 {
            let delta = abs(Double(left[index]) - Double(right[index])) / 255
            peak = Swift.max(peak, delta)
            total += delta
            counted += 1
        }
        return (peak, total / Double(counted))
    }

    private static func bytes(of image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.displayP3)
        else { return nil }
        var raw = [UInt8](repeating: 0, count: width * height * 4)
        let drew = raw.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(
                data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0,
                                           width: width, height: height))
            return true
        }
        return drew ? raw : nil
    }

    private static func write(
        to url: URL, marked: Bool = false,
        transform: CGAffineTransform = .identity
    ) async -> Bool {
        let width = 512
        let height = 288
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov)
        else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes4444,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_64RGBAHalf,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<12 {
            guard let pool = adaptor.pixelBufferPool else { return false }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                    == kCVReturnSuccess, let pixels = buffer else {
                return false
            }
            CVPixelBufferLockBaseAddress(pixels, [])
            if let base = CVPixelBufferGetBaseAddress(pixels) {
                let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
                for y in 0..<height {
                    let row = (base + y * rowBytes)
                        .assumingMemoryBound(to: UInt16.self)
                    for x in 0..<width {
                        var code: SIMD3<Float>
                        if marked {
                            // Dim everywhere but one corner of the stored frame, so the rotation
                            // has something unambiguous to carry.
                            let corner = x < width / 8 && y < height / 8
                            code = SIMD3(repeating: corner ? 0.95 : 0.1)
                        } else {
                            // A full sweep of log code values across the frame, tinted down the
                            // columns so the three channels never agree.
                            let t = Float(x) / Float(width - 1)
                            let tint = Float(y) / Float(height - 1) * 0.15
                            code = SIMD3<Float>(t, max(0, t - tint),
                                                min(1, t + tint))
                        }
                        for channel in 0..<3 {
                            row[x * 4 + channel] =
                                Float16(code[channel]).bitPattern
                        }
                        row[x * 4 + 3] = Float16(1).bitPattern
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            while !input.isReadyForMoreMediaData {
                try? await Task.sleep(for: .milliseconds(5))
            }
            let time = CMTime(value: CMTimeValue(frame), timescale: 30)
            guard adaptor.append(pixels, withPresentationTime: time) else {
                return false
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed
    }
}
