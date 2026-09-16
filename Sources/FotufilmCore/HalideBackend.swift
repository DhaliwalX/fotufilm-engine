import Foundation

import FotufilmHalide

/// Swift-to-C bridge for the Halide CPU engine — the still-image half of the processing core.
enum HalideBackend {
    static var isAvailable: Bool { fotufilm_halide_available() == 1 }

    /// Stages 1-7: scene-linear RGB in, developed per-layer density out.
    static func develop(image: ImageBuffer, stock: FilmStock,
                        options: FotufilmEngine.Options) throws -> ImageBuffer? {
        try run(image, stock: stock, options: options, measuresScene: true) {
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
                      outputTransform: FilmOutputTransform? = nil) throws -> ImageBuffer? {
        try run(density, stock: stock, options: options,
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
                        outputTransform: FilmOutputTransform? = nil) throws -> ImageBuffer? {
        try image.validate()
        let width = image.width, height = image.height
        guard width > 0, height > 0 else {
            return isAvailable ? ImageBuffer(width: width, height: height) : nil
        }
        var invocation = try FilmEngineInvocation(
            validating: stock, options: options, width: width, height: height,
            noFilm: noFilm)
        guard isAvailable else { return nil }
        if let outputTransform {
            invocation.featureMask |= FilmEngineFeature.encodeOut
            switch outputTransform.transfer {
            case .linear: invocation.featureMask |= FilmEngineFeature.outputLinear
            case .powerLaw: invocation.featureMask |= FilmEngineFeature.outputPower
            case .logarithmic: invocation.featureMask |= FilmEngineFeature.outputLog
            }
            invocation.setOutputTransform(outputTransform)
        }
        if invocation.sceneMeteringActive {
            withPlanarPointers(image.planes) { red, green, blue in
                invocation.measureToneBase(planarR: red!, g: green!, b: blue!,
                                           width: width, height: height)
            }
        }

        let apron = max(1, invocation.spatialSupport)
        let tile = try tileSize(width: width, height: height, apron: apron,
                                budget: memoryBudget)
        if (tile.width < width || tile.height < height),
           invocation.featureMask & FilmEngineFeature.flare != 0 {
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
                                    let bottom = min(height, top + tile.height)
                                    let from = max(0, top - apron)
                                    let to = min(height, bottom + apron)
                                    var left = 0
                                    while left < width && result == 0 {
                                        let right = min(width, left + tile.width)
                                        let start = max(0, left - apron)
                                        let end = min(width, right + apron)
                                        func render(_ r: UnsafePointer<Float>, _ g: UnsafePointer<Float>,
                                                    _ b: UnsafePointer<Float>) -> Int32 {
                                            fotufilm_halide_process_tile(
                                                r, g, b, outputR.baseAddress, outputG.baseAddress,
                                                outputB.baseAddress, Int32(end - start), Int32(to - from),
                                                Int32(width), Int32(height), Int32(start), Int32(from),
                                                Int32(left - start), Int32(top - from),
                                                Int32(right - left), Int32(bottom - top),
                                                configuration.baseAddress, exposure, film, paper,
                                                Int32(invocation.spectral.exposure.dimension),
                                                invocation.featureMask, invocation.seed)
                                        }
                                        if start == 0 && end == width {
                                            let offset = from * width
                                            result = render(inputR! + offset, inputG! + offset, inputB! + offset)
                                        } else {
                                            // The C bridge takes contiguous planes. Include these three
                                            // bounded copies in the tile's intermediate-memory estimate.
                                            let tileWidth = end - start
                                            let tileCount = tileWidth * (to - from)
                                            let storage = UnsafeMutablePointer<Float>.allocate(capacity: tileCount * 3)
                                            defer { storage.deallocate() }
                                            for (channel, source) in [inputR!, inputG!, inputB!].enumerated() {
                                                for row in from..<to {
                                                    (storage + channel * tileCount + (row - from) * tileWidth)
                                                        .initialize(from: source + row * width + start, count: tileWidth)
                                                }
                                            }
                                            result = render(storage, storage + tileCount, storage + 2 * tileCount)
                                        }
                                        left = right
                                    }
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

    /// Rows of finished output per strip, or zero if even one interior row cannot fit.
    static func stripRows(width: Int, height: Int, apron: Int, budget: Int) -> Int {
        let perRow = max(width * processBytesPerPixel, 1)
        if height <= budget / perRow { return height }
        return max(0, min(height, budget / perRow - 2 * apron))
    }

    /// Prefer strips that do useful work beyond their blur overlap. Otherwise split both axes,
    /// preserving the complete spatial support instead of silently raising the memory budget.
    static func tileSize(width: Int, height: Int, apron: Int, budget: Int) throws
        -> (width: Int, height: Int) {
        guard width > 0, height > 0, apron >= 0, budget > 0 else {
            throw TransportError.invalid("render dimensions and memory budget must be positive")
        }
        let rows = stripRows(width: width, height: height, apron: apron, budget: budget)
        if rows == height || rows >= max(64, apron) { return (width, rows) }

        let pixels = budget / (processBytesPerPixel + 3 * MemoryLayout<Float>.stride)
        let minimumWidth = min(width, 2 * apron + 1)
        let minimumHeight = min(height, 2 * apron + 1)
        guard pixels / minimumWidth >= minimumHeight else {
            // A narrow strip may still fit because it borrows the caller's input without copies.
            if rows > 0 { return (width, rows) }
            throw TransportError.backend("CPU render memory budget is too small for the image's spatial support")
        }
        var paddedHeight = min(height, max(minimumHeight, Int(Double(pixels).squareRoot())))
        let paddedWidth = min(width, max(minimumWidth, pixels / paddedHeight))
        paddedHeight = min(height, pixels / paddedWidth)
        return (paddedWidth == width ? width : paddedWidth - 2 * apron,
                paddedHeight == height ? height : paddedHeight - 2 * apron)
    }

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
    ) throws -> ImageBuffer? {
        try image.validate()
        let width = image.width, height = image.height
        guard width > 0, height > 0 else {
            return isAvailable ? ImageBuffer(width: width, height: height) : nil
        }
        var invocation = try FilmEngineInvocation(
            validating: stock, options: options, width: width, height: height)
        guard isAvailable else { return nil }
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
        if measuresScene, invocation.sceneMeteringActive {
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
