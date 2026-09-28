import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif

// Video for the web editor's native backend, independent of any platform's media framework. A
// platform supplies movie decoding and encoding as `HostPlatform.videoSource` and `.videoWriter`;
// frame selection, caching, trim and timing, and the develop of every frame live here and in
// `HostService+Video.swift`.

/// One decoded movie frame in the engine's only input: upright, scene-linear Rec.2020 RGBA with
/// diffuse white at 1.
struct HostVideoFrame {
    /// Presentation time and duration, in seconds of the source's timeline.
    var time: Double
    var duration: Double
    var width: Int
    var height: Int
    /// Upright scene-linear Rec.2020 RGBA; empty when the frame came as `display8`.
    var rgba: [Float]
    /// Upright RGBA8 Display P3 codes, as an 8-bit decoder delivered them, where a reader was
    /// asked for them and its road decodes that way: the codes a develop that reads display
    /// codes takes as they are, with no trip through linear light.
    var display8: HostVideoCodes? = nil
}

/// A frame's upright RGBA8 codes, written where they are wanted: a decoder's sample goes straight
/// into a develop's input rather than through an array first.
protocol HostVideoCodes {
    /// Bytes `write` fills: four a pixel.
    var count: Int { get }
    func write(into destination: UnsafeMutableRawPointer)
}

extension HostVideoCodes {
    var bytes: [UInt8] {
        [UInt8](unsafeUninitializedCapacity: count) { buffer, initialized in
            write(into: buffer.baseAddress!)
            initialized = count
        }
    }
}

extension Array: HostVideoCodes where Element == UInt8 {
    func write(into destination: UnsafeMutableRawPointer) {
        withUnsafeBytes { destination.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
    }
}

extension HostVideoFrame {
    /// Linear light for every 8-bit sRGB code, as the managed 8-bit road reads its codes.
    static let srgbTable: [Float] = (0..<256).map { ColorScience.srgbToLinear(Float($0) / 255) }

    /// Scene-linear Rec.2020 for 8-bit Display P3 codes, as the managed road converts them: for a
    /// develop that needs light after all.
    static func scene(display8: HostVideoCodes) -> [Float] {
        let codes = display8.bytes
        var scene = [Float](repeating: 1, count: codes.count)
        for i in stride(from: 0, to: codes.count, by: 4) {
            let rgb = ColorScience.linearDisplayP3ToRec2020(
                SIMD3(srgbTable[Int(codes[i])], srgbTable[Int(codes[i + 1])],
                      srgbTable[Int(codes[i + 2])]))
            scene[i] = rgb.x.isFinite ? rgb.x : 0
            scene[i + 1] = rgb.y.isFinite ? rgb.y : 0
            scene[i + 2] = rgb.z.isFinite ? rgb.z : 0
        }
        return scene
    }

    /// The frame's light, whichever way it came.
    var scene: [Float] { display8.map(Self.scene(display8:)) ?? rgba }
}

/// How a movie's code values are read, the edit's `video.encoding`: the file's own colour tags,
/// or a camera log encoding the file does not declare.
enum HostVideoInterpretation: Equatable, CustomStringConvertible {
    case standard
    case camera(CameraLogEncoding)

    init(_ id: String?) {
        self = id.flatMap(CameraLogEncoding.init(rawValue:)).map(Self.camera) ?? .standard
    }

    var description: String {
        switch self {
        case .standard: return "standard"
        case .camera(let encoding): return encoding.rawValue
        }
    }
}

/// A movie a platform can decode. Sizes are upright, after the track's own rotation.
protocol HostVideoSource: AnyObject {
    var width: Int { get }
    var height: Int { get }
    /// The first frame's time and the movie's end, in seconds.
    var start: Double { get }
    var duration: Double { get }
    /// Nominal frames per second, for frame numbers and the encoder's rate.
    var frameRate: Double { get }
    var hasAudio: Bool { get }
    /// The range above diffuse white the file's colour tags declare: 1 for SDR.
    var taggedHeadroom: Float { get }
    /// Whether the file stores more than eight bits a component or HDR light: what sends an
    /// export down the deep road on the engine's reference schedule (`HostVideoRoad`).
    var isDeep: Bool { get }

