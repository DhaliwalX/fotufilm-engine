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

    public static func decode(data: Data, identifierHint: String? = nil, linearSamples: Bool = false) throws -> CIImage {
        if RawDecode.isRaw(data: data, identifierHint: identifierHint) {
            guard let filter = RawDecode.filter(data: data, identifierHint: identifierHint) else { throw Failure.unreadable }
            RawDecode.configure(filter, recipe: .init(correctsLens: false,
                extendedDynamicRangeAmount: 0, recoversHighlights: false))
            filter.exposure = 0
            filter.baselineExposure = 0
            filter.shadowBias = 0
            filter.boostShadowAmount = 0
            if filter.isLuminanceNoiseReductionSupported { filter.luminanceNoiseReductionAmount = 0 }
            if filter.isColorNoiseReductionSupported { filter.colorNoiseReductionAmount = 0 }
            guard let image = filter.outputImage else { throw Failure.unreadable }
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

    public static func sampleBorder(image: CIImage, rect: CGRect) throws -> SIMD3<Float> {
        let e = image.extent
        let r = CGRect(x: e.minX + rect.minX * e.width, y: e.maxY - rect.maxY * e.height,
                       width: rect.width * e.width, height: rect.height * e.height).integral.intersection(e)
        guard r.width >= 2, r.height >= 2 else { throw Failure.invalidBorder }
        var patch = atOrigin(image.cropped(to: r))
        let scale = min(1, 128 / max(r.width, r.height))
        patch = patch.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let buffer = try samples(patch)
        var result = SIMD3<Float>.zero
        for c in 0..<3 {
            let values = buffer.planes[c].filter { $0.isFinite && $0 > 0 }.sorted()
            guard values.count >= buffer.pixelCount * 9 / 10, !values.isEmpty else { throw Failure.invalidBorder }
            result[c] = values[values.count / 2]
        }
        return result
    }

    public static func samples(_ image: CIImage) throws -> ImageBuffer {
        let image = atOrigin(image)
        let w = Int(image.extent.width), h = Int(image.extent.height)
        guard w > 0, h > 0, w <= 40000, h <= 40000, w * h <= 150_000_000 else { throw Failure.unreadable }
        var rgba = [Float](repeating: 0, count: w * h * 4)
        let context = CIContext(options: [.workingColorSpace: linearSpace])
        context.render(image, toBitmap: &rgba, rowBytes: w * 16,
                       bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: linearSpace)
        var result = ImageBuffer(width: w, height: h)
        for c in 0..<3 { for i in 0..<w*h { result.planes[c][i] = rgba[4*i+c] } }
        return result
    }

    /// Samples outside the model's usable density range (commonly the film holder) are
    /// excluded and painted black. No artificial density floor enters the measurement API.
    public static func positive(image: CIImage, border: SIMD3<Float>, stock: FilmStock) throws -> CIImage {
        var scan = try samples(image)
        let base = SIMD3<Float>(stock.curves[0].dMin, stock.curves[1].dMin, stock.curves[2].dMin)
        var minimum = SIMD3<Float>(repeating: 0)
        var maximum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        for record in 0..<3 {
            let channel = stock.isMonochrome ? 1 : record
            // A small interior margin avoids rounding a boundary value beyond the strict
            // interchange range during the subsequent Double-precision log conversion.
            let low = border[channel] * pow(10, base[record] - NegativeInterchange.range.upperBound + 0.0001)
            let high = border[channel] * pow(10, base[record] - NegativeInterchange.range.lowerBound - 0.0001)
            minimum[channel] = max(minimum[channel], low)
            maximum[channel] = min(maximum[channel], high)
        }
        var invalid = [Bool](repeating: false, count: scan.pixelCount)
        for i in 0..<scan.pixelCount {
            invalid[i] = (0..<3).contains { !scan.planes[$0][i].isFinite || scan.planes[$0][i] <= minimum[$0]
                || scan.planes[$0][i] >= maximum[$0] }
            if invalid[i] { for c in 0..<3 { scan.planes[c][i] = border[c] } }
        }
        let converter = try ScannedNegativeConverter(dark: .zero, light: border, reference: .filmBase)
        let rows: [SIMD3<Float>] = stock.isMonochrome
            ? Array(repeating: SIMD3<Float>(0, 1, 0), count: 3)
            : [SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1)]
        let mapping = try ScanDensityCalibration(reference: .filmBase, rows: rows,
            offset: base)
        var options = FotufilmEngine.Options()
        options.paper = .screen
        let positive = try FotufilmEngine(stock: stock, options: options)
            .printScannedNegative(linearScan: scan, converter: converter, calibration: mapping)
        var rgba = [Float](repeating: 1, count: positive.pixelCount * 4)
        for i in 0..<positive.pixelCount { for c in 0..<3 {
            rgba[4*i+c] = invalid[i] ? 0 : positive.planes[c][i]
        } }
        let data = rgba.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: positive.width * 16,
            size: CGSize(width: positive.width, height: positive.height), format: .RGBAf,
            colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!)
    }

    private static func atOrigin(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }
}
#endif
