// Develops one scene through the engine's CPU and GPU roads on identical inputs, so their pictures
// can be compared across machines: Metal on a Mac (the kernels the Mac app runs), CUDA or Vulkan
// on Linux (FOTUFILM_GPU_DEVICE=vulkan), and the CPU everywhere. Scenes and pictures travel as
// PFM, scene-linear float RGB, so no image codec stands between two machines.
//
//   fotufilm-parity --export-input photo.jpg scene.pfm [--max-edge N]   macOS: decode a photo
//   fotufilm-parity --chart scene.pfm [--size WxH]                      a synthetic scene
//   fotufilm-parity --develop scene.pfm out.pfm --device cpu|gpu [--stock id] [--no-grain]
//                   [--exact]
//   fotufilm-parity --compare reference.pfm candidate.pfm

import FotufilmCore
import FotufilmHalide
import Foundation
#if canImport(FotufilmImaging)
import FotufilmImaging
#endif

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func argument(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func operands(after name: String, count: Int) -> [String] {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), index + count < arguments.count else {
        fail("\(name) takes \(count) paths")
    }
    return Array(arguments[(index + 1)...(index + count)])
}

/// Interleaved RGB floats, top row first.
struct Picture {
    var width: Int
    var height: Int
    var rgb: [Float]
}

// PFM stores rows bottom first, little endian when the scale is negative.
func writePFM(_ picture: Picture, to path: String) {
    var data = Data("PF\n\(picture.width) \(picture.height)\n-1.0\n".utf8)
    let row = picture.width * 3
    for y in stride(from: picture.height - 1, through: 0, by: -1) {
        picture.rgb[(y * row)..<((y + 1) * row)].withUnsafeBufferPointer {
            data.append(UnsafeBufferPointer(start: UnsafeRawPointer($0.baseAddress!)
                .assumingMemoryBound(to: UInt8.self), count: row * 4))
        }
    }
    guard FileManager.default.createFile(atPath: path, contents: data) else {
        fail("could not write \(path)")
    }
}

func readPFM(_ path: String) -> Picture {
    guard let data = FileManager.default.contents(atPath: path) else { fail("could not read \(path)") }
    var fields: [String] = []
    var offset = 0
    var current = ""
    while fields.count < 4, offset < data.count {
        let byte = data[offset]
        offset += 1
        if byte == 0x0A || byte == 0x20 {
            if !current.isEmpty { fields.append(current); current = "" }
        } else {
            current.append(Character(UnicodeScalar(byte)))
        }
    }
    guard fields.count == 4, fields[0] == "PF", let width = Int(fields[1]),
          let height = Int(fields[2]), let scale = Float(fields[3]), scale < 0 else {
        fail("\(path) is not a little-endian colour PFM")
    }
    let row = width * 3
    guard data.count - offset >= width * height * 12 else { fail("\(path) is truncated") }
    var rgb = [Float](repeating: 0, count: width * height * 3)
    data.withUnsafeBytes { bytes in
        let floats = bytes.baseAddress!.advanced(by: offset)
        for y in 0..<height {
            let source = floats.advanced(by: (height - 1 - y) * row * 4)
            rgb.withUnsafeMutableBytes {
                $0.baseAddress!.advanced(by: y * row * 4).copyMemory(from: source, byteCount: row * 4)
            }
        }
    }
    return Picture(width: width, height: height, rgb: rgb)
}

/// The engine's synthetic test scene (fotufilmbench's): gradients, edges and a bright square.
func chart(width: Int, height: Int) -> Picture {
    var rgb = [Float](repeating: 0, count: width * height * 3)
    for y in 0..<height {
        let v = Float(y) / Float(height - 1)
        for x in 0..<width {
            let u = Float(x) / Float(width - 1)
            let square: Float = (u > 0.35 && u < 0.5 && v > 0.35 && v < 0.5) ? 6 : 0
            let index = (y * width + x) * 3
            rgb[index] = u * 1.2 + square
            rgb[index + 1] = v * 1.1 + square
            rgb[index + 2] = (1 - u) * 0.9 + square
        }
    }
    return Picture(width: width, height: height, rgb: rgb)
}