    /// The frame showing at `seconds`, decoded at `width` x `height`. Successive calls moving
    /// forward in small steps, as playback makes them, should read on rather than seek.
    /// `displayCodes` asks for `display8` where the decode is 8-bit Display P3, as `frames` does.
    func frame(at seconds: Double, width: Int, height: Int,
               interpretation: HostVideoInterpretation, displayCodes: Bool) throws -> HostVideoFrame

    /// Every frame shown from `start` until `end`, in order, decoded at `width` x `height`.
    /// `displayCodes` asks for `display8` frames where the decode is 8-bit Display P3.
    func frames(from start: Double, to end: Double, width: Int, height: Int,
                interpretation: HostVideoInterpretation, displayCodes: Bool) throws
        -> HostVideoFrameReader

    /// The sound as interleaved 16-bit PCM at `sampleRate`, for a playback clock the page's
    /// media element can always play; nil when the movie is silent.
    func audioPCM(sampleRate: Int) throws -> (samples: [Int16], channels: Int)?
}

/// Frames in presentation order; nil after the last.
protocol HostVideoFrameReader: AnyObject {
    func next() throws -> HostVideoFrame?
}

/// A delivery format the platform can encode, as the export dialog lists it.
struct HostVideoFormat {
    var id: String
    var label: String
    var fileExtension: String
    var mimeType: String
    /// Whether frames arrive as linear Display P3 light for a deep encode, rather than the
    /// preview's dithered 8-bit Display P3.
    var takesLinearLight: Bool
    /// Whether the quality setting changes the encode. ProRes has none.
    var compresses: Bool
    /// Bits per component the file stores.
    var bits: Int

    /// Whether the format can carry HDR (HLG): the deep formats, as in the Mac app.
    var carriesHDR: Bool { takesLinearLight }

    var json: [String: Any] {
        ["id": id, "label": label, "extension": fileExtension, "type": mimeType,
         "quality": compresses, "bits": bits, "colorSpace": "display-p3", "hdr": carriesHDR]
    }
}

extension HostVideoFormat {
    /// The formats the Mac app offers (`VideoExportFormat`): H.264 in an MPEG-4 or QuickTime
    /// movie, 10-bit HEVC, and Apple ProRes. A writer offers those its platform encodes.
    static let deliveries: [HostVideoFormat] = [
        HostVideoFormat(id: "mp4", label: "MPEG-4 · H.264", fileExtension: "mp4",
                        mimeType: "video/mp4", takesLinearLight: false, compresses: true, bits: 8),
        HostVideoFormat(id: "mov", label: "QuickTime · H.264", fileExtension: "mov",
                        mimeType: "video/quicktime", takesLinearLight: false, compresses: true,
                        bits: 8),
        HostVideoFormat(id: "hevc10", label: "HEVC 10-bit", fileExtension: "mp4",
                        mimeType: "video/mp4", takesLinearLight: true, compresses: true, bits: 10),
    ] + [("prores422proxy", "Apple ProRes 422 Proxy"), ("prores422lt", "Apple ProRes 422 LT"),
         ("prores422", "Apple ProRes 422"), ("prores422hq", "Apple ProRes 422 HQ"),
         ("prores4444", "Apple ProRes 4444"), ("prores4444xq", "Apple ProRes 4444 XQ")].map {
        HostVideoFormat(id: $0.0, label: $0.1, fileExtension: "mov", mimeType: "video/quicktime",
                        takesLinearLight: true, compresses: false,
                        bits: $0.0.hasPrefix("prores4444") ? 12 : 10)
    }
}

/// The Mac app's Video File Size (`AppSettings.VideoExportBitrate`): what a compressed movie may
/// spend per pixel of each frame.
enum HostVideoBitrate: String, CaseIterable {
    case automatic, smaller, higher, maximum

    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .smaller: return "Smaller Files"
        case .higher: return "Higher Quality"
        case .maximum: return "Maximum"
        }
    }

    /// Bits per pixel per frame, nil to leave the rate to the encoder. HLG spends half as much
    /// again, as the Mac app's HDR exports do.
    func bitsPerPixel(hdr: Bool) -> Double? {
        switch self {
        case .automatic: return nil
        case .smaller: return hdr ? 0.18 : 0.12
        case .higher: return hdr ? 0.36 : 0.24
        case .maximum: return hdr ? 0.54 : 0.36
        }
    }
}

