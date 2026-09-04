import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmImaging)
import FotufilmImaging
#endif

/// Every intermediate of a still-capture develop, written to disk for inspection — the debugging
/// path for "the photograph came out wrong and the question is which stage did it".
enum CaptureDump {
    private static let mode =
        ProcessInfo.processInfo.environment["FOTUFILM_CAPTURE_DUMP"]

    static var isEnabled: Bool { mode != nil && mode != "0" }

    private static var wantsRawScene: Bool { mode == "raw" }

    private static var ladderEdge: Int {
        Int(ProcessInfo.processInfo
            .environment["FOTUFILM_CAPTURE_DUMP_EDGE"] ?? "") ?? 2048
    }

    /// One optional stage of the physical pipeline: what to call it, the feature bit that says the
    /// recipe actually runs it, and how to switch it off at the source the engine derives it from.
    struct Stage {
        let label: String
        let feature: Int32
        let kill: (inout FilmStock, inout EditState) -> Void
    }

    /// In pipeline order.
    static let stages: [Stage] = [
        Stage(label: "flare", feature: FilmEngineFeature.flare) { stock, _ in
            stock.flare = 0
        },
        Stage(label: "emulsion-diffusion", feature: FilmEngineFeature.mtf) { stock, _ in
            stock.emulsionDiffusionMM = [0, 0, 0]
            stock.emulsionDiffusionSecondaryMM = [0, 0, 0]
            stock.emulsionDiffusionPrimaryShare = [1, 1, 1]
            stock.lumaDiffusionMM = 0
        },
        Stage(label: "halation", feature: FilmEngineFeature.halation) { _, state in
            state.halation = 0
        },
        Stage(label: "couplers", feature: FilmEngineFeature.couplers) { stock, _ in
            // The geometry has to go first and on its own line: the engine prefers it over the
            // matrix, so zeroing the matrix alone left this stage doing nothing at all for every
            // stock that states one. Assigning nil does not disturb the cached matrix, which the
            // next line clears.
            stock.couplerGeometry = nil
            stock.couplerInhibition = [[0, 0, 0], [0, 0, 0], [0, 0, 0]]
            stock.couplerDiffusionMM = 0
        },
        Stage(label: "adjacency", feature: FilmEngineFeature.adjacency) { stock, _ in
            stock.adjacencyStrength = 0
        },
        Stage(label: "grain", feature: FilmEngineFeature.grain) { _, state in
            state.grain = 0
        },
    ]

    /// Writes the whole dump for one capture.
    static func dump(negative data: Data, raw: Bool,
                     source: PhotoSource, state: EditState,
                     final rendered: Rendered, hdr: Bool, exact: Bool) {
        guard isEnabled, let stock = state.stock else { return }
        guard let directory = currentPressDirectory ?? newDumpDirectory()
        else { return }

        let negativeName = "00-negative." + (raw ? "dng" : sniffExtension(of: data))
        try? data.write(to: directory.appendingPathComponent(negativeName))

        rendered.write(to: directory.appendingPathComponent("90-final.jpg"),
                       format: .jpeg, metadata: .strip)
        if hdr && state.supportsHDROutput {
            rendered.writeHDR(to: directory.appendingPathComponent("91-final-hdr.heic"),
                              as: .hlg, metadata: .strip)
        }

        guard let scene = FilmRender.scene(source: source, state: state,
                                           longEdge: ladderEdge) else {
            print("CaptureDump: could not decode the scene for the ladder")
            writeManifest(to: directory, state: state, stock: stock, raw: raw,
                          hdr: hdr, exact: exact, scene: nil, rendered: rendered,
                          rungs: [])
            return
        }
        writeScenePNG(scene, to: directory.appendingPathComponent("01-scene-linear.png"))
        if wantsRawScene {
            let bytes = Data(bytes: scene.pixels.baseAddress,
                             count: scene.width * scene.height * 8)
            try? bytes.write(to: directory
                .appendingPathComponent("01-scene-linear.rgba16f.bin"))
        }

        let mask = FilmEngineInvocation(
            stock: stock, options: state.options,
            width: scene.width, height: scene.height).featureMask
        let active = stages.filter { mask & $0.feature != 0 }

        var rungs: [[String: Any]] = []
        for step in 0...active.count {
            var rungStock = stock
            var rungState = state
            for stage in active[step...] { stage.kill(&rungStock, &rungState) }
            let label = step == 0 ? "base" : active[step - 1].label
            let file = "2\(step)-\(label).jpg"
            let began = Date()
            guard let developed = FilmRender.develop(
                scene, state: rungState, exact: exact, stock: rungStock
            )?.image else {
                print("CaptureDump: rung \(label) failed to develop")
                continue
            }
            let ms = Date().timeIntervalSince(began) * 1000
            developed.write(to: directory.appendingPathComponent(file),
                            format: .jpeg, quality: 0.92, metadata: .strip)
            rungs.append([
                "file": file,
                "stages": ["base"] + active[..<step].map(\.label),
                "developMS": (ms * 10).rounded() / 10,
            ])
        }

        writeManifest(to: directory, state: state, stock: stock, raw: raw,
                      hdr: hdr, exact: exact, scene: scene, rendered: rendered,
                      rungs: rungs)
        let written = (try? FileManager.default
            .contentsOfDirectory(atPath: directory.path).count) ?? 0
        print("CaptureDump: wrote \(written) files to \(directory.path)")
    }

