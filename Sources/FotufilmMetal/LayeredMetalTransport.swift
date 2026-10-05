import Foundation
import Metal
import FotufilmHalide
#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Layered Transport on Metal: scene preparation and development through the shipping AOT entry
/// points, and the transport through the Halide pipeline on Metal.
public enum LayeredMetalTransport {
    public static func process(_ pixels: [Float], width: Int, height: Int, stock: FilmStock,
                               options: FotufilmEngine.Options, frameIndex: UInt64 = 0,
                               invocation: FilmEngineInvocation? = nil, pixelPitchMM: Double? = nil) throws -> [Float] {
        var linear: FilmOutputTransform? = nil
        return try process(pixels, width: width, height: height, stock: stock, options: options,
                           frameIndex: frameIndex, invocation: invocation, pixelPitchMM: pixelPitchMM,
                           outputTransform: &linear)
    }

    /// The same, delivering `outputTransform`'s encoding from the development itself when the
    /// build carries it; otherwise `outputTransform` comes back nil and the result is linear.
    public static func process(_ pixels: [Float], width: Int, height: Int, stock: FilmStock,
                               options: FotufilmEngine.Options, frameIndex: UInt64 = 0,
                               invocation: FilmEngineInvocation? = nil, pixelPitchMM: Double? = nil,
                               outputTransform: inout FilmOutputTransform?) throws -> [Float] {
        guard pixels.count == width * height * 4, let model = options.transportConstruction(for: stock),
              TransportBackend.metal.isAvailable else { throw TransportError.backend("Metal transport unavailable") }
        let n = width * height
        let scene = TransportScene(rgba: pixels, width: width, height: height)
        // Heads rendered one at a time — a lens with flare or diffusion — expose the scene packed
        // opaque, as `render` packs it, through a light grid; both are made on the first such head.
        var opaque: [Float]?, grid = [Float]()
        let light = { (head: FilmEngineInvocation, destination: UnsafeMutablePointer<Float>) throws in
            if opaque == nil {
                var packed = pixels
                packed.withUnsafeMutableBufferPointer { packed in
                    rows(height) { range in
                        for i in range.lowerBound * width..<range.upperBound * width { packed[4 * i + 3] = 1 }
                    }
                }
                opaque = packed
                grid = [Float](repeating: 0, count: n * 3)
            }
            try lightGrid(opaque!, width: width, height: height, head, into: &grid)
            grid.withUnsafeBufferPointer { grid in
                rows(height) { range in
                    for i in range.lowerBound * width..<range.upperBound * width {
                        for c in 0..<3 { destination[c * n + i] = grid[3 * i + c] }
                    }
                }
            }
        }
        let execution = TransportExecution(render: render, backend: .metal, light: light)
        guard options.stage != .texture else {
            outputTransform = nil
            var result = try LayeredTransportRenderer.process(image: scene.image, stock: stock,
                options: options, model: model, frameIndex: frameIndex, execution: execution,
                invocation: invocation, pixelPitchMM: pixelPitchMM)
            var output = pixels
            output.withUnsafeMutableBufferPointer { output in
                withPlanes(&result.planes) { planes in
                    rows(height) { range in
                        for i in range.lowerBound * width..<range.upperBound * width {
                            for c in 0..<3 { output[4 * i + c] = planes[c][i] }
                        }
                    }
                }
            }
            return output
        }
        // The records develop as the develop reads them, interleaved, a donor stock's fourth in
        // the alpha (opaque otherwise); the scene's alpha is laid back over the developed frame.
        // The sum is let go before the development takes room of its own.
        var records = pixels
        var continuation: FilmEngineInvocation
        do {
            let exposed = try LayeredTransportRenderer.expose(scene: scene, stock: stock,
                options: options, model: model, frameIndex: frameIndex, execution: execution,
                invocation: invocation, pixelPitchMM: pixelPitchMM)
            exposed.sum.withUnsafeBufferPointer { sum in
                records.withUnsafeMutableBufferPointer { records in
                    rows(height) { range in
                        for i in range.lowerBound * width..<range.upperBound * width {
                            for c in 0..<exposed.channels { records[4 * i + c] = sum[c * n + i] }
                            if exposed.channels == 3 { records[4 * i + 3] = 1 }
                        }
                    }
                }
            }
            continuation = exposed.continuation
        }
        if let transform = outputTransform, encodes(continuation.featureMask) {
            continuation.featureMask |= FilmEngineFeature.encodeOut
            continuation.setOutputTransform(transform)
        } else {
            outputTransform = nil
        }
        var output = try develop(records, width: width, height: height, continuation)
        pixels.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { output in
                rows(height) { range in
                    for i in range.lowerBound * width..<range.upperBound * width {
                        output[4 * i + 3] = source[4 * i + 3]
                    }
                }
            }
        }
        return output
    }

    /// The scene's light under a head invocation, as the three-channel grid LIGHT_OUT produces.
    /// Transport clears the legacy halation radii, so the grid has unit stride and retains every
    /// source pixel. The ordinary float entry point promises RGBA and cannot receive this variant.
    private static func lightGrid(_ scene: [Float], width: Int, height: Int,
                                  _ supplied: FilmEngineInvocation, into output: inout [Float]) throws {
        var invocation = supplied
        invocation.featureMask |= FilmEngineFeature.floatIO
        let status = scene.withUnsafeBufferPointer { source in
            if invocation.featureMask & FilmEngineFeature.flare != 0 {
                invocation.flareMean = invocation.measuredAreaWeightedFlareMean(
                    linearRGBA: source.baseAddress!, width: width, height: height)
            }
            return output.withUnsafeMutableBufferPointer { destination in
                invocation.configuration.withUnsafeBufferPointer { config in
                    invocation.withSpectralPointers { exposure, film, paper in
                        fotufilm_halide_metal_process_light_grid(
                            source.baseAddress, destination.baseAddress,
                            Int32(width), Int32(height), 0, Int32(height),
                            0, 0, config.baseAddress, exposure, film, paper,
                            Int32(invocation.spectral.exposure.dimension),
                            invocation.spectralCacheID, invocation.featureMask, invocation.seed)
                    }
                }
            }
        }
        guard status == 0 else { throw TransportError.backend("Metal transport stage failed (\(status))") }
    }

    private static func render(_ image: ImageBuffer, _ supplied: FilmEngineInvocation,
                               _ lightOnly: Bool) throws -> ImageBuffer {
        let width = image.width, height = image.height, n = image.pixelCount
        var input = Array(repeating: Float(1), count: n * 4)
        // A fourth plane is a donor stock's fourth record, read from the record input's alpha.
        let carried = image.planes.count
        input.withUnsafeMutableBufferPointer { input in
            reading(image.planes[...]) { planes in
                rows(height) { range in
                    for i in range.lowerBound * width..<range.upperBound * width {
                        for c in 0..<carried { input[4 * i + c] = planes[c][i] }
                    }
                }
            }
        }
        var result = ImageBuffer(width: width, height: height)
        if lightOnly {
            var grid = [Float](repeating: 0, count: n * 3)
            try lightGrid(input, width: width, height: height, supplied, into: &grid)
            unpack(grid, channels: 3, into: &result)
            return result
        }
        unpack(try develop(input, width: width, height: height, supplied), channels: 4, into: &result)
        return result
    }

    /// Whether the build develops a Layered frame's records under `mask` with its encoding.
    public static func encodes(_ mask: Int32) -> Bool {
        fotufilm_halide_metal_variant_exists(
            mask | FilmEngineFeature.floatIO | FilmEngineFeature.encodeOut) == 1
    }

    /// The float develop of interleaved RGBA under an invocation.
    private static func develop(_ input: [Float], width: Int, height: Int,
                                _ supplied: FilmEngineInvocation) throws -> [Float] {
        var invocation = supplied
        invocation.featureMask |= FilmEngineFeature.floatIO
        if invocation.featureMask & FilmEngineFeature.flare != 0 {
            input.withUnsafeBufferPointer {
                invocation.flareMean = invocation.measuredAreaWeightedFlareMean(
                    linearRGBA: $0.baseAddress!, width: width, height: height)
            }
        }
        var output = [Float](repeating: 0, count: width * height * 4)
        let status = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                invocation.configuration.withUnsafeBufferPointer { config in
                    invocation.withSpectralPointers { exposure, film, paper in
                        fotufilm_halide_metal_process_linear_float(source.baseAddress, destination.baseAddress,
                            Int32(width), Int32(height), 0, 0, config.baseAddress,
                            exposure, film, paper, Int32(invocation.spectral.exposure.dimension),
                            invocation.spectralCacheID, invocation.featureMask, invocation.seed)
                    }
                }
            }
        }
        guard status == 0 else { throw TransportError.backend("Metal transport stage failed (\(status))") }
        return output
    }

    private static func unpack(_ interleaved: [Float], channels: Int, into image: inout ImageBuffer) {
        let width = image.width
        interleaved.withUnsafeBufferPointer { source in
            withPlanes(&image.planes) { planes in
                rows(image.height) { range in
                    for i in range.lowerBound * width..<range.upperBound * width {
                        for c in 0..<3 { planes[c][i] = source[channels * i + c] }
                    }
                }
            }
        }
    }

    /// The first three planes' storage, writable from several threads at once.
    private static func withPlanes(_ planes: inout [[Float]],
                                   _ body: ([UnsafeMutablePointer<Float>]) -> Void) {
        // Swapped out so each plane is borrowed alone, without a copy.
        var r = [Float](), g = [Float](), b = [Float]()
        swap(&r, &planes[0]); swap(&g, &planes[1]); swap(&b, &planes[2])
        defer { swap(&r, &planes[0]); swap(&g, &planes[1]); swap(&b, &planes[2]) }
        r.withUnsafeMutableBufferPointer { r in
            g.withUnsafeMutableBufferPointer { g in
                b.withUnsafeMutableBufferPointer { b in
                    body([r.baseAddress!, g.baseAddress!, b.baseAddress!])
                }
            }
        }
    }

    /// Every plane's storage, read from several threads at once.
    private static func reading(_ planes: ArraySlice<[Float]>, _ gathered: [UnsafePointer<Float>] = [],
                                _ body: ([UnsafePointer<Float>]) -> Void) {
        guard let first = planes.first else { return body(gathered) }
        first.withUnsafeBufferPointer { reading(planes.dropFirst(), gathered + [$0.baseAddress!], body) }
    }

    /// Runs `body` over bands of rows in parallel.
    private static func rows(_ height: Int, _ body: (Range<Int>) -> Void) {
        let bands = min(height, 64)
        DispatchQueue.concurrentPerform(iterations: bands) { band in
            body(band * height / bands..<(band + 1) * height / bands)
        }
    }
}
