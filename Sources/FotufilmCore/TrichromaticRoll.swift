import Foundation

/// Exposures scanned under red, green and blue light, merged frame by frame into trichromatic
/// scans (`TrichromaticScan`). Exposures may come frame by frame or in passes, a roll at
/// a time; they are taken in the order their names give, the order the camera made them.
public enum TrichromaticRoll {
    /// An exposure decoded as linear RGBA, through the camera's daylight balance where it is a
    /// RAW.
    public typealias Decode = (_ url: URL) throws -> (rgba: [Float], width: Int, height: Int)

    /// A merged frame: its exposures (red, green, blue) and its scan.
    public struct Frame {
        public var sources: [URL]
        public var scan: URL
        public var green: TrichromaticScan.Registration
        public var blue: TrichromaticScan.Registration
        /// Green or blue lined up only loosely: the scan fringes where the layers part.
        public var loose: Bool { green.loose || blue.loose }
    }

    /// What became of every exposure.
    public struct Outcome {
        public var frames: [Frame] = []
        /// Frames that could not be merged, and why.
        public var failures: [(sources: [URL], reason: String)] = []
        /// Exposures of no picture, and exposures under white or mixed light, left out.
        public var blanks: [URL] = []
        public var others: [URL] = []
        /// Exposures repeated by a later exposure under the same light, left out for the repeat,
        /// as a frame retaken.
        public var repeats: [URL] = []
    }

    public struct Cancelled: Error {}

    /// Where a frame's scan goes by default: beside its red exposure, named after it.
    public static func scanURL(red: URL) -> URL {
        red.deletingLastPathComponent()
            .appendingPathComponent(red.deletingPathExtension().lastPathComponent + "-rgb.tif")
    }

    /// How many exposures a computer reads at once: decoders run side by side, each holding an
    /// exposure's pixels.
    public static var readers: Int {
        min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
    }

