import Foundation

/// The native scan importer's approximate RGB-density mapping. A sampled border
/// removes base/fog and the chosen film restores its model base. Optional per-record gains
/// scale each channel's density, for scanners whose channels do not read the dyes' own
/// densities. This does not fit a scanner profile or correct illumination, flare or dye
/// cross-talk.
public struct ApproximateNegativeScan: Encodable, Sendable {
    public let border: [Float]
    public let baseDensity: [Float]
    public let recordChannels: [Int]
    /// Record density per unit of scanner-channel density above the border.
    public let gains: [Float]
    public let minimumSample: [Float]
    public let maximumSample: [Float]

    public static let gainRange: ClosedRange<Float> = 0.5...2

    public init(stock: FilmStock, border: SIMD3<Float>, gains: SIMD3<Float> = .one) throws {
        guard !stock.isReversal else { throw ScannedNegativeError.positiveOutputRequired }
        _ = try ScannedNegativeConverter(dark: .zero, light: border, reference: .filmBase)
        guard (0..<3).allSatisfy({ gains[$0].isFinite && Self.gainRange.contains(gains[$0]) }) else {
            throw ScannedNegativeError.invalidCalibration
        }
        self.border = [border.x, border.y, border.z]
        baseDensity = (0..<3).map { stock.curves[$0].dMin }
        recordChannels = stock.isMonochrome ? [1, 1, 1] : [0, 1, 2]
        self.gains = stock.isMonochrome ? [1, 1, 1] : [gains.x, gains.y, gains.z]
        var minimum = [Float](repeating: 0, count: 3)
        var maximum = [Float](repeating: .greatestFiniteMagnitude, count: 3)
        for record in 0..<3 {
            let channel = recordChannels[record]
            let gain = self.gains[record]
            // Leave the same interior margin used by native scanned-negative import.
            let low = border[channel] * pow(10, (baseDensity[record] - NegativeInterchange.range.upperBound) / gain + 0.0001)
            let high = border[channel] * pow(10, (baseDensity[record] - NegativeInterchange.range.lowerBound) / gain - 0.0001)
            minimum[channel] = max(minimum[channel], low)
            maximum[channel] = min(maximum[channel], high)
        }
        minimumSample = minimum
        maximumSample = maximum
    }

    /// One linear scan sample's record densities: the border's scanner density removed and the
    /// film's model base restored. `nil` where `convert` would mark the pixel invalid.
    @inlinable
    public func density(of sample: SIMD3<Float>) -> SIMD3<Float>? {
        for channel in 0..<3 {
            let value = sample[channel]
            guard value.isFinite, value > minimumSample[channel],
                  value < maximumSample[channel] else { return nil }
        }
        var density = SIMD3<Float>.zero
        for record in 0..<3 {
            let channel = recordChannels[record]
            density[record] = baseDensity[record]
                - gains[record] * log10(sample[channel] / border[channel])
        }
        return density
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
        let rows = recordChannels.indices.map { record -> SIMD3<Float> in
            var row = SIMD3<Float>.zero; row[recordChannels[record]] = gains[record]; return row
        }
        let calibration = try ScanDensityCalibration(reference: .filmBase, rows: rows,
            offset: SIMD3(baseDensity[0], baseDensity[1], baseDensity[2]))
        return Result(density: try converter.negativeDensity(linearScan: scan, calibration: calibration), invalid: invalid)
    }

    /// What a frame's own tones say about reading it on a film: per-record gains, and where its
    /// highlights sit.
    public struct Balance: Equatable, Sendable {
        /// Make the frame's densest end, its highlights, read as one exposure on every record,
        /// green held as it is. Broadband scanners and cameras see a cyan dye through a red
        /// channel that also passes light the dye does not absorb, which otherwise leaves the
        /// highlights off colour at every tone.
        public var gains: SIMD3<Float>
        /// The highlights' exposure in stops over the film's mid-grey, for
        /// `FotufilmEngine.Options.sceneHighlightStops`. Nil for a frame too flat to tell.
        public var highlightStops: Float?

        public static let neutral = Balance(gains: .one, highlightStops: nil)
    }

    /// Reads `preview`, linear scan RGB of the framed picture, against `stock`. The central 80%
    /// keeps the holder out, as automatic conversion does; a monochrome film reads one channel.
    public static func balance(stock: FilmStock, border: SIMD3<Float>,
                               preview: ImageBuffer) -> Balance {
        guard preview.width >= 2, preview.height >= 2 else { return .neutral }
        var channels = [[Float]](repeating: [], count: 3)
        let mx = preview.width / 10, my = preview.height / 10
        for y in my..<(preview.height - my) { for x in mx..<(preview.width - mx) {
            let i = y * preview.width + x
            let pixel = (0..<3).map { preview.planes[$0][i] }
            guard pixel.allSatisfy({ $0.isFinite && $0 > 0 }) else { continue }
            for c in 0..<3 { channels[c].append(-log10(pixel[c] / border[c])) }
        } }
        guard channels[0].count >= 16 else { return .neutral }
        let dense = channels.map { values -> Float in
            let sorted = values.sorted()
            return sorted[Int(Float(sorted.count - 1) * 0.995)]
        }
        guard dense[1] > 0.05 else { return .neutral }
        let exposure = stock.curves[1].logExposure(density: stock.curves[1].dMin + dense[1])
        var gains = SIMD3<Float>.one
        if !stock.isMonochrome {
            for record in [0, 2] where dense[record] > 0.05 {
                let expected = stock.curves[record].density(logExposure: exposure)
                    - stock.curves[record].dMin
                gains[record] = min(max(expected / dense[record], gainRange.lowerBound),
                                    gainRange.upperBound)
            }
        }
        return Balance(gains: gains, highlightStops: exposure / log10(2))
    }
}
