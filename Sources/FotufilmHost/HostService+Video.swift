import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmEditModel)
import FotufilmEditModel
#endif

/// The editor's video calls (`web/src/backend/macos/video-import.js` and `host.js`): a movie
/// arrives in chunks, becomes an image whose pixels are the frame each render selects, and
/// exports frame by frame through the same geometry and develop as its previews.
extension HostService {
    /// `call` for hosts that show progress: an export reports `{progress, frames, finalizing}`.
    public func call(_ method: String, params: Data, payload: UnsafeRawBufferPointer?,
                     progress: @escaping ([String: Any]) -> Void) throws -> Answer {
        guard method == "exportVideo" else { return try call(method, params: params, payload: payload) }
        return try video(method, params: params, payload: payload, progress: progress)
    }

    func video(_ method: String, params: Data, payload: UnsafeRawBufferPointer?,
               progress: (([String: Any]) -> Void)?) throws -> Answer {
        guard HostPlatform.current.videoSource != nil, HostPlatform.current.videoWriter != nil else {
            throw HostEngine.Failure(description: "This host cannot open videos.")
        }
        let parameters = (try? JSONSerialization.jsonObject(with: params)) as? [String: Any] ?? [:]
        switch method {
        case "beginVideo":
            return try answer(["handle": videos.begin(name: parameters["name"] as? String ?? "video")])
        case "appendVideo":
            let offset = parameters["offset"] as? Int ?? 0
            // A binary channel sends the bytes beside the message; WebKit's sends base64.
            if let payload, payload.count > 0 {
                try videos.append(parameters["handle"], offset: offset, bytes: payload)
            } else if let text = parameters["data"] as? String, let data = Data(base64Encoded: text) {
                try data.withUnsafeBytes {
                    try videos.append(parameters["handle"], offset: offset, bytes: $0)
                }
            }
            return try answer([:])
        case "importVideo":
            return try importVideo(parameters)
        default:
            return try answer(HostActivity.during("Exporting a movie") {
                try exportVideo(parameters, progress: progress ?? { _ in })
            })
        }
    }

    /// Opens the uploaded movie.
    private func importVideo(_ parameters: [String: Any]) throws -> Answer {
        try importMovie(at: videos.take(parameters["handle"]), owned: true,
                        playback: parameters["playback"] as? Bool == true)
    }

    /// Opens a movie: an upload the video then owns and deletes, or a file read in place. The
    /// answer is the image descriptor with `video`, the first frame as the preview and, when
    /// `playback` asks for it, the sound as a WAV clock.
    func importMovie(at file: URL, owned: Bool, playback: Bool) throws -> Answer {
        guard let sources = HostPlatform.current.videoSource else {
            throw HostEngine.Failure(description: "This host cannot open videos.")
        }
        let source: HostVideoSource
        do { source = try sources.open(file) }
        catch {
            if owned { try? FileManager.default.removeItem(at: file) }
            throw error
        }
        let image = HostVideo(source: source, owning: owned ? file : nil).makeImage()
        var descriptor = image.descriptor
        var payloads = ["preview": previewPNG(image)]
        if playback, let video = image.video {
            payloads["playback"] = try video.playbackWAV()
            descriptor["playbackType"] = "audio/wav"
        }
        descriptor["handle"] = register(image)
        return try answer(descriptor, images: payloads)
    }

