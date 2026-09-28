#if canImport(AVFoundation)
import AVFoundation
import XCTest
import CFotufilmHost
@testable import FotufilmHost
#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmEditModel)
import FotufilmEditModel
#endif

/// Video through the host: a one-second test movie written here, grey rising a step each frame
/// with a tone under it, decoded, developed and exported through the editor's calls.
final class HostVideoTests: XCTestCase {
    private static let size = (width: 64, height: 48)
    private static let rate = 30
    private static let frames = 30

    private var movie: URL!

    private func open(_ url: URL) throws -> HostVideoSource {
        try XCTUnwrap(HostPlatform.current.videoSource).open(url)
    }

    private static var engine: HostEngine?

    /// Starting AVAssetWriter loads a system framework that exports Halide runtime symbols of
    /// its own, and a pipeline JIT-compiled after that binds to them. So every develop these
    /// tests make is compiled first, on a still. The AOT library the hosts ship links its
    /// runtime statically and is unaffected.
    override class func setUp() {
        guard let engine = try? HostEngine(),
              let edit = try? JSONDecoder().decode(WebNativeEdit.self, from: Data(
                #"{"edit": {"stock": "gold200"}, "profileRequest": {"controls": {}}}"#.utf8))
        else { return }
        let scene = [Float](repeating: 0.18, count: 64 * 48 * 4)
        var pixels = [UInt8](repeating: 0, count: 64 * 48 * 16)
        for (format, realtime) in [(HostEngine.PixelFormat.rgba8DisplayP3, false), (.rgba8DisplayP3, true),
                                   (.rgba32FloatLinearP3, false)] {
            pixels.withUnsafeMutableBytes { buffer in
                try? engine.develop(scene, width: 64, height: 48, contentHeadroom: 1, edit: edit,
                                    realtime: realtime,
                                    into: .init(maxEdge: 0, format: format, pixels: buffer.baseAddress!,
                                                rowBytes: 64 * (format == .rgba8DisplayP3 ? 4 : 16),
                                                capacity: buffer.count))
            }
        }
        // And every road the video pipeline takes, for the same reason.
        for road in VideoRoad.allCases {
            if let roads = try? pipelines(engine, road) {
                _ = try? develop(roads.pipeline, roads.scene, frameIndex: 0)
            }
        }
        self.engine = engine
    }

    override func setUpWithError() throws {
        movie = FileManager.default.temporaryDirectory
            .appendingPathComponent("fotufilm-video-test-\(UUID().uuidString).mov")
        try Self.writeMovie(to: movie)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: movie)
    }

    /// Mean green of a decoded frame: rises with the frame number.
    private func level(_ frame: HostVideoFrame) -> Float {
        stride(from: 1, to: frame.rgba.count, by: 4).map { frame.rgba[$0] }.reduce(0, +)
            / Float(frame.width * frame.height)
    }

    func testFramesFollowTheClockForwardAndBack() throws {
        let source = try open(movie)
        XCTAssertEqual(source.width, Self.size.width)
        XCTAssertEqual(source.height, Self.size.height)
        XCTAssertEqual(source.duration, 1, accuracy: 0.01)
        XCTAssertEqual(source.frameRate, Double(Self.rate), accuracy: 0.01)
        XCTAssertTrue(source.hasAudio)

        // The sequential read is the reference each seek must agree with.
        let reader = try source.frames(from: 0, to: 1, width: 32, height: 24, interpretation: .standard,
                                       displayCodes: false)
        var sequence: [HostVideoFrame] = []
        while let frame = try reader.next() { sequence.append(frame) }
        XCTAssertEqual(sequence.count, Self.frames)
        XCTAssertEqual(sequence[0].width, 32)
        for (a, b) in zip(sequence, sequence.dropFirst()) { XCTAssertLessThan(level(a), level(b)) }

        // Playback steps forward, a scrub jumps back and ahead; every answer is the frame showing.
        for index in [0, 1, 2, 3, 10, 11, 4, 29, 28, 15, 15, 16] {
            let time = (Double(index) + 0.5) / Double(Self.rate)
            let frame = try source.frame(at: time, width: 32, height: 24, interpretation: .standard,
                                         displayCodes: false)
            // A reader opened mid-frame reports the frame from where it was opened.
            XCTAssertGreaterThanOrEqual(frame.time, Double(index) / Double(Self.rate) - 1e-3)
            XCTAssertLessThanOrEqual(frame.time, time + 1e-3)
            XCTAssertEqual(level(frame), level(sequence[index]), accuracy: 1e-6, "frame \(index)")
        }
        // Exactly on a frame's start is that frame.
        let exact = try source.frame(at: 5.0 / Double(Self.rate), width: 32, height: 24,
                                     interpretation: .standard, displayCodes: false)
        XCTAssertEqual(level(exact), level(sequence[5]), accuracy: 1e-6)
    }

    func testCameraLogReadsCodeValuesThroughTheCurve() throws {
        let source = try open(movie)
        let standard = try source.frame(at: 0.5, width: 32, height: 24, interpretation: .standard,
                                        displayCodes: false)
        let log = try source.frame(at: 0.5, width: 32, height: 24,
                                   interpretation: HostVideoInterpretation("appleLog"),
                                   displayCodes: false)
        // Frame 15's code, 120/255, read through the Apple Log curve with diffuse white at 1:
        // the decoder hands the untouched code over, not the colour-managed picture.
        let expected = AppleLogCurve.linear(120 / 255) / 0.9
        XCTAssertEqual(level(log), expected, accuracy: expected * 0.1)
        XCTAssertGreaterThan(abs(level(log) - level(standard)), expected * 0.2)
        XCTAssertEqual(HostVideoInterpretation("appleLog").description, "appleLog")
        XCTAssertEqual(HostVideoInterpretation("nonsense"), .standard)
    }

    func testPlaybackClockIsAWaveAsLongAsTheMovie() throws {
        let video = HostVideo(source: try open(movie), owning: nil)
        let wav = try video.playbackWAV()
        XCTAssertEqual(Array(wav[0..<4]), Array("RIFF".utf8))
        XCTAssertEqual(Array(wav[8..<12]), Array("WAVE".utf8))
        // 48 kHz stereo 16-bit for one second, and the tone is audible in it.
        XCTAssertGreaterThanOrEqual(wav.count - 44, 48_000 * 4 - 16)
        let samples = wav[44...].withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        XCTAssertGreaterThan(samples.map { abs(Int($0)) }.max() ?? 0, 1000)
    }

    // MARK: Through the editor's calls

    private func makeEngine() throws -> HostEngine {
        guard let engine = Self.engine else { throw XCTSkip("No engine in this build.") }
        return engine
    }

    private func json(_ answer: HostService.Answer) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: answer.json) as? [String: Any])
    }

    private func call(_ service: HostService, _ method: String, _ params: [String: Any],
                      payload: Data? = nil) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: params)
        guard let payload else { return try json(service.call(method, params: data, payload: nil)) }
        return try payload.withUnsafeBytes {
            try json(service.call(method, params: data, payload: $0))
        }
    }

    /// Uploads the movie in three chunks, as the page does.
    private func importMovie(_ service: HostService) throws -> (Int, HostService.Answer) {
        let bytes = try Data(contentsOf: movie)
        let upload = try call(service, "beginVideo", ["name": "clip.mov", "size": bytes.count])
        let handle = try XCTUnwrap(upload["handle"] as? String)
        let chunk = bytes.count / 3 + 1
        for offset in stride(from: 0, to: bytes.count, by: chunk) {
            _ = try call(service, "appendVideo", ["handle": handle, "offset": offset],
                         payload: bytes[offset..<min(bytes.count, offset + chunk)])
        }
        let answer = try service.call("importVideo", params: JSONSerialization.data(
            withJSONObject: ["handle": handle, "playback": true]), payload: nil)
        _ = try call(service, "release", ["handle": handle])
        return (try XCTUnwrap(json(answer)["handle"] as? Int), answer)
    }

    private func renderRequest(_ handle: Int, time: Double, video: [String: Any] = [:]) -> [String: Any] {
        ["handle": handle, "maxEdge": 64, "videoTime": time, "previewQuality": "playback",
         "edit": ["stock": "gold200", "video": video], "profileRequest": ["controls": [String: Any]()]]
    }

    func testImportRenderAndExportThroughTheService() throws {
        let engine = try makeEngine()
        let service = engine.service
        let capabilities = HostPlatform.current.capabilities
        XCTAssertEqual(capabilities["video"] as? Bool, true)
        let formats = try XCTUnwrap(capabilities["videoExportTypes"] as? [[String: Any]])
        XCTAssertTrue(formats.contains { $0["id"] as? String == "prores422" })

        let (handle, imported) = try importMovie(service)
        let descriptor = try json(imported)
        XCTAssertEqual(descriptor["naturalWidth"] as? Int, Self.size.width)
        let clip = try XCTUnwrap(descriptor["video"] as? [String: Any])
        XCTAssertEqual(clip["duration"] as? Double ?? 0, 1, accuracy: 0.01)
        XCTAssertEqual(descriptor["playbackType"] as? String, "audio/wav")
        let payloads = try XCTUnwrap(descriptor["payloads"] as? [String: [Int]])
        XCTAssertNotNil(payloads["preview"])
        let playback = try XCTUnwrap(payloads["playback"])
        XCTAssertEqual(Array(imported.payload[playback[0]..<(playback[0] + 4)]), Array("RIFF".utf8))

        // Two frames develop differently; the same frame twice is served from the caches.
        func render(_ time: Double) throws -> (json: [String: Any], preview: [UInt8]) {
            let answer = try service.call("render", params: JSONSerialization.data(
                withJSONObject: renderRequest(handle, time: time)), payload: nil)
            let body = try json(answer)
            let range = try XCTUnwrap((body["payloads"] as? [String: [Int]])?["original"])
            return (body, Array(answer.payload[range[0]..<(range[0] + range[1])]))
        }
        let early = try render(0.1), late = try render(0.9)
        XCTAssertNotEqual(early.preview, late.preview)
        XCTAssertEqual(try render(0.9 + 0.2 / Double(Self.rate)).preview, late.preview)

        // Trim 0.2...0.7 s to a 10-bit HEVC movie with the tone carried across.
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("fotufilm-export-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        var request = renderRequest(handle, time: 0, video: ["trimStart": 0.2, "trimEnd": 0.7, "audio": true])
        request["maxEdge"] = 45
        request["format"] = "hevc10"
        request["bitrate"] = "higher"
        request["path"] = output.path
        var reports: [[String: Any]] = []
        let saved = try json(service.call("exportVideo", params: JSONSerialization.data(
            withJSONObject: request), payload: nil) { reports.append($0) })
        XCTAssertEqual(saved["frames"] as? Int, 15)
        // A 45 x 34 frame is padded to even sizes, never rescaled.
        XCTAssertEqual(saved["width"] as? Int, 46)
        XCTAssertEqual(saved["height"] as? Int, 34)
        XCTAssertEqual(reports.last?["finalizing"] as? Bool, true)

        let written = AVURLAsset(url: output)
        let duration = try waitFor { try await written.load(.duration) }
        XCTAssertEqual(duration.seconds, 0.5, accuracy: 0.05)
        let tracks = try waitFor { try await written.load(.tracks) }
        XCTAssertEqual(tracks.filter { $0.mediaType == .audio }.count, 1)
        let video = try XCTUnwrap(tracks.first { $0.mediaType == .video })
        let formats2 = try waitFor { try await video.load(.formatDescriptions) }
        XCTAssertEqual(formats2.first.map(CMFormatDescriptionGetMediaSubType), kCMVideoCodecType_HEVC)
    }

    func testExportsProResAndCancels() throws {
        let engine = try makeEngine()
        let service = engine.service
        let (handle, _) = try importMovie(service)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("fotufilm-export-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: output) }
        var request = renderRequest(handle, time: 0, video: ["audio": false])
        request["format"] = "prores422"
        request["path"] = output.path
        let saved = try json(service.call("exportVideo", params: JSONSerialization.data(
            withJSONObject: request), payload: nil) { _ in })
        XCTAssertEqual(saved["frames"] as? Int, Self.frames)
        let tracks = try waitFor { try await AVURLAsset(url: output).load(.tracks) }
        XCTAssertEqual(tracks.map(\.mediaType), [.video])

        // A cancel mid-export stops it and leaves no file behind.
        try FileManager.default.removeItem(at: output)
        var cancelled = false
        do {
            _ = try service.call("exportVideo", params: JSONSerialization.data(
                withJSONObject: request), payload: nil) { _ in engine.cancel() }
        } catch let failure as HostEngine.Failure {
            cancelled = failure.cancelled
        }
        XCTAssertTrue(cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testRetimesToTheChosenFrameRate() throws {
        let engine = try makeEngine()
        let service = engine.service
        let (handle, _) = try importMovie(service)
        XCTAssertEqual(HostPlatform.current.capabilities["videoFrameRates"] as? [Int],
                       [16, 18, 24, 25, 30, 60])
        // A lower rate drops source frames without developing them; a higher one keeps the
        // source's, as the Mac app does.
        for (rate, frames) in [(24.0, 24), (60.0, 30)] {
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent("fotufilm-export-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: output) }
            var request = renderRequest(handle, time: 0, video: ["audio": false, "frameRate": rate])
            request["maxEdge"] = 32
            request["format"] = "mp4"
            request["bitrate"] = "smaller"
            request["path"] = output.path
            let saved = try json(service.call("exportVideo", params: JSONSerialization.data(
                withJSONObject: request), payload: nil) { _ in })
            XCTAssertEqual(saved["frames"] as? Int, frames)
            let track = try XCTUnwrap(waitFor {
                try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first
            })
            let nominal = try waitFor { try await track.load(.nominalFrameRate) }
            XCTAssertEqual(Double(nominal), Double(frames), accuracy: 0.5)
        }
    }

    func testFastProcessingPrintsAtTheDeliveredSize() throws {
        let engine = try makeEngine()
        let service = engine.service
        XCTAssertEqual(HostPlatform.current.capabilities["videoProcessing"] as? Bool,
                       HostPlatform.current.videoDeveloper != nil)
        let (handle, _) = try importMovie(service)
        // Fast develops the film at no more than its edge, here 32 pixels, and prints at 64.
        setenv("FOTUFILM_FAST_EDGE", "32", 1)
        defer { unsetenv("FOTUFILM_FAST_EDGE") }
        if HostPlatform.current.videoDeveloper != nil {
            let request = renderRequest(handle, time: 0)
            let prepared = try service.prepare(JSONSerialization.data(withJSONObject: request))
            let format = try XCTUnwrap(HostPlatform.current.videoWriter?.formats
                .first { $0.id == "mp4" })
            for (processing, size) in [(HostVideoProcessing.full, (64, 48)), (.fast, (32, 24))] {
                let development = try service.videoPipeline(
                    prepared, body: request, format: format, interpretation: .standard,
                    processing: processing, proceed: { true }).development
                XCTAssertEqual(development.developWidth, size.0, "\(processing)")
                XCTAssertEqual(development.developHeight, size.1, "\(processing)")
            }
        }
        var developed: [String: [UInt8]] = [:]
        for processing in ["full", "fast"] {
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent("fotufilm-export-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: output) }
            var request = renderRequest(handle, time: 0, video: ["audio": false])
            request["format"] = "mp4"
            request["videoProcessing"] = processing
            request["path"] = output.path
            let saved = try json(service.call("exportVideo", params: JSONSerialization.data(
                withJSONObject: request), payload: nil) { _ in })
            XCTAssertEqual(saved["frames"] as? Int, Self.frames, processing)
            XCTAssertEqual(saved["width"] as? Int, Self.size.width, processing)
            XCTAssertEqual(saved["height"] as? Int, Self.size.height, processing)
            developed[processing] = try Self.middleFrame(of: output)
        }
        // The same picture either way: the fast film is the full one, a little softer.
        let (mean, _) = Self.difference8(try XCTUnwrap(developed["full"]),
                                         try XCTUnwrap(developed["fast"]))
        XCTAssertLessThan(mean, 2)
    }

    func testUnsupportedHybridKeepsFullResolutionForFallback() throws {
        let engine = try makeEngine()
        let service = engine.service
        let (handle, _) = try importMovie(service)
        setenv("FOTUFILM_FAST_EDGE", "32", 1)
        defer { unsetenv("FOTUFILM_FAST_EDGE") }
        var request = renderRequest(handle, time: 0)
        var edit = try XCTUnwrap(request["edit"] as? [String: Any])
        edit["halationModel"] = "layered"
        request["edit"] = edit
        let prepared = try service.prepare(JSONSerialization.data(withJSONObject: request))
        let film = try XCTUnwrap(engine.stock("gold200"))
        XCTAssertNotNil(try prepared.edit.options(for: film).transportConstruction(for: film))
        let format = try XCTUnwrap(HostPlatform.current.videoWriter?.formats.first { $0.id == "mp4" })
        let pipeline = try service.videoPipeline(prepared, body: request, format: format,
            interpretation: .standard, processing: .fast, proceed: { true })
        XCTAssertTrue(pipeline is HostFrameVideoPipeline)
        XCTAssertEqual(pipeline.development.developWidth, 64)
        XCTAssertEqual(pipeline.development.developHeight, 48)
        XCTAssertFalse(pipeline.development.hybrid)
    }

    /// The pipeline against the frame-by-frame develop it replaces, road by road, on one frame
    /// of a colour ramp: 8-bit roads in codes, deep ones relative to the mean light.
    func testPipelineAgreesWithTheFrameByFrameDevelop() throws {
        let engine = try makeEngine()
        guard HostPlatform.current.videoDeveloper != nil else {
            throw XCTSkip("This platform develops movies frame by frame.")
        }
        for road in VideoRoad.allCases {
            let roads = try Self.pipelines(engine, road)
            XCTAssertFalse(roads.pipeline is HostFrameVideoPipeline, "\(road)")
            let fast = try Self.develop(roads.pipeline, roads.scene, frameIndex: 7)
            let reference = try Self.develop(roads.portable, roads.fullScene, frameIndex: 7)
            // The grain moves from frame to frame and holds within one.
            XCTAssertEqual(try Self.develop(roads.pipeline, roads.scene, frameIndex: 7), fast,
                           "\(road)")
            XCTAssertNotEqual(try Self.develop(roads.pipeline, roads.scene, frameIndex: 8), fast,
                              "\(road)")
            let (mean, largest) = roads.pipeline.development.linearOutput
                ? Self.differenceLinear(reference, fast) : Self.difference8(reference, fast)
            XCTAssertLessThan(mean, road.meanTolerance, "\(road)")
            XCTAssertLessThan(largest, road.largestTolerance, "\(road)")
            if road == .fast {
                let channels = reference.indices.filter { $0 % 4 != 3 }
                    .map { abs(Int(reference[$0]) - Int(fast[$0])) }.sorted()
                XCTAssertLessThanOrEqual(channels[channels.count * 99 / 100], 8,
                                         "Fast must not introduce a broad tonal shift")
            }
        }
    }

    /// An 8-bit decoder's codes go into the 8-bit road as they are, and develop to the very codes
    /// their light would: the direct road only skips the trip.
    func testDisplayCodesDevelopAsTheirLightDoes() throws {
        let engine = try makeEngine()
        guard HostPlatform.current.videoDeveloper != nil else {
            throw XCTSkip("This platform develops movies frame by frame.")
        }
        let roads = try Self.pipelines(engine, .eightBit)
        XCTAssertTrue(roads.pipeline.takesDisplayCodes)
        let count = roads.pipeline.development.developWidth
            * roads.pipeline.development.developHeight
        var codes = [UInt8](repeating: 255, count: count * 4)
        for i in codes.indices where i % 4 != 3 { codes[i] = UInt8(truncatingIfNeeded: i * 37 / 4) }
        try roads.pipeline.submit(display8: codes, frameIndex: 5)
        var direct: [UInt8] = []
        try roads.pipeline.receive { direct = Array($0) }
        let throughLight = try Self.develop(roads.pipeline, HostVideoFrame.scene(display8: codes),
                                            frameIndex: 5)
        XCTAssertEqual(direct, throughLight)
        // A road that reads light takes codes through it.
        XCTAssertFalse(roads.portable.takesDisplayCodes)
    }

    func testSelectionsAndNoFilmTakeTheFrameByFrameDevelop() throws {
        let engine = try makeEngine()
        guard HostPlatform.current.videoDeveloper != nil else {
            throw XCTSkip("This platform develops movies frame by frame.")
        }
        let selective: [String: Any] = ["kind": "light", "sample": [0.2, 0.2, 0.2], "range": 2,
                                        "params": ["ev": 1.0]]
        let selected = try Self.pipelines(engine, .eightBit, edit: ["selective": selective])
        XCTAssertTrue(selected.pipeline is HostFrameVideoPipeline)
        let plain = try Self.pipelines(engine, .eightBit)
        // The selection, reaching every light here, brightens the frame.
        let lifted = try Self.develop(selected.pipeline, selected.scene, frameIndex: 3)
        let ground = try Self.develop(plain.portable, plain.fullScene, frameIndex: 3)
        XCTAssertGreaterThan(lifted.reduce(0) { $0 + Int($1) }, ground.reduce(0) { $0 + Int($1) })
        let noFilm = try Self.pipelines(engine, .eightBit, stock: nil)
        XCTAssertTrue(noFilm.pipeline is HostFrameVideoPipeline)
    }

    // MARK: Pipelines

    /// The roads through the engine an export can take (`HostVideoRoad`), and how closely each
    /// agrees with the frame-by-frame develop.
    enum VideoRoad: CaseIterable {
        /// An 8-bit source to H.264: the 8-bit kernels against the float reference.
        case eightBit
        /// Fast: the film at half size, printed at the delivered one.
        case fast
        /// An 8-bit source to ProRes: the float kernel's realtime schedule.
        case deepRealtime
        /// An HDR source to H.264 and to ProRes: the float reference both ways.
        case deepReference8
        case deepReference

        var format: String { self == .deepRealtime || self == .deepReference ? "prores422" : "mp4" }
        var deepSource: Bool { self == .deepReference8 || self == .deepReference }
        /// The realtime and reduced-density roads approximate the full-frame float develop.
        /// Bound their mean and tail separately; the reference float road uses the same develop
        /// as the frame-by-frame path and should agree to floating-point precision.
        var meanTolerance: Double {
            switch self {
            case .eightBit, .fast: return 1.5
            case .deepRealtime: return 0.01
            case .deepReference8: return 0.01
            case .deepReference: return 1e-6
            }
        }
        var largestTolerance: Double {
            switch self {
            case .eightBit: return 16
            // Digital Reference amplifies isolated grain differences where reduced density is
            // interpolated. Keep the mean and 99th-percentile checks tight as well.
            case .fast: return 24
            case .deepRealtime: return 0.15
            case .deepReference8: return 1
            case .deepReference: return 1e-4
            }
        }
    }

    /// A 64 x 48 colour ramp through the service's own pipeline for `road`, and the
    /// frame-by-frame develop of the same development.
    private static func pipelines(
        _ engine: HostEngine, _ road: VideoRoad, edit: [String: Any] = [:],
        stock: String? = "gold200"
    ) throws -> (pipeline: HostVideoPipeline, portable: HostVideoPipeline, scene: [Float],
                 fullScene: [Float]) {
        let service = engine.service
        let (width, height) = (64, 48)
        var rgba = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let u = Float(x) / Float(width - 1), v = Float(y) / Float(height - 1)
                let light = ColorScience.linearDisplayP3ToRec2020(
                    SIMD3(u, 1 - u, 0.25 + 0.5 * u) * (0.03 + 0.9 * v))
                for c in 0..<3 { rgba[(y * width + x) * 4 + c] = light[c] }
            }
        }
        let image = HostImage(rgba: rgba, width: width, height: height, contentHeadroom: 1)
        var saved = edit
        if let stock { saved["stock"] = stock }
        let body: [String: Any] = ["handle": service.register(image), "edit": saved,
                                   "profileRequest": ["controls": [String: Any]()]]
        let prepared = try service.prepare(JSONSerialization.data(withJSONObject: body))
        let format = try XCTUnwrap(HostPlatform.current.videoWriter?.formats
            .first { $0.id == road.format })
        let chosen = try service.videoPipeline(prepared, body: body, format: format,
                                               interpretation: .standard, processing: .full,
                                               proceed: { true })
        var development = chosen.development
        let portable = HostFrameVideoPipeline(development)
        let fullScene = try service.framedScene(prepared)
        guard !(chosen is HostFrameVideoPipeline),
              let developer = HostPlatform.current.videoDeveloper
        else { return (chosen, portable, fullScene, fullScene) }
        if road.deepSource {
            development.road = HostVideoRoad(deepSource: true,
                                             deepDelivery: format.takesLinearLight)
        }
        var scene = fullScene
        if road == .fast {
            (development.developWidth, development.developHeight) = (width / 2, height / 2)
            scene = AreaResample.reduce(fullScene, width: width, height: height,
                                        to: width / 2, height / 2)
        }
        let pipeline = try XCTUnwrap(developer.pipeline(for: development, proceed: { true }))
        return (pipeline, portable, scene, fullScene)
    }

    private static func develop(_ pipeline: HostVideoPipeline, _ scene: [Float],
                                frameIndex: UInt64) throws -> [UInt8] {
        try pipeline.submit(scene, frameIndex: frameIndex)
        var delivered: [UInt8] = []
        try pipeline.receive { delivered = Array($0) }
        return delivered
    }

    /// Mean and largest difference of the colour channels of two 8-bit RGBA frames, in codes.
    private static func difference8(_ a: [UInt8], _ b: [UInt8]) -> (Double, Double) {
        precondition(a.count == b.count && !a.isEmpty)
        var sum = 0.0, largest = 0.0
        for i in 0..<a.count where i % 4 != 3 {
            let d = abs(Double(a[i]) - Double(b[i]))
            sum += d
            largest = max(largest, d)
        }
        return (sum / Double(a.count / 4 * 3), largest)
    }

    /// The same for linear light, relative to the reference's mean light.
    private static func differenceLinear(_ reference: [UInt8],
                                         _ other: [UInt8]) -> (Double, Double) {
        let a = reference.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let b = other.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        precondition(a.count == b.count && !a.isEmpty)
        var sum = 0.0, level = 0.0, largest = 0.0
        for i in 0..<a.count where i % 4 != 3 {
            let d = abs(Double(a[i]) - Double(b[i]))
            sum += d
            level += abs(Double(a[i]))
            largest = max(largest, d)
        }
        let meanLevel = max(level, 1e-9) / Double(a.count / 4 * 3)
        return (sum / max(level, 1e-9), largest / meanLevel)
    }

    /// The frame half way through a written movie, as 8-bit RGBA.
    private static func middleFrame(of url: URL) throws -> [UInt8] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try waitFor {
            try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        }
        let (width, height) = (image.width, image.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    // MARK: The test movie

    /// One second of H.264 at 30 fps, grey rising eight codes a frame, with a 440 Hz tone in
    /// 48 kHz linear PCM.
    private static func writeMovie(to url: URL) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height,
        ])
        let sampleRate = 48_000
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        video.expectsMediaDataInRealTime = false
        audio.expectsMediaDataInRealTime = false
        writer.add(video)
        writer.add(audio)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for index in 0..<frames {
            while !video.isReadyForMoreMediaData { usleep(1000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
            for y in 0..<size.height {
                for x in 0..<size.width {
                    let i = y * rowBytes + x * 4
                    base[i] = UInt8(8 * index); base[i + 1] = UInt8(8 * index)
                    base[i + 2] = UInt8(8 * index); base[i + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(index),
                                                                              timescale: CMTimeScale(rate))))
        }
        video.markAsFinished()

        var format: CMAudioFormatDescription?
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0)
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                       formatDescriptionOut: &format)
        let tone = (0..<sampleRate).map { Int16(8000 * sin(2 * Double.pi * 440 * Double($0) / Double(sampleRate))) }
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: tone.count * 2,
                                           blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                           dataLength: tone.count * 2, flags: 0, blockBufferOut: &block)
        tone.withUnsafeBytes {
            _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!,
                                              offsetIntoDestination: 0, dataLength: $0.count)
        }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: tone.count,
            presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sample)
        while !audio.isReadyForMoreMediaData { usleep(1000) }
        XCTAssertTrue(audio.append(try XCTUnwrap(sample)))
        audio.markAsFinished()

        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        XCTAssertEqual(writer.status, .completed, writer.error.map { "\($0)" } ?? "")
    }
}
#endif
