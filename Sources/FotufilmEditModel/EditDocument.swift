import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// One photograph's edit in the catalogue's own terms: each control by its field id, in the units
/// the catalogue declares, and absent where it rests. Every surface hands the engine one of these,
/// and `options(for:)` is the only place an edit becomes engine options.
public struct EditDocument: Equatable, Sendable {
    public enum Value: Equatable, Sendable {
        case number(Double), flag(Bool), choice(String), choices([String]), curve([Double])
    }

    public struct Failure: Error, CustomStringConvertible, Equatable {
        public let description: String
    }

    public var values: [EditorControlField: Value]

    public init(_ values: [EditorControlField: Value] = [:]) {
        self.values = values
    }

    public subscript(field: EditorControlField) -> Value? {
        get { values[field] }
        set { values[field] = newValue }
    }

    /// Controls resolved here rather than through an engine binding: they choose presets, compose
    /// with each other, or only mean something once the output medium is known.
    static let composed: Set<EditorControlField> = [
        .gauge, .paper, .sceneLight, .sceneLightKelvin, .lensFilterStack, .metering,
        .printerEnabled, .printerLamp, .printerExposure, .printerMagenta, .printerYellow,
    ]

    /// `nativeFormatID` is the gauge the film comes in, used when the edit does not choose one.
    public func options(for stock: FilmStock,
                        nativeFormatID: String? = nil) throws -> FotufilmEngine.Options {
        var options = FotufilmEngine.Options()

        let formatID = try choice(.gauge) ?? nativeFormatID ?? FilmFormat.houseDefaultID
        guard let format = FilmFormat.preset(id: formatID) else {
            throw Failure(description: "Unknown film format: \(formatID)")
        }
        options.format = format
        if let medium = try choice(.paper) {
            guard let paper = PrintPaper.preset(id: medium) else {
                throw Failure(description: "Unknown output medium: \(medium)")
            }
            options.paper = paper
        }
        let paper = (options.paper ?? .default(for: stock)).resolved(for: stock)

        options.sceneIlluminantKelvin = try sourceLight()

        let fitted = EditorLensFilters.resolve(try choices(.lensFilterStack) ?? [])
        guard fitted.unknown.isEmpty else { throw Failure(description: "Unknown lens filter.") }
        let meteringID = try choice(.metering) ?? LensFilterCompensation.throughTheLens.rawValue
        guard let metering = LensFilterCompensation(rawValue: meteringID) else {
            throw Failure(description: "Unknown filter metering choice.")
        }
        options.lensFilters = LensFilterStack(fitted.absorbing, compensation: metering)
        options.diffusionFilter = fitted.diffusion

        let stockControls = Dictionary(uniqueKeysWithValues:
            EditorControlCatalogue.controls(for: stock).map { ($0.field, $0) })
        for (field, input) in values.sorted(by: { $0.key.rawValue < $1.key.rawValue })
        where !Self.composed.contains(field) {
            guard let control = stockControls[field] ?? EditorControlCatalogue.control(field),
                  let binding = control.binding else {
                throw Failure(description: "Unsupported control: \(field.rawValue)")
            }
            let value = try Self.engineValue(input, of: control, stock: stock, paper: paper)
            if field == .push, let stops = value.number,
               !stock.supportsDevelopment(stops: Float(stops)) {
                throw Failure(description:
                    "This film has no development condition at the selected stop value.")
            }
            binding.apply(value, to: &options)
        }

        var printer = PrinterProfile.simulatedTungsten
        if let lamp = try number(.printerLamp) { printer.lampKelvin = Float(lamp) }
        if let stops = try number(.printerExposure) { printer.exposureEV = Float(stops) }
        if let magenta = try number(.printerMagenta) { printer.magenta = Float(magenta) }
        if let yellow = try number(.printerYellow) { printer.yellow = Float(yellow) }
        options.printer = try flag(.printerEnabled) == true ? printer.normalized : nil
        if !paper.isNegative { options.negativeViewing = nil }
        return options
    }

    // MARK: - Reading values

