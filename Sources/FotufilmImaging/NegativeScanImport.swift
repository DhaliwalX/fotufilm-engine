import Foundation
#if canImport(CoreImage)
import CoreImage
import ImageIO
#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// An approximate, colour-managed importer. It deliberately does not claim to recover
/// sensor-channel measurements or a calibrated film dye basis from arbitrary image files.
public enum NegativeScanImport {
    public enum Failure: LocalizedError {
        case unreadable, noProfile, invalidBorder, conversion
        public var errorDescription: String? {
            switch self {
            case .unreadable: return "This negative could not be decoded. Try an unadjusted TIFF or a supported camera RAW file."
            case .noProfile: return "This image has no colour profile. Choose Linear Samples only if the scan was saved with a linear transfer curve."
            case .invalidBorder: return "Sample a larger area of clear, unexposed film. Avoid the holder, sprocket holes, lettering and image detail."
            case .conversion: return "The positive could not be rendered."
            }
        }
    }

    public static let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    /// Where a film reading takes its samples: wide enough that no real scan's dense dyes fall
    /// outside it and read as negative light.
    public static let filmSpace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!

    public static func decode(data: Data, identifierHint: String? = nil, linearSamples: Bool = false) throws -> CIImage {
        if RawDecode.isRaw(data: data, identifierHint: identifierHint) {
            guard let filter = scanFilter(data: data, identifierHint: identifierHint),
                  let image = filter.outputImage else { throw Failure.unreadable }
            return atOrigin(image)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure.unreadable }
        guard linearSamples || cg.colorSpace != nil else { throw Failure.noProfile }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
        let image = CIImage(cgImage: cg, options: linearSamples ? [.colorSpace: linearSpace] : [:])
        return atOrigin(image.oriented(forExifOrientation: orientation))
    }

    /// A camera RAW's filter as a scan is decoded: on the white the camera recorded, every
    /// rendering choice off.
    static func scanFilter(data: Data, identifierHint: String?) -> CIRAWFilter? {
        guard let filter = RawDecode.filter(data: data, identifierHint: identifierHint)
        else { return nil }
        RawDecode.configure(filter, recipe: .init(correctsLens: false,
            extendedDynamicRangeAmount: 0, recoversHighlights: false))
        filter.exposure = 0
        filter.baselineExposure = 0
        filter.shadowBias = 0
        filter.boostShadowAmount = 0
        if filter.isLuminanceNoiseReductionSupported { filter.luminanceNoiseReductionAmount = 0 }
        if filter.isColorNoiseReductionSupported { filter.colorNoiseReductionAmount = 0 }
        return filter
    }

    /// What `data` says of how its scan was made and how `decode` decodes it: the camera the
    /// file names and, of a camera RAW, the white it is decoded on and the matrix its channels
    /// are mixed with. The matrix is looked for only where a reading would take it, of a camera
    /// whose channels are measured (`NegativeScanSource.setup`), and where a decode can show it,
    /// which a DNG's cannot.
    public static func source(data: Data, identifierHint: String? = nil) -> NegativeScanSource {
        var source = NegativeScanSource(
            camera: RawDecode.cameraIdentity(data: data, identifierHint: identifierHint))
        guard RawDecode.isRaw(data: data, identifierHint: identifierHint),
              let filter = scanFilter(data: data, identifierHint: identifierHint)
        else { return source }
        let kelvin = filter.neutralTemperature
        if kelvin.isFinite, kelvin > 0 { source.kelvin = kelvin }
        let white = filter.neutralChromaticity
        if white.x > 0, white.y > 0, white.x + white.y < 1 {
            source.white = [Float(white.x), Float(white.y)]
        }
        if let camera = source.camera, CameraSpectralProfileStore.resolve(camera) != nil,
           !isDNG(data: data, identifierHint: identifierHint) {
            // A decoder mixes one camera's channels one way on one white, and a roll's frames
            // are mostly scanned on the same: the matrix found for one serves the rest.
            let key = "\(camera.make ?? "")|\(camera.model ?? "")|\(kelvin)|\(white.x)|\(white.y)"
            source.matrix = DecoderMatrices.shared.matrix(key) {
                decoderMatrix(data: data, identifierHint: identifierHint)?
                    .flatMap { [$0.x, $0.y, $0.z] }
            }
        }
        return source
    }

    /// Decoder matrices found in this process, by camera and white. One that was not found is
    /// looked for again: another frame of the roll may show it.
    final class DecoderMatrices: @unchecked Sendable {
        static let shared = DecoderMatrices()
        private let lock = NSLock()
        private var found: [String: [Float]] = [:]

        func matrix(_ key: String, find: () -> [Float]?) -> [Float]? {
            lock.lock()
            let known = found[key]
            lock.unlock()
            if let known { return known }
            guard let matrix = find() else { return nil }
            lock.lock()
            if found.count >= 64 { found.removeAll() }
            found[key] = matrix
            lock.unlock()
            return matrix
        }
    }

