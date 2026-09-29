import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmEditModel)
import FotufilmEditModel
#endif

/// Export All (`exportBatch`): every photograph open in the editor, each with its own edit, into
/// one folder. Three stages overlap: the next photographs are decoded and framed on worker
/// threads, the current one develops on the GPU, and the ones before it are encoded and written
/// on others, so the GPU is never waiting on a decoder or an encoder. How far each stage runs
/// ahead is bounded by the machine's memory (`BatchPlan`).
extension HostService {
    /// How many photographs may be in each stage at once.
    struct BatchPlan: Equatable {
        /// Photographs decoded and framed ahead of the one developing.
        var ahead: Int
        /// Decodes at once.
        var decoders: Int
        /// Developed photographs being encoded and written at once.
        var encoders: Int

        /// A 45 MP photograph holds about 0.7 GB decoded and as much again framed, so the stages
        /// run further ahead only where memory allows it.
        static func forMachine(memory: UInt64 = ProcessInfo.processInfo.physicalMemory,
                               cores: Int = ProcessInfo.processInfo.activeProcessorCount) -> BatchPlan {
            let gigabytes = memory >> 30
            let encoders = max(1, min(3, cores / 4))
            if gigabytes >= 32 { return BatchPlan(ahead: 2, decoders: 2, encoders: encoders) }
            if gigabytes >= 16 { return BatchPlan(ahead: 1, decoders: 1, encoders: min(2, encoders)) }
            return BatchPlan(ahead: 1, decoders: 1, encoders: 1)
        }
    }

    /// One photograph of a batch through its stages.
    private final class BatchSlot {
        var job: StillJob?
        var reduced = false
        var failure: String?
        var written: [String: Any]?
    }

