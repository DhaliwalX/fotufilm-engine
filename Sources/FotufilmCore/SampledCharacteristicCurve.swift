import Foundation

/// A runtime density record with C1 Hermite interpolation through every sample.
/// Local extrema are retained; interpolation does not overshoot adjacent samples.
/// The endpoint tangents are zero, joining constant extrapolation continuously.
public struct SampledCharacteristicCurve: Codable, Sendable {
    public static let maximumSamples = 1024
    public let logExposure: [Float]
    public let density: [Float]
    public let slopes: [Float]

    private enum CodingKeys: String, CodingKey { case logExposure, density }

    public init(logExposure: [Float], density: [Float]) throws {
        guard (2...Self.maximumSamples).contains(logExposure.count),
              density.count == logExposure.count,
              logExposure.allSatisfy(\.isFinite), density.allSatisfy(\.isFinite),
              zip(logExposure, logExposure.dropFirst()).allSatisfy({ $0 < $1 }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [],
                debugDescription: "Sampled curves require 2...1024 finite density/exposure pairs with strictly increasing exposure."))
        }
        self.logExposure = logExposure
        self.density = density
        var slopes = [Float](repeating: 0, count: density.count)
        for i in 1..<(density.count - 1) {
            let h0 = Double(logExposure[i]) - Double(logExposure[i - 1])
            let h1 = Double(logExposure[i + 1]) - Double(logExposure[i])
            let d0 = (Double(density[i]) - Double(density[i - 1])) / h0
            let d1 = (Double(density[i + 1]) - Double(density[i])) / h1
            if d0 * d1 > 0 {
                let w0 = 2 * h1 + h0, w1 = h1 + 2 * h0
                slopes[i] = Float((w0 + w1) / (w0 / d0 + w1 / d1))
            }
        }
        guard slopes.allSatisfy(\.isFinite) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [],
                debugDescription: "Sampled curve tangents must be finite."))
        }
        self.slopes = slopes
    }

    /// Translates an already validated record for speed loss and base fog.
    func shifted(logExposure shift: Float, density fog: Float = 0) -> Self {
        Self(logExposure: logExposure.map { $0 + shift },
             density: density.map { $0 + fog }, slopes: slopes)
    }

    private init(logExposure: [Float], density: [Float], slopes: [Float]) {
        self.logExposure = logExposure
        self.density = density
        self.slopes = slopes
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(logExposure: values.decode([Float].self, forKey: .logExposure),
                      density: values.decode([Float].self, forKey: .density))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(logExposure, forKey: .logExposure)
        try values.encode(density, forKey: .density)
    }

    public func value(at x: Float) -> Float {
        if x <= logExposure[0] { return density[0] }
        if x >= logExposure[logExposure.count - 1] { return density[density.count - 1] }
        var low = 0, high = logExposure.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if logExposure[mid] <= x { low = mid } else { high = mid }
        }
        return Self.hermite(x: x, x0: logExposure[low], x1: logExposure[high],
                            y0: density[low], y1: density[high],
                            m0: slopes[low], m1: slopes[high])
    }

    static func hermite(x: Float, x0: Float, x1: Float, y0: Float, y1: Float,
                        m0: Float, m1: Float) -> Float {
        let h = x1 - x0
        let t = min(max((x - x0) / h, 0), 1)
        let delta = y1 - y0
        let a = h * m0, b = h * m1
        return y0 + t * (a + t * (3 * delta - 2 * a - b
                                 + t * (-2 * delta + a + b)))
    }
}
