import Foundation

/// The native scan importer's approximate RGB-density mapping. A sampled border
/// removes base/fog and the chosen film restores its model base. This does not fit
/// a scanner profile or correct illumination, flare or dye cross-talk.
public struct ApproximateNegativeScan: Encodable, Sendable {
    public let border: [Float]
    public let baseDensity: [Float]
    public let recordChannels: [Int]
    public let minimumSample: [Float]
    public let maximumSample: [Float]

    public init(stock: FilmStock, border: SIMD3<Float>) throws {
        guard !stock.isReversal else { throw ScannedNegativeError.positiveOutputRequired }
        _ = try ScannedNegativeConverter(dark: .zero, light: border, reference: .filmBase)
        self.border = [border.x, border.y, border.z]
        baseDensity = (0..<3).map { stock.curves[$0].dMin }
        recordChannels = stock.isMonochrome ? [1, 1, 1] : [0, 1, 2]
        var minimum = [Float](repeating: 0, count: 3)
        var maximum = [Float](repeating: .greatestFiniteMagnitude, count: 3)
        for record in 0..<3 {
            let channel = recordChannels[record]
            // Leave the same interior margin used by native scanned-negative import.
            let low = border[channel] * pow(10, baseDensity[record] - NegativeInterchange.range.upperBound + 0.0001)
            let high = border[channel] * pow(10, baseDensity[record] - NegativeInterchange.range.lowerBound - 0.0001)
            minimum[channel] = max(minimum[channel], low)
            maximum[channel] = min(maximum[channel], high)
        }
        minimumSample = minimum
        maximumSample = maximum
    }

    public struct Result {
        public let density: ImageBuffer
        public let invalid: [Bool]
    }

    /// Invalid pixels (often the holder) are excluded, not clipped to an invented
    /// density. Callers paint those pixels black after the shared print stage.
    public func convert(_ image: ImageBuffer) throws -> Result {
        guard image.width > 0, image.height > 0, image.planes.count == 3,
              image.planes.allSatisfy({ $0.count == image.pixelCount }) else {
            throw ScannedNegativeError.invalidImage
        }
        var scan = image
        var invalid = [Bool](repeating: false, count: scan.pixelCount)
        for pixel in 0..<scan.pixelCount {
            invalid[pixel] = (0..<3).contains { channel in
                let value = scan.planes[channel][pixel]
                return !value.isFinite || value <= minimumSample[channel] || value >= maximumSample[channel]
            }
            if invalid[pixel] {
                for channel in 0..<3 { scan.planes[channel][pixel] = border[channel] }
            }
        }
        let light = SIMD3<Float>(border[0], border[1], border[2])
        let converter = try ScannedNegativeConverter(dark: .zero, light: light, reference: .filmBase)
        let rows = recordChannels.map { channel -> SIMD3<Float> in
            var row = SIMD3<Float>.zero; row[channel] = 1; return row
        }
        let calibration = try ScanDensityCalibration(reference: .filmBase, rows: rows,
            offset: SIMD3(baseDensity[0], baseDensity[1], baseDensity[2]))
        return Result(density: try converter.negativeDensity(linearScan: scan, calibration: calibration), invalid: invalid)
    }
}