    func exportBatch(_ parameters: [String: Any],
                     progress: @escaping ([String: Any]) -> Void) throws -> [String: Any] {
        guard let directory = parameters["directory"] as? String, !directory.isEmpty else {
            throw HostEngine.Failure(description: "No destination was chosen.")
        }
        guard let encoder = HostPlatform.current.encoder else {
            throw HostEngine.Failure(description: "This build has no image encoder.")
        }
        let items = parameters["items"] as? [[String: Any]] ?? []
        let type = parameters["type"] as? String ?? "image/jpeg"
        let quality = (parameters["quality"] as? Double).map { min(max($0, 0.01), 1) } ?? 0.95
        let deep = type == "image/tiff"
        let hdr = type == "image/heic" && parameters["hdr"] as? Bool == true && encoder.writesHDR
        let exact = parameters["photoQuality"] as? String != "fast"
        let metadata = (parameters["metadata"] as? String).flatMap(HostMetadataPolicy.init) ?? .default
        let size = parameters["size"] as? String ?? "full"
        let destinations = Self.batchDestinations(
            items.map { $0["filename"] as? String ?? "" },
            in: URL(fileURLWithPath: directory, isDirectory: true))
        let plan = BatchPlan.forMachine()
        let shouldContinue = engine.continuation()

        let count = items.count
        let slots = (0..<count).map { _ in BatchSlot() }
        let ready = (0..<count).map { _ in DispatchSemaphore(value: 0) }
        // The photograph developing counts against the lookahead until its develop is done.
        let lookahead = DispatchSemaphore(value: plan.ahead + 1)
        let decoders = DispatchSemaphore(value: plan.decoders)
        let encoders = DispatchSemaphore(value: plan.encoders)
        let finished = DispatchSemaphore(value: 0)
        let workers = DispatchQueue(label: "fotufilm.batch", qos: .userInitiated,
                                    attributes: .concurrent)
        let stopped = BatchFlag()

        // Decode and frame, in order, as far ahead as the plan allows.
        DispatchQueue.global(qos: .userInitiated).async {
            for index in 0..<count {
                lookahead.wait()
                if stopped.isSet || !shouldContinue() {
                    for rest in index..<count { ready[rest].signal() }
                    return
                }
                decoders.wait()
                workers.async {
                    defer {
                        decoders.signal()
                        ready[index].signal()
                    }
                    Self.draining {
                        do {
                            let (job, reduced) = try self.batchJob(items[index], size: size,
                                                                   exact: exact)
                            slots[index].job = job
                            slots[index].reduced = reduced
                        } catch {
                            slots[index].failure = Self.message(error)
                        }
                    }
                }
            }
        }

        var done = 0, encoding = 0
        func report(developing name: String? = nil, at position: Int = 0) {
            while finished.wait(timeout: .now()) == .success {
                encoding -= 1
                done += 1
            }
            var body: [String: Any] = ["progress": Double(done) / Double(max(count, 1)),
                                       "done": done, "total": count]
            if let name {
                body["name"] = name
                body["current"] = position
            }
            progress(body)
        }
        var cancelled = false
        HostActivity.during("Exporting photographs") {
            photos: for index in 0..<count {
                ready[index].wait()
                let slot = slots[index]
                let name = items[index]["name"] as? String ?? destinations[index].lastPathComponent
                guard shouldContinue() else {
                    cancelled = true
                    break
                }
                guard slot.job != nil else {
                    lookahead.signal()
                    done += 1
                    report()
                    continue
                }
                report(developing: name, at: index + 1)
                // The framed scene is let go as soon as it has developed.
                let developed = Result {
                    try Self.draining { () throws -> HostStill in
                        defer { slot.job = nil }
                        return try self.developStill(slot.job!, deep: deep, hdr: hdr, exact: exact)
                    }
                }
                var still: HostStill
                switch developed {
                case .success(let result):
                    still = result
                case .failure(let failure as HostEngine.Failure) where failure.cancelled:
                    cancelled = true
                    break photos
                case .failure(let failure):
                    slot.failure = Self.message(failure)
                    lookahead.signal()
                    done += 1
                    report()
                    continue
                }
                lookahead.signal()
                still.metadata = metadata
                encoders.wait()
                encoding += 1
                let destination = destinations[index]
                workers.async {
                    defer {
                        encoders.signal()
                        finished.signal()
                    }
                    Self.draining {
                        do {
                            let size = try encoder.write(still, type: type, quality: quality,
                                                         to: destination)
                            slot.written = ["filename": destination.lastPathComponent,
                                            "path": destination.path,
                                            "width": size.width, "height": size.height]
                        } catch {
                            slot.failure = Self.message(error)
                        }
                    }
                }
                report()
            }
            // Stops the decoder and lets it past its wait; what it already decoded is dropped.
            stopped.set()
            for _ in 0..<count { lookahead.signal() }
            while encoding > 0 {
                finished.wait()
                encoding -= 1
                done += 1
                if !cancelled { report() }
            }
        }
        if cancelled { throw HostEngine.Failure(description: "Cancelled.", cancelled: true) }

        var written: [[String: Any]] = [], failed: [[String: Any]] = [], reduced: [String] = []
        for (index, slot) in slots.enumerated() {
            let name = items[index]["name"] as? String ?? destinations[index].lastPathComponent
            if let file = slot.written {
                written.append(file)
                if slot.reduced { reduced.append(name) }
            } else {
                failed.append(["name": name, "error": slot.failure ?? "The photograph was not exported."])
            }
        }
        return ["directory": directory, "written": written, "failed": failed, "reduced": reduced]
    }

    /// A photograph of the batch decoded, framed at the size asked for and ready to develop: its
    /// own file opened here, or a photograph the editor holds. A size past the developer's memory
    /// limit gives way to the largest that fits, as the export sheet selects (`reduced`).
    private func batchJob(_ item: [String: Any], size: String, exact: Bool) throws
        -> (StillJob, reduced: Bool) {
        var body = item
        body["viewport"] = nil
        body["maxEdge"] = nil
        var source: HostImage?
        if let path = item["path"] as? String, !path.isEmpty {
            guard FileManager.default.isReadableFile(atPath: path) else {
                throw HostEngine.Failure(description: "The file cannot be read.")
            }
            source = try HostImage.open(URL(fileURLWithPath: path))
        } else if item["handle"] == nil {
            throw HostEngine.Failure(description: "The photograph is not open.")
        }
        let whole = try prepare(JSONSerialization.data(withJSONObject: body), image: source)
        if whole.image.video != nil {
            throw HostEngine.Failure(description: "Movies are exported one at a time.")
        }
        let (width, height) = whole.sizes.output
        for (index, edge) in Self.batchEdges(size, longEdge: max(width, height)).enumerated() {
            var prepared = whole
            prepared.maxEdge = edge
            prepared.sizes = whole.geometry.sizes(width: whole.image.width,
                                                  height: whole.image.height, maxEdge: edge)
            guard engine.canDevelop(width: prepared.sizes.output.0, height: prepared.sizes.output.1,
                                    edit: prepared.edit,
                                    contentHeadroom: prepared.image.contentHeadroom,
                                    exactMath: exact) else { continue }
            let scene = try makeScene(prepared.image, geometry: prepared.geometry,
                                      sizes: prepared.sizes)
            return (try stillJob(prepared, scene: scene, body: body), index > 0)
        }
        throw HostEngine.Failure(
            description: "The photograph exceeds this device’s safe memory limit at every export size.")
    }