    /// Whether a raw file is a DNG, whose white the decoder adapts after the file's own matrix:
    /// no decode of it shows how the camera's channels were mixed.
    private static func isDNG(data: Data, identifierHint: String?) -> Bool {
        let dng = "com.adobe.raw-image"
        let sniffed = CGImageSourceCreateWithData(data as CFData, nil)
            .flatMap { CGImageSourceGetType($0) as String? }
        return sniffed == dng || identifierHint == dng
    }

    /// The long edge the decodes that show the decoder's matrix are asked for at.
    static let matrixProbeLongEdge = 128
    /// How far those decodes' tints are moved either way, in the decoder's own tint units: far
    /// enough to tell apart the red and blue of a camera whose balances a tint moves much alike.
    static let matrixProbeTint: Float = 80

    /// The matrix `decode` mixes a camera RAW's balanced channels into the film space with,
    /// rows the scan's red, green and blue. The decoder does not say it, so it is found from
    /// small decodes of the file on its own white and on two others of the same colour
    /// temperature, one greener and one pinker (`NegativeScanDecoderMatrix`). Nil where they do
    /// not show one matrix: a DNG's, whose white is adapted after its matrix.
    static func decoderMatrix(data: Data, identifierHint: String? = nil) -> [SIMD3<Float>]? {
        let context = CIContext(options: [.workingColorSpace: linearSpace,
                                          .cacheIntermediates: false])
        func pixels(tint: Float) -> [SIMD3<Float>]? {
            guard let filter = scanFilter(data: data, identifierHint: identifierHint)
            else { return nil }
            filter.scaleFactor = RawDecode.scaleFactor(for: filter,
                                                       targetLongEdge: matrixProbeLongEdge)
            if tint != 0 {
                // The temperature is set back: it turns the decoder's matrix, a tint does not.
                let kelvin = filter.neutralTemperature
                filter.neutralTint += tint
                filter.neutralTemperature = kelvin
            }
            guard let image = filter.outputImage.map(atOrigin) else { return nil }
            let width = Int(image.extent.width), height = Int(image.extent.height)
            guard width > 0, height > 0, width * height <= 4_000_000 else { return nil }
            var rgba = [Float](repeating: 0, count: width * height * 4)
            context.render(image, toBitmap: &rgba, rowBytes: width * 16,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .RGBAf, colorSpace: filmSpace)
            return (0..<width * height).map {
                SIMD3(rgba[4 * $0], rgba[4 * $0 + 1], rgba[4 * $0 + 2])
            }
        }
        guard let before = pixels(tint: 0), let greener = pixels(tint: matrixProbeTint),
              let pinker = pixels(tint: -matrixProbeTint),
              greener.count == before.count, pinker.count == before.count else { return nil }
        return NegativeScanDecoderMatrix.recovered(before: before, tinted: [greener, pinker])
    }

