#if canImport(CoreImage) && canImport(ImageIO)
import XCTest
import CoreImage
import ImageIO
import simd
import UniformTypeIdentifiers
@testable import FotufilmHost
import FotufilmCore

/// Writes the render baseline: a fixed matrix of inputs and output media developed through the
/// editor's own path (prepare, frame, develop) on the CPU and on the GPU. Nothing is compared
/// here. `tools/render-baseline.sh` runs these with `FOTUFILM_RENDER_BASELINE_OUT` set and hands
/// the dumps to `tools/render-baseline.py`, which compares them with the committed fingerprints
/// in `Tests/RenderBaseline/references`. Without that variable every test here skips, so the
/// ordinary suite never runs them.
///
/// The inputs are synthetic and deterministic: one chart, entered four ways. Scene light stands in
/// for a camera RAW (the RAW decoder itself is not covered), the JPEG and the gain-map HEIC are
/// committed files written from the chart by `testWriteInputFiles`, and the negative is the chart
/// exposed onto a strip of film with a rebate and a dense holder.
final class RenderBaselineTests: XCTestCase {
    static let stock = "gold200"
    /// One medium for each of the print routes: a paper, Lab Scan, telecine, Cineon Log, Digital
    /// Reference and the negative itself.
    static let media = ["ektacolor-edge", "lab-scan", "telecine", "cineon-log", "screen", "negative"]
    static let inputs = ["scene", "jpeg", "heic-hdr", "negative"]
    static let chartWidth = 960, chartHeight = 540
    static let maxEdge = 640
    /// The clear film's transmittance under the scanner's light: an orange mask.
    static let filmBase = SIMD3<Float>(0.8, 0.45, 0.2)

    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("RenderBaseline")
    static var inputDirectory: URL { directory.appendingPathComponent("inputs") }

    private func output(_ name: String) throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["FOTUFILM_RENDER_BASELINE_OUT"],
              !path.isEmpty else {
            throw XCTSkip("Set FOTUFILM_RENDER_BASELINE_OUT, or run tools/render-baseline.sh.")
        }
        let url = URL(fileURLWithPath: path).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - The matrix

    func testCPU() throws {
        let directory = try output("cpu")
        try develop(on: try HostEngine(developer: HalideCPUDeveloper()), into: directory)
    }

    func testMetal() throws {
        let directory = try output("metal")
        let engine = try HostEngine()
        guard engine.developer.kind == "metal" else {
            throw XCTSkip("No Metal developer on this machine (\(engine.developer.kind)).")
        }
        try develop(on: engine, into: directory)
    }

