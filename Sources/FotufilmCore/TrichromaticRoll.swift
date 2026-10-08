import Foundation

/// Exposures scanned under red, green and blue light, merged frame by frame into trichromatic
/// scans (`TrichromaticScan`). Exposures may alternate light by light or come in passes, a roll at
/// a time; they are taken in the order their names give, the order the camera made them.
public enum TrichromaticRoll {
    /// An exposure decoded as linear RGBA, through the camera's daylight balance where it is a
    /// RAW: about `longEdge` long to measure, or whole (nil) to merge.
    public typealias Decode = (_ url: URL, _ longEdge: Int?) throws
        -> (rgba: [Float], width: Int, height: Int)

    /// A merged frame: its exposures (red, green, blue) and its scan.
    public struct Frame {
        public var sources: [URL]
        public var scan: URL
        public var green: TrichromaticScan.Registration
        public var blue: TrichromaticScan.Registration
    }

    /// What became of every exposure.
    public struct Outcome {
        public var frames: [Frame] = []
        /// Frames that could not be merged, and why.
        public var failures: [(sources: [URL], reason: String)] = []
        /// Exposures of no picture, and exposures under white or mixed light, left out.
        public var blanks: [URL] = []
        public var others: [URL] = []
    }

    public struct Cancelled: Error {}

    /// Where a frame's scan goes by default: beside its red exposure, named after it.
    public static func scanURL(red: URL) -> URL {
        red.deletingLastPathComponent()
            .appendingPathComponent(red.deletingPathExtension().lastPathComponent + "-rgb.tif")
    }

    /// Measures, groups and merges `files`; `store` keeps each frame's scan (given its red
    /// exposure) and says where. `progress` hears the share done and what is under way.
    public static func merge(_ files: [URL], decode: Decode,
                             store: (_ scan: Data, _ red: URL) throws -> URL,
                             progress: (_ done: Double, _ status: String) -> Void = { _, _ in },
                             shouldContinue: () -> Bool = { true }) throws -> Outcome {
        let files = files.sorted {
            $0.path.compare($1.path, options: [.numeric, .caseInsensitive]) == .orderedAscending
        }
        var measured: [TrichromaticScan.Measured] = []
        for (index, file) in files.enumerated() {
            guard shouldContinue() else { throw Cancelled() }
            progress(0.2 * Double(index) / Double(files.count), "Measuring \(file.lastPathComponent)")
            let preview = try decode(file, 1024)
            measured.append(try TrichromaticScan.measure(preview.rgba, width: preview.width,
                                                         height: preview.height))
        }
        var outcome = Outcome()
        outcome.blanks = zip(files, measured).filter { $1.light == .blank }.map(\.0)
        outcome.others = zip(files, measured).filter { $1.light == .other }.map(\.0)
        let lights = measured.map(\.light)
        let frames: [[Int]]
        do {
            frames = try TrichromaticScan.frames(lights)
        } catch TrichromaticScan.Failure.ungrouped(let index) {
            throw Ungrouped(at: files[index], lights: lights)
        }

        for (number, frame) in frames.enumerated() {
            let sources = frame.map { files[$0] }
            func done(_ step: Int) -> Double {
                0.2 + 0.8 * (Double(number) + Double(step) / 4) / Double(frames.count)
            }
            do {
                var layers: [[Float]] = []
                var size: (width: Int, height: Int)?
                for (light, index) in frame.enumerated() {
                    guard shouldContinue() else { throw Cancelled() }
                    progress(done(light), "Reading \(files[index].lastPathComponent)")
                    let exposure = try decode(files[index], nil)
                    if let size, size.width != exposure.width || size.height != exposure.height {
                        throw Mismatch()
                    }
                    size = (exposure.width, exposure.height)
                    layers.append(try TrichromaticScan.layer(exposure.rgba, width: exposure.width,
                                                             height: exposure.height,
                                                             colour: measured[index].colour))
                }
                guard shouldContinue(), let size else { throw Cancelled() }
                progress(done(3), "Merging \(sources[0].lastPathComponent)")
                let green = try TrichromaticScan.register(layers[1], to: layers[0], width: size.width,
                                                          height: size.height)
                let blue = try TrichromaticScan.register(layers[2], to: layers[0], width: size.width,
                                                         height: size.height)
                let scan = try TrichromaticScan.merge(red: layers[0], green: layers[1],
                                                      blue: layers[2], width: size.width,
                                                      height: size.height, green: green, blue: blue)
                outcome.frames.append(Frame(sources: sources, scan: try store(scan, sources[0]),
                                            green: green, blue: blue))
            } catch let cancelled as Cancelled {
                throw cancelled
            } catch {
                outcome.failures.append((sources, error.localizedDescription))
            }
        }
        progress(1, "Merged")
        return outcome
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