    /// Whether a file says how its samples encode light: an embedded profile, or a PNG's colour
    /// chunks, as `Sources/CFotufilmCodecs` reads them. ImageIO gives every other file sRGB, and a
    /// scan without one is the scanner's raw output, read as linear samples.
    public static func statesEncoding(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return true }
        let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any] ?? [:]
        return properties[kCGImagePropertyProfileName] != nil
            || [kCGImagePropertyPNGsRGBIntent, kCGImagePropertyPNGGamma,
                kCGImagePropertyPNGChromaticities].contains { png[$0] != nil }
    }

    /// One exposure of a trichromatic scan (`TrichromaticRoll`), as interleaved RGBA in the film
    /// space: a camera RAW through a fixed daylight balance, so each light keeps its colour, at
    /// half its size (each colour has only a quarter of the photosites); anything else as a scan.
    public static func exposure(data: Data, identifierHint: String?) throws
        -> (rgba: [Float], width: Int, height: Int) {
        var image: CIImage
        if RawDecode.isRaw(data: data, identifierHint: identifierHint) {
            guard let filter = RawDecode.filter(data: data, identifierHint: identifierHint) else {
                throw Failure.unreadable
            }
            RawDecode.configure(filter, recipe: .init(neutralKelvin: 6500, correctsLens: false,
                extendedDynamicRangeAmount: 0, recoversHighlights: false))
            // Exactly half: the policy's demosaic margin would make it whole.
            filter.scaleFactor = 0.5
            filter.exposure = 0
            filter.baselineExposure = 0
            if filter.isLuminanceNoiseReductionSupported { filter.luminanceNoiseReductionAmount = 0 }
            if filter.isColorNoiseReductionSupported { filter.colorNoiseReductionAmount = 0 }
            guard let output = filter.outputImage else { throw Failure.unreadable }
            image = atOrigin(output)
        } else {
            image = try decode(data: data, identifierHint: identifierHint,
                               linearSamples: !statesEncoding(data))
        }
        let width = Int(image.extent.width), height = Int(image.extent.height)
        guard width > 0, height > 0, width <= 40000, height <= 40000,
              width * height <= 150_000_000 else { throw Failure.unreadable }
        var rgba = [Float](repeating: 1, count: width * height * 4)
        let context = ExposureContexts.shared.take()
        defer { ExposureContexts.shared.give(context) }
        context.render(image, toBitmap: &rgba, rowBytes: width * 16,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       format: .RGBAf, colorSpace: filmSpace)
        return (rgba, width, height)
    }

    /// Contexts kept for the exposures of a roll: making one costs as much as a decode, and
    /// exposures read at once each need their own to run side by side.
    private final class ExposureContexts: @unchecked Sendable {
        static let shared = ExposureContexts()
        private let lock = NSLock()
        private var idle: [CIContext] = []

        func take() -> CIContext {
            lock.lock()
            defer { lock.unlock() }
            return idle.popLast()
                ?? CIContext(options: [.workingColorSpace: linearSpace, .cacheIntermediates: false])
        }

        func give(_ context: CIContext) {
            lock.lock()
            idle.append(context)
            lock.unlock()
        }
    }

    public static func sampleBorder(image: CIImage, rect: CGRect,
                                    colorSpace: CGColorSpace = linearSpace) throws -> SIMD3<Float> {
        let e = image.extent
        let r = CGRect(x: e.minX + rect.minX * e.width, y: e.maxY - rect.maxY * e.height,
                       width: rect.width * e.width, height: rect.height * e.height).integral.intersection(e)
        guard r.width >= 2, r.height >= 2 else { throw Failure.invalidBorder }
        var patch = atOrigin(image.cropped(to: r))
        let scale = min(1, 128 / max(r.width, r.height))
        patch = patch.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let buffer = try samples(patch, colorSpace: colorSpace)
        var result = SIMD3<Float>.zero
        for c in 0..<3 {
            let values = buffer.planes[c].filter { $0.isFinite && $0 > 0 }.sorted()
            guard values.count >= buffer.pixelCount * 9 / 10, !values.isEmpty else { throw Failure.invalidBorder }
            result[c] = values[values.count / 2]
        }
        return result
    }

    public static func samples(_ image: CIImage,
                               colorSpace: CGColorSpace = linearSpace) throws -> ImageBuffer {
        let image = atOrigin(image)
        let w = Int(image.extent.width), h = Int(image.extent.height)
        guard w > 0, h > 0, w <= 40000, h <= 40000, w * h <= 150_000_000 else { throw Failure.unreadable }
        var rgba = [Float](repeating: 0, count: w * h * 4)
        let context = CIContext(options: [.workingColorSpace: linearSpace])
        context.render(image, toBitmap: &rgba, rowBytes: w * 16,
                       bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: colorSpace)
        var result = ImageBuffer(width: w, height: h)
        for c in 0..<3 { for i in 0..<w*h { result.planes[c][i] = rgba[4*i+c] } }
        return result
    }

    /// The kernels read the scan as the film (`FotufilmEngine.Options.scanReading`). Samples
    /// outside the model's usable density range (commonly the film holder) print black. No
    /// artificial density floor enters the measurement API.
    public static func positive(image: CIImage, border: SIMD3<Float>, stock: FilmStock) throws -> CIImage {
        let scan = try samples(image)
        var options = FotufilmEngine.Options()
        options.paper = .screen
        options.stage = .print
        options.scanReading = try ApproximateNegativeScan(stock: stock, border: border)
        let positive = try FotufilmEngine(stock: stock, options: options)
            .printPositiveChecked(negativeDensity: scan)
        var rgba = [Float](repeating: 1, count: positive.pixelCount * 4)
        for i in 0..<positive.pixelCount { for c in 0..<3 { rgba[4*i+c] = positive.planes[c][i] } }
        let data = rgba.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: positive.width * 16,
            size: CGSize(width: positive.width, height: positive.height), format: .RGBAf,
            colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!)
    }

    public static func automaticPlan(image: CIImage, monochrome: Bool) throws -> AutomaticNegativeScan {
        let scale = min(1, 512 / max(image.extent.width, image.extent.height))
        let preview = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return try AutomaticNegativeScan(preview: samples(preview), monochrome: monochrome)
    }

    public static func positive(image: CIImage, automatic plan: AutomaticNegativeScan) throws -> CIImage {
        let positive = try plan.convert(samples(image))
        var rgba = [Float](repeating: 1, count: positive.pixelCount * 4)
        for i in 0..<positive.pixelCount { for c in 0..<3 { rgba[4*i+c] = positive.planes[c][i] } }
        let data = rgba.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: positive.width * 16,
            size: CGSize(width: positive.width, height: positive.height), format: .RGBAf,
            colorSpace: linearSpace)
    }

    private static func atOrigin(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }
}
#endif