    /// The no-film press — the app calls it "Normal" — develops nothing: the
    /// device's own photograph is the output.
    static func dump(plain data: Data, raw: Bool) {
        guard isEnabled,
              let directory = currentPressDirectory ?? newDumpDirectory()
        else { return }
        let name = "00-photograph." + (raw ? "dng" : sniffExtension(of: data))
        try? data.write(to: directory.appendingPathComponent(name))
        let manifest: [String: Any] = [
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
            "stockID": StockPreset.noFilmID,
            "stock": StockPreset.noFilmName,
            "rawNegative": raw,
            "notes": "No film loaded: the device's own photograph, as written.",
        ]
        if let json = try? JSONSerialization.data(
            withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) {
            try? json.write(to: directory.appendingPathComponent("manifest.json"))
        }
        print("CaptureDump: wrote plain capture to \(directory.path)")
    }

    /// One press of an automated run: the film to load and, when the spec says, the dynamic range
    /// to deliver in instead of the stored setting.
    struct AutoStep {
        let stockID: String
        let range: AppSettings.DynamicRange?
    }

    /// FOTUFILM_CAPTURE_AUTO holds a comma-separated list of presses, `<stockID>[@hdr|@sdr]`.
    static var autoSteps: [AutoStep]? {
        guard isEnabled, let spec = ProcessInfo.processInfo
            .environment["FOTUFILM_CAPTURE_AUTO"], !spec.isEmpty
        else { return nil }
        let steps = spec.split(separator: ",").compactMap { press -> AutoStep? in
            let parts = press.split(separator: "@")
            guard let stock = parts.first, !stock.isEmpty else { return nil }
            var range: AppSettings.DynamicRange?
            if parts.count > 1 {
                guard let stated = AppSettings.DynamicRange(
                    rawValue: String(parts[1])) else { return nil }
                range = stated
            }
            return AutoStep(stockID: String(stock), range: range)
        }
        return steps.isEmpty ? nil : steps
    }

    /// Whether this launch is an automated run.
    static var isAutoRun: Bool { autoSteps != nil }

    /// Exercises the camera-return race by closing the editor before the background still save has
    /// finished. This is deliberately tied to an automated capture so it cannot affect an ordinary
    /// launch, even if a stale environment variable is present.
    static var autoClosesEditor: Bool {
        isAutoRun && ProcessInfo.processInfo.environment[
            "FOTUFILM_CAPTURE_AUTO_CLOSE_EDITOR"] == "1"
    }

    /// The host polls for auto-complete.json rather than watching a console.
    static func clearAutoRunReceipt() {
        try? FileManager.default.removeItem(
            at: dumpsRoot.appendingPathComponent("auto-complete.json"))
    }