/// The frame rates an export may retime to, as the Mac app's export sheet offers them; the
/// source's own rate is the default.
let hostVideoFrameRates = [16, 18, 24, 25, 30, 60]

/// What an export writes: the size, cadence and look of the movie, and where its sound comes from.
struct HostVideoDelivery {
    var url: URL
    var format: HostVideoFormat
    var width: Int
    var height: Int
    var frameRate: Double
    /// What a compressed format may spend per pixel; ProRes ignores it.
    var bitrate: HostVideoBitrate
    /// The SDR shoulder the film delivers through, for writers that encode linear light.
    var shoulderKnee: Float
    /// The source timeline range the movie covers; its first frame is at `range.lowerBound`.
    var range: ClosedRange<Double>
    /// The movie whose sound is carried across, when the edit keeps it. A writer carries the
    /// audio of sources its platform reads and leaves others silent.
    var audio: HostVideoSource?
    /// BT.2100 HLG in BT.2020 rather than SDR Display P3, for formats that carry it.
    var hdr = false
}

/// Encodes developed frames into a movie file.
protocol HostVideoWriter: AnyObject {
    func begin(_ delivery: HostVideoDelivery) throws
    /// Tightly packed rows, `width * 4` bytes of Display P3 or `width * 16` of linear light as
    /// the format takes them, shown from `seconds` on the source timeline.
    func append(_ pixels: UnsafeRawBufferPointer, at seconds: Double) throws
    func finish() throws
    /// Stops the encode and removes the partial file.
    func cancel()
}

/// Opens movies: the platform's `HostPlatform.videoSource`. Without one the editor declines
/// movie files rather than failing on them.
protocol HostVideoSourceFactory {
    /// Whether a file the host was handed by path is a movie this platform reads.
    func isMovie(_ url: URL) -> Bool
    func open(_ url: URL) throws -> HostVideoSource
}

/// Encodes movies: the platform's `HostPlatform.videoWriter`.
protocol HostVideoWriterFactory {
    /// The delivery formats, as the export dialog lists them.
    var formats: [HostVideoFormat] { get }
    func writer(for format: HostVideoFormat) throws -> HostVideoWriter
}

/// An imported movie: the file it reads, the frame the current request selected, and the
/// image the renders see, whose pixels are that frame decoded at the size each render asks for.
final class HostVideo {
    let source: HostVideoSource
    /// The uploaded copy the video owns and deletes; nil for a file read in place.
    private let file: URL?
    /// The render path's view of the movie. It holds this video, so a lease on the image is a
    /// lease on the movie and its file.
    private(set) weak var image: HostImage?
    private var time: Double
    private var interpretation = HostVideoInterpretation.standard
    /// The last frame decoded, kept so a render that changes only the edit decodes nothing.
    private var cached: (key: String, frame: HostVideoFrame)?
    /// A frame an export hands over, served instead of decoding.
    private var held: HostVideoFrame?

    /// Takes ownership of `file`, when given, which is deleted with the video.
    init(source: HostVideoSource, owning file: URL?) {
        self.source = source
        self.file = file
        time = source.start
    }

    deinit { if let file { try? FileManager.default.removeItem(at: file) } }

