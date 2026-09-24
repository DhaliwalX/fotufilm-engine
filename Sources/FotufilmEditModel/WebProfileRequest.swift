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

    public func configured() throws -> (FilmStock, FotufilmEngine.Options) {
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
        let fitted = EditorLensFilters.resolve(filters ?? [])
        guard fitted.unknown.isEmpty else { throw Failure(description: "Unknown lens filter.") }
        guard let metering = LensFilterCompensation(rawValue: filterMetering ?? "throughTheLens") else {
            throw Failure(description: "Unknown filter metering choice.")
        }
        options.lensFilters = LensFilterStack(fitted.absorbing, compensation: metering)
        options.diffusionFilter = fitted.diffusion
        let paper = (options.paper ?? .default(for: stock)).resolved(for: stock)
        let stockControls = Dictionary(uniqueKeysWithValues:
            EditorControlCatalogue.controls(for: stock, on: .web).map { ($0.field, $0) })
        var printer = PrinterProfile.simulatedTungsten
        var printerEnabled = false
        for (name, input) in controls.sorted(by: { $0.key < $1.key }) {
            guard let field = EditorControlField(rawValue: name),
                  let control = stockControls[field] ?? EditorControlCatalogue.control(field),
                  control.binding != nil || [.printerEnabled, .printerLamp, .printerExposure,
                      .printerMagenta, .printerYellow].contains(field) else {
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
            case (.menu, .choice(let id)):
                guard let choices = WebProfileCatalogue.choices(field, stock: stock, paper: paper),
                      let index = choices.firstIndex(where: { $0.id == id }) else {
                    throw Failure(description: "Unknown \(control.title) choice: \(id)")
                }
                switch control.binding {
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
            if field == .push, let stops = value.number, !stock.supportsDevelopment(stops: Float(stops)) {
                throw Failure(description: "This film has no development condition at the selected stop value.")
            }
            switch field {
            case .printerEnabled: printerEnabled = value.flag ?? false
            case .printerLamp: printer.lampKelvin = Float(value.number!)
            case .printerExposure: printer.exposureEV = Float(value.number!)
            case .printerMagenta: printer.magenta = Float(value.number!)
            case .printerYellow: printer.yellow = Float(value.number!)
            default: control.binding?.apply(value, to: &options)
            }
        }
        options.printer = printerEnabled ? printer.normalized : nil
        if !paper.isNegative { options.negativeViewing = nil }
        return (stock, options)
    }
}
