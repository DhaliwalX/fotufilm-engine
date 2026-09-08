import Foundation

public enum HalationModel: String, Codable, CaseIterable, Sendable, Identifiable {
    case legacy
    case layered
    public var id: String { rawValue }
    public var name: String { self == .legacy ? "Legacy" : "Layered Transport" }
}

public extension FotufilmEngine.Options {
    func transportConstruction(for stock: FilmStock) -> LayeredTransport? {
        guard stage != .print else { return nil }
        if let layeredTransport { return layeredTransport }
        guard halationModel == .layered else { return nil }
        return stock.layeredTransport ?? .illustrative(stock: stock, format: format)
    }

    var withoutLayeredTransport: Self {
        var copy = self
        copy.halationModel = .legacy; copy.layeredTransport = nil
        return copy
    }
}

public extension LayeredTransport {
    /// Generic geometry for model comparison; optical constants are illustrative. The stock
    /// supplies its return ratios and compact response, without modifying its calibration.
    static func illustrative(stock: FilmStock, format: FilmFormat) -> Self {
        Self(constructionID: "illustrative-generic-stack", provenance: "illustrative",
            layers: [
                .init(id: "blue-coating", thicknessMM: 0.006, refractiveIndex: [1.52], absorptionPerMM: [0.4]),
                .init(id: "green-coating", thicknessMM: 0.006, refractiveIndex: [1.52], absorptionPerMM: [0.4]),
                .init(id: "red-coating", thicknessMM: 0.006, refractiveIndex: [1.52], absorptionPerMM: [0.4]),
                .init(id: "support", thicknessMM: Double(format.base.thicknessMM),
                      refractiveIndex: [Double(format.base.refractiveIndex)], absorptionPerMM: [0.2])],
            recordDepthMM: [0.015, 0.009, 0.003], angularExponent: [[2.2], [2], [1.8]],
            captureProbability: [[0.35], [0.4], [0.5]],
            returnedToDirect: stock.halationStrength.map { [Double($0)] },
            coreSigmaMM: stock.emulsionDiffusionMM.map(Double.init))
    }
}
