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
        guard pixels.count == width * height * 4, let model = options.transportConstruction(for: stock),
              TransportBackend.metal.isAvailable else { throw TransportError.backend("Metal transport unavailable") }
        var input = ImageBuffer(width: width, height: height)
        for c in 0..<3 { for i in 0..<input.pixelCount { input.planes[c][i] = pixels[4*i+c] } }
        let execution = TransportExecution(render: render, backend: .metal)
        let result = try LayeredTransportRenderer.process(image: input, stock: stock, options: options,
            model: model, frameIndex: frameIndex, execution: execution,
            invocation: invocation, pixelPitchMM: pixelPitchMM)
        var output = pixels
        for c in 0..<3 { for i in 0..<input.pixelCount { output[4*i+c] = result.planes[c][i] } }
        return output
    }

    private static func render(_ image: ImageBuffer, _ supplied: FilmEngineInvocation,
                               _ lightOnly: Bool) throws -> ImageBuffer {
        var invocation = supplied
        invocation.featureMask |= FilmEngineFeature.floatIO
        var input = Array(repeating: Float(1), count: image.pixelCount * 4)
        // A fourth plane is a donor stock's fourth record, read from the record input's alpha.
        for c in 0..<image.planes.count { for i in 0..<image.pixelCount { input[4*i+c] = image.planes[c][i] } }
        if invocation.featureMask & FilmEngineFeature.flare != 0 {
            input.withUnsafeBufferPointer {
                invocation.flareMean = invocation.measuredAreaWeightedFlareMean(
                    linearRGBA: $0.baseAddress!, width: image.width, height: image.height)
            }
        }
        // LIGHT_OUT produces a three-channel light grid. Transport clears the legacy
        // halation radii, so its grid has unit stride and retains every source pixel.
        // The ordinary float entry point promises RGBA and cannot receive this AOT variant.
        let channels = lightOnly ? 3 : 4
        var output = [Float](repeating: 0, count: image.pixelCount * channels)
        let status = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                invocation.configuration.withUnsafeBufferPointer { config in
                    invocation.withSpectralPointers { exposure, film, paper in
                        if lightOnly {
                            return fotufilm_halide_metal_process_light_grid(
                                source.baseAddress, destination.baseAddress,
                                Int32(image.width), Int32(image.height), 0, Int32(image.height),
                                0, 0, config.baseAddress, exposure, film, paper,
                                Int32(invocation.spectral.exposure.dimension),
                                invocation.spectralCacheID, invocation.featureMask, invocation.seed)
                        }
                        return fotufilm_halide_metal_process_linear_float(source.baseAddress, destination.baseAddress,
                            Int32(image.width), Int32(image.height), 0, 0, config.baseAddress,
                            exposure, film, paper, Int32(invocation.spectral.exposure.dimension),
                            invocation.spectralCacheID, invocation.featureMask, invocation.seed)
                    }
                }
            }
        }
        guard status == 0 else { throw TransportError.backend("Metal transport stage failed (\(status))") }
        var result = image
        for c in 0..<3 { for i in 0..<image.pixelCount { result.planes[c][i] = output[channels*i+c] } }
        return result
    }
}
