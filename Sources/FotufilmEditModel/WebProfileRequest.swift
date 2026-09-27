import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// A bounded settings request. It never receives image pixels or asks the host for network access.
public struct WebProfileRequest: Decodable {
    public let stock: FilmStockDefinition
    public let width: Int
    public let height: Int
    public let filters: [String]?
    public let filterMetering: String?
    public let format: String?
    public let medium: String?
    public let sceneKelvin: Float?
    public let sceneHighlightStops: Float?
    public let controls: [String: Value]

    public enum Value: Decodable {
        case number(Double), flag(Bool), choice(String), curve([Double])
        public init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let flag = try? value.decode(Bool.self) { self = .flag(flag) }
            else if let number = try? value.decode(Double.self), number.isFinite {
                self = .number(number)
            } else if let text = try? value.decode(String.self) { self = .choice(text) }
            else { self = .curve(try value.decode([Double].self)) }
        }
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    public func prepare() throws -> Data {
        let (stock, options) = try configured()
        return try WebFilmProfile.prepare(stock: stock, options: options, width: width, height: height)
    }

    /// The request's edit as one document: top-level choices become the controls they stand for.
    public var document: EditDocument {
        var document = EditDocument()
        for (name, input) in controls {
            guard let field = EditorControlField(rawValue: name) else { continue }
            switch input {
            case .number(let number): document[field] = .number(number)
            case .flag(let flag): document[field] = .flag(flag)
            case .choice(let id): document[field] = .choice(id)
            case .curve(let points): document[field] = .curve(points)
            }
        }
        if let format { document[.gauge] = .choice(format) }
        if let medium { document[.paper] = .choice(medium) }
        if let filters { document[.lensFilterStack] = .choices(filters) }
        if let filterMetering { document[.metering] = .choice(filterMetering) }
        if let sceneKelvin {
            document[.sceneLight] = .choice("custom")
            document[.sceneLightKelvin] = .number(Double(sceneKelvin))
        }
        return document
    }

    public func configured() throws -> (FilmStock, FotufilmEngine.Options) {
        let stock = try self.stock.validated().stock
        if let unknown = controls.keys.first(where: { EditorControlField(rawValue: $0) == nil }) {
            throw Failure(description: "Unsupported profile control: \(unknown)")
        }
        var options: FotufilmEngine.Options
        do {
            options = try document.options(for: stock, nativeFormatID: self.stock.nativeFormatID)
        } catch let failure as EditDocument.Failure {
            throw Failure(description: failure.description)
        }
        if let sceneHighlightStops {
            guard sceneHighlightStops.isFinite, (-64...64).contains(sceneHighlightStops) else {
                throw Failure(description: "Invalid scene measurement.")
            }
            options.sceneHighlightStops = sceneHighlightStops
        }
        return (stock, options)
    }
}
