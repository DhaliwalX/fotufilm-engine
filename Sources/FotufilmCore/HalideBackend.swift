import Foundation

#if canImport(FotufilmHalide)
import FotufilmHalide
#else
@_silgen_name("fotufilm_halide_available")
private func fotufilm_halide_available() -> Int32
@_silgen_name("fotufilm_halide_develop")
private func fotufilm_halide_develop(
    _ inputR: UnsafePointer<Float>?, _ inputG: UnsafePointer<Float>?,
    _ inputB: UnsafePointer<Float>?,
    _ outputR: UnsafeMutablePointer<Float>?, _ outputG: UnsafeMutablePointer<Float>?,
    _ outputB: UnsafeMutablePointer<Float>?,
    _ width: Int32, _ height: Int32,
    _ configuration: UnsafePointer<Float>?,
    _ exposureLUT: UnsafePointer<Float>?, _ lutDimension: Int32,
    _ featureMask: Int32, _ seed: UInt32
) -> Int32
@_silgen_name("fotufilm_halide_print")
private func fotufilm_halide_print(
    _ inputR: UnsafePointer<Float>?, _ inputG: UnsafePointer<Float>?,
    _ inputB: UnsafePointer<Float>?,
    _ outputR: UnsafeMutablePointer<Float>?, _ outputG: UnsafeMutablePointer<Float>?,
    _ outputB: UnsafeMutablePointer<Float>?,
    _ width: Int32, _ height: Int32,
    _ configuration: UnsafePointer<Float>?,
    _ filmLUT: UnsafePointer<Float>?, _ paperLUT: UnsafePointer<Float>?,
    _ lutDimension: Int32, _ featureMask: Int32
) -> Int32
@_silgen_name("fotufilm_halide_process")
private func fotufilm_halide_process(
    _ inputR: UnsafePointer<Float>?, _ inputG: UnsafePointer<Float>?,
    _ inputB: UnsafePointer<Float>?,
    _ outputR: UnsafeMutablePointer<Float>?, _ outputG: UnsafeMutablePointer<Float>?,
    _ outputB: UnsafeMutablePointer<Float>?,
    _ width: Int32, _ height: Int32,
    _ configuration: UnsafePointer<Float>?,
    _ exposureLUT: UnsafePointer<Float>?, _ filmLUT: UnsafePointer<Float>?,
    _ paperLUT: UnsafePointer<Float>?, _ lutDimension: Int32,
    _ featureMask: Int32, _ seed: UInt32
) -> Int32
@_silgen_name("fotufilm_halide_process_strip")
private func fotufilm_halide_process_strip(
    _ inputR: UnsafePointer<Float>?, _ inputG: UnsafePointer<Float>?,
    _ inputB: UnsafePointer<Float>?,
    _ outputR: UnsafeMutablePointer<Float>?, _ outputG: UnsafeMutablePointer<Float>?,
    _ outputB: UnsafeMutablePointer<Float>?,
    _ width: Int32, _ height: Int32,
    _ outputWidth: Int32, _ outputHeight: Int32,
    _ originX: Int32, _ originY: Int32,
    _ interiorTop: Int32, _ interiorHeight: Int32,
    _ configuration: UnsafePointer<Float>?,
    _ exposureLUT: UnsafePointer<Float>?, _ filmLUT: UnsafePointer<Float>?,
    _ paperLUT: UnsafePointer<Float>?, _ lutDimension: Int32,
    _ featureMask: Int32, _ seed: UInt32
) -> Int32
@_silgen_name("fotufilm_halide_gaussian")
private func fotufilm_halide_gaussian(
    _ input: UnsafePointer<Float>?, _ output: UnsafeMutablePointer<Float>?,
    _ width: Int32, _ height: Int32, _ sigma: Float, _ radius: Int32
) -> Int32
@_silgen_name("fotufilm_halide_approximate_gaussian")
private func fotufilm_halide_approximate_gaussian(
    _ input: UnsafePointer<Float>?, _ output: UnsafeMutablePointer<Float>?,
    _ width: Int32, _ height: Int32, _ radius: Int32
) -> Int32
#endif