    /// Makes the image the renders develop; the video lives as long as it does.
    func makeImage() -> HostImage {
        let image = HostImage(width: source.width, height: source.height,
                              contentHeadroom: source.taggedHeadroom) { [unowned self] width, height in
            self.pixels(width: width, height: height)
        }
        image.video = self
        self.image = image
        select(time: source.start, interpretation: .standard, playback: false)
        return image
    }

    /// The fields of a render request that pick the frame: `videoTime`, the edit's
    /// `video.encoding` and `previewQuality`.
    private struct Selection: Decodable {
        struct Edit: Decodable {
            struct Video: Decodable { var encoding: String? }
            var video: Video?
        }
        var videoTime: Double?
        var previewQuality: String?
        var edit: Edit?
    }

    /// Points the image at the frame a render request names.
    func select(_ request: Data) {
        let selection = try? JSONDecoder().decode(Selection.self, from: request)
        select(time: selection?.videoTime ?? source.start,
               interpretation: HostVideoInterpretation(selection?.edit?.video?.encoding),
               playback: selection?.previewQuality == "playback")
    }

    func select(time: Double, interpretation: HostVideoInterpretation, playback: Bool) {
        self.time = min(max(time, source.start), max(source.start, source.duration))
        self.interpretation = interpretation
        held = nil
        let number = frameNumber(self.time)
        image?.frameKey = "\(interpretation)|\(number)"
        image?.pace = (UInt64(number), playback)
        image?.contentHeadroom = headroom(interpretation)
    }

    /// Hands an export's decoded frame to the render path.
    func hold(_ frame: HostVideoFrame, interpretation: HostVideoInterpretation) {
        held = frame
        let number = frameNumber(frame.time)
        image?.frameKey = "\(interpretation)|held|\(frame.time)"
        image?.pace = (UInt64(number), false)
        image?.contentHeadroom = headroom(interpretation)
    }

    /// The frame number a time falls in, from the first frame: what moves the grain.
    func frameNumber(_ seconds: Double) -> Int {
        max(0, Int(((seconds - source.start) * max(1, source.frameRate) + 1e-3).rounded(.down)))
    }

    /// Camera log capacity is not declared content range; HLG and PQ are bounded transfers.
    func headroom(_ interpretation: HostVideoInterpretation) -> Float {
        switch interpretation {
        case .standard: return source.taggedHeadroom
        case .camera(let encoding): return encoding.declaredHeadroom ?? 1
        }
    }

    private func pixels(width: Int, height: Int) -> [Float] {
        if let held {
            if held.width == width && held.height == height { return held.scene }
            return AreaResample.reduce(held.scene, width: held.width, height: held.height,
                                       to: width, height)
        }
        let key = "\(interpretation)|\(frameNumber(time))|\(width)x\(height)"
        if let cached, cached.key == key { return cached.frame.scene }
        do {
            let frame = try source.frame(at: time, width: width, height: height,
                                         interpretation: interpretation, displayCodes: false)
            let rgba = frame.width == width && frame.height == height ? frame.rgba
                : AreaResample.reduce(frame.rgba, width: frame.width, height: frame.height,
                                      to: width, height)
            cached = (key, HostVideoFrame(time: frame.time, duration: frame.duration,
                                          width: width, height: height, rgba: rgba))
            return rgba
        } catch {
            // The import decoded this movie, so a frame that will not decode is a damaged one;
            // it develops as black rather than failing the edit.
            return [Float](repeating: 0, count: width * height * 4)
        }
    }

