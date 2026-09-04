import Foundation

/// One measured result of developing a stock away from its pack's reference process.
///
/// Push/pull is not a stock-only exponent. The developer, dilution, temperature, agitation and
/// time jointly determine the finished characteristic curves, and colour records need not move
/// together. A condition therefore carries the complete measured curves rather than rates to
/// apply to the reference curves. Optional fields are replaced only where the same source measured
/// them; an absent measurement never becomes an inferred grain or adjacency change.
public struct FilmDevelopmentCondition: Sendable {
    /// Exposure-rating difference from the pack's reference process, in stops.
    public var stops: Float
    /// Label printed in editors and validation errors.
    public var label: String
    /// Development time that produced these measurements.
    public var timeMinutes: Float
    /// Meter setting associated with this condition, where the source states one.
    public var exposureIndex: Float?
    /// Complete dye-forming layer curves at this condition.
    public var curves: [CharacteristicCurve]
    /// Complete donor-layer curves, where the stock coats donor records.
    public var donorCurves: [CharacteristicCurve]

    public var grainStrength: Float?
    public var grainSizeMM: Float?
    public var grainLayerWeights: [Float]?
    public var grainFogDensity: Float?
    public var adjacencyStrength: Float?

    public init(
        stops: Float,
        label: String,
        timeMinutes: Float,
        exposureIndex: Float? = nil,
        curves: [CharacteristicCurve],
        donorCurves: [CharacteristicCurve] = [],
        grainStrength: Float? = nil,
        grainSizeMM: Float? = nil,
        grainLayerWeights: [Float]? = nil,
        grainFogDensity: Float? = nil,
        adjacencyStrength: Float? = nil
    ) {
        self.stops = stops
        self.label = label
        self.timeMinutes = timeMinutes
        self.exposureIndex = exposureIndex
        self.curves = curves
        self.donorCurves = donorCurves
        self.grainStrength = grainStrength
        self.grainSizeMM = grainSizeMM
        self.grainLayerWeights = grainLayerWeights
        self.grainFogDensity = grainFogDensity
        self.adjacencyStrength = adjacencyStrength
    }
}

/// The fixed process shared by a stock's measured development conditions.
public struct FilmDevelopmentProfile: Sendable {
    public var developer: String
    public var dilution: String?
    public var temperatureC: Float
    public var agitation: String
    public var source: String
    public var sourcePage: Int
    public var conditions: [FilmDevelopmentCondition]

    public init(
        developer: String,
        dilution: String? = nil,
        temperatureC: Float,
        agitation: String,
        source: String,
        sourcePage: Int,
        conditions: [FilmDevelopmentCondition]
    ) {
        self.developer = developer
        self.dilution = dilution
        self.temperatureC = temperatureC
        self.agitation = agitation
        self.source = source
        self.sourcePage = sourcePage
        self.conditions = conditions
    }
}

public enum FilmDevelopmentError: Error, Equatable, CustomStringConvertible {
    case unavailable(stock: String, requestedStops: Float)
    case unmeasuredCondition(stock: String, requestedStops: Float, availableStops: [Float])
    case invalidProfile(stock: String, condition: String, reason: String)

    public var description: String {
        switch self {
        case let .unavailable(stock, requested):
            return "\(stock) has no measured push/pull response; cannot apply \(Self.stops(requested))"
        case let .unmeasuredCondition(stock, requested, available):
            let choices = available.map(Self.stops).joined(separator: ", ")
            return "\(stock) has no measured response at \(Self.stops(requested)); available: \(choices)"
        case let .invalidProfile(stock, condition, reason):
            return "\(stock) has an invalid measured condition '\(condition)': \(reason)"
        }
    }

    private static func stops(_ value: Float) -> String {
        let number = value == value.rounded()
            ? String(Int(value)) : String(format: "%.2f", value)
        return "\(value > 0 ? "+" : "")\(number) stop\(abs(value) == 1 ? "" : "s")"
    }
}

public extension FilmStock {
    /// The exact non-reference conditions this stock can render, in slider order.
    var supportedDevelopmentStops: [Float] {
        developmentProfile?.conditions.map(\.stops).sorted() ?? []
    }

    var hasMeasuredDevelopmentResponse: Bool {
        !supportedDevelopmentStops.isEmpty
    }

    /// Whether a requested condition is measured. Reference development is always exact because
    /// it is the stock itself; it is not repeated in `developmentProfile.conditions`.
    func supportsDevelopment(stops: Float) -> Bool {
        stops == 0 || developmentCondition(stops: stops) != nil
    }

    /// The stock as measured after the requested development. Reference development returns
    /// `self` exactly. Any other request must match a pack condition; interpolation would put an
    /// unmeasured curve back into the path this type exists to remove.
    func pushed(stops: Float) throws -> FilmStock {
        guard stops != 0 else { return self }
        guard let profile = developmentProfile else {
            throw FilmDevelopmentError.unavailable(stock: name, requestedStops: stops)
        }
        guard let condition = developmentCondition(stops: stops) else {
            throw FilmDevelopmentError.unmeasuredCondition(
                stock: name, requestedStops: stops,
                availableStops: profile.conditions.map(\.stops).sorted())
        }
        guard condition.curves.count == curves.count else {
            throw FilmDevelopmentError.invalidProfile(
                stock: name, condition: condition.label,
                reason: "\(condition.curves.count) layer curves; expected \(curves.count)")
        }
        guard condition.donorCurves.count == donorLayers.count else {
            throw FilmDevelopmentError.invalidProfile(
                stock: name, condition: condition.label,
                reason: "\(condition.donorCurves.count) donor curves; expected \(donorLayers.count)")
        }

        var developed = self
        developed.curves = condition.curves
        for index in developed.donorLayers.indices {
            developed.donorLayers[index].curve = condition.donorCurves[index]
        }
        if let value = condition.grainStrength { developed.grainStrength = value }
        if let value = condition.grainSizeMM { developed.grainSizeMM = value }
        if let value = condition.grainLayerWeights { developed.grainLayerWeights = value }
        if let value = condition.grainFogDensity { developed.grainFogDensity = value }
        if let value = condition.adjacencyStrength { developed.adjacencyStrength = value }
        return developed
    }

    private func developmentCondition(stops: Float) -> FilmDevelopmentCondition? {
        let tolerance: Float = 1e-4
        return developmentProfile?.conditions.first {
            abs($0.stops - stops) <= tolerance
        }
    }
}
