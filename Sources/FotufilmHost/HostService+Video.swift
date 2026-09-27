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
            return try answer(exportVideo(parameters, progress: progress ?? { _ in }))
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
    /// and encodes them where the host's save panel said, with the movie's sound.
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
        let swapped = prepared.geometry.rotation % 2 != 0
        let frameSize = swapped ? (prepared.sizes.frame.1, prepared.sizes.frame.0) : prepared.sizes.frame
        let knee = prepared.edit.edit.stock.flatMap { id in
            FilmStock.presets[id].flatMap { stock in
                try? prepared.edit.document.options(for: stock).sdrShoulderKnee(for: stock)
            }
        } ?? FilmSDRDelivery.boundedShoulderKnee
        // A lower frame rate retimes the movie as the Mac app's export sheet does: each output
        // frame shows the source frame on screen at its time. A rate at or above the source's
        // keeps every frame at its own time.
        let retime = (parameters["frameRate"] as? Double)
            .flatMap { $0 > 0 && $0 < source.frameRate - 0.01 ? $0 : nil }
        let url = URL(fileURLWithPath: path)
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

        let proceed = engine.continuation()
        let bytesPerPixel = format.takesLinearLight ? 16 : 4
        var pixels = [UInt8](repeating: 0, count: paddedWidth * paddedHeight * bytesPerPixel)
        var count = 0, next = 0
        do {
            let frames = Prefetch(try source.frames(from: start, to: end, width: frameSize.0,
                                                    height: frameSize.1,
                                                    interpretation: interpretation))
            var last = -Double.infinity, reported = DispatchTime.now().uptimeNanoseconds
            while let frame = try frames.next() {
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
                video.hold(frame, interpretation: interpretation)
                let scene = try sceneFor(prepared.image, geometry: prepared.geometry, sizes: prepared.sizes)
                try pixels.withUnsafeMutableBytes { buffer in
                    try engine.develop(
                        scene, width: width, height: height,
                        contentHeadroom: prepared.image.contentHeadroom, edit: prepared.edit,
                        frameIndex: prepared.image.pace.frameIndex,
                        into: .init(maxEdge: 0,
                                    format: format.takesLinearLight ? .rgba32FloatLinearP3 : .rgba8DisplayP3,
                                    pixels: buffer.baseAddress!,
                                    rowBytes: paddedWidth * bytesPerPixel, capacity: buffer.count))
                    Self.pad(buffer, width: width, height: height, paddedWidth: paddedWidth,
                             paddedHeight: paddedHeight, bytesPerPixel: bytesPerPixel)
                    for shown in times { try writer.append(UnsafeRawBufferPointer(buffer), at: shown) }
                }
                last = time
                count += times.count
                let now = DispatchTime.now().uptimeNanoseconds
                if now - reported > 100_000_000 {
                    reported = now
                    progress(["progress": min(0.999, (time + frame.duration - start) / (end - start)),
                              "frames": count])
                }
            }
            guard count > 0 else {
                throw HostEngine.Failure(description: "The selected range has no video frames.")
            }
            progress(["progress": 1, "frames": count, "finalizing": true])
            // A short movie may report nothing before this, so a cancel can still land here.
            guard proceed() else { throw HostEngine.Failure(description: "Cancelled.", cancelled: true) }
            try writer.finish()
        } catch {
            writer.cancel()
            throw error
        }
        return ["filename": url.lastPathComponent, "width": paddedWidth, "height": paddedHeight,
                "frames": count]
    }

    /// Decodes the next frame while the current one develops.
    private final class Prefetch {
        private let reader: HostVideoFrameReader
        private let queue = DispatchQueue(label: "fotufilm.video.decode", qos: .userInitiated)
        private var pending: DispatchWorkItem?
        private var result: Result<HostVideoFrame?, Error>?

        init(_ reader: HostVideoFrameReader) { self.reader = reader }

        func next() throws -> HostVideoFrame? {
            if pending == nil { read() }
            pending?.wait()
            let frame = try result!.get()
            pending = nil
            if frame != nil { read() }
            return frame
        }

        private func read() {
            let item = DispatchWorkItem { [self] in result = Result { try reader.next() } }
            pending = item
            queue.async(execute: item)
        }

        deinit { pending?.wait() }
    }

    /// Repeats the last column and row into the one-pixel margin an odd size leaves.
    private static func pad(_ buffer: UnsafeMutableRawBufferPointer, width: Int, height: Int,
                            paddedWidth: Int, paddedHeight: Int, bytesPerPixel: Int) {
        let rowBytes = paddedWidth * bytesPerPixel
        if paddedWidth > width {
            for y in 0..<height {
                let row = buffer.baseAddress! + y * rowBytes
                (row + width * bytesPerPixel).copyMemory(from: row + (width - 1) * bytesPerPixel,
                                                         byteCount: bytesPerPixel)
            }
        }
        if paddedHeight > height {
            (buffer.baseAddress! + height * rowBytes).copyMemory(
                from: buffer.baseAddress! + (height - 1) * rowBytes, byteCount: rowBytes)
        }
    }
}