    /// The selected frame as the decoder's 8-bit Display P3 codes at this size, for a develop
    /// that reads them as they are; nil where the source decodes this movie as light, or for a
    /// frame an export holds.
    func displayCodes(width: Int, height: Int) -> HostVideoCodes? {
        guard held == nil else { return nil }
        let key = "\(interpretation)|\(frameNumber(time))|\(width)x\(height)"
        if let cached, cached.key == key { return cached.frame.display8 }
        guard let frame = try? source.frame(at: time, width: width, height: height,
                                             interpretation: interpretation, displayCodes: true),
              frame.width == width, frame.height == height else { return nil }
        // Light decoded here is the frame `pixels` would decode next.
        cached = (key, frame)
        return frame.display8
    }

    /// The descriptor fields the editor's transport controls read (`image.video`).
    var descriptor: [String: Any] {
        ["start": source.start, "duration": source.duration, "frameRate": source.frameRate,
         "audio": source.hasAudio]
    }

    /// The sound as a WAV file, or a silent one as long as the movie: a clock and a soundtrack
    /// any media element plays, where the movie's own codecs may not.
    func playbackWAV() throws -> [UInt8] {
        let rate = 48_000
        if let audio = try source.audioPCM(sampleRate: rate), !audio.samples.isEmpty {
            return Self.wav(audio.samples.withUnsafeBytes { Array($0) }, sampleRate: rate,
                            channels: audio.channels, bits: 16)
        }
        // Silence costs one byte a sample at the lowest rate every browser accepts.
        let silentRate = 8_000
        let count = Int((max(source.duration, 0.1) * Double(silentRate)).rounded(.up))
        return Self.wav([UInt8](repeating: 128, count: count), sampleRate: silentRate,
                        channels: 1, bits: 8)
    }

    static func wav(_ data: [UInt8], sampleRate: Int, channels: Int, bits: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(44 + data.count)
        func tag(_ text: String) { out += Array(text.utf8) }
        func u32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { out += $0 } }
        func u16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { out += $0 } }
        tag("RIFF"); u32(36 + data.count); tag("WAVE")
        tag("fmt "); u32(16); u16(1); u16(channels); u32(sampleRate)
        u32(sampleRate * channels * bits / 8); u16(channels * bits / 8); u16(bits)
        tag("data"); u32(data.count)
        out += data
        return out
    }
}

/// Movie bytes arriving from the editor in chunks, and the movies they became.
final class HostVideoLibrary {
    private let lock = NSLock()
    private var uploads: [String: URL] = [:]
    private var nextUpload = 1
    /// This process's own directory, so two running hosts never delete each other's files.
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("fotufilm-video", isDirectory: true)
        .appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
                                isDirectory: true)

    deinit { try? FileManager.default.removeItem(at: directory) }

    /// A new upload's handle. Upload handles are strings, so releasing one never releases an
    /// image with the same number.
    func begin(name: String) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = URL(fileURLWithPath: name).pathExtension
        let url = directory.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : "." + ext))
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw HostEngine.Failure(description: "The video could not be staged.")
        }
        lock.lock()
        defer { lock.unlock() }
        let handle = "upload-\(nextUpload)"
        nextUpload += 1
        uploads[handle] = url
        return handle
    }

    func append(_ handle: Any?, offset: Int, bytes: UnsafeRawBufferPointer) throws {
        let url = try upload(handle)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seek(toOffset: UInt64(max(0, offset)))
        try file.write(contentsOf: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: bytes.baseAddress!),
                                        count: bytes.count, deallocator: .none))
    }

    /// Hands the upload's file to its new owner; the upload is gone afterwards.
    func take(_ handle: Any?) throws -> URL {
        let url = try upload(handle)
        lock.lock()
        uploads[handle as! String] = nil
        lock.unlock()
        return url
    }

    /// Releases an unfinished upload. Handles that are not uploads are ignored.
    func release(_ handle: Any?) {
        guard let handle = handle as? String else { return }
        lock.lock()
        let url = uploads.removeValue(forKey: handle)
        lock.unlock()
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    private func upload(_ handle: Any?) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        guard let handle = handle as? String, let url = uploads[handle] else {
            throw HostEngine.Failure(description: "That video upload is no longer open.")
        }
        return url
    }
}