/// Box-reduces a picture so its long edge is at most `edge`.
func reduced(_ picture: Picture, toLongEdge edge: Int) -> Picture {
    let factor = Int((Double(max(picture.width, picture.height)) / Double(edge)).rounded(.up))
    guard factor > 1 else { return picture }
    let width = picture.width / factor, height = picture.height / factor
    var rgb = [Float](repeating: 0, count: width * height * 3)
    let area = Float(factor * factor)
    for y in 0..<height {
        for x in 0..<width {
            for channel in 0..<3 {
                var sum: Float = 0
                for dy in 0..<factor {
                    for dx in 0..<factor {
                        sum += picture.rgb[((y * factor + dy) * picture.width + x * factor + dx) * 3
                            + channel]
                    }
                }
                rgb[(y * width + x) * 3 + channel] = sum / area
            }
        }
    }
    return Picture(width: width, height: height, rgb: rgb)
}

func develop(_ scene: Picture, onGPU gpu: Bool, stock: FilmStock, noGrain: Bool,
             exact: Bool) -> Picture {
    let (width, height) = (scene.width, scene.height)
    let count = width * height
    var options = FotufilmEngine.Options()
    if noGrain { options.grainScale = 0 }
    var invocation = FilmEngineInvocation(stock: stock, options: options, width: width, height: height)
    if exact { invocation.featureMask |= FilmEngineFeature.exactMath }
    let dimension = Int32(invocation.spectral.exposure.dimension)
    var interleaved = [Float](repeating: 1, count: count * 4)
    for index in 0..<count {
        for channel in 0..<3 {
            let value = scene.rgb[index * 3 + channel]
            interleaved[index * 4 + channel] = value.isFinite ? value : 0
        }
    }
    // Whole-frame measurements, as the renderers take them before developing.
    if invocation.featureMask & FilmEngineFeature.flare != 0 {
        interleaved.withUnsafeBufferPointer {
            invocation.flareMean = invocation.measuredAreaWeightedFlareMean(
                linearRGBA: $0.baseAddress!, width: width, height: height)
        }
    }
    if invocation.sceneMeteringActive {
        var measurement = invocation.toneBaseMeasurement()
        interleaved.withUnsafeBufferPointer {
            measurement.add(linearRGBA: $0.baseAddress!, rows: 0..<height)
        }
        invocation.setToneBase(measurement)
    }

    var rgb = [Float](repeating: 0, count: count * 3)
    var status: Int32 = -1
    if gpu {
        var output = [Float](repeating: 0, count: count * 4)
        invocation.configuration.withUnsafeBufferPointer { configuration in
            invocation.withSpectralPointers { exposure, film, paper in
                interleaved.withUnsafeBufferPointer { input in
                    output.withUnsafeMutableBufferPointer { result in
                        #if os(Linux)
                        guard fotufilm_halide_cuda_prepare(
                            invocation.featureMask, exposure, film, paper, dimension,
                            invocation.spectralCacheID) == 0 else { return }
                        status = fotufilm_halide_cuda_process_linear_float(
                            input.baseAddress, result.baseAddress, Int32(width), Int32(height),
                            0, 0, configuration.baseAddress, exposure, film, paper, dimension,
                            invocation.spectralCacheID, invocation.featureMask, invocation.seed)
                        #else
                        guard fotufilm_halide_metal_prepare(
                            invocation.featureMask, exposure, film, paper, dimension,
                            invocation.spectralCacheID) == 0 else { return }
                        status = fotufilm_halide_metal_process_linear_float(
                            input.baseAddress, result.baseAddress, Int32(width), Int32(height),
                            0, 0, configuration.baseAddress, exposure, film, paper, dimension,
                            invocation.spectralCacheID, invocation.featureMask, invocation.seed)
                        #endif
                    }
                }
            }
        }
        for index in 0..<count {
            for channel in 0..<3 { rgb[index * 3 + channel] = output[index * 4 + channel] }
        }
    } else {
        let plane = { (channel: Int) in (0..<count).map { interleaved[$0 * 4 + channel] } }
        let (inR, inG, inB) = (plane(0), plane(1), plane(2))
        var outR = [Float](repeating: 0, count: count)
        var outG = outR, outB = outR
        invocation.configuration.withUnsafeBufferPointer { configuration in
            invocation.withSpectralPointers { exposure, film, paper in
                status = fotufilm_halide_process(
                    inR, inG, inB, &outR, &outG, &outB,
                    Int32(width), Int32(height), configuration.baseAddress,
                    exposure, film, paper, dimension, invocation.featureMask, invocation.seed)
            }
        }
        let out = [outR, outG, outB]
        // The GPU float output ends in max(value, 0); the CPU's does not.
        for index in 0..<count {
            for channel in 0..<3 { rgb[index * 3 + channel] = max(out[channel][index], 0) }
        }
    }
    guard status == 0 else { fail("\(gpu ? "GPU" : "CPU") develop failed: \(status)") }
    return Picture(width: width, height: height, rgb: rgb)
}