/// Swift-to-C bridge for the Halide CPU engine — the still-image half of the processing core.
enum HalideBackend {
    static var isAvailable: Bool { fotufilm_halide_available() == 1 }

    /// Stages 1-7: scene-linear RGB in, developed per-layer density out.
    static func develop(image: ImageBuffer, stock: FilmStock,
                        options: FotufilmEngine.Options) -> ImageBuffer? {
        run(image, stock: stock, options: options, measuresScene: true) {
            inputR, inputG, inputB, outputR, outputG, outputB,
            width, height, invocation, configuration in
            invocation.withSpectralPointers { exposure, _, _ in
                fotufilm_halide_develop(
                    inputR, inputG, inputB, outputR, outputG, outputB,
                    width, height, configuration,
                    exposure, Int32(invocation.spectral.exposure.dimension),
                    invocation.featureMask, invocation.seed)
            }
        }
    }

    /// Stage 8: developed density in, display-linear RGB out — or, when `outputTransform` names
    /// one, the host's own space out, the delivery taken in the kernel rather than by a caller
    /// walking the finished frame. The same step the fused GPU pipeline takes, from the same
    /// expression, so the two roads cannot deliver different frames.
    static func print(density: ImageBuffer, stock: FilmStock,
                      options: FotufilmEngine.Options,
                      outputTransform: FilmOutputTransform? = nil) -> ImageBuffer? {
        run(density, stock: stock, options: options,
            outputTransform: outputTransform) {
            inputR, inputG, inputB, outputR, outputG, outputB,
            width, height, invocation, configuration in
            invocation.withSpectralPointers { _, film, paper in
                fotufilm_halide_print(
                    inputR, inputG, inputB, outputR, outputG, outputB,
                    width, height, configuration, film, paper,
                    Int32(invocation.spectral.filmOutput.dimension),
                    invocation.featureMask)
            }
        }
    }

    /// Both halves in one call, so the developed density stays inside the engine instead of being
    /// copied out into Swift planes and straight back in again.
    ///
    /// `noFilm` develops with nothing in the gate — the creative controls, the delivery basis and
    /// the grade — which is `PlainDevelop` expressed as a kernel. It still names a stock, because
    /// the configuration is built from one, but no slot the stock filled is read.
    static func process(image: ImageBuffer, stock: FilmStock,
                        options: FotufilmEngine.Options,
                        memoryBudget: Int = defaultMemoryBudget,
                        noFilm: Bool = false,
                        outputTransform: FilmOutputTransform? = nil) -> ImageBuffer? {
        guard isAvailable else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return ImageBuffer(width: width, height: height) }
        var invocation = FilmEngineInvocation(
            stock: stock, options: options, width: width, height: height,
            noFilm: noFilm)
        if let outputTransform {
            invocation.featureMask |= FilmEngineFeature.encodeOut
            switch outputTransform.transfer {
            case .linear: invocation.featureMask |= FilmEngineFeature.outputLinear
            case .powerLaw: invocation.featureMask |= FilmEngineFeature.outputPower
            case .logarithmic: invocation.featureMask |= FilmEngineFeature.outputLog
            }
            invocation.setOutputTransform(outputTransform)
        }
        if invocation.localToneActive {
            withPlanarPointers(image.planes) { red, green, blue in
                invocation.measureToneBase(planarR: red!, g: green!, b: blue!,
                                           width: width, height: height)
            }
        }

        let apron = max(1, invocation.spatialSupport)
        let rows = stripRows(width: width, height: height, apron: apron,
                             budget: memoryBudget)
        if rows < height, invocation.featureMask & FilmEngineFeature.flare != 0 {
            invocation.flareMean = measuredGlare(image: image, invocation: invocation)
        }

