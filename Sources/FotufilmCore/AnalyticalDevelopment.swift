import Foundation

/// Finite-capacity, three-record negative development. Parameters must be calibrated together;
/// the stock's characteristic curves remain the reference used to time the output medium.
///
/// `n = sigmoid(slope * (log10Exposure - midpoint))`
/// `s = n * (1 - exp(-budget / (1 + scale * inhibition * G(s))))`
/// `density = stock.dMin + capacity * s`
///
/// Rows receive inhibitor, columns release it. G is the stock's normalized lateral Gaussian,
/// or identity when spatial effects are disabled. This is an effective development model, not
/// a time-resolved chemical simulation. It currently runs in the Halide reference backends.
public struct AnalyticalDevelopment: Codable, Sendable, Equatable {
    public var slope: [Float]
    public var midpoint: [Float]
    public var budget: [Float]
    public var capacity: [Float]
    public var inhibition: [[Float]]

    public static let iterations = 64
    /// With the engine's inhibition scale below two, the fixed-point contraction stays below
    /// 0.75. Sixty-four simultaneous updates then bound normalized truncation error below 5e-8.
    public static let maximumContraction: Float = 0.375

    public init(slope: [Float], midpoint: [Float], budget: [Float], capacity: [Float],
                inhibition: [[Float]]) {
        self.slope = slope
        self.midpoint = midpoint
        self.budget = budget
        self.capacity = capacity
        self.inhibition = inhibition
    }

    public struct InvalidParameters: Error, CustomStringConvertible {
        public let description: String
    }

    public func validate() throws {
        func vector(_ values: [Float], _ name: String, _ range: ClosedRange<Float>) throws {
            guard values.count == 3, values.allSatisfy({ $0.isFinite && range.contains($0) }) else {
                throw InvalidParameters(description: "\(name) requires three finite values in \(range)")
            }
        }
        try vector(slope, "slope", 0.01...20)
        try vector(midpoint, "midpoint", -10...10)
        try vector(budget, "budget", 0.05...30)
        try vector(capacity, "capacity", 0.01...6)
        guard inhibition.count == 3 else {
            throw InvalidParameters(description: "inhibition requires three receiver rows")
        }
        for row in inhibition { try vector(row, "inhibition", 0...100) }
        guard contractionBound <= Self.maximumContraction else {
            throw InvalidParameters(description: "inhibition exceeds the fixed-point contraction limit")
        }
    }

    /// Global infinity-norm derivative bound for unit inhibition scale, including n <= 1.
    public var contractionBound: Float {
        (0..<3).map { i in
            let q = budget[i]
            let derivative = q >= 2 ? 4 * exp(-2) / q : q * exp(-q)
            return derivative * inhibition[i].reduce(0, +)
        }.max() ?? 0
    }

    /// Pointwise reference for calibration and diagnostics. Spatial rendering uses the same
    /// simultaneous update in shared Halide physics, diffusing developed material each time.
    public func developedFraction(logExposure: [Float], scale: Float = 1) -> [Float] {
        precondition(logExposure.count == 3)
        precondition((try? validate()) != nil)
        let strength = FilmEngineInvocation.effectiveCouplerScale(scale)
        let latent = (0..<3).map { i in
            1 / (1 + exp(-min(max(slope[i] * (logExposure[i] - midpoint[i]), -80), 80)))
        }
        var s = (0..<3).map { latent[$0] * -expm1(-budget[$0]) }
        for _ in 0..<Self.iterations {
            s = (0..<3).map { i in
                let inhibitor = (0..<3).reduce(Float(0)) { $0 + inhibition[i][$1] * s[$1] }
                return latent[i] * -expm1(-budget[i] / (1 + strength * inhibitor))
            }
        }
        return s
    }

    /// Appended to the stable engine configuration ABI: enabled, slopes, midpoints, budgets,
    /// capacities, then the row-major interaction matrix.
    var configuration: [Float] { [1] + slope + midpoint + budget + capacity + inhibition.flatMap { $0 } }
}