    /// Develops every frame of the edit's trim through the render path's geometry and film,
    /// and encodes them where the host's save panel said, with the movie's sound. Frames develop
    /// on the platform's video pipeline where it takes the edit (several in flight, as the Mac
    /// app exports), and one at a time through `HostEngine.develop` otherwise.
    private func exportVideo(_ parameters: [String: Any],
                             progress: ([String: Any]) -> Void) throws -> [String: Any] {
        guard let path = parameters["path"] as? String else {
            throw HostEngine.Failure(description: "No destination was chosen.")
        }
        let formatID = parameters["format"] as? String ?? "mp4"
        guard let writers = HostPlatform.current.videoWriter,
              let format = writers.formats.first(where: { $0.id == formatID }) else {
            throw HostEngine.Failure(description: "This host cannot write \(formatID) video.")
        }
        var body = parameters
        for name in ["viewport", "printFrame", "videoTime", "stage"] { body[name] = nil }
        body["previewQuality"] = "still"
        let prepared = try prepare(JSONSerialization.data(withJSONObject: body))
        guard let video = prepared.image.video else {
            throw HostEngine.Failure(description: "That is not a video.")
        }
        let source = video.source
        let settings = (parameters["edit"] as? [String: Any])?["video"] as? [String: Any] ?? [:]
        let interpretation = HostVideoInterpretation(settings["encoding"] as? String)
        let start = max(source.start, settings["trimStart"] as? Double ?? 0)
        let end = min(source.duration, settings["trimEnd"] as? Double ?? source.duration)
        guard end > start else {
            throw HostEngine.Failure(description: "Trim out must be after trim in and inside the clip.")
        }

        // 4:2:0 codecs need even sizes: the last column or row is repeated, never the aspect changed.
        let (width, height) = prepared.sizes.output
        let (paddedWidth, paddedHeight) = (width + width % 2, height + height % 2)
        let knee = prepared.edit.edit.stock.flatMap { id in
            FilmStock.presets[id].flatMap { stock in
                try? prepared.edit.document.options(for: stock).sdrShoulderKnee(for: stock)
            }
        } ?? FilmSDRDelivery.boundedShoulderKnee
        // A lower cadence retimes the movie as the Mac app's export does: each output
        // frame shows the source frame on screen at its time. A rate at or above the source's
        // keeps every frame at its own time.
        let retime = (settings["frameRate"] as? Double)
            .flatMap { $0 > 0 && $0 < source.frameRate - 0.01 ? $0 : nil }
        let url = URL(fileURLWithPath: path)
        let proceed = engine.continuation()
        let pipeline = try videoPipeline(
            prepared, body: body, format: format, interpretation: interpretation,
            processing: HostVideoProcessing(parameters["videoProcessing"] as? String),
            proceed: proceed)
        // Frames decode at the size the film develops at: the delivered one, or Fast's.
        let developSizes = pipeline.development.hybrid
            ? prepared.geometry.sizes(width: prepared.image.width, height: prepared.image.height,
                                      maxEdge: HostVideoProcessing.fast.developLongEdge)
            : prepared.sizes
        let swapped = prepared.geometry.rotation % 2 != 0
        let frameSize = swapped ? (developSizes.frame.1, developSizes.frame.0) : developSizes.frame

        let writer = try writers.writer(for: format)
        try writer.begin(HostVideoDelivery(
            url: url, format: format, width: paddedWidth, height: paddedHeight,
            frameRate: retime ?? source.frameRate,
            bitrate: (parameters["bitrate"] as? String).flatMap(HostVideoBitrate.init) ?? .automatic,
            shoulderKnee: knee, range: start...end,
            audio: settings["audio"] as? Bool == false ? nil : source,
            // HDR where the page asks, the format carries it and the film delivers it.
            hdr: parameters["hdr"] as? Bool == true && format.carriesHDR
                && deliversHDR(prepared.edit)))

        let clock = pipeline.clock
        let began = DispatchTime.now().uptimeNanoseconds
        var count = 0, next = 0
        // Frames developing and not yet written, oldest first: when each shows, and how far into
        // the trim it reaches.
        var pending: [(times: [Double], reaches: Double)] = []
        var reported = DispatchTime.now().uptimeNanoseconds
        func write() throws {
            let frame = pending.removeFirst()
            try pipeline.receive { pixels in
                let started = clock.mark()
                for shown in frame.times { try writer.append(pixels, at: shown) }
                clock.charge("append", since: started)
            }
            count += frame.times.count
            let now = DispatchTime.now().uptimeNanoseconds
            if now - reported > 100_000_000 {
                reported = now
                progress(["progress": min(0.999, frame.reaches / (end - start)), "frames": count])
            }
        }
        do {
            // A frame the film takes as it was decoded — nothing turned, cut or resized — skips
            // light where the pipeline reads the decoder's display codes.
            let direct = pipeline.takesDisplayCodes && prepared.geometry.isIdentity
                && developSizes.frame == developSizes.output
            let frames = Prefetch(try source.frames(from: start, to: end, width: frameSize.0,
                                                    height: frameSize.1,
                                                    interpretation: interpretation,
                                                    displayCodes: direct))
            var last = -Double.infinity
            while true {
                var started = clock.mark()
                guard let frame = try frames.next() else { break }
                clock.charge("decode wait", since: started)
                guard proceed() else { throw HostEngine.Failure(description: "Cancelled.", cancelled: true) }
                // A frame showing at the trim's start begins the movie there.
                let time = max(start, frame.time)
                guard frame.time + frame.duration > start + 1e-6, time > last + 1e-6 else { continue }
                var times = [time]
                if let retime {
                    // The output frames that fall while this one shows; none skips its develop.
                    times = []
                    let shownUntil = min(end, frame.time + frame.duration) - 1e-6
                    while start + Double(next) / retime < shownUntil {
                        times.append(start + Double(next) / retime)
                        next += 1
                    }
                    if times.isEmpty { continue }
                }
                started = clock.mark()
                video.hold(frame, interpretation: interpretation)
                if let codes = frame.display8 {
                    try pipeline.submit(display8: codes, frameIndex: prepared.image.pace.frameIndex)
                    clock.charge("submit", since: started)
                } else {
                    let scene = try sceneFor(prepared.image, geometry: prepared.geometry,
                                             sizes: developSizes)
                    clock.charge("scene", since: started)
                    started = clock.mark()
                    try pipeline.submit(scene, frameIndex: prepared.image.pace.frameIndex)
                    clock.charge("submit", since: started)
                }
                pending.append((times, time + frame.duration - start))
                last = time
                // One frame fewer than the pipeline holds stays in flight, so the next submit
                // finds its buffers free.
                while pending.count > pipeline.depth - 1 { try write() }
            }
            while !pending.isEmpty { try write() }
            guard count > 0 else {
                throw HostEngine.Failure(description: "The selected range has no video frames.")
            }
            progress(["progress": 1, "frames": count, "finalizing": true])
            // A short movie may report nothing before this, so a cancel can still land here.
            guard proceed() else { throw HostEngine.Failure(description: "Cancelled.", cancelled: true) }
            try writer.finish()
        } catch {
            pipeline.drain()
            writer.cancel()
            throw error
        }
        clock.report("\(pipeline.name), \(width)x\(height) \(format.id)", frames: count,
                     wall: Double(DispatchTime.now().uptimeNanoseconds - began) / 1e9)
        return ["filename": url.lastPathComponent, "path": url.path, "width": paddedWidth,
                "height": paddedHeight, "frames": count]
    }