    /// The long edges to try for an export size id — "full", a fraction ("0.75") or a long edge
    /// in pixels ("2048") of the cropped picture, as `web/src/export-sizes.js` names them — the
    /// size asked for first (nil: the whole picture), then the smaller sizes the export sheet
    /// offers, largest first.
    static func batchEdges(_ size: String, longEdge: Int) -> [Int?] {
        let value = Double(size) ?? 0
        let asked: Int? = size == "full" || value <= 0
            ? nil
            : value < 1 ? Int((Double(longEdge) * value).rounded()) : Int(value)
        let first = asked.flatMap { $0 >= longEdge ? nil : $0 }
        let fractions = [0.75, 0.5, 0.25].map { Int((Double(longEdge) * $0).rounded()) }
            .filter { $0 >= 640 }
        let smaller = Set(fractions + [3840, 2048, 1600])
            .filter { $0 < (first ?? longEdge) - 1 }
            .sorted(by: >)
        return [first] + smaller.map { Optional($0) }
    }

    /// Where each photograph of a batch is written: its suggested name in `folder`, numbered past
    /// any file already there or named earlier in the batch, so nothing is overwritten.
    static func batchDestinations(_ names: [String], in folder: URL,
                                  exists: (URL) -> Bool = {
                                      FileManager.default.fileExists(atPath: $0.path)
                                  }) -> [URL] {
        var taken = Set<String>()
        return names.map { suggested in
            var name = suggested.replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            while name.hasPrefix(".") { name.removeFirst() }
            if name.isEmpty { name = "photo" }
            let stem = (name as NSString).deletingPathExtension
            let suffix = (name as NSString).pathExtension
            var candidate = name, number = 2
            // Case-insensitive, as the Mac's and Windows' file systems compare names.
            while taken.contains(candidate.lowercased())
                || exists(folder.appendingPathComponent(candidate)) {
                candidate = suffix.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(suffix)"
                number += 1
            }
            taken.insert(candidate.lowercased())
            return folder.appendingPathComponent(candidate)
        }
    }

    /// What the editor keeps each file's edit under (`HostFileIdentity`), hashed in parallel:
    /// Export All finds the kept edits of photographs not opened yet.
    func fileIdentities(_ parameters: [String: Any]) -> [String: Any] {
        let paths = parameters["paths"] as? [String] ?? []
        var identities = [String?](repeating: nil, count: paths.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: paths.count) { index in
            let url = URL(fileURLWithPath: paths[index])
            let isMovie = HostPlatform.current.videoSource?.isMovie(url) == true
            let identity = HostFileIdentity.identity(of: url, isMovie: isMovie)
            lock.lock()
            identities[index] = identity
            lock.unlock()
        }
        return ["identities": identities.map { $0 ?? NSNull() as Any }]
    }

    private static func message(_ error: Error) -> String {
        (error as? HostEngine.Failure)?.description ?? error.localizedDescription
    }

    /// Frees what a stage's Objective-C calls left for autorelease before the next photograph.
    private static func draining<Result>(_ body: () throws -> Result) rethrows -> Result {
        #if canImport(ObjectiveC)
        try autoreleasepool(invoking: body)
        #else
        try body()
        #endif
    }
}

/// A flag set once from one thread and read from others.
private final class BatchFlag {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