    /// Measures, groups and merges `files`; `store` keeps each frame's scan (given its red
    /// exposure) and says where. `progress` hears the share done and what is under way.
    /// `readers` exposures are read at once, so `decode` must be safe to call side by side.
    ///
    /// Each exposure is decoded once: measured, then its layer kept in a temporary folder until
    /// the roll is grouped, since a roll scanned a pass at a time completes no frame before its
    /// last pass.
    public static func merge(_ files: [URL], decode: Decode, readers: Int = 1,
                             store: (_ scan: Data, _ red: URL) throws -> URL,
                             progress: (_ done: Double, _ status: String) -> Void = { _, _ in },
                             shouldContinue: () -> Bool = { true }) throws -> Outcome {
        let files = files.sorted {
            $0.path.compare($1.path, options: [.numeric, .caseInsensitive]) == .orderedAscending
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("trichromatic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Reading takes most of the time: registering and merging a frame takes about as long as
        // reading one of its exposures.
        let reading = 3.0 / 4
        var lights = [TrichromaticScan.Light](repeating: .other, count: files.count)
        var layers: [Int: Layer] = [:]
        var next = 0, read = 0
        var failure: Error?
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: max(1, min(readers, files.count))) { _ in
            while true {
                lock.lock()
                let index = next
                next += 1
                let going = index < files.count && failure == nil
                if going {
                    progress(reading * Double(read) / Double(files.count),
                             "Reading \(files[index].lastPathComponent)")
                }
                lock.unlock()
                guard going else { return }
                do {
                    guard shouldContinue() else { throw Cancelled() }
                    let exposure = try decode(files[index])
                    let measured = try TrichromaticScan.measure(exposure.rgba, width: exposure.width,
                                                                height: exposure.height)
                    var layer: Layer?
                    if [.red, .green, .blue].contains(measured.light) {
                        layer = Layer(url: folder.appendingPathComponent("\(index).layer"),
                                      width: exposure.width, height: exposure.height)
                        try layer?.write(TrichromaticScan.layer(exposure.rgba, width: exposure.width,
                                                                height: exposure.height,
                                                                colour: measured.colour))
                    }
                    lock.lock()
                    lights[index] = measured.light
                    layers[index] = layer
                    read += 1
                    lock.unlock()
                } catch {
                    lock.lock()
                    if failure == nil { failure = error }
                    lock.unlock()
                    return
                }
            }
        }
        if let failure { throw failure }
        var outcome = Outcome()
        outcome.blanks = zip(files, lights).filter { $1 == .blank }.map(\.0)
        outcome.others = zip(files, lights).filter { $1 == .other }.map(\.0)
        // A frame exposed twice under one light, the second time straight away or after its other
        // lights: the later exposure is kept.
        var grouped = lights
        var last: [TrichromaticScan.Light: Int] = [:]
        for later in layers.keys.sorted() {
            defer { last[lights[later]] = later }
            guard let earlier = last[lights[later]] else { continue }
            guard shouldContinue() else { throw Cancelled() }
            let a = layers[earlier]!, b = layers[later]!
            guard a.width == b.width, a.height == b.height,
                  try b.withSamples({ later in
                      try a.withSamples { earlier in
                          try TrichromaticScan.repeats(later, earlier: earlier, width: a.width,
                                                       height: a.height)
                      }
                  })
            else { continue }
            grouped[earlier] = .other
            outcome.repeats.append(files[earlier])
            try? FileManager.default.removeItem(at: a.url)
        }
        let frames: [[Int]]
        do {
            frames = try TrichromaticScan.frames(grouped)
        } catch TrichromaticScan.Failure.ungrouped(let index) {
            throw Ungrouped(at: files[index], lights: grouped)
        }

        for (number, frame) in frames.enumerated() {
            guard shouldContinue() else { throw Cancelled() }
            let sources = frame.map { files[$0] }
            progress(reading + (1 - reading) * Double(number) / Double(frames.count),
                     "Merging \(sources[0].lastPathComponent)")
            do {
                let stored = frame.map { layers[$0]! }
                defer { stored.forEach { try? FileManager.default.removeItem(at: $0.url) } }
                let (width, height) = (stored[0].width, stored[0].height)
                guard stored.allSatisfy({ $0.width == width && $0.height == height }) else {
                    throw Mismatch()
                }
                let red = try stored[0].read(), green = try stored[1].read()
                let blue = try stored[2].read()
                let greenFit = try TrichromaticScan.register(green, to: red, width: width,
                                                             height: height)
                let blueFit = try TrichromaticScan.register(blue, to: red, width: width,
                                                            height: height)
                let scan = try TrichromaticScan.merge(red: red, green: green, blue: blue,
                                                      width: width, height: height,
                                                      green: greenFit, blue: blueFit)
                outcome.frames.append(Frame(sources: sources, scan: try store(scan, sources[0]),
                                            green: greenFit, blue: blueFit))
            } catch let cancelled as Cancelled {
                throw cancelled
            } catch {
                outcome.failures.append((sources, error.localizedDescription))
            }
        }
        progress(1, "Merged")
        return outcome
    }

    /// One exposure's layer, kept as raw floats while the roll is read.
    struct Layer {
        var url: URL
        var width: Int, height: Int

        func write(_ samples: [Float]) throws {
            try samples.withUnsafeBytes { try Data($0).write(to: url) }
        }

        func read() throws -> [Float] { try withSamples(Array.init) }

        func withSamples<T>(_ body: (UnsafeBufferPointer<Float>) throws -> T) throws -> T {
            let data = try Data(contentsOf: url, options: .alwaysMapped)
            guard data.count == width * height * MemoryLayout<Float>.size else { throw Mismatch() }
            return try data.withUnsafeBytes { try body($0.bindMemory(to: Float.self)) }
        }
    }

    /// Exposures that do not group into frames: where the order breaks, and how many there are
    /// of each light.
    public struct Ungrouped: LocalizedError {
        public var at: URL
        public var lights: [TrichromaticScan.Light]
        public var errorDescription: String? {
            let count = { (light: TrichromaticScan.Light) in lights.filter { $0 == light }.count }
            return "The exposures do not group into frames from \(at.lastPathComponent) on "
                + "(red \(count(.red)), green \(count(.green)), blue \(count(.blue))). Choose each "
                + "frame's red, green and blue exposures, or whole passes of equal length."
        }
    }

    struct Mismatch: LocalizedError {
        var errorDescription: String? { "The exposures are not the same size." }
    }
}
