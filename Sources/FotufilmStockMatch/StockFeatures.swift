import Foundation

/// One film measured against one photograph.
public struct StockFeatures: Equatable, Sendable {

    /// Adding a case is a file-format change; `StockPreference.History`
    /// stores raw features and versions itself for that reason.
    public enum Term: Int, CaseIterable, Sendable {
        case meterMiss
        case outsideLatitude
        case recoveryDemand
        case grainOnSmoothFrame
        case clipping
        case structureLoss
        case chromaLoss
        case chromaDelta
        case contrastDelta
        case structureDelta
        case warmthDelta
        case grainAmount

        public var isPenalty: Bool { rawValue <= Term.chromaLoss.rawValue }

        public var name: String {
            switch self {
            case .meterMiss: return "latitude"
            case .outsideLatitude: return "outside"
            case .recoveryDemand: return "recovery"
            case .grainOnSmoothFrame: return "grain/smooth"
            case .clipping: return "clipping"
            case .structureLoss: return "flattened"
            case .chromaLoss: return "drained"
            case .chromaDelta: return "colour ±"
            case .contrastDelta: return "contrast ±"
            case .structureDelta: return "texture ±"
            case .warmthDelta: return "warmth ±"
            case .grainAmount: return "grain"
            }
        }
    }

    public static let count = Term.allCases.count

    /// SIMD16 rather than an array of twelve: these are dotted a few million times per training
    /// pass, and the four spare lanes stay zero.
    var storage: SIMD16<Float>

    public init() { storage = .zero }

    public subscript(term: Term) -> Float {
        get { storage[term.rawValue] }
        set { storage[term.rawValue] = newValue }
    }

    public var values: [Float] { Term.allCases.map { storage[$0.rawValue] } }

    public init(values: [Float]) {
        storage = .zero
        for index in 0..<min(values.count, StockFeatures.count) {
            storage[index] = values[index]
        }
    }
}

/// What each feature is worth, plus a per-film bias.
public struct StockWeights: Equatable, Sendable, Codable {
    public var terms: [Float]
    public var bias: [String: Float]

    public init(terms: [Float], bias: [String: Float] = [:]) {
        self.terms = terms
        self.bias = bias
    }

    /// Lower is better: this is a total penalty.
    public func score(_ features: StockFeatures, film: String) -> Float {
        var vector = SIMD16<Float>.zero
        for index in 0..<min(terms.count, 16) { vector[index] = terms[index] }
        return (vector * features.storage).sum() + (bias[film] ?? 0)
    }
}