    static func writeAutoRunReceipt(viewfinderRestored: Bool? = nil) {
        stampsLock.lock()
        let written = stamps
        stampsLock.unlock()
        var receipt: [String: Any] = [
            "completedAt": ISO8601DateFormatter().string(from: Date()),
            "dumps": written,
        ]
        if let viewfinderRestored {
            receipt["viewfinderRestored"] = viewfinderRestored
        }
        try? FileManager.default.createDirectory(
            at: dumpsRoot, withIntermediateDirectories: true)
        if let json = try? JSONSerialization.data(
            withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]) {
            try? json.write(
                to: dumpsRoot.appendingPathComponent("auto-complete.json"))
        }
        print("CaptureDump: auto run complete — \(written.count) dumps")
    }

    private static var dumpsRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/capture-dumps")
    }

    private static let stampsLock = NSLock()
    private static var stamps: [String] = []
    private static var pressDirectoryStorage: URL?

    /// The directory of the press in flight.
    static func openPressDirectory() {
        guard isEnabled else { return }
        let directory = newDumpDirectory()
        stampsLock.lock()
        pressDirectoryStorage = directory
        stampsLock.unlock()
    }

    static var currentPressDirectory: URL? {
        stampsLock.lock()
        defer { stampsLock.unlock() }
        return pressDirectoryStorage
    }

    private static var activeSamples = 0

    static func beginViewfinderSample() {
        stampsLock.lock()
        activeSamples += 1
        stampsLock.unlock()
    }

    static func endViewfinderSample() {
        stampsLock.lock()
        activeSamples -= 1
        stampsLock.unlock()
    }

    static var isSamplingViewfinder: Bool {
        stampsLock.lock()
        defer { stampsLock.unlock() }
        return activeSamples > 0
    }

    private static func newDumpDirectory() -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = formatter.string(from: Date())
        var stamp = base
        var attempt = 1
        while FileManager.default.fileExists(
            atPath: dumpsRoot.appendingPathComponent(stamp).path) {
            attempt += 1
            stamp = "\(base)-\(attempt)"
        }
        let directory = dumpsRoot.appendingPathComponent(stamp)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        } catch {
            print("CaptureDump: could not create \(directory.path): \(error)")
            return nil
        }
        stampsLock.lock()
        stamps.append(stamp)
        stampsLock.unlock()
        return directory
    }

    /// The viewfinder sample's pixels, written here so both dumps speak one vocabulary: the sample
    /// is taken by the camera engine, where the buffers and the realtime engine live, but the
    /// encoding is this file's.
    static func write(rgba8 bytes: UnsafeRawPointer, width: Int, height: Int,
                      to url: URL) {
        guard let context = CGContext(
            data: UnsafeMutableRawPointer(mutating: bytes),
            width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.displayP3)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
            let image = context.makeImage() else { return }
        writeImage(image, to: url)
    }

    /// The HDR path's linear float rows, through the same sRGB encode the scene PNG gets — light
    /// above display white clips in the file, as it does there.
    static func write(linearFloat values: UnsafePointer<Float>,
                      width: Int, height: Int, to url: URL) {
        let encoded = UnsafeMutableBufferPointer<UInt16>
            .allocate(capacity: width * height * 4)
        PrintEncoding.encodeRows(
            UnsafeBufferPointer(start: values, count: width * height * 4),
            rows: 0..<height, width: width, into: encoded, transfer: .srgb)
        guard let image = PrintEncoding.makeImage(
            takingOwnershipOf: encoded, width: width, height: height,
            colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!
        ) else { return }
        writeImage(image, to: url)
    }

    private static func writeImage(_ image: CGImage, to url: URL) {
        let type: UTType = url.pathExtension == "png" ? .png : .jpeg
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, 1, nil) else { return }
        let options: CFDictionary? = type == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary
            : nil
        CGImageDestinationAddImage(destination, image, options)
        CGImageDestinationFinalize(destination)
    }

    private static func writeScenePNG(_ scene: FilmRender.Scene, to url: URL) {
        let width = scene.width, height = scene.height
        let encoded = UnsafeMutableBufferPointer<UInt16>
            .allocate(capacity: width * height * 4)
        let bandRows = 64
        var band = [Float](repeating: 0,
                           count: min(bandRows, height) * width * 4)
        scene.withPixels { pixels in
            var row = 0
            while row < height {
                let upper = min(height, row + bandRows)
                band.withUnsafeMutableBufferPointer { buffer in
                    for index in 0..<((upper - row) * width * 4) {
                        buffer[index] = Float(pixels[row * width * 4 + index])
                    }
                    PrintEncoding.encodeRows(
                        UnsafeBufferPointer(buffer), rows: row..<upper,
                        width: width, into: encoded, transfer: .srgb)
                }
                row = upper
            }
        }
        guard let image = PrintEncoding.makeImage(
            takingOwnershipOf: encoded, width: width, height: height,
            colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!
        ) else {
            print("CaptureDump: could not build the scene image")
            return
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    private static func writeManifest(
        to directory: URL, state: EditState, stock: FilmStock, raw: Bool,
        hdr: Bool, exact: Bool, scene: FilmRender.Scene?, rendered: Rendered,
        rungs: [[String: Any]]
    ) {
        var manifest: [String: Any] = [
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
            "stockID": state.stockID,
            "stock": stock.name,
            "format": state.formatID,
            "rawNegative": raw,
            "hdr": hdr,
            "exactMath": exact,
            "ladderLongEdge": ladderEdge,
            "final": ["width": rendered.image.width,
                      "height": rendered.image.height],
            "rungs": rungs,
            "options": [
                "exposureEV": state.exposure,
                "temperatureMired": state.temperatureMired,
                "tint": state.tint,
                "highlights": state.highlights,
                "shadows": state.shadows,
                "localTone": state.localTone,
                "saturation": state.saturation,
                "vibrance": state.vibrance,
                "grain": state.grain,
                "halation": state.halation,
                "halationColour": state.halationColour,
                "halationSpectrum": state.halationSpectrum,
                "couplers": state.couplers,
                "printCorrection": state.printCorrection,
                "seed": String(state.seed, radix: 16),
            ],
            "notes": "Ladder frames are uncropped and SDR; each rung adds its "
                + "named stage to every stage before it, so the difference "
                + "between consecutive rungs is that stage's contribution.",
        ]
        if let scene {
            var about: [String: Any] = [
                "width": scene.width,
                "height": scene.height,
                "contentHeadroom": scene.contentHeadroom,
            ]
            if let baked = scene.bakedMired { about["bakedMired"] = baked }
            manifest["scene"] = about
        }
        guard let json = try? JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? json.write(to: directory.appendingPathComponent("manifest.json"))
    }

    private static func sniffExtension(of data: Data) -> String {
        data.starts(with: [0xFF, 0xD8]) ? "jpg" : "heic"
    }
}