        let count = width * height
        var red = [Float](repeating: 0, count: count)
        var green = [Float](repeating: 0, count: count)
        var blue = [Float](repeating: 0, count: count)
        let status = withPlanarPointers(image.planes) { inputR, inputG, inputB in
            red.withUnsafeMutableBufferPointer { outputR in
                green.withUnsafeMutableBufferPointer { outputG in
                    blue.withUnsafeMutableBufferPointer { outputB in
                        invocation.configuration.withUnsafeBufferPointer { configuration in
                            invocation.withSpectralPointers { exposure, film, paper in
                                var result: Int32 = 0
                                var top = 0
                                while top < height && result == 0 {
                                    let bottom = min(height, top + rows)
                                    let from = max(0, top - apron)
                                    let to = min(height, bottom + apron)
                                    let offset = from * width
                                    result = fotufilm_halide_process_strip(
                                        inputR! + offset, inputG! + offset,
                                        inputB! + offset,
                                        outputR.baseAddress, outputG.baseAddress,
                                        outputB.baseAddress,
                                        Int32(width), Int32(to - from),
                                        Int32(width), Int32(height),
                                        0, Int32(from),
                                        Int32(top - from), Int32(bottom - top),
                                        configuration.baseAddress,
                                        exposure, film, paper,
                                        Int32(invocation.spectral.exposure.dimension),
                                        invocation.featureMask, invocation.seed)
                                    top = bottom
                                }
                                return result
                            }
                        }
                    }
                }
            }
        }
        guard status == 0 else { return nil }
        return ImageBuffer(width: width, height: height, planes: [red, green, blue])
    }

    /// Whole-frame veiling-glare mean, measured a row at a time so the answer does not depend on
    /// how the frame is later cut up.
    private static func measuredGlare(
        image: ImageBuffer, invocation: FilmEngineInvocation
    ) -> SIMD3<Float> {
        let width = image.width, height = image.height
        var rowSums = [SIMD3<Double>](repeating: .zero, count: height)
        withPlanarPointers(image.planes) { red, green, blue in
            rowSums.withUnsafeMutableBufferPointer { sums in
                invocation.flareExposureRowSums(
                    planarR: red!, g: green!, b: blue!, width: width,
                    rows: height, into: sums)
            }
        }
        var total = SIMD3<Double>.zero
        for row in rowSums { total += row }
        let mean = total / Double(width * height)
        return SIMD3(Float(mean.x), Float(mean.y), Float(mean.z))
    }

    /// What the engine's own intermediates may use, over and above the
    /// caller's frame-sized input and output.
    static let defaultMemoryBudget = 192 << 20

    /// Peak live intermediate bytes per pixel handed to the engine, across
    /// the fused develop-and-print pipeline.
    static let processBytesPerPixel = 64

    /// Rows of finished output per strip.
    static func stripRows(width: Int, height: Int, apron: Int, budget: Int) -> Int {
        let perRow = max(width * processBytesPerPixel, 1)
        let usable = budget / perRow - 2 * apron
        if usable >= max(minimumStripRows, apron) { return min(height, usable) }
        // Below that the smallest strip is the *worst* choice, not the safest one. A strip
        // carries an apron of `apron` rows on each side, so it computes `rows + 2 * apron` to
        // deliver `rows`: once the apron is the larger of the two, cutting the frame up
        // multiplies the work without saving anything. It does not even save memory — the
        // resident window is `rows + 2 * apron`, which for a 64-row strip behind a 577-row
        // apron is larger than the whole 1080-row frame it was trying to avoid holding.
        //
        // Measured, on a frame carrying a lens diffusion filter's halo: 64-row strips at 1080p
        // computed 13.75x the frame and at 4K 27x, which is exactly the slowdown the stage
        // appeared to have until this was the thing that had it.
        return height
    }

    /// Interior rows in the smallest strip the engine will cut.
    static let minimumStripRows = 64

    /// Lends the input planes and a freshly allocated set of output planes to
    /// one of the C entry points.
    private static func run(
        _ image: ImageBuffer, stock: FilmStock, options: FotufilmEngine.Options,
        measuresScene: Bool = false,
        outputTransform: FilmOutputTransform? = nil,
        _ body: (
            UnsafePointer<Float>?, UnsafePointer<Float>?, UnsafePointer<Float>?,
            UnsafeMutablePointer<Float>?, UnsafeMutablePointer<Float>?,
            UnsafeMutablePointer<Float>?, Int32, Int32,
            FilmEngineInvocation, UnsafePointer<Float>?
        ) -> Int32
    ) -> ImageBuffer? {
        guard isAvailable else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return ImageBuffer(width: width, height: height) }
        var invocation = FilmEngineInvocation(
            stock: stock, options: options, width: width, height: height)
        if let outputTransform {
            // This road JITs and caches its pipelines, so naming the shape costs a cache slot
            // rather than a shipped variant: it is always worth compiling the one transcendental
            // the delivery uses instead of selecting among three per pixel.
            invocation.featureMask |= FilmEngineFeature.encodeOut
            switch outputTransform.transfer {
            case .linear: invocation.featureMask |= FilmEngineFeature.outputLinear
            case .powerLaw: invocation.featureMask |= FilmEngineFeature.outputPower
            case .logarithmic: invocation.featureMask |= FilmEngineFeature.outputLog
            }
            invocation.setOutputTransform(outputTransform)
        }
        if measuresScene, invocation.localToneActive {
            withPlanarPointers(image.planes) { red, green, blue in
                invocation.measureToneBase(planarR: red!, g: green!, b: blue!,
                                           width: width, height: height)
            }
        }
        let count = width * height
        var red = [Float](repeating: 0, count: count)
        var green = [Float](repeating: 0, count: count)
        var blue = [Float](repeating: 0, count: count)
        let status = withPlanarPointers(image.planes) { inputR, inputG, inputB in
            red.withUnsafeMutableBufferPointer { outputR in
                green.withUnsafeMutableBufferPointer { outputG in
                    blue.withUnsafeMutableBufferPointer { outputB in
                        invocation.configuration.withUnsafeBufferPointer { configuration in
                            body(inputR, inputG, inputB,
                                 outputR.baseAddress, outputG.baseAddress,
                                 outputB.baseAddress, Int32(width), Int32(height),
                                 invocation, configuration.baseAddress)
                        }
                    }
                }
            }
        }
        guard status == 0 else { return nil }
        return ImageBuffer(width: width, height: height, planes: [red, green, blue])
    }

    static func gaussian(_ plane: [Float], width: Int, height: Int,
                         sigma: Float, radius: Int) -> [Float]? {
        guard isAvailable else { return nil }
        var output = [Float](repeating: 0, count: plane.count)
        let status = plane.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { output in
                fotufilm_halide_gaussian(input.baseAddress, output.baseAddress,
                                        Int32(width), Int32(height), sigma, Int32(radius))
            }
        }
        return status == 0 ? output : nil
    }

    static func approximateGaussian(_ plane: [Float], width: Int, height: Int,
                                    radius: Int) -> [Float]? {
        guard isAvailable else { return nil }
        var output = [Float](repeating: 0, count: plane.count)
        let status = plane.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { output in
                fotufilm_halide_approximate_gaussian(
                    input.baseAddress, output.baseAddress,
                    Int32(width), Int32(height), Int32(radius))
            }
        }
        return status == 0 ? output : nil
    }

    private static func withPlanarPointers<Result>(
        _ planes: [[Float]],
        _ body: (UnsafePointer<Float>?, UnsafePointer<Float>?, UnsafePointer<Float>?) -> Result
    ) -> Result {
        planes[0].withUnsafeBufferPointer { r in
            planes[1].withUnsafeBufferPointer { g in
                planes[2].withUnsafeBufferPointer { b in
                    body(r.baseAddress, g.baseAddress, b.baseAddress)
                }
            }
        }
    }

}