    private func choice(_ field: EditorControlField) throws -> String? {
        switch values[field] {
        case nil: return nil
        case .choice(let id): return id
        default: throw invalid(field)
        }
    }

    private func choices(_ field: EditorControlField) throws -> [String]? {
        switch values[field] {
        case nil: return nil
        case .choices(let ids): return ids
        default: throw invalid(field)
        }
    }

    private func number(_ field: EditorControlField) throws -> Double? {
        switch values[field] {
        case nil: return nil
        case .number(let number) where number.isFinite:
            if let control = EditorControlCatalogue.control(field), case .slider(let scale) = control.kind,
               !scale.admitted.contains(number) {
                throw Failure(description: "\(control.title) is outside its supported range.")
            }
            return number
        default: throw invalid(field)
        }
    }

    private func flag(_ field: EditorControlField) throws -> Bool? {
        switch values[field] {
        case nil: return nil
        case .flag(let on): return on
        default: throw invalid(field)
        }
    }

    private func invalid(_ field: EditorControlField) -> Failure {
        Failure(description: "Invalid value for \(EditorControlCatalogue.control(field)?.title ?? field.rawValue).")
    }

    /// The source light the film is exposed under; nil follows the stock.
    private func sourceLight() throws -> Float? {
        let lights = EditorControlCatalogue.sourceLights
        let id = try choice(.sceneLight) ?? lights[0].id
        guard let selection = lights.firstIndex(where: { $0.id == id }) else {
            throw Failure(description: "Unknown source illuminant: \(id)")
        }
        let custom = try number(.sceneLightKelvin) ?? 6504
        return EditorControlCatalogue.sourceLightKelvin(selection: selection, custom: custom)
            .flatMap { $0 > 0 ? $0 : nil }
    }

    private static func engineValue(_ input: Value, of control: EditorControl,
                                    stock: FilmStock, paper: PrintPaper) throws -> EditorControlValue {
        switch (control.kind, input) {
        case (.slider(let scale), .number(let number)),
             (.chips(let scale, _), .number(let number)):
            guard number.isFinite, scale.admitted.contains(number) else {
                throw Failure(description: "\(control.title) is outside its supported range.")
            }
            return .number(number)
        case (.toggle, .flag(let flag)):
            return .flag(flag)
        case (.menu, .choice(let id)):
            guard let choices = WebProfileCatalogue.choices(control.field, stock: stock, paper: paper),
                  let index = choices.firstIndex(where: { $0.id == id }) else {
                throw Failure(description: "Unknown \(control.title) choice: \(id)")
            }
            switch control.binding {
            case .grainMottleShare, .shutterSeconds, .printViewingKelvin:
                return .optionalNumber(choices[index].value)
            default:
                return .choice(index)
            }
        case (.curve(let curve), .curve(let values)):
            guard values.count == curve.handles.count,
                  values.allSatisfy({ $0.isFinite && curve.range.contains($0) }) else {
                throw Failure(description: "Invalid \(control.title) control points.")
            }
            return .curve(values)
        default:
            throw Failure(description: "Invalid value for \(control.title).")
        }
    }
}

extension EditDocument.Value: Codable {
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let flag = try? value.decode(Bool.self) { self = .flag(flag) }
        else if let number = try? value.decode(Double.self), number.isFinite { self = .number(number) }
        else if let text = try? value.decode(String.self) { self = .choice(text) }
        else if let ids = try? value.decode([String].self) { self = .choices(ids) }
        else { self = .curve(try value.decode([Double].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .number(let number): try value.encode(number)
        case .flag(let flag): try value.encode(flag)
        case .choice(let id): try value.encode(id)
        case .choices(let ids): try value.encode(ids)
        case .curve(let points): try value.encode(points)
        }
    }
}

extension EditDocument: Codable {
    /// `{"exposure": 0.8, "sceneLight": "tungsten3200", …}`, keyed by field id.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: Value].self)
        var values: [EditorControlField: Value] = [:]
        for (name, value) in raw {
            guard let field = EditorControlField(rawValue: name) else {
                throw Failure(description: "Unsupported control: \(name)")
            }
            values[field] = value
        }
        self.init(values)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) }))
    }
}
