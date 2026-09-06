import Foundation

/// The denominator used to measure scanner-channel transmission.
public enum ScanDensityReference: String, Sendable {
    /// Unobstructed light: measured density includes the film base and fog.
    case clearLight
    /// Unexposed, developed film: measured density is relative to that film base and fog.
    case filmBase
}

public enum ScannedNegativeError: Error, Equatable {
    case invalidReference(channel: Int)
    case invalidCalibration
    case referenceMismatch
    case invalidImage
    case invalidSample(channel: Int, pixel: Int)
    case densityOutOfRange(channel: Int, pixel: Int)
    case positiveOutputRequired
}

/// A supplied affine calibration from scanner-channel density to `NegativeInterchange`.
/// Rows are output film records; columns are input scanner R, G, B. The offset must include
/// the target model's base density when the input reference is `.filmBase`.
///
/// This is an approximation whose useful range must be established with measured patches for
/// the particular scanner, illuminant, film and development. There is no universal identity
/// calibration for colour negatives. Fitting profiles is separate from this runtime API.
public struct ScanDensityCalibration: Sendable {
    public let reference: ScanDensityReference
    public let rows: [SIMD3<Float>]
    public let offset: SIMD3<Float>

    public init(reference: ScanDensityReference, rows: [SIMD3<Float>],
                offset: SIMD3<Float>) throws {
        guard rows.count == 3,
              rows.allSatisfy({ row in (0..<3).allSatisfy { row[$0].isFinite } }),
              (0..<3).allSatisfy({ offset[$0].isFinite }) else {
            throw ScannedNegativeError.invalidCalibration
        }
        self.reference = reference
        self.rows = rows
        self.offset = offset
    }
}

/// Converts linear, ungraded scanner/camera samples; it does not decode image files, transfer
/// curves or RAW mosaics. Supply dark and reference samples captured with the same settings
/// and in the same channel basis as the image. Flat-field uneven illumination before calling.
/// An ordinary colour-managed/display RGB image is not a linear scanner measurement.
public struct ScannedNegativeConverter: Sendable {
    public let dark: SIMD3<Float>
    public let light: SIMD3<Float>
    public let reference: ScanDensityReference

    public init(dark: SIMD3<Float>, light: SIMD3<Float>,
                reference: ScanDensityReference) throws {
        for channel in 0..<3 {
            guard dark[channel].isFinite, light[channel].isFinite,
                  light[channel] > dark[channel] else {
                throw ScannedNegativeError.invalidReference(channel: channel)
            }
        }
        self.dark = dark
        self.light = light
        self.reference = reference
    }

    /// D = -log10((sample - dark) / (reference - dark)), per scanner channel.
    /// These values are NOT yet `NegativeInterchange`. Values above the reference are allowed
    /// and give negative densities. Samples at/below dark and nonfinite samples are rejected
    /// rather than clipped to invented densities; saturated captures must be detected upstream.
    public func scannerDensity(linearScan image: ImageBuffer) throws -> ImageBuffer {
        guard image.width > 0, image.height > 0, image.planes.count == 3,
              image.planes.allSatisfy({ $0.count == image.pixelCount }) else {
            throw ScannedNegativeError.invalidImage
        }
        var result = image
        for channel in 0..<3 {
            // Double intermediates avoid overflow subtracting finite float reference values.
            let black = Double(dark[channel])
            let span = Double(light[channel]) - black
            for pixel in 0..<image.pixelCount {
                let sample = Double(image.planes[channel][pixel])
                guard sample.isFinite, sample > black else {
                    throw ScannedNegativeError.invalidSample(channel: channel, pixel: pixel)
                }
                result.planes[channel][pixel] = Float(-log10((sample - black) / span))
            }
        }
        return result
    }

    /// Recovers model densities using an explicit calibration. No characteristic curve,
    /// halation or grain is applied: those effects are already present in the scanned film.
    /// Calibration must match the film model and lab settings used by the subsequent print.
    public func negativeDensity(linearScan image: ImageBuffer,
                                calibration: ScanDensityCalibration) throws -> ImageBuffer {
        guard calibration.reference == reference else {
            throw ScannedNegativeError.referenceMismatch
        }
        let measured = try scannerDensity(linearScan: image)
        var result = measured
        for pixel in 0..<image.pixelCount {
            for channel in 0..<3 {
                let row = calibration.rows[channel]
                let value = Double(calibration.offset[channel])
                    + Double(row.x) * Double(measured.planes[0][pixel])
                    + Double(row.y) * Double(measured.planes[1][pixel])
                    + Double(row.z) * Double(measured.planes[2][pixel])
                let density = Float(value)
                guard NegativeInterchange.contains(density) else {
                    throw ScannedNegativeError.densityOutOfRange(channel: channel, pixel: pixel)
                }
                result.planes[channel][pixel] = density
            }
        }
        return result
    }
}

extension FotufilmEngine {
    /// Linear scan to display-linear Display P3 positive. Always enters at the print boundary,
    /// regardless of `options.stage`, preserving the negative's existing exposure effects.
    /// The supplied calibration must target this stock and its configured lab settings.
    /// As with `printPositive`, a linked Halide backend is required.
    public func printScannedNegative(linearScan image: ImageBuffer,
                                     converter: ScannedNegativeConverter,
                                     calibration: ScanDensityCalibration) throws -> ImageBuffer {
        guard !stock.isReversal, options.negativeViewing == nil,
              !options.paper(for: stock).isNegative else {
            throw ScannedNegativeError.positiveOutputRequired
        }
        let density = try converter.negativeDensity(linearScan: image, calibration: calibration)
        return printPositive(negativeDensity: density)
    }
}
