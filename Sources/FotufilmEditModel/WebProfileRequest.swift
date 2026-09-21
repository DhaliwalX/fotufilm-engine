import Foundation
import FotufilmCore

/// A bounded settings request. It never receives image pixels or asks the host for network access.
public struct WebProfileRequest: Decodable {
    public let stock: FilmStockDefinition
    public let width: Int
    public let height: Int
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
        let stock = try self.stock.validated().stock
        var options = FotufilmEngine.Options()
        let formatID = format ?? self.stock.nativeFormatID ?? FilmFormat.houseDefaultID
        guard let format = FilmFormat.preset(id: formatID) else {
            throw Failure(description: "Unknown film format: \(formatID)")
        }
        options.format = format
        if let medium {
            guard let paper = PrintPaper.preset(id: medium) else {
                throw Failure(description: "Unknown output medium: \(medium)")
            }
            options.paper = paper
        }
        if let sceneKelvin {
            guard sceneKelvin.isFinite, (1000...25000).contains(sceneKelvin) else {
                throw Failure(description: "Invalid source illuminant.")
            }
            options.sceneIlluminantKelvin = sceneKelvin
        }
        if let sceneHighlightStops {
            guard sceneHighlightStops.isFinite, (-64...64).contains(sceneHighlightStops) else {
                throw Failure(description: "Invalid scene measurement.")
            }
            options.sceneHighlightStops = sceneHighlightStops
        }
        for (name, input) in controls.sorted(by: { $0.key < $1.key }) {
            guard let field = EditorControlField(rawValue: name),
                  let control = EditorControlCatalogue.control(field),
                  let binding = control.binding else {
                throw Failure(description: "Unsupported profile control: \(name)")
            }
            let value: EditorControlValue
            switch (control.kind, input) {
            case (.slider(let scale), .number(let number)),
                 (.chips(let scale, _), .number(let number)):
                guard scale.admitted.contains(number) else {
                    throw Failure(description: "\(control.title) is outside its supported range.")
                }
                value = .number(number)
            case (.toggle, .flag(let flag)): value = .flag(flag)
            case (.menu(let menu), .choice(let id)):
                guard let choices = menu.fixedChoices,
                      let index = choices.firstIndex(where: { $0.id == id }) else {
                    throw Failure(description: "Unknown \(control.title) choice: \(id)")
                }
                switch binding {
                case .grainMottleShare, .shutterSeconds, .printViewingKelvin:
                    value = .optionalNumber(choices[index].value)
                default: value = .choice(index)
                }
            case (.curve(let curve), .curve(let values)):
                guard values.count == curve.handles.count,
                      values.allSatisfy({ $0.isFinite && curve.range.contains($0) }) else {
                    throw Failure(description: "Invalid \(control.title) control points.")
                }
                value = .curve(values)
            default: throw Failure(description: "Invalid value for \(control.title).")
            }
            binding.apply(value, to: &options)
        }
        return try WebFilmProfile.prepare(stock: stock, options: options,
                                          width: width, height: height)
    }
}
