import AppKit
import AVFoundation
import CoreVideo
import Foundation
import Metal
import UniformTypeIdentifiers

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// A still's per-stage durations, when `FOTUFILM_STILL_TIMINGS` is set.
///
/// The render already measures every stage for the progress UI and this path throws the durations
/// away; keeping them is the only way to see where a still's wall clock goes without inferring it
/// from the whole process's.
@Sendable private func printStillStage(_ event: FilmRender.Event) {
    guard case .finished(let stage, let duration) = event else { return }
    print(String(format: "  %-10@ %8.1f ms", stage.rawValue as NSString, duration * 1000))
}

private func stillStageReporter() -> FilmRender.Reporter? {
    ProcessInfo.processInfo.environment["FOTUFILM_STILL_TIMINGS"] == nil
        ? nil : printStillStage
}

/// Headless end-to-end run of the offline video developer, for driving from the command line:
/// build/macos/Fotufilm.app/Contents/MacOS/Fotufilm \ --develop-video=/path/in.mov
/// [--develop-out=/path/out.mov] \ [--develop-fps=18] [--develop-stock=id] \
/// [--develop-codec=h264|hevc-main10|prores422-proxy|prores422-lt|prores422| \
/// prores422-hq|prores4444|prores4444-xq] \
/// [--develop-paper=ektacolor-edge|screen] \ [--develop-camera "Make Model"] [--develop-cct 3200]
/// Prints progress and exits with 0 on success, so a shell can assert on it.
enum HeadlessDevelop {
    @discardableResult
    static func developVideoIfRequested() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let argument = arguments.first(where: { $0.hasPrefix("--develop-video=") })
        else { return false }
        let input = URL(fileURLWithPath:
            String(argument.dropFirst("--develop-video=".count)))
        let output = arguments.first { $0.hasPrefix("--develop-out=") }
            .map { URL(fileURLWithPath: String($0.dropFirst("--develop-out=".count))) }
            ?? input.deletingPathExtension().appendingPathExtension("developed.mov")
        let frameRate = arguments.first { $0.hasPrefix("--develop-fps=") }
            .flatMap { Int($0.dropFirst("--develop-fps=".count)) }
        let codecArgument = arguments.first { $0.hasPrefix("--develop-codec=") }
            .map { String($0.dropFirst("--develop-codec=".count)) }
        let codec: VideoPipeline.ExportCodec? = codecArgument.flatMap { name in
            switch name {
            case "h264": return .h264
            case "hevc", "hevc-main10": return .hevc
            case "prores422-proxy": return .proRes422Proxy
            case "prores422-lt": return .proRes422LT
            case "prores422": return .proRes422
            case "prores422-hq": return .proRes422HQ
            case "prores4444": return .proRes4444
            case "prores4444-xq": return .proRes4444XQ
            default: return nil
            }
        }
        if let codecArgument, codec == nil {
            print("DevelopVideo failed: unknown codec '\(codecArgument)'.")
            exit(1)
        }
        let fast = arguments.contains("--develop-fast")
        // Deterministic overrides for the profile-correction path, so a harness can exercise
        // it without a clip that actually carries capture metadata: `--develop-camera` is
        // "Make Model" (first word the make, the rest the model), `--develop-cct` a scene
        // temperature in kelvin. Either form: `--develop-camera=…` or a separate argument.
        func flagValue(_ name: String) -> String? {
            if let joined = arguments.first(where: { $0.hasPrefix(name + "=") }) {
                return String(joined.dropFirst(name.count + 1))
            }
            if let index = arguments.firstIndex(of: name),
               arguments.indices.contains(index + 1) {
                return arguments[index + 1]
            }
            return nil
        }
        let camera: CameraIdentity? = flagValue("--develop-camera").flatMap { named in
            let trimmed = named.trimmingCharacters(in: .whitespaces)
            guard let split = trimmed.firstIndex(of: " ") else { return nil }
            let make = String(trimmed[..<split])
            let model = trimmed[trimmed.index(after: split)...]
                .trimmingCharacters(in: .whitespaces)
            guard !make.isEmpty, !model.isEmpty else { return nil }
            return CameraIdentity(make: make, model: model)
        }
        let sceneCCT = flagValue("--develop-cct").flatMap(Float.init)
        let encoding: VideoSourceEncoding = arguments
            .first { $0.hasPrefix("--develop-log=") }
            .map { String($0.dropFirst("--develop-log=".count)) }
            .flatMap { name in
                switch name {
                case "apple-log": return .appleLog
                case "slog3-cine": return .slog3Cine
                case "slog3": return .slog3
                case "slog2": return .slog2
                case "flog": return .flog
                case "flog2": return .flog2
                case "flog2-c": return .flog2C
                case "hlg": return .hlg
                default: return nil
                }
            } ?? .standard
        let paperArgument = arguments.first { $0.hasPrefix("--develop-paper=") }
            .map { String($0.dropFirst("--develop-paper=".count)) }
        // Unstated stays unstated: the stock names the medium it was designed for.
        let paper: PrintPaper? = paperArgument.flatMap(PrintPaper.preset(id:))
        if let paperArgument, PrintPaper.preset(id: paperArgument) == nil {
            print("DevelopVideo failed: unknown paper '\(paperArgument)'."
                  + " Choices: "
                  + PrintPaper.allCases.map(\.id).joined(separator: ", "))
            exit(1)
        }
        // Unstated defers to the app's own setting, which is what a harness reproducing what
        // the user would get should do. Naming one pins the delivery: an SDR clip for a
        // Rec.709 destination that would otherwise inherit whatever this Mac last chose.
        let dynamicRange: Bool? = arguments.contains("--develop-hdr") ? true
            : (arguments.contains("--develop-sdr") ? false : nil)
        // The gauge the clip is meant to have been shot on. Unstated keeps the stock's own
        // native format, which is what a clip off a camera should get; naming one is for a
        // deliberate transfer — 16mm off a sensor that never saw a 16mm gate.
        let formatArgument = arguments.first { $0.hasPrefix("--develop-format=") }
            .map { String($0.dropFirst("--develop-format=".count)) }
        if let formatArgument, FilmFormat.preset(id: formatArgument) == nil {
            print("DevelopVideo failed: unknown format '\(formatArgument)'."
                  + " Choices: "
                  + FilmFormat.presets.map(\.id).joined(separator: ", "))
            exit(1)
        }
        let stockArgument = arguments.first { $0.hasPrefix("--develop-stock=") }
            .map { String($0.dropFirst("--develop-stock=".count)) }
        guard let stockID = stockArgument ?? FilmStock.presetIDs.first,
              let stock = FilmStock.named(stockID) else {
            print("DevelopVideo failed: "
                  + (stockArgument.map { "'\($0)' is not installed. Choices: "
                        + FilmStock.presetIDs.joined(separator: ", ") }
                     ?? "no film stocks installed"))
            exit(1)
        }
        Task {
            do {
                var options = FotufilmEngine.Options()
                options.format = formatArgument.flatMap(FilmFormat.preset(id:))
                    ?? FilmFormat.native(forStockID: stockID)
                options.paper = paper
                print("DevelopVideo film: \(stockID) "
                      + "format: \(options.format.name) "
                      + "paper: \(options.paper(for: stock).id)")
                let asset = AVURLAsset(url: input)
                if let track = try? await asset.loadTracks(withMediaType: .video).first,
                   let formats = try? await track.load(.formatDescriptions) {
                    let bits = formats.map(VideoPipeline.sourceBitsPerComponent).max() ?? 8
                    print("DevelopVideo source depth: \(bits)-bit")
                }
                let start = Date()
                try await VideoDeveloper.export(
                    from: asset, to: output,
                    stock: stock, options: options,
                    developLongEdge: fast
                        ? ProcessInfo.processInfo.environment["FOTUFILM_FAST_EDGE"]
                            .flatMap(Int.init) ?? 1920
                        : nil,
                    frameRate: frameRate,
                    fileType: output.pathExtension.lowercased() == "mp4"
                        ? .mp4 : .mov,
                    codec: codec,
                    sourceEncoding: encoding,
                    camera: camera, sceneCCT: sceneCCT,
                    hdr: dynamicRange,
                    progress: { fraction, frame, total in
                        print(String(format: "DevelopVideo progress %.2f (frame %d of %d)",
                                     fraction, frame, total))
                    })
                print(String(format: "DevelopVideo done in %.1fs: %@",
                             Date().timeIntervalSince(start), output.path))
                exit(0)
            } catch {
                print("DevelopVideo failed: \(error.localizedDescription)")
                exit(1)
            }
        }
        return true
    }

    @discardableResult
    static func developStillIfRequested() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let argument = arguments.first(where: { $0.hasPrefix("--develop-still=") })
        else { return false }
        let input = URL(fileURLWithPath:
            String(argument.dropFirst("--develop-still=".count)))
        func value(_ name: String) -> String? {
            arguments.first { $0.hasPrefix(name) }
                .map { String($0.dropFirst(name.count)) }
        }
        let outDirectory = value("--still-out=")
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? input.deletingLastPathComponent()
        let longEdge = value("--still-long-edge=").flatMap { Int($0) }
            ?? 1800
        let hdr = arguments.contains("--still-hdr")
        let paperArgument = value("--still-paper=")
        let paper: PrintPaper? = paperArgument.flatMap(PrintPaper.preset(id:))
        if let paperArgument, PrintPaper.preset(id: paperArgument) == nil {
            print("DevelopStill failed: unknown paper '\(paperArgument)'."
                  + " Choices: "
                  + PrintPaper.allCases.map(\.id).joined(separator: ", "))
            exit(1)
        }
        let formatArgument = value("--still-format=")
        if let formatArgument, FilmFormat.preset(id: formatArgument) == nil {
            print("DevelopStill failed: unknown format '\(formatArgument)'."
                  + " Choices: "
                  + FilmFormat.presets.map(\.id).joined(separator: ", "))
            exit(1)
        }
        // The lens sliders, so a correction can be looked at without a window. Each runs -1...1, the
        // same travel the editor gives them.
        var lens = LensAdjustment.neutral
        lens.distortion = value("--still-lens-distortion=")
            .flatMap { Double($0) } ?? 0
        lens.vignetting = value("--still-lens-vignette=")
            .flatMap { Double($0) } ?? 0
        lens.redCyan = value("--still-lens-red-cyan=").flatMap { Double($0) } ?? 0
        lens.blueYellow = value("--still-lens-blue-yellow=")
            .flatMap { Double($0) } ?? 0
        let correctsLens = !lens.isNeutral
            || arguments.contains("--still-lens-profile")

        let stockArgument = value("--still-stock=") ?? "all"
        let stockIDs = stockArgument == "all"
            ? FilmStock.presetIDs
            : stockArgument.split(separator: ",").map(String.init)
        Task.detached {
            guard let data = try? Data(contentsOf: input) else {
                print("DevelopStill failed: could not read \(input.path)")
                exit(1)
            }
            let hint = UTType(filenameExtension: input.pathExtension)?.identifier
            let source = PhotoSource.raw(data: data, hint: hint)
                ?? PhotoSource.file(data: data)
            print("DevelopStill source: \(source.detail)"
                  + (source.isRaw ? " (raw)" : ""))
            try? FileManager.default.createDirectory(
                at: outDirectory, withIntermediateDirectories: true)
            let stem = input.deletingPathExtension().lastPathComponent
            for stockID in stockIDs {
                var state = EditState()
                state.stockID = stockID
                // `EditState` always holds a medium, so an unstated one is resolved against the
                // stock here rather than left for the engine.
                state.paper = paper
                    ?? StockPreset.preset(id: stockID).map {
                        PrintPaper.default(for: $0.stock)
                    }
                    ?? PrintPaper.default
                state.lensCorrectionEnabled = correctsLens
                state.lensAdjustment = lens
                if let formatArgument {
                    state.selectFormat(formatArgument)
                }
                // `no-film` develops without an emulsion rather than not at all, so it is asked for
                // by name; only a film the pack does not carry is skipped.
                guard state.stock != nil || !state.hasFilm else {
                    print("DevelopStill \(stockID): not installed, skipped")
                    continue
                }
                let timings = stillStageReporter()
                guard let scene = FilmRender.scene(
                    source: source, state: state, longEdge: longEdge,
                    report: timings) else {
                    print("DevelopStill \(stockID): scene decode failed")
                    exit(1)
                }
                let sceneMean = mean(of: scene)
                let balance = FilmRender.remainingBalance(for: state, scene: scene)
                guard let developed = FilmRender.develop(
                    scene, state: state, hdr: hdr,
                    dynamicRange: hdr ? .hdr : .sdr, report: timings) else {
                    print("DevelopStill \(stockID): develop failed")
                    exit(1)
                }
                let output = outDirectory
                    .appendingPathComponent("\(stem).\(stockID).jpg")
                guard developed.image.write(
                    to: output, format: .jpeg,
                    metadata: .preserveWithoutLocation) else {
                    print("DevelopStill \(stockID): JPEG write failed")
                    exit(1)
                }
                if hdr && state.supportsHDROutput {
                    let hdrOutput = outDirectory
                        .appendingPathComponent("\(stem).\(stockID).heic")
                    // The app's own container choice — gain map where the OS can write
                    // one, HLG below macOS 15 — not a hardcoded form that would fail
                    // outright where the gain-map writer is missing.
                    guard developed.image.writeHDR(
                        to: hdrOutput, as: AppSettings.stillHDRContainer,
                        metadata: .preserveWithoutLocation) else {
                        print("DevelopStill \(stockID): HDR write failed")
                        exit(1)
                    }
                }
                let printMean = mean(of: developed.image.image)
                func triple(_ v: SIMD3<Double>) -> String {
                    String(format: "[%.4f %.4f %.4f]", v.x, v.y, v.z)
                }
                print("DevelopStill \(stockID): headroom=\(scene.contentHeadroom)"
                      + " balanceK=\(balance.kelvin) tint=\(balance.tint)"
                      + " scene=\(triple(sceneMean))"
                      + " film=\(triple(sceneMean))"
                      + " print=\(triple(printMean))"
                      + " -> \(output.lastPathComponent)")
            }
            print("DevelopStill done")
            exit(0)
        }
        return true
    }

    @discardableResult
    @MainActor
    static func pickStockIfRequested() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let argument = arguments.first(where: {
            $0.hasPrefix("--pick-stock=")
        }) else { return false }
        let input = URL(fileURLWithPath:
            String(argument.dropFirst("--pick-stock=".count)))
        let verbose = arguments.contains("--pick-verbose")
        let teach = arguments.first { $0.hasPrefix("--pick-teach=") }
            .map { String($0.dropFirst("--pick-teach=".count)) }

        guard let data = try? Data(contentsOf: input) else {
            print("PickStock failed: cannot read \(input.path)")
            exit(1)
        }
        let hint = UTType(filenameExtension: input.pathExtension)?.identifier
        let source = PhotoSource.raw(data: data, hint: hint)
            ?? PhotoSource.file(data: data)
        guard !StockPreset.all.isEmpty else {
            print("PickStock failed: no stock pack installed")
            exit(1)
        }
        print("PickStock source: \(source.detail)"
              + (source.isRaw ? " (raw)" : ""))

        let start = Date()
        let store = StockPreferenceStore.shared
        guard let ranking = StockSuggestion.choose(source: source,
                                                   state: EditState(),
                                                   weights: store.weights)
        else {
            print("PickStock \(input.lastPathComponent): scene decode failed")
            exit(1)
        }
        let elapsed = Date().timeIntervalSince(start)
        print(String(format: "PickStock %@: %@ [%d films, %.2fs]",
                     input.lastPathComponent, ranking.summary,
                     ranking.ordered.count, elapsed))
        if verbose {
            func cell(_ text: String, _ width: Int) -> String {
                text.count >= width ? text
                    : text.padding(toLength: width, withPad: " ", startingAt: 0)
            }
            guard let first = ranking.ordered.first else { exit(0) }
            print("  " + cell("film", 22) + cell("total", 8)
                  + first.terms.map { cell($0.name, 14) }.joined())
            for candidate in ranking.ordered {
                print("  " + cell(candidate.name, 22)
                      + cell(String(format: "%.3f", candidate.total), 8)
                      + candidate.terms.map {
                          cell(String(format: "%.3f", $0.value), 14)
                      }.joined())
            }
        }
        if let teach {
            store.record(photoID: input.lastPathComponent,
                         chosenFilmID: teach, ranking: ranking,
                         proposedFilmID: ranking.best?.id)
            print("PickStock taught: \(input.lastPathComponent) -> \(teach)"
                  + " (\(store.observationCount) observations)")
            Thread.sleep(forTimeInterval: 0.2)
        }
        exit(0)
    }

    @discardableResult
    static func benchStockPickIfRequested() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let argument = arguments.first(where: {
            $0.hasPrefix("--bench-stock-pick=")
        }) else { return false }
        let input = URL(fileURLWithPath:
            String(argument.dropFirst("--bench-stock-pick=".count)))
        let runs = arguments.compactMap { argument -> Int? in
            guard argument.hasPrefix("--bench-runs=") else { return nil }
            return Int(argument.dropFirst("--bench-runs=".count))
        }.first ?? 5

        guard let data = try? Data(contentsOf: input) else {
            print("BenchStockPick failed: cannot read \(input.path)")
            exit(1)
        }
        let hint = UTType(filenameExtension: input.pathExtension)?.identifier
        let source = PhotoSource.raw(data: data, hint: hint)
            ?? PhotoSource.file(data: data)
        guard !StockPreset.all.isEmpty else {
            print("BenchStockPick failed: no stock pack installed")
            exit(1)
        }

        let edges = arguments.compactMap { argument -> [Int]? in
            guard argument.hasPrefix("--bench-long-edge=") else { return nil }
            return argument.dropFirst("--bench-long-edge=".count)
                .split(separator: ",").compactMap { Int($0) }
        }.first ?? [StockSuggestion.scoringLongEdge]

        print("BenchStockPick \(input.lastPathComponent)"
              + " [\(StockPreset.all.count) in pack, best of \(runs)]")
        for edge in edges {
            guard let timings = StockPickBenchmark.run(source: source,
                                                       longEdge: edge,
                                                       runs: runs) else {
                print("BenchStockPick \(input.lastPathComponent): decode failed")
                exit(1)
            }
            if edges.count > 1 { print("  long edge \(edge):") }
            for line in timings.report { print(line) }
        }
        exit(0)
    }

    @discardableResult
    @MainActor
    static func reportStockLearningIfRequested() -> Bool {
        guard ProcessInfo.processInfo.arguments.contains("--pick-learn")
        else { return false }

        let store = StockPreferenceStore.shared
        print("PickLearn: \(store.observationCount) observations")
        for line in store.report.lines { print(line) }

        let learned = store.weights
        let moved = zip(learned.terms, StockPreference.prior.terms)
            .enumerated()
            .filter { abs($0.element.0 - $0.element.1) > 0.005 }
        if moved.isEmpty {
            print("  no term has moved off the hand-set weights yet")
        } else {
            for (index, pair) in moved {
                let name = StockFeatures.Term(rawValue: index)?.name ?? "?"
                print(String(format: "  %@: %.3f -> %.3f", name,
                             pair.1, pair.0))
            }
        }
        for (film, bias) in learned.bias.sorted(by: { $0.value < $1.value })
        where abs(bias) > 0.005 {
            print(String(format: "  %@ bias %+.3f", FilmChoice.name(for: film),
                         bias))
        }
        exit(0)
    }

    private static func mean(of scene: FilmRender.Scene) -> SIMD3<Double> {
        let bandRows = max(1, 262_144 / max(scene.width, 1))
        var scratch = [Float](repeating: 0,
                              count: min(bandRows, scene.height) * scene.width * 4)
        var sums = SIMD3<Double>()
        scene.withPixels { pixels in
            var row = 0
            while row < scene.height {
                let upper = min(scene.height, row + bandRows)
                scratch.withUnsafeMutableBufferPointer { buffer in
                    FilmRender.expand(pixels, rows: row..<upper,
                                      width: scene.width, into: buffer)
                    for pixel in 0..<((upper - row) * scene.width) {
                        sums.x += Double(buffer[pixel * 4])
                        sums.y += Double(buffer[pixel * 4 + 1])
                        sums.z += Double(buffer[pixel * 4 + 2])
                    }
                }
                row = upper
            }
        }
        return sums / Double(scene.width * scene.height)
    }

    private static func mean(of image: CGImage) -> SIMD3<Double> {
        guard let data = image.dataProvider?.data as Data? else { return .init() }
        let componentBytes = image.bitsPerComponent / 8
        let pixelBytes = image.bitsPerPixel / 8
        let rowBytes = image.bytesPerRow
        var sums = SIMD3<Double>()
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for y in 0..<image.height {
                for x in 0..<image.width {
                    let base = y * rowBytes + x * pixelBytes
                    for channel in 0..<3 {
                        let offset = base + channel * componentBytes
                        let value: Double
                        if componentBytes == 2 {
                            value = Double(raw.loadUnaligned(
                                fromByteOffset: offset, as: UInt16.self)) / 65535
                        } else {
                            value = Double(raw[offset]) / 255
                        }
                        sums[channel] += value
                    }
                }
            }
        }
        return sums / Double(image.width * image.height)
    }

    @discardableResult
    @MainActor static func verifyPeekIfRequested() -> Bool {
        guard ProcessInfo.processInfo.arguments.contains("--verify-peek")
        else { return false }
        Task { @MainActor in
            func canvasImageView(in view: NSView) -> NSImageView? {
                if let scroll = view as? NSScrollView,
                   let document = scroll.documentView {
                    for sub in document.subviews {
                        if let imageView = sub as? NSImageView { return imageView }
                    }
                }
                for sub in view.subviews {
                    if let found = canvasImageView(in: sub) { return found }
                }
                return nil
            }
            for attempt in 1...20 {
                try? await Task.sleep(for: .seconds(2))
                guard let window = NSApp.windows.first(where: { $0.isVisible }),
                      let content = window.contentView,
                      let imageView = canvasImageView(in: content),
                      let before = imageView.image else { continue }
                let centre = imageView.convert(
                    NSPoint(x: imageView.bounds.midX, y: imageView.bounds.midY),
                    to: nil)
                func send(_ kind: NSEvent.EventType) {
                    guard let event = NSEvent.mouseEvent(
                        with: kind, location: centre, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil,
                        eventNumber: 0, clickCount: 1, pressure: 1) else { return }
                    window.sendEvent(event)
                }
                send(.leftMouseDown)
                let during = imageView.image
                send(.leftMouseUp)
                let after = imageView.image
                guard during !== before, after === before else { continue }
                let size = during.map { "\(Int($0.size.width))x\(Int($0.size.height))" }
                    ?? "nil"
                print("verify-peek: swapped to \(size) original on attempt \(attempt)")
                print("verify-peek PASS")
                exit(0)
            }
            print("verify-peek FAIL: the hold never swapped the print")
            exit(1)
        }
        return true
    }

    @discardableResult
    static func verifyLogConversionIfRequested() -> Bool {
        guard ProcessInfo.processInfo.arguments.contains("--verify-log-conversion")
        else { return false }
        var pass = true
        let encodings: [VideoSourceEncoding] =
            [.appleLog, .slog3Cine, .slog3, .slog2,
             .flog, .flog2, .flog2C, .hlg]
        for encoding in encodings {
            guard let line = verifyLogConversion(encoding) else {
                print("verify-log \(encoding.rawValue): FAILED to run")
                pass = false
                continue
            }
            print(line.text)
            pass = pass && line.ok
            guard let banding = verifyLogBanding(encoding) else {
                print("verify-log \(encoding.rawValue): banding FAILED to run")
                pass = false
                continue
            }
            print(banding.text)
            pass = pass && banding.ok
        }
        print(pass ? "verify-log PASS" : "verify-log FAIL")
        exit(pass ? 0 : 1)
    }

    @discardableResult
    static func verifyLogStillIfRequested() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let argument = arguments.first(where: {
            $0.hasPrefix("--verify-log-still=")
        }) else { return false }
        let url = URL(fileURLWithPath:
            String(argument.dropFirst("--verify-log-still=".count)))
        let encoding: VideoSourceEncoding = arguments
            .first { $0.hasPrefix("--verify-log-curve=") }
            .map { String($0.dropFirst("--verify-log-curve=".count)) }
            .flatMap { name in
                switch name {
                case "apple-log": return .appleLog
                case "slog3-cine": return .slog3Cine
                case "slog3": return .slog3
                case "slog2": return .slog2
                case "flog": return .flog
                case "flog2": return .flog2
                case "flog2-c": return .flog2C
                case "hlg": return .hlg
                default: return nil
                }
            } ?? .slog3
        Task {
            let asset = AVURLAsset(url: url)
            let seconds = 0.5
            let edge: CGFloat = 4096
            guard let deep = await VideoPipeline.sourceFrame(
                    of: asset, at: seconds, longestSide: edge,
                    encoding: encoding) else {
                print("verify-log-still: no frame at \(seconds)s")
                exit(1)
            }
            guard let generated = await VideoPipeline.sourceFrame(
                    of: asset, at: seconds, longestSide: edge),
                  let shallow = LogConverter.convertImage(generated,
                                                          encoding: encoding)
            else {
                print("verify-log-still: the 8-bit road would not run")
                exit(1)
            }
            guard let deepRow = middleRow(of: deep),
                  let shallowRow = middleRow(of: shallow) else {
                print("verify-log-still: could not read the frames back")
                exit(1)
            }
            let d = contour(deepRow)
            let s = contour(shallowRow)
            let live = d.levels >= 16
            let ok = live && d.levels > s.levels && d.step <= s.step
            print(String(
                format: "verify-log-still %@ (%dx%d): deep %d levels step %d, "
                    + "generator+table %d levels step %d %@",
                encoding.rawValue, deep.width, deep.height,
                d.levels, d.step, s.levels, s.step,
                ok ? "ok" : (live ? "FAILED" : "FAILED (no gradient in frame)")))
            print(ok ? "verify-log-still PASS" : "verify-log-still FAIL")
            exit(ok ? 0 : 1)
        }
        return true
    }

    private static func middleRow(of image: CGImage) -> [UInt8]? {
        let width = image.width
        guard width > 1, image.height > 0,
              let space = CGColorSpace(name: CGColorSpace.displayP3)
        else { return nil }
        var row = [UInt8](repeating: 0, count: width * 4)
        let drew = row.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(
                data: storage.baseAddress, width: width, height: 1,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: -(image.height / 2),
                                           width: width, height: image.height))
            return true
        }
        return drew ? row : nil
    }

    private static func contour(_ row: [UInt8]) -> (step: Int, levels: Int) {
        var step = 0
        var levels = Set<UInt8>()
        for i in stride(from: 0, to: row.count, by: 4) {
            levels.insert(row[i])
            if i >= 4 { step = max(step, abs(Int(row[i]) - Int(row[i - 4]))) }
        }
        return (step, levels.count)
    }

    /// `--verify-preview-depth` measures what the playback preview's decode depth is worth, through
    /// the engine, and exits.
    @discardableResult
    static func verifyPreviewDepthIfRequested() -> Bool {
        guard ProcessInfo.processInfo.arguments
            .contains("--verify-preview-depth") else { return false }
        guard let stockID = FilmStock.presetIDs.first,
              let stock = FilmStock.named(stockID),
              let engine = HalideMetalFilmRenderer.shared,
              let device = MTLCreateSystemDefaultDevice() else {
            print("verify-preview-depth FAIL: no engine or no film")
            exit(1)
        }
        // One column per 10-bit code, a few rows so the spatial stages have something to run on.
        let width = 1024, height = 64
        let count = width * height * 4
        // Grain off. It is a per-pixel random draw, so it would scatter neighbouring codes apart
        // and inflate the level counts below for both paths alike — hiding, behind noise, the
        // gradation this is trying to count.
        var options = FotufilmEngine.Options()
        options.grainScale = 0

        var deepInput = [Float](repeating: 0, count: count)
        var quantizedInput = [Float](repeating: 0, count: count)
        var shallowBytes = [UInt8](repeating: 255, count: count)
        for y in 0..<height {
            for x in 0..<width {
                let signal = Float(x) / 1023
                // What the deep tap delivers: the full-float code, sRGB-decoded
                // exactly as `fillLinearFloatInput` decodes this positive range.
                let deepLinear = ColorScience.srgbToLinear(signal)
                // What the 8-bit tap delivered: the same signal with only 256
                // rungs to land on, decoded through the same curve.
                let code = UInt8((min(max(signal, 0), 1) * 255).rounded())
                let shallowLinear = ColorScience.srgbToLinear(Float(code) / 255)
                let pixel = (y * width + x) * 4
                for channel in 0..<3 {
                    deepInput[pixel + channel] = deepLinear
                    quantizedInput[pixel + channel] = shallowLinear
                    shallowBytes[pixel + channel] = code
                }
                deepInput[pixel + 3] = 1
                quantizedInput[pixel + 3] = 1
            }
        }

        engine.prepare(stock: stock, options: options,
                       frameWidth: width, frameHeight: height)
        // Both develops run the float path and the same reference schedule, so the only thing
        // between them is the depth of the decode — which is what this is measuring, and what
        // conflating it with the schedule would hide.
        guard let deep = developFloat(deepInput, engine: engine, device: device,
                                      width: width, height: height,
                                      stock: stock, options: options),
              let quantized = developFloat(quantizedInput, engine: engine,
                                           device: device, width: width,
                                           height: height, stock: stock,
                                           options: options) else {
            print("verify-preview-depth FAIL: the float road did not run")
            exit(1)
        }

        var worst: Float = 0
        var total: Float = 0
        // The shadows are where the codes a deep decode keeps actually live: the bottom tenth of
        // the ramp, which is the region a log encoding exists to protect and the region 8 bits
        // merges hardest — 103 of the ramp's 10-bit codes land on 26 of the 8-bit tap's.
        let shadowColumns = 0..<103
        var deepLevels = Set<UInt16>()
        var quantizedLevels = Set<UInt16>()
        for x in 0..<width {
            for channel in 0..<3 {
                let index = x * 4 + channel
                let difference = abs(Float(deep[index]) - Float(quantized[index]))
                worst = max(worst, difference)
                total += difference
            }
            if shadowColumns.contains(x) {
                deepLevels.insert(deep[x * 4 + 1])
                quantizedLevels.insert(quantized[x * 4 + 1])
            }
        }
        let mean = total / Float(width * 3)
        // Report differences in the preview's 8-bit code scale rather than fractions.
        let scale: Float = 255 / 65535
        let ok = deepLevels.count > quantizedLevels.count && worst > 0
        print(String(
            format: "verify-preview-depth: print moves %.2f codes worst, "
                + "%.3f mean; shadow levels deep %d vs quantized %d %@",
            worst * scale, mean * scale, deepLevels.count,
            quantizedLevels.count, ok ? "ok" : "FAILED"))
        // Verify that an 8-bit source still uses the shallow decode path.
        var shallowOut = [UInt8](repeating: 0, count: count)
        let shallowRan = shallowBytes.withUnsafeBufferPointer { input in
            shallowOut.withUnsafeMutableBufferPointer { output in
                engine.processSRGB8(Array(input), width: width, height: height,
                                    stock: stock, options: options,
                                    frameIndex: 0)
                    .map { developed in
                        output.baseAddress!.update(from: developed,
                                                   count: min(count,
                                                              developed.count))
                        return true
                    } ?? false
            }
        }
        print(shallowRan
              ? "verify-preview-depth: the 8-bit road still runs, for the "
                + "8-bit sources that still take it"
              : "verify-preview-depth: the 8-bit road did not run")
        // And the decode itself, on a real deep file rather than on an array: the path has to reach
        // the right verdict about it, and the container it names has to be one the decoder actually
        // fills.
        let delivered = verifyDeepDecode(width: width, height: height)
        print(delivered.text)
        // The paused frame takes its own path to the same emulsion — a still decode, a 16-bit draw,
        // the float engine — so it is checked on the same probe rather than assumed to follow.
        let still = verifyDeepStill(stock: stock, options: options,
                                    width: width, height: height)
        print(still.text)
        // And the tap itself, which is the one surface whose depth is not ours to decide: a player
        // item is a negotiation, and the answer to whether it honours the request is empirical.
        let tap = verifyDeepTap(width: width, height: height)
        print(tap.text)
        let pass = ok && shallowRan && delivered.ok && still.ok && tap.ok
        print(pass ? "verify-preview-depth PASS" : "verify-preview-depth FAIL")
        exit(pass ? 0 : 1)
    }

    private static func verifyDeepDecode(
        width: Int, height: Int
    ) -> (text: String, ok: Bool) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fotufilm-depth-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        guard writeRampClip(to: url, width: width, height: height) else {
            return ("verify-preview-depth: could not write a ProRes probe", false)
        }

        let asset = AVURLAsset(url: url)
        let semaphore = DispatchSemaphore(value: 0)
        var formats: [CMFormatDescription] = []
        var track: AVAssetTrack?
        Task {
            track = try? await asset.loadTracks(withMediaType: .video).first
            formats = (try? await track?.load(.formatDescriptions)) ?? []
            semaphore.signal()
        }
        semaphore.wait()
        guard let track else {
            return ("verify-preview-depth: the probe has no video track", false)
        }
        let road = VideoDecodeDepth.road(hdr: false, log: false,
                                         sourceFormats: formats)
        let bits = formats.map(VideoDecodeDepth.bitsPerComponent).max() ?? 0

        guard let reader = try? AVAssetReader(asset: asset) else {
            return ("verify-preview-depth: the probe would not open", false)
        }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: VideoPipeline.decodeSettings(deep: road.deepInput,
                                                        isLog: false))
        guard reader.canAdd(output) else {
            return ("verify-preview-depth: the probe would not read", false)
        }
        reader.add(output)
        guard reader.startReading(), let sample = output.copyNextSampleBuffer(),
              let pixels = CMSampleBufferGetImageBuffer(sample) else {
            return ("verify-preview-depth: the probe decoded no frame", false)
        }
        defer { reader.cancelReading() }
        let format = CVPixelBufferGetPixelFormatType(pixels)

        // How much of the ramp came back apart. A 4:2:2 ProRes carries a neutral ramp entirely in
        // luma, so what survives here is the depth and not the chroma sampling.
        var levels = Set<UInt16>()
        if format == kCVPixelFormatType_64RGBAHalf {
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            if let base = CVPixelBufferGetBaseAddress(pixels) {
                let row = base.assumingMemoryBound(to: UInt16.self)
                for x in 0..<CVPixelBufferGetWidth(pixels) {
                    levels.insert(row[x * 4 + 1])
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
        }
        let ok = road.deepInput && bits > 8
            && format == kCVPixelFormatType_64RGBAHalf && levels.count > 256
        return (String(
            format: "verify-preview-depth: probe reads %d-bit, road asks deep "
                + "%@, decoder delivers %@, %d ramp levels survive %@",
            bits, road.deepInput ? "yes" : "no",
            format == kCVPixelFormatType_64RGBAHalf ? "half float" : "8-bit",
            levels.count, ok ? "ok" : "FAILED"), ok)
    }

    private static func verifyDeepTap(
        width: Int, height: Int
    ) -> (text: String, ok: Bool) {
        // Three shapes, and the expectation for each is the policy the tap implements rather than a
        // wish about it.
        var notes: [String] = []
        var ok = true
        for (shape, wantsDeep) in [("raw", true), ("passthrough", false),
                                   ("coloured", false)] {
            let result = probeTap(width: width, height: height, shape: shape)
            let matched = result.deep == wantsDeep
            notes.append("\(shape) \(result.text)"
                         + (matched ? "" : " UNEXPECTED"))
            ok = ok && matched
        }
        return ("verify-preview-depth: player tap "
                + notes.joined(separator: ", ")
                + (ok ? " ok" : " FAILED"), ok)
    }

    private static func probeTap(
        width: Int, height: Int, shape: String
    ) -> (text: String, deep: Bool) {
        let composited = shape != "raw"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fotufilm-tap-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        guard writeRampClip(to: url, width: width, height: height) else {
            return ("probe unwritable", false)
        }
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        if composited {
            let semaphore = DispatchSemaphore(value: 0)
            var composition: AVMutableVideoComposition?
            Task {
                composition = try? await AVMutableVideoComposition
                    .videoComposition(withPropertiesOf: asset)
                semaphore.signal()
            }
            semaphore.wait()
            guard let composition else { return ("no composition", false) }
            if shape == "coloured" {
                composition.colorPrimaries = AVVideoColorPrimaries_P3_D65
                composition.colorTransferFunction =
                    VideoPipeline.sRGBTransferFunction
                composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
            }
            item.videoComposition = composition
        }
        let player = AVPlayer(playerItem: item)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_64RGBAHalf,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        item.add(output)

        // The item has to become ready and the tap has to be handed a frame, both of which want a
        // run loop this early in the process.
        let deadline = Date().addingTimeInterval(10)
        var pixels: CVPixelBuffer?
        player.play()
        while Date() < deadline, pixels == nil {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            guard item.status == .readyToPlay else { continue }
            for tick in 0..<4 {
                let time = CMTime(value: CMTimeValue(tick), timescale: 30)
                if output.hasNewPixelBuffer(forItemTime: time),
                   let frame = output.copyPixelBuffer(forItemTime: time,
                                                      itemTimeForDisplay: nil) {
                    pixels = frame
                    break
                }
            }
        }
        player.pause()
        guard let pixels else {
            return ("delivered no frame — the item declined the container and "
                    + "the preview would be black", false)
        }
        let format = CVPixelBufferGetPixelFormatType(pixels)
        let deep = format == kCVPixelFormatType_64RGBAHalf
        // What the tap actually carries, counted the way the reader's probe counts it: a shallow
        // delivery padded into half float would come back with a quarter of the ramp.
        var levels = Set<UInt16>()
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        if deep, let base = CVPixelBufferGetBaseAddress(pixels) {
            let row = base.assumingMemoryBound(to: UInt16.self)
            for x in 0..<CVPixelBufferGetWidth(pixels) {
                levels.insert(row[x * 4 + 1])
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
        return (String(format: "delivers %@ with %d ramp levels",
                       deep ? "half float" : "8-bit", levels.count),
                deep && levels.count > 256)
    }

    private static func verifyDeepStill(
        stock: FilmStock, options: FotufilmEngine.Options,
        width: Int, height: Int
    ) -> (text: String, ok: Bool) {
        var notes: [String] = []
        var ok = true
        // Upright, then a quarter turn: the second says the orientation permutation transposes the
        // frame instead of stretching it into a buffer the wrong way round.
        for rotated in [false, true] {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("fotufilm-still-\(UUID().uuidString).mov")
            defer { try? FileManager.default.removeItem(at: url) }
            guard writeRampClip(to: url, width: width, height: height,
                                quarterTurn: rotated) else {
                notes.append("probe unwritable")
                ok = false
                continue
            }
            let asset = AVURLAsset(url: url)
            let semaphore = DispatchSemaphore(value: 0)
            var still: CGImage?
            var developed: (print: CGImage, source: CGImage)?
            Task {
                still = await VideoPipeline.sourceFrame(of: asset, at: 0,
                                                        longestSide: 4096)
                if let still {
                    developed = await VideoPreviewSimulator()
                        .developFullResolutionImage(
                            still, stock: stock, options: options,
                            frameIndex: 0)
                }
                semaphore.signal()
            }
            semaphore.wait()
            guard let still, let developed else {
                notes.append(rotated ? "rotated develop failed"
                                     : "upright develop failed")
                ok = false
                continue
            }
            let expectedWidth = rotated ? height : width
            let expectedHeight = rotated ? width : height
            let sized = still.width == expectedWidth
                && still.height == expectedHeight
            let deepStill = still.bitsPerComponent == 16
            let deepPrint = developed.print.bitsPerComponent == 16
                && developed.source.bitsPerComponent == 16
            let printSized = developed.print.width == expectedWidth
                && developed.print.height == expectedHeight
            ok = ok && sized && deepStill && deepPrint && printSized
            notes.append(String(
                format: "%@ %dx%d @%d bpc -> print %dx%d @%d bpc",
                rotated ? "turned" : "upright",
                still.width, still.height, still.bitsPerComponent,
                developed.print.width, developed.print.height,
                developed.print.bitsPerComponent))
        }
        return ("verify-preview-depth: paused frame "
                + notes.joined(separator: ", ")
                + (ok ? " ok" : " FAILED"), ok)
    }

    private static func writeRampClip(
        to url: URL, width: Int, height: Int, quarterTurn: Bool = false
    ) -> Bool {
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov)
        else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes422,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: VideoPipeline.sdrColorProperties,
        ])
        // Stored in natural orientation and carrying the rotation, which is how a phone records a
        // portrait clip: the frames are landscape and the transform says which way is up.
        if quarterTurn { input.transform = CGAffineTransform(rotationAngle: .pi / 2) }
        input.expectsMediaDataInRealTime = false
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

        for frame in 0..<4 {
            guard let pool = adaptor.pixelBufferPool else { return false }
            var bufferOut: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &bufferOut)
                    == kCVReturnSuccess, let buffer = bufferOut else { return false }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
                for y in 0..<height {
                    let row = (base + y * rowBytes)
                        .assumingMemoryBound(to: UInt16.self)
                    for x in 0..<width {
                        let signal = Float16(Float(x) / Float(width - 1))
                        for channel in 0..<3 {
                            row[x * 4 + channel] = signal.bitPattern
                        }
                        row[x * 4 + 3] = Float16(1).bitPattern
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { usleep(1_000) }
            guard adaptor.append(buffer, withPresentationTime:
                    CMTime(value: CMTimeValue(frame), timescale: 30))
            else { return false }
        }
        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
        return writer.status == .completed
    }

    private static func developFloat(
        _ linear: [Float], engine: HalideMetalFilmRenderer, device: MTLDevice,
        width: Int, height: Int, stock: FilmStock,
        options: FotufilmEngine.Options, realtime: Bool = false
    ) -> [UInt16]? {
        let count = width * height * 4
        guard let input = device.makeBuffer(length: count * 4,
                                            options: .storageModeShared),
              let output = device.makeBuffer(length: count * 4,
                                             options: .storageModeShared)
        else { return nil }
        linear.withUnsafeBufferPointer { source in
            input.contents().assumingMemoryBound(to: Float.self)
                .update(from: source.baseAddress!, count: count)
        }
        guard engine.processLinearFloat(
            input: input, output: output, width: width, height: height,
            stock: stock, options: options, frameIndex: 0, realtime: realtime)
        else { return nil }
        var encoded = [UInt16](repeating: 0, count: count)
        encoded.withUnsafeMutableBufferPointer { destination in
            PrintEncoding.encodeRows(
                UnsafeBufferPointer(
                    start: output.contents().assumingMemoryBound(to: Float.self),
                    count: count),
                rows: 0..<height, width: width, into: destination,
                transfer: .shoulderedSRGB)
        }
        return encoded
    }

    private static func verifyLogConversion(
        _ encoding: VideoSourceEncoding
    ) -> (text: String, ok: Bool)? {
        let width = 1024, height = 64
        guard let converter = LogConverter(encoding: encoding,
                                           width: width, height: height)
        else { return nil }
        var halves = [UInt16](repeating: 0, count: width * height * 4)
        var state: UInt64 = 0x46494C4D
        func random10BitCode() -> Float {
            state ^= state >> 12; state ^= state << 25; state ^= state >> 27
            return Float((state &* 2685821657736338717) >> 54 & 1023) / 1023
        }
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                for channel in 0..<3 {
                    let code = y == 0
                        ? Float(x) / 1023
                        : random10BitCode()
                    halves[i + channel] = Float16(code).bitPattern
                }
                halves[i + 3] = Float16(1).bitPattern
            }
        }
        var reference = [Float](repeating: 0, count: width * height * 4)
        let referenceRan = halves.withUnsafeBytes { source in
            reference.withUnsafeMutableBufferPointer { dest in
                converter.convertLinearPacked(
                    source.baseAddress!, rowBytes: width * 8,
                    into: dest.baseAddress!)
            }
        }
        guard referenceRan else { return nil }

        // What a CPU/GPU parity check structurally cannot see: both paths agreeing on the wrong
        // primaries is still agreement. So the contract is recomputed here from the encoding's own
        // curve and its *working-space* matrix — scene-linear Rec.2020, diffuse white on 1.0 —
        // and the reference path is held to it. A Display P3 matrix stood in this seam unnoticed
        // precisely because nothing ever asked which basis the floats were in.
        var worstBasis: Float = 0
        if let cameraEncoding = encoding.cameraEncoding {
            let curve = cameraEncoding.curve
            let working = cameraEncoding.gamut.toRec2020.map { Float($0) }
            for pixel in 0..<(width * height) {
                let lin = (0..<3).map {
                    curve.linear(Float(Float16(bitPattern: halves[pixel * 4 + $0])))
                }
                for channel in 0..<3 {
                    let expected = (working[channel * 3] * lin[0]
                        + working[channel * 3 + 1] * lin[1]
                        + working[channel * 3 + 2] * lin[2]) / 0.9
                    worstBasis = max(
                        worstBasis, abs(reference[pixel * 4 + channel] - expected))
                }
            }
        }

        var pixelBufferOut: CVPixelBuffer?
        guard CVPixelBufferCreate(
                kCFAllocatorDefault, width, height,
                kCVPixelFormatType_64RGBAHalf,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                &pixelBufferOut) == kCVReturnSuccess,
              let pixelBuffer = pixelBufferOut,
              let metal = MTLCreateSystemDefaultDevice(),
              let gpuOut = metal.makeBuffer(length: width * height * 16,
                                            options: .storageModeShared)
        else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
            halves.withUnsafeBytes { source in
                for row in 0..<height {
                    (base + row * rowBytes).copyMemory(
                        from: source.baseAddress! + row * width * 8,
                        byteCount: width * 8)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        guard converter.convertLinearOnGPU(pixelBuffer, into: gpuOut)
        else { return ("verify-log \(encoding.rawValue): GPU road unavailable", false) }
        let gpu = gpuOut.contents().assumingMemoryBound(to: Float.self)
        var worstGPU: Float = 0
        for i in 0..<(width * height * 4) {
            worstGPU = max(worstGPU, abs(gpu[i] - reference[i]))
        }

        var deepReference = [UInt8](repeating: 0, count: width * height * 4)
        let deepReferenceRan = halves.withUnsafeBytes { source in
            deepReference.withUnsafeMutableBufferPointer { dest in
                converter.convertDeepPacked(
                    source.baseAddress!, rowBytes: width * 8,
                    into: dest.baseAddress!)
            }
        }
        guard deepReferenceRan,
              let deepOut = metal.makeBuffer(length: width * height * 4,
                                             options: .storageModeShared),
              converter.convertDeepOnGPU(pixelBuffer, into: deepOut)
        else { return ("verify-log \(encoding.rawValue): deep GPU road unavailable",
                       false) }
        let deepGPU = deepOut.contents().assumingMemoryBound(to: UInt8.self)
        var worstDeepGPU = 0
        for i in 0..<(width * height * 4) {
            worstDeepGPU = max(worstDeepGPU,
                               abs(Int(deepGPU[i]) - Int(deepReference[i])))
        }

        guard let rampConverter = LogConverter(encoding: encoding,
                                               width: 256, height: 1)
        else { return nil }
        var rampHalves = [UInt16](repeating: 0, count: 256 * 4)
        var rampBytes = [UInt8](repeating: 0, count: 256 * 4)
        for code in 0..<256 {
            for channel in 0..<3 {
                rampHalves[code * 4 + channel] = Float16(Float(code) / 255).bitPattern
                rampBytes[code * 4 + channel] = UInt8(code)
            }
            rampHalves[code * 4 + 3] = Float16(1).bitPattern
            rampBytes[code * 4 + 3] = 255
        }
        var rampFloat = [Float](repeating: 0, count: 256 * 4)
        var rampTable = [UInt8](repeating: 0, count: 256 * 4)
        let rampsRan = rampHalves.withUnsafeBytes { source in
            rampFloat.withUnsafeMutableBufferPointer { dest in
                rampConverter.convertLinearPacked(
                    source.baseAddress!, rowBytes: 256 * 8,
                    into: dest.baseAddress!)
            }
        } && rampBytes.withUnsafeBytes { source in
            rampTable.withUnsafeMutableBytes { dest in
                rampConverter.convertPacked(
                    source.baseAddress!, rowBytes: 256 * 4, bgra: true,
                    into: dest.baseAddress!)
            }
        }
        guard rampsRan else { return nil }
        // Both paths taken to the *same* display signal before they are compared. The float path
        // holds engine input — scene light over diffuse white, no shoulder — so it takes the 8-bit
        // path's `displayRender` here; multiplying the 0.9 back in undoes the normalisation that
        // render applies again. Without that step this compared a shouldered path against an
        // unshouldered one and stood at ~13 codes for reasons no code change could move.
        var worstCodes: Float = 0
        for code in 0..<256 {
            for channel in 0..<3 {
                let scene = rampFloat[code * 4 + channel] * 0.9
                let encoded = LogConverter.encodeSRGB(
                    LogConverter.displayRender(scene)) * 255
                worstCodes = max(worstCodes,
                                 abs(encoded - Float(rampTable[code * 4 + channel])))
            }
        }

        let ok = worstGPU <= 1e-4 && worstCodes <= 2 && worstDeepGPU <= 1
            && worstBasis <= 1e-5
        let text = String(
            format: "verify-log %@: gpu-cpu %.2e linear, %d codes deep, "
                + "float-vs-table %.2f codes, working-basis %.2e %@",
            encoding.rawValue, worstGPU, worstDeepGPU, worstCodes, worstBasis,
            ok ? "ok" : "FAILED")
        return (text, ok)
    }

    private static func verifyLogBanding(
        _ encoding: VideoSourceEncoding
    ) -> (text: String, ok: Bool)? {
        let steps = 1024
        guard let deepRamp = LogConverter(encoding: encoding,
                                          width: steps, height: 1),
              let tableRamp = LogConverter(encoding: encoding,
                                           width: steps, height: 1)
        else { return nil }
        var halves = [UInt16](repeating: 0, count: steps * 4)
        var bytes = [UInt8](repeating: 0, count: steps * 4)
        for i in 0..<steps {
            let code = Float(i) / Float(steps - 1)
            for channel in 0..<3 {
                halves[i * 4 + channel] = Float16(code).bitPattern
                bytes[i * 4 + channel] = UInt8((code * 255).rounded())
            }
            halves[i * 4 + 3] = Float16(1).bitPattern
            bytes[i * 4 + 3] = 255
        }
        var deep = [UInt8](repeating: 0, count: steps * 4)
        var table = [UInt8](repeating: 0, count: steps * 4)
        let ran = halves.withUnsafeBytes { source in
            deep.withUnsafeMutableBufferPointer { dest in
                deepRamp.convertDeepPacked(source.baseAddress!,
                                           rowBytes: steps * 8,
                                           into: dest.baseAddress!)
            }
        } && bytes.withUnsafeBytes { source in
            table.withUnsafeMutableBytes { dest in
                tableRamp.convertPacked(source.baseAddress!,
                                        rowBytes: steps * 4, bgra: true,
                                        into: dest.baseAddress!)
            }
        }
        guard ran else { return nil }

        /// Largest jump between neighbouring codes, and how many of the 256
        /// output levels the ramp reaches.
        func contour(_ ramp: [UInt8]) -> (step: Int, levels: Int) {
            var step = 0
            var levels = Set<UInt8>()
            for i in 0..<steps {
                levels.insert(ramp[i * 4])
                if i > 0 {
                    step = max(step, abs(Int(ramp[i * 4])
                                         - Int(ramp[(i - 1) * 4])))
                }
            }
            return (step, levels.count)
        }
        let deepContour = contour(deep)
        let tableContour = contour(table)

        let ok = deepContour.step <= 2 && deepContour.levels >= 250
            && tableContour.step > deepContour.step
            && tableContour.levels < deepContour.levels
        let text = String(
            format: "verify-log %@: ramp deep %d levels step %d, "
                + "table %d levels step %d %@",
            encoding.rawValue, deepContour.levels, deepContour.step,
            tableContour.levels, tableContour.step, ok ? "ok" : "FAILED")
        return (text, ok)
    }

    // MARK: - Showing the two paths rather than counting them

    /// Develops one 10-bit frame down both paths and writes the prints out as pictures: Fotufilm
    /// --dump-path-images /path/to/dir `verify-preview-depth` says the deep path keeps 103 shadow
    /// levels where the shallow one keeps 43.
    @discardableResult
    static func dumpRoadImagesIfRequested() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--dump-road-images")
        else { return false }
        let directory = flag + 1 < arguments.count
            ? URL(fileURLWithPath: arguments[flag + 1])
            : FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        // A colour negative, not the pack's first entry.
        guard let stock = FilmStock.named("pro400h")
                ?? FilmStock.presetIDs.first.flatMap(FilmStock.named),
              let engine = HalideMetalFilmRenderer.shared,
              let device = MTLCreateSystemDefaultDevice() else {
            print("dump-road-images FAIL: no engine or no film")
            exit(1)
        }
        var options = FotufilmEngine.Options()
        options.grainScale = 0

        let width = 640, height = 400
        let scene = roadScene(width: width, height: height)
        engine.prepare(stock: stock, options: options,
                       frameWidth: width, frameHeight: height)

        // Build the previous tap representation: an 8-bit signal developed and published at 8 bits.
        var shallowBytes = [UInt8](repeating: 255, count: width * height * 4)
        var deepLinear = [Float](repeating: 1, count: width * height * 4)
        for index in stride(from: 0, to: width * height * 4, by: 4) {
            for channel in 0..<3 {
                let signal = scene[index + channel]
                shallowBytes[index + channel] =
                    UInt8((min(max(signal, 0), 1) * 255).rounded())
                deepLinear[index + channel] = ColorScience.srgbToLinear(signal)
            }
            deepLinear[index + 3] = 1
        }

        guard let shallow = engine.processSRGB8(
            shallowBytes, width: width, height: height,
            stock: stock, options: options, frameIndex: 0) else {
            print("dump-road-images FAIL: the 8-bit road did not run")
            exit(1)
        }
        // The live preview's schedule and the paused frame's, because those are the two paths that
        // changed and they do not develop alike.
        guard let live = developFloat(deepLinear, engine: engine,
                                      device: device, width: width,
                                      height: height, stock: stock,
                                      options: options, realtime: true),
              let still = developFloat(deepLinear, engine: engine,
                                       device: device, width: width,
                                       height: height, stock: stock,
                                       options: options, realtime: false) else {
            print("dump-road-images FAIL: the float road did not run")
            exit(1)
        }

        var lines: [String] = []
        for (name, deep, title) in [
            ("preview", live, "live preview tap — realtime schedule"),
            ("paused-frame", still, "paused frame and export — reference schedule")
        ] {
            let sheet = roadSheet(shallow: shallow, deep: deep,
                                  width: width, height: height, title: title)
            let url = directory.appendingPathComponent("road-\(name).png")
            writeSheet(sheet.image, to: url)
            lines.append(String(
                format: "%@: worst %.1f codes, mean %.2f; shadow wedge levels "
                    + "8-bit road %d, deep road %d shown / %d held -> %@",
                name, sheet.worst, sheet.mean, sheet.shallowLevels,
                sheet.deepLevelsShown, sheet.deepLevelsHeld, url.path))
        }
        for line in lines { print("dump-road-images: \(line)") }
        print("dump-road-images DONE")
        exit(0)
    }

    private static func roadScene(width: Int, height: Int) -> [Float] {
        var scene = [Float](repeating: 1, count: width * height * 4)
        let skyRows = 0..<(height * 65 / 100)
        let wedgeRows = skyRows.upperBound..<(height * 82 / 100)
        for y in 0..<height {
            for x in 0..<width {
                let across = Float(x) / Float(width - 1)
                var rgb: SIMD3<Float>
                if skyRows.contains(y) {
                    // A dusk sky: bright at the horizon, falling away upward, warm on one side and
                    // cool on the other.
                    let toHorizon = Float(y) / Float(skyRows.count - 1)
                    let base = 0.09 + 0.42 * powf(toHorizon, 1.7)
                    rgb = SIMD3(base * (0.86 + 0.20 * across),
                                base * 0.94,
                                base * (1.10 - 0.18 * across))
                } else if wedgeRows.contains(y) {
                    rgb = SIMD3(repeating: across)          // full-range wedge
                } else {
                    // The deep shadow wedge: the bottom tenth of the scale, the region a log
                    // encoding exists to protect and the one eight bits merges hardest.
                    rgb = SIMD3(repeating: across * 0.10)
                }
                let index = (y * width + x) * 4
                for channel in 0..<3 {
                    // Ten bits, and no more: the codes a 10-bit clip stores.
                    let clamped = min(max(rgb[channel], 0), 1)
                    scene[index + channel] = (clamped * 1023).rounded() / 1023
                }
                scene[index + 3] = 1
            }
        }
        return scene
    }

    private static func roadSheet(
        shallow: [UInt8], deep: [UInt16], width: Int, height: Int, title: String
    ) -> (image: CGImage, worst: Float, mean: Float, shallowLevels: Int,
          deepLevelsShown: Int, deepLevelsHeld: Int) {
        var worst: Float = 0, total: Float = 0
        for index in stride(from: 0, to: width * height * 4, by: 4) {
            for channel in 0..<3 {
                let a = Float(shallow[index + channel])
                let b = Float(deep[index + channel]) * 255 / 65535
                worst = max(worst, abs(a - b))
                total += abs(a - b)
            }
        }
        // Gradation across the shadow wedge, green channel — the luminance the eye reads banding
        // in, and counting the three together would report channel separation as gradation.
        var shallowLevels = Set<UInt8>()
        var deepShown = Set<UInt8>(), deepHeld = Set<UInt16>()
        let shadowRow = height * 91 / 100
        for x in 0..<width {
            let index = (shadowRow * width + x) * 4 + 1
            shallowLevels.insert(shallow[index])
            deepHeld.insert(deep[index])
            deepShown.insert(UInt8(Float(deep[index]) * 255 / 65535))
        }

        // Difference, at a gain that puts a one-code move at a quarter scale.
        var difference = [UInt8](repeating: 255, count: width * height * 4)
        let gain: Float = 64
        for index in stride(from: 0, to: width * height * 4, by: 4) {
            for channel in 0..<3 {
                let a = Float(shallow[index + channel])
                let b = Float(deep[index + channel]) * 255 / 65535
                difference[index + channel] =
                    UInt8(min(abs(a - b) * gain, 255).rounded())
            }
        }

        let margin = 12, label = 22, stripLabel = 20, band = height / 5
        let panelWidth = width
        let panelHeight = label + height + stripLabel + band
        let sheetWidth = margin + 3 * (panelWidth + margin)
        let sheetHeight = margin + label + margin + panelHeight + margin
        guard let context = CGContext(
            data: nil, width: sheetWidth, height: sheetHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { fatalError("no sheet context") }
        context.setFillColor(CGColor(gray: 0.10, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: sheetWidth, height: sheetHeight))

        let previous = NSGraphicsContext.current
        NSGraphicsContext.current =
            NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.current = previous }
        func draw(_ text: String, atX x: Int, y: Int, size: CGFloat = 13) {
            NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular),
                .foregroundColor: NSColor.white
            ]).draw(at: NSPoint(x: x, y: y))
        }
        draw(title, atX: margin, y: sheetHeight - margin - label, size: 15)

        // The wedge, cropped to its left third and lifted three stops, because at unity the region
        // this whole change is about prints as black.
        let stripTop = height * 83 / 100
        let stripWidth = width, stripHeight = height - stripTop
        func strip(_ read: (Int) -> Float,
                   floor: SIMD3<Float>, gain: SIMD3<Float>) -> [UInt8] {
            var out = [UInt8](repeating: 255, count: stripWidth * stripHeight * 4)
            for y in 0..<stripHeight {
                for x in 0..<stripWidth {
                    let source = ((stripTop + y) * width + x) * 4
                    let destination = (y * stripWidth + x) * 4
                    for channel in 0..<3 {
                        let lifted = (read(source + channel) - floor[channel])
                            * gain[channel]
                        out[destination + channel] =
                            UInt8(min(max(lifted, 0), 255).rounded())
                    }
                }
            }
            return out
        }
        // One stretch, measured off the shallow strip and applied unchanged to both, so the two
        // panels stay comparable.
        var floor = SIMD3<Float>(repeating: 255)
        var ceiling = SIMD3<Float>(repeating: 0)
        for y in 0..<stripHeight {
            for x in 0..<stripWidth {
                let index = ((stripTop + y) * width + x) * 4
                for channel in 0..<3 {
                    let value = Float(shallow[index + channel])
                    floor[channel] = min(floor[channel], value)
                    ceiling[channel] = max(ceiling[channel], value)
                }
            }
        }
        // One gain for all three, off the widest channel. A per-channel gain would normalise the
        // colour away and make a print with almost nothing in its red record look like one that has
        // plenty.
        let widest = max(ceiling.x - floor.x,
                         max(ceiling.y - floor.y, ceiling.z - floor.z))
        let lift = SIMD3<Float>(repeating: 255 / max(widest, 1))

        let panels: [(String, CGImage?, [UInt8])] = [
            ("before — 8-bit decode, 8-bit publish",
             rgbaImage(shallow, width: width, height: height),
             strip({ Float(shallow[$0]) }, floor: floor, gain: lift)),
            ("after — deep decode, 16-bit publish",
             deepImage(deep, width: width, height: height),
             strip({ Float(deep[$0]) * 255 / 65535 }, floor: floor, gain: lift)),
            (String(format: "difference x%.0f", gain),
             rgbaImage(difference, width: width, height: height),
             strip({ Float(difference[$0]) },
                   floor: .zero, gain: SIMD3(repeating: 2)))
        ]
        let top = sheetHeight - margin - label - margin
        draw(String(format: "below: the deep shadow wedge, its own black pulled"
                    + " up and the rest stretched x%.0f — the same stretch on"
                    + " all three", lift.x),
             atX: margin, y: top - label - height - stripLabel + 4, size: 11)
        for (column, panel) in panels.enumerated() {
            let x = margin + column * (panelWidth + margin)
            draw(panel.0, atX: x, y: top - label + 4, size: 12)
            guard let image = panel.1 else { continue }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: x, y: top - label - height,
                                           width: panelWidth, height: height))
            // At 1:1 and lifted, which is all it takes: the shallow path's steps are four times
            // wider than the deep path's.
            if let strip = rgbaImage(panel.2, width: stripWidth,
                                     height: stripHeight) {
                context.draw(strip, in: CGRect(
                    x: x, y: top - label - height - stripLabel - band,
                    width: panelWidth, height: band))
            }
        }
        guard let image = context.makeImage() else { fatalError("no sheet") }
        return (image, worst, total / Float(width * height * 3),
                shallowLevels.count, deepShown.count, deepHeld.count)
    }

    private static func rgbaImage(
        _ bytes: [UInt8], width: Int, height: Int
    ) -> CGImage? {
        guard let data = CFDataCreate(nil, bytes, bytes.count),
              let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue:
                CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)
    }

    private static func deepImage(
        _ values: [UInt16], width: Int, height: Int
    ) -> CGImage? {
        let pixels = UnsafeMutableBufferPointer<UInt16>
            .allocate(capacity: values.count)
        _ = pixels.initialize(from: values)
        return PrintEncoding.makeImage(
            takingOwnershipOf: pixels, width: width, height: height,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    private static func writeSheet(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