/// Differences in output reflectance, and in 8-bit sRGB codes of the clipped reflectance: what a
/// saved picture would show.
func compare(_ reference: Picture, _ candidate: Picture) {
    guard reference.width == candidate.width, reference.height == candidate.height else {
        fail("sizes differ: \(reference.width)x\(reference.height) vs \(candidate.width)x\(candidate.height)")
    }
    func code(_ value: Float) -> Int {
        let v = min(max(value, 0), 1)
        let encoded = v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
        return Int((encoded * 255).rounded())
    }
    var differences = [Float]()
    differences.reserveCapacity(reference.rgb.count)
    var codes = [Int](repeating: 0, count: 256)
    var nonFinite = 0
    for index in 0..<reference.rgb.count {
        let a = reference.rgb[index], b = candidate.rgb[index]
        guard a.isFinite, b.isFinite else { nonFinite += 1; continue }
        differences.append(abs(a - b))
        codes[min(255, abs(code(a) - code(b)))] += 1
    }
    differences.sort()
    let quantile = { (p: Double) -> Float in
        differences[min(differences.count - 1, Int(Double(differences.count) * p))]
    }
    let mean = differences.reduce(0, +) / Float(max(differences.count, 1))
    let samples = differences.count
    let over1 = codes[2...].reduce(0, +)
    let maxCode = codes.lastIndex { $0 > 0 } ?? 0
    print(String(format: "reflectance: max %.6f  mean %.7f  p99 %.6f  p99.9 %.6f",
                 differences.last ?? 0, mean, quantile(0.99), quantile(0.999)))
    print(String(format: "8-bit sRGB:  max %d codes  identical %.3f%%  off by >1 %.4f%%  non-finite %d",
                 maxCode, 100 * Double(codes[0]) / Double(samples),
                 100 * Double(over1) / Double(samples), nonFinite))
}

if let _ = argument("--compare") {
    let paths = operands(after: "--compare", count: 2)
    compare(readPFM(paths[0]), readPFM(paths[1]))
    exit(0)
}

if argument("--chart") != nil {
    let path = operands(after: "--chart", count: 1)[0]
    let size = (argument("--size") ?? "1920x1080").lowercased().split(separator: "x").compactMap { Int($0) }
    guard size.count == 2 else { fail("--size wants WxH") }
    writePFM(chart(width: size[0], height: size[1]), to: path)
    exit(0)
}

if argument("--export-input") != nil {
    let paths = operands(after: "--export-input", count: 2)
    #if canImport(FotufilmImaging)
    let image: SceneImage
    do { image = try SceneImage.decode(url: URL(fileURLWithPath: paths[0])) } catch { fail("\(error)") }
    var rgb = [Float](repeating: 0, count: image.width * image.height * 3)
    for index in 0..<(image.width * image.height) {
        for channel in 0..<3 { rgb[index * 3 + channel] = image.rgba[index * 4 + channel] }
    }
    let edge = Int(argument("--max-edge") ?? "") ?? 2048
    let scene = reduced(Picture(width: image.width, height: image.height, rgb: rgb), toLongEdge: edge)
    writePFM(scene, to: paths[1])
    print("scene \(scene.width)x\(scene.height) -> \(paths[1])")
    exit(0)
    #else
    fail("--export-input decodes with the Mac's image decoder; export on a Mac")
    #endif
}

if argument("--develop") != nil {
    let paths = operands(after: "--develop", count: 2)
    let device = argument("--device") ?? "gpu"
    guard device == "cpu" || device == "gpu" else { fail("--device is cpu or gpu") }
    let stockID = argument("--stock") ?? "portra400"
    guard let stock = FilmStock.named(stockID) else {
        fail("no stock \(stockID): \(String(describing: FilmStockPack.loadError))")
    }
    let scene = readPFM(paths[0])
    let start = Date()
    let picture = develop(scene, onGPU: device == "gpu", stock: stock,
                          noGrain: CommandLine.arguments.contains("--no-grain"),
                          exact: CommandLine.arguments.contains("--exact"))
    writePFM(picture, to: paths[1])
    print(String(format: "%@ %@ %dx%d in %.2fs -> %@", device, stockID, scene.width, scene.height,
                 Date().timeIntervalSince(start), paths[1]))
    exit(0)
}

fail("usage: see the top of Sources/fotufilm-parity/main.swift")
