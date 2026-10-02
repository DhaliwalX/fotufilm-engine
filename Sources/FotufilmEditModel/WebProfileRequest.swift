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
    public let sceneChannelMedians: [Float]?
    public let sceneToneStops: [Float]?
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
        EditDocument(webControls: controls, format: format, medium: medium, filters: filters,
                     filterMetering: filterMetering, sceneKelvin: sceneKelvin)
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
        if let sceneChannelMedians {
            guard sceneChannelMedians.count == 3,
                  sceneChannelMedians.allSatisfy({ $0.isFinite && (-64...64).contains($0) }) else {
                throw Failure(description: "Invalid scene measurement.")
            }
            options.sceneChannelMedians = SIMD3(sceneChannelMedians[0], sceneChannelMedians[1],
                                                sceneChannelMedians[2])
        }
        if let sceneToneStops {
            guard sceneToneStops.count == 3,
                  sceneToneStops.allSatisfy({ $0.isFinite && (-64...64).contains($0) }) else {
                throw Failure(description: "Invalid scene measurement.")
            }
            options.sceneToneStops = SIMD3(sceneToneStops[0], sceneToneStops[1], sceneToneStops[2])
        }
        return (stock, options)
    }
}