    /// The pipeline an export's frames develop on, with the road through the engine the Mac
    /// app's exporter would take (`HostVideoRoad`).
    func videoPipeline(_ prepared: Prepared, body: [String: Any], format: HostVideoFormat,
                       interpretation: HostVideoInterpretation, processing: HostVideoProcessing,
                       proceed: @escaping () -> Bool) throws -> HostVideoPipeline {
        let (width, height) = prepared.sizes.output
        let film = engine.stock(prepared.edit.edit.stock)
        if let id = prepared.edit.edit.stock, film == nil {
            throw HostEngine.Failure(description: "Film \(id) is not installed.")
        }
        let image = prepared.image
        let contentHeadroom = image.contentHeadroom
        func options(_ edit: WebNativeEdit) throws -> FotufilmEngine.Options {
            var options = try engine.options(edit, stock: film ?? .noFilm,
                                             contentHeadroom: contentHeadroom)
            // An explicit mottle share takes the delivery ratio, as the Mac app's exports do.
            options.completeDeliveryMottle()
            return options
        }
        let ground = try options(prepared.edit)
        let selection = activeSelection(body, cropMode: prepared.request.cropMode == true)
        let selected = try selection.map { try options($0.develop(prepared.edit)) }

        var log = false
        if case .camera = interpretation { log = true }
        let road = HostVideoRoad(deepSource: image.video?.source.isDeep == true || log,
                                 deepDelivery: format.takesLinearLight)
        let pixelFormat: HostEngine.PixelFormat = format.takesLinearLight
            ? .rgba32FloatLinearP3 : .rgba8DisplayP3
        let bytesPerPixel = format.takesLinearLight ? 16 : 4
        let (paddedWidth, paddedHeight) = (width + width % 2, height + height % 2)

        // The portable develop: `HostEngine.develop`, with the selection blended over it.
        let developFrame: HostVideoFrameDevelop = { [unowned self] scene, sceneWidth, sceneHeight,
                                                    frameIndex, into in
            let scene = HostVideoPixels.resample(scene, width: sceneWidth, height: sceneHeight,
                                                 to: width, height)
            func develop(_ options: FotufilmEngine.Options, into pixels: UnsafeMutableRawPointer,
                         rowBytes: Int, capacity: Int) throws {
                try engine.develop(scene, width: width, height: height, film: film,
                                   options: options, frameIndex: frameIndex,
                                   into: .init(maxEdge: 0, format: pixelFormat, pixels: pixels,
                                               rowBytes: rowBytes, capacity: capacity))
            }
            guard let selection, let selected else {
                try develop(ground, into: into.baseAddress!, rowBytes: paddedWidth * bytesPerPixel,
                            capacity: into.count)
                HostVideoPixels.pad(into.baseAddress!, width: width, height: height,
                                    paddedWidth: paddedWidth, paddedHeight: paddedHeight,
                                    bytesPerPixel: bytesPerPixel)
                return
            }
            func developed(_ options: FotufilmEngine.Options) throws -> [UInt8] {
                var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
                try pixels.withUnsafeMutableBytes {
                    try develop(options, into: $0.baseAddress!, rowBytes: width * bytesPerPixel,
                                capacity: $0.count)
                }
                return pixels
            }
            var pixels = try developed(ground)
            var subject: [Float]?
            // With nobody found a subject selection leaves the frame as it is, as the preview does.
            if selection.isSubject,
               let found = subjects(scene, width: width, height: height, image: image),
               found.count > 0 {
                subject = found.weights(at: selection.point, width: width, height: height,
                                        edge: selection.subjectEdge,
                                        feather: selection.subjectFeather)
            }
            if !selection.isSubject || subject != nil {
                let local = try developed(selected)
                if format.takesLinearLight {
                    var light = pixels.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                    selection.composite(
                        ground: &light,
                        selected: local.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) },
                        scene: scene, width: width, height: height, subject: subject)
                    pixels = light.withUnsafeBytes { Array($0) }
                } else {
                    pixels = selection.composite(ground: pixels, selected: local, scene: scene,
                                                 width: width, height: height, showMask: false,
                                                 subject: subject)
                }
            }
            pixels.withUnsafeBytes {
                HostVideoPixels.deliver($0.baseAddress!, width: width, height: height,
                                        bytesPerPixel: bytesPerPixel, into: into.baseAddress!,
                                        paddedWidth: paddedWidth, paddedHeight: paddedHeight)
            }
        }

        var development = HostVideoDevelopment(
            stock: film ?? .noFilm, options: ground, road: road, width: width, height: height,
            paddedWidth: paddedWidth, paddedHeight: paddedHeight, developWidth: width,
            developHeight: height, linearOutput: format.takesLinearLight,
            knee: film.map { ground.sdrShoulderKnee(for: $0) } ?? FilmSDRDelivery.boundedShoulderKnee,
            seed: UInt32(truncatingIfNeeded: ground.seed), developFrame: developFrame)
        // The platform's pipeline takes a film with no selection over it; a selection develops
        // twice and blends, which the portable develop does. `FOTUFILM_VIDEO_PORTABLE=1` holds
        // every export to the portable develop: the seam the two are compared across.
        guard film != nil, selection == nil,
              ProcessInfo.processInfo.environment["FOTUFILM_VIDEO_PORTABLE"] != "1",
              let developer = HostPlatform.current.videoDeveloper
        else { return HostFrameVideoPipeline(development) }
        // Fast develops the 8-bit road's film at no more than its long edge and prints it at the
        // delivered size, where that is larger.
        if !road.deep, let edge = processing.developLongEdge {
            let small = prepared.geometry.sizes(width: image.width, height: image.height,
                                                maxEdge: edge).output
            if small.0 < width || small.1 < height {
                (development.developWidth, development.developHeight) = small
            }
        }
        if let pipeline = developer.pipeline(for: development, proceed: proceed) { return pipeline }
        // A rejected hybrid cannot print its reduced density through this platform. Keep the
        // original scene resolution for the ordinary develop instead of enlarging blurred input.
        development.developWidth = width
        development.developHeight = height
        return HostFrameVideoPipeline(development)
    }

    /// The edit's selective adjustment, when it changes the picture.
    private func activeSelection(_ body: [String: Any], cropMode: Bool) -> HostSelection? {
        guard !cropMode,
              let saved = (body["edit"] as? [String: Any])?["selective"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: saved),
              let selection = try? JSONDecoder().decode(HostSelection.self, from: data),
              selection.isActive
        else { return nil }
        return selection
    }

    /// Decodes the next frame while the current one develops.
    /// Decodes ahead of the develop on a queue of its own. Two frames ahead: a 4K frame's
    /// conversion sometimes outlasts one develop, and a second frame in hand keeps the GPU's
    /// two in flight fed.
    private final class Prefetch {
        private final class Read {
            var result: Result<HostVideoFrame?, Error>?
            let done = DispatchSemaphore(value: 0)
            func get() throws -> HostVideoFrame? {
                done.wait()
                done.signal()
                return try result!.get()
            }
        }

        private let reader: HostVideoFrameReader
        private let queue = DispatchQueue(label: "fotufilm.video.decode", qos: .userInitiated)
        private let ahead = 2
        private var reads: [Read] = []
        private var ended = false

        init(_ reader: HostVideoFrameReader) { self.reader = reader }

        func next() throws -> HostVideoFrame? {
            topUp()
            guard !reads.isEmpty else { return nil }
            let frame = try reads.removeFirst().get()
            if frame == nil { ended = true; reads.removeAll() }
            topUp()
            return frame
        }

        private func topUp() {
            while !ended, reads.count < ahead {
                let read = Read()
                queue.async { [reader] in
                    read.result = Result { try reader.next() }
                    read.done.signal()
                }
                reads.append(read)
            }
        }

        // The reader outlives no read still decoding from it.
        deinit { queue.sync {} }
    }
}
