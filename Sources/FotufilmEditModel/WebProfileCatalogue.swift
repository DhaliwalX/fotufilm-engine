import Foundation
import FotufilmCore

/// Stock- and medium-dependent choices for native browser profiles.
public enum WebProfileCatalogue {
    static func choices(_ field: EditorControlField, stock: FilmStock?, paper: PrintPaper) -> [EditorMenuChoice]? {
        switch field {
        case .shutter:
            return [EditorMenuChoice(nil, "Instantaneous", id: "off")]
                + (stock.map { EditorControlCatalogue.shutterTimes(for: $0) }
                   ?? EditorControlCatalogue.shutterLadder).map {
                    EditorMenuChoice($0, EditorControlCatalogue.shutterName($0), id: String(Int($0)))
                }
        case .printLight: return EditorControlCatalogue.viewingLights(for: paper)
        case .negativeViewing:
            return NegativeViewing.allCases.enumerated().map {
                EditorMenuChoice(Double($0.offset), $0.element.name, id: $0.element.id)
            }
        default: return EditorControlCatalogue.control(field)?.kind.menu?.fixedChoices
        }
    }

    static func encodedChoice(_ choice: EditorMenuChoice) -> ControlsManifest.Choice {
        .init(id: choice.id, label: choice.label, detail: choice.detail, value: choice.value)
    }

    static var menus: [String: [ControlsManifest.Choice]] {
        var result = Dictionary(uniqueKeysWithValues: [EditorControlField.shutter, .printLight, .negativeViewing].map {
            ($0.rawValue, choices($0, stock: nil, paper: .default)!.map(encodedChoice))
        })
        var seen = Set<String>()
        result["printLight"] = PrintPaper.allCases.flatMap(EditorControlCatalogue.viewingLights)
            .filter { seen.insert($0.id).inserted }.map(encodedChoice)
        return result
    }

    private struct Medium: Encodable {
        let viewingLights: [ControlsManifest.Choice]
        let enlarger, correction, screenConversion, screenGrade, negative: Bool
    }
    private struct Stock: Encodable {
        let available: [String]
        let nativeFormat: String
        let scales: [String: ControlsManifest.Scale]
        let choices: [String: [ControlsManifest.Choice]]
        let media: [String: Medium]
    }

    public static func data(_ definitions: [String: FilmStockDefinition]) throws -> Data {
        var result: [String: Stock] = [:]
        for (id, definition) in definitions {
            let stock = try definition.validated().stock
            let controls = EditorControlCatalogue.controls(for: stock, on: .web)
            let scales = Dictionary(uniqueKeysWithValues: controls.compactMap { control -> (String, ControlsManifest.Scale)? in
                guard [.push, .halationReturn].contains(control.field), let scale = control.kind.scale else { return nil }
                return (control.field.rawValue, ControlsManifest.Scale(scale))
            })
            let media = Dictionary(uniqueKeysWithValues: PrintPaper.choices(for: stock).map { paper in
                (paper.id, Medium(
                    viewingLights: EditorControlCatalogue.viewingLights(for: paper).map(encodedChoice),
                    enlarger: Enlarger.illuminates(stock: stock, paper: paper),
                    correction: !stock.isReversal && !stock.isMonochrome && paper.acceptsPrintCorrection,
                    screenConversion: paper == .screen && !stock.isReflectionPrint,
                    screenGrade: paper == .screen && !stock.isReflectionPrint && !stock.isReversal,
                    negative: paper.isNegative))
            })
            result[id] = Stock(available: controls.map { $0.field.rawValue },
                nativeFormat: definition.nativeFormatID ?? FilmFormat.houseDefaultID,
                scales: scales,
                choices: ["shutter": choices(.shutter, stock: stock, paper: .default)!.map(encodedChoice)],
                media: media)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(result)
    }
}