    /// The chart as the browser engine takes it, for `tools/render-baseline-wasm.mjs`: scene light
    /// as float RGBA, and the committed JPEG decoded to sRGB codes as a canvas would.
    func testWriteWasmInputs() throws {
        let directory = try output("inputs")
        let scene = Self.chart(width: Self.chartWidth, height: Self.chartHeight)
        try scene.withUnsafeBytes { try Data($0).write(to: directory.appendingPathComponent("scene.f32")) }
        let jpeg = try XCTUnwrap(CGImageSourceCreateWithURL(
            Self.inputDirectory.appendingPathComponent("chart.jpg") as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(jpeg, 0, nil))
        var codes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &codes, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        for i in 0..<(image.width * image.height) { codes[i * 4 + 3] = 255 }
        try Data(codes).write(to: directory.appendingPathComponent("display.rgba8"))
        try JSONSerialization.data(withJSONObject: [
            "width": Self.chartWidth, "height": Self.chartHeight, "stock": Self.stock,
            "media": Self.media,
        ]).write(to: directory.appendingPathComponent("inputs.json"))
    }

    private func develop(on engine: HostEngine, into directory: URL) throws {
        let service = engine.service
        let lights = FileManager.default.temporaryDirectory
            .appendingPathComponent("fotufilm-baseline-lights-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: lights) }
        service.negativeScans = HostNegativeScans(lights: HostNegativeLightFrames(directory: lights))

        let decoder = CoreImageDecoder()
        var handles: [String: Int] = [:]
        handles["scene"] = service.register(HostImage(
            rgba: Self.chart(width: Self.chartWidth, height: Self.chartHeight),
            width: Self.chartWidth, height: Self.chartHeight, contentHeadroom: 1))
        handles["jpeg"] = service.register(
            try decoder.decode(Self.inputDirectory.appendingPathComponent("chart.jpg")))
        let hdr = try decoder.decode(Self.inputDirectory.appendingPathComponent("chart-hdr.heic"))
        XCTAssertGreaterThan(hdr.contentHeadroom, 1, "the HEIC's gain map was not read")
        handles["heic-hdr"] = service.register(hdr)
        let strip = HostImage(rgba: Self.negativeStrip(width: Self.chartWidth, height: Self.chartHeight),
                              width: Self.chartWidth, height: Self.chartHeight, contentHeadroom: 1)
        let negative = service.register(strip)
        service.negativeScans.add(HostNegativeScan(scan: strip) { _ in nil }, handle: negative)
        handles["negative"] = negative

        for input in Self.inputs {
            for medium in Self.media {
                var edit: [String: Any] = ["stock": Self.stock, "params": [String: Any]()]
                if input == "negative" {
                    edit["negative"] = ["border": (0..<3).map { Double(Self.filmBase[$0]) }]
                }
                let body: [String: Any] = [
                    "handle": handles[input]!, "maxEdge": Self.maxEdge, "edit": edit,
                    "profileRequest": ["controls": [String: Any](), "medium": medium],
                ]
                let prepared = try service.prepare(JSONSerialization.data(withJSONObject: body))
                let scene = try service.framedScene(prepared)
                let (width, height) = prepared.sizes.output
                var rgba = [Float](repeating: 0, count: width * height * 4)
                try rgba.withUnsafeMutableBytes { buffer in
                    try engine.develop(scene, width: width, height: height,
                                       contentHeadroom: prepared.image.contentHeadroom,
                                       edit: prepared.edit,
                                       into: .init(maxEdge: 0, format: .rgba32FloatLinearP3,
                                                   pixels: buffer.baseAddress!,
                                                   rowBytes: width * 16, capacity: buffer.count))
                }
                var rgb = [Float]()
                rgb.reserveCapacity(width * height * 3)
                for i in 0..<(width * height) { rgb.append(contentsOf: rgba[(i * 4)..<(i * 4 + 3)]) }
                try Self.writeRecord(name: "\(input)-\(medium)", width: width, height: height,
                                     values: rgb, to: directory.appendingPathComponent("\(input)-\(medium).bin"))
            }
        }
    }

    /// One dump in the `FSPY` layout `tools/aot-parity.mm` writes, so one reader takes every
    /// backend: the name, two integers (here the frame's width and height), a status, the floats.
    static func writeRecord(name: String, width: Int, height: Int, values: [Float], to url: URL) throws {
        var data = Data("FSPY".utf8)
        func int32(_ value: Int) { withUnsafeBytes(of: Int32(value).littleEndian) { data.append(contentsOf: $0) } }
        int32(name.utf8.count)
        data.append(contentsOf: Array(name.utf8))
        int32(width << 16 | height)
        int32(0)
        int32(values.count)
        values.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url)
    }

    // MARK: - The chart

    /// Scene-linear Rec. 2020 RGBA, mid-grey 0.18 at diffuse exposure: a neutral ramp twelve stops
    /// long, twelve colour patches, a saturated hue sweep, specular highlights up to 64 on a dark
    /// field for the halation and the shoulder, and a zone plate for the spatial stages.
    static func chart(width: Int, height: Int) -> [Float] {
        let patches: [SIMD3<Float>] = [
            [0.11, 0.08, 0.06], [0.40, 0.30, 0.24], [0.12, 0.19, 0.33], [0.10, 0.14, 0.07],
            [0.24, 0.22, 0.43], [0.20, 0.45, 0.42], [0.55, 0.28, 0.06], [0.10, 0.10, 0.37],
            [0.42, 0.11, 0.13], [0.09, 0.05, 0.14], [0.37, 0.48, 0.08], [0.65, 0.42, 0.06],
        ]
        let highlights: [(x: Float, y: Float, radius: Float, value: SIMD3<Float>)] = [
            (0.10, 0.74, 0.030, [4.0, 3.8, 3.4]),
            (0.24, 0.84, 0.020, [16.0, 15.0, 13.0]),
            (0.38, 0.72, 0.010, [64.0, 60.0, 52.0]),
        ]
        var rgba = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let u = (Float(x) + 0.5) / Float(width), v = (Float(y) + 0.5) / Float(height)
                var value = SIMD3<Float>(repeating: 0.18)
                if v < 0.15 {
                    value = SIMD3(repeating: 0.18 * exp2(-8 + 12 * u))
                } else if v < 0.45 {
                    let column = min(Int(u * 6), 5), row = v < 0.3 ? 0 : 1
                    let inset = abs(u * 6 - Float(column) - 0.5) < 0.42
                        && abs((v - 0.15) / 0.15 - Float(row) - 0.5) < 0.42
                    if inset { value = patches[row * 6 + column] }
                } else if v < 0.6 {
                    let hue = u * 6
                    let rgb = SIMD3<Float>(
                        min(max(abs(hue - 3) - 1, 0), 1),
                        min(max(2 - abs(hue - 2), 0), 1),
                        min(max(2 - abs(hue - 4), 0), 1))
                    value = 0.04 + 0.5 * rgb
                } else if u < 0.5 {
                    value = SIMD3(repeating: 0.01)
                    for spot in highlights {
                        let dx = (u - spot.x) * Float(width) / Float(height), dy = v - spot.y
                        if dx * dx + dy * dy < spot.radius * spot.radius { value = spot.value }
                    }
                } else {
                    let cx = Float(x) - Float(width) * 0.75, cy = Float(y) - Float(height) * 0.8
                    let phase = Float.pi * (cx * cx + cy * cy) / Float(width)
                    value = SIMD3(repeating: 0.18 * (1 + 0.8 * cos(phase)))
                }
                let index = (y * width + x) * 4
                rgba[index] = value.x
                rgba[index + 1] = value.y
                rgba[index + 2] = value.z
            }
        }
        return rgba
    }

    /// The chart exposed onto colour negative film and scanned: a picture whose densities follow
    /// the chart's log exposure, a strip of clear film above and below it, and a dense holder at
    /// the left. Linear Rec. 2020 transmittance through the orange mask.
    static func negativeStrip(width: Int, height: Int) -> [Float] {
        let pictureHeight = height * 4 / 5, top = (height - pictureHeight) / 2
        let holder = width * 3 / 100
        let picture = chart(width: width - holder, height: pictureHeight)
        var rgba = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var density = SIMD3<Float>(repeating: 0)
                if x < holder {
                    density = SIMD3(repeating: 4)
                } else if y >= top, y < top + pictureHeight {
                    let index = ((y - top) * (width - holder) + x - holder) * 4
                    for c in 0..<3 {
                        let exposure = max(picture[index + c], 1e-4) / 0.18
                        density[c] = min(max(0.7 + 0.62 * log10(exposure), 0.05), 2.4)
                            * (1 + 0.05 * Float(c))
                    }
                }
                let index = (y * width + x) * 4
                for c in 0..<3 { rgba[index + c] = filmBase[c] * pow(10, -density[c]) }
            }
        }
        return rgba
    }

    // MARK: - The committed input files

    /// Writes `chart.jpg` and `chart-hdr.heic` into `FOTUFILM_RENDER_BASELINE_INPUTS`. Run once to
    /// make the committed files; encoders change between releases, so the baseline reads the
    /// committed bytes rather than encoding afresh.
    func testWriteInputFiles() throws {
        guard let path = ProcessInfo.processInfo.environment["FOTUFILM_RENDER_BASELINE_INPUTS"],
              !path.isEmpty else { throw XCTSkip("Set FOTUFILM_RENDER_BASELINE_INPUTS to write the inputs.") }
        guard #available(macOS 15.0, *) else { throw XCTSkip("gain-map HEIC needs macOS 15") }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let width = Self.chartWidth, height = Self.chartHeight
        let scene = Self.chart(width: width, height: height)

        // The JPEG: the chart as a camera would deliver it, clipped at display white in sRGB.
        let toSRGB = simd_float3x3(rows: [[1.6605, -0.5876, -0.0728],
                                          [-0.1246, 1.1329, -0.0083],
                                          [-0.0182, -0.1006, 1.1187]])
        var codes = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            let linear = toSRGB * SIMD3(scene[i * 4], scene[i * 4 + 1], scene[i * 4 + 2])
            for c in 0..<3 {
                let l = min(max(linear[c], 0), 1)
                let encoded = l <= 0.0031308 ? 12.92 * l : 1.055 * pow(l, 1 / 2.4) - 0.055
                codes[i * 4 + c] = UInt8((encoded * 255).rounded())
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(codes) as CFData))
        let jpeg = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let jpegURL = directory.appendingPathComponent("chart.jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            jpegURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, jpeg,
                                   [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        // The HEIC: an SDR picture clipped at display white and a gain map that restores the
        // highlights to 8x above it, in Display P3.
        let toP3 = simd_float3x3(rows: [[1.3436, -0.2822, -0.0614],
                                        [-0.0653, 1.0758, -0.0105],
                                        [0.0028, -0.0196, 1.0168]])
        var base = [Float](repeating: 1, count: width * height * 4), alternate = base
        for i in 0..<(width * height) {
            let p3 = toP3 * SIMD3(scene[i * 4], scene[i * 4 + 1], scene[i * 4 + 2])
            for c in 0..<3 {
                base[i * 4 + c] = min(max(p3[c], 0), 1)
                alternate[i * 4 + c] = min(max(p3[c], 0), 8)
            }
        }
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        func image(_ pixels: [Float]) -> CIImage {
            CIImage(bitmapData: pixels.withUnsafeBufferPointer { Data(buffer: $0) },
                    bytesPerRow: width * 16, size: CGSize(width: width, height: height),
                    format: .RGBAf, colorSpace: linear)
        }
        try CIContext(options: [.cacheIntermediates: false]).writeHEIFRepresentation(
            of: image(base), to: directory.appendingPathComponent("chart-hdr.heic"), format: .RGB10,
            colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
            options: [.hdrImage: image(alternate), .hdrGainMapAsRGB: true])
    }
}
#endif
