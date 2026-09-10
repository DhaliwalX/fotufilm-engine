import Foundation

#if canImport(FotufilmCore)
import FotufilmCore
#endif

public struct ControlsExport {
    public enum Content {
        case whole(String)
        case regions([String: String])
    }

    public struct Output {
        public let path: URL
        public let content: Content

        public func render(existing: String?) -> String? {
            switch content {
            case .whole(let text):
                return text
            case .regions(let regions):
                guard var text = existing else { return nil }
                for (name, body) in regions {
                    guard let replaced = ControlsExport.replaceRegion(named: name, in: text, with: body) else {
                        return nil
                    }
                    text = replaced
                }
                return text
            }
        }
    }

    public static func outputs(engineRoot: URL, consumerRoot: URL?) -> [Output] {
        var outputs: [Output] = [
            Output(path: engineRoot.appendingPathComponent("tools/controls/controls.json"),
                   content: .whole(ControlsManifest.encoded())),
            Output(path: engineRoot.appendingPathComponent("resolve/Generated/FotufilmBridgeSlots.h"),
                   content: .whole(bridgeSlotsHeader())),
            Output(path: engineRoot.appendingPathComponent("resolve/Generated/FotufilmBridgeSlots.swift"),
                   content: .whole(bridgeSlotsSwift())),
            Output(path: engineRoot.appendingPathComponent("finalcut/Generated/FotufilmParameterIDs.h"),
                   content: .whole(fxplugIDsHeader())),
            Output(path: engineRoot.appendingPathComponent("finalcut/Generated/fxplug-parameters.json"),
                   content: .whole(fxplugParametersJSON())),
            Output(path: engineRoot.appendingPathComponent("finalcut/MotionTemplate/Fotufilm.moef"),
                   content: .whole(motionTemplate())),
            Output(path: engineRoot.appendingPathComponent("web/src/generated/controls.js"),
                   content: .whole(webControls())),
            Output(path: engineRoot.appendingPathComponent("web/engine/generated/fotufilm_wasm_controls.inc"),
                   content: .whole(wasmControls())),
            Output(path: engineRoot.appendingPathComponent("docs/documentation.html"),
                   content: .regions(documentationRegions())),
            Output(path: engineRoot.appendingPathComponent("resolve/README.md"),
                   content: .regions(["resolve-controls": resolveReadmeTable()])),
        ]
        if let consumerRoot {
            let kotlin = consumerRoot.appendingPathComponent(
                "android/app/src/main/kotlin/com/muastudio/fotufilm/engine")
            outputs += [
                Output(path: kotlin.appendingPathComponent("EditState.kt"), content: .whole(kotlinEditState())),
                Output(path: kotlin.appendingPathComponent("EditorControls.kt"), content: .whole(kotlinControls())),
                Output(path: kotlin.appendingPathComponent("EditStateJson.kt"), content: .whole(kotlinJson())),
                Output(path: kotlin.appendingPathComponent("ControlTransforms.kt"),
                       content: .whole(kotlinTransforms())),
                Output(path: consumerRoot.appendingPathComponent("docs/documentation.html"),
                       content: .regions(documentationRegions())),
            ]
        }
        return outputs
    }

    public static func replaceRegion(named name: String, in text: String, with body: String) -> String? {
        let open = "<tbody data-controls=\"\(name)\">"
        guard let start = text.range(of: open),
              let end = text.range(of: "</tbody>", range: start.upperBound..<text.endIndex) else { return nil }
        let indent = String(text[..<start.lowerBound].reversed().prefix { $0 == " " }.reversed())
        let rows = body.split(separator: "\n").map { indent + "  " + $0 }.joined(separator: "\n")
        return text.replacingCharacters(in: start.upperBound..<end.lowerBound, with: "\n" + rows + "\n" + indent)
    }

    static var controls: [EditorControl] { EditorControlCatalogue.all }

    static func hostEntries(on surface: EditorSurface) -> [(group: HostGroup, order: Int, control: EditorControl?, auxiliary: HostAuxiliary?)] {
        var entries: [(HostGroup, Int, EditorControl?, HostAuxiliary?)] = []
        for (control, host) in EditorControlCatalogue.hostParameters(on: surface) {
            entries.append((host.group, host.order, control, nil))
        }
        for auxiliary in EditorControlCatalogue.auxiliaries where auxiliary.surfaces.contains(surface) {
            guard let group = auxiliary.group else { continue }
            if surface == .finalcut, auxiliary.fxplugID == nil { continue }
            entries.append((group, auxiliary.order, nil, auxiliary))
        }
        return entries.sorted { lhs, rhs in
            let li = EditorControlCatalogue.hostGroupOrder.firstIndex(of: lhs.0)!
            let ri = EditorControlCatalogue.hostGroupOrder.firstIndex(of: rhs.0)!
            return li != ri ? li < ri : lhs.1 < rhs.1
        }.map { ($0.0, $0.1, $0.2, $0.3) }
    }

    static func topLevelAuxiliaries(on surface: EditorSurface) -> [HostAuxiliary] {
        EditorControlCatalogue.auxiliaries
            .filter { $0.group == nil && $0.surfaces.contains(surface) }
            .filter { surface != .finalcut || $0.fxplugID != nil }
            .sorted { $0.order < $1.order }
    }


    static func bridgeSlotsHeader() -> String {
        var lines = ["#ifndef FOTUFILM_BRIDGE_SLOTS_H", "#define FOTUFILM_BRIDGE_SLOTS_H", "", "enum {"]
        for entry in EditorControlCatalogue.bridgeSlots {
            lines.append("    FOTUFILM_BRIDGE_\(entry.symbol) = \(entry.slot),")
        }
        lines.append("    FOTUFILM_BRIDGE_PARAMETER_COUNT = \(EditorControlCatalogue.bridgeSlotCount),")
        lines.append("};")
        lines.append("")
        lines.append("#endif")
        return lines.joined(separator: "\n") + "\n"
    }

    static func bridgeSlotsSwift() -> String {
        var lines = ["enum BridgeSlot {"]
        for entry in EditorControlCatalogue.bridgeSlots {
            lines.append("    static let \(lowerCamel(entry.symbol)) = \(entry.slot)")
        }
        lines.append("    static let count = \(EditorControlCatalogue.bridgeSlotCount)")
        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }

    static func lowerCamel(_ symbol: String) -> String {
        let parts = symbol.lowercased().split(separator: "_")
        return parts.enumerated().map { index, part in
            index == 0 ? String(part) : part.prefix(1).uppercased() + part.dropFirst()
        }.joined()
    }


    struct FxplugEntry {
        let id: Int
        let symbol: String
        let label: String
        let groupID: Int?
        let kind: String
        let value: Double
        let published: Bool
    }

    static func fxplugEntries() -> [FxplugEntry] {
        var entries: [FxplugEntry] = []
        for auxiliary in topLevelAuxiliaries(on: .finalcut) where auxiliary.order < 100 {
            entries.append(FxplugEntry(id: auxiliary.fxplugID!, symbol: auxiliary.fxplugSymbol!,
                                       label: auxiliary.label, groupID: nil, kind: "label", value: 0,
                                       published: true))
        }
        for entry in hostEntries(on: .finalcut) {
            let groupID = entry.group.topLevel.fxplugID
            if let control = entry.control, let host = control.host, let id = host.fxplugID {
                var value = 0.0
                var kind = host.kind.typeName
                switch host.kind {
                case .double(_, _, let resting, _, _): value = resting
                case .integer(_, _, let resting): value = Double(resting)
                case .boolean(let resting): value = resting ? 1 : 0
                case .choice(let menu, let resting):
                    kind = "choice"
                    value = Double(resting)
                    if resting < 0, case .dynamic(let dynamic) = menu {
                        value = Double(dynamicMenuCount(dynamic))
                    }
                }
                entries.append(FxplugEntry(id: id, symbol: host.fxplugSymbol!, label: host.label, groupID: groupID,
                                           kind: kind, value: value, published: true))
            } else if let auxiliary = entry.auxiliary, let id = auxiliary.fxplugID {
                if case .textureToggles = auxiliary.kind {
                    let published = Set(publishedLabels(excludingTextureToggles: true))
                    for (index, stage) in TextureStages.ordered.enumerated() {
                        let label = published.contains(stage.name) ? stage.name + " Stage" : stage.name
                        entries.append(FxplugEntry(id: id + index, symbol: "", label: label, groupID: groupID,
                                                   kind: "boolean", value: 1, published: true))
                    }
                } else {
                    entries.append(FxplugEntry(id: id, symbol: auxiliary.fxplugSymbol!, label: auxiliary.label,
                                               groupID: groupID, kind: "hiddenString", value: 0, published: false))
                }
            }
        }
        for auxiliary in topLevelAuxiliaries(on: .finalcut) where auxiliary.order >= 100 {
            entries.append(FxplugEntry(id: auxiliary.fxplugID!, symbol: auxiliary.fxplugSymbol!,
                                       label: auxiliary.label, groupID: nil, kind: "hiddenString", value: 0,
                                       published: false))
        }
        return entries
    }

    static func publishedLabels(excludingTextureToggles: Bool) -> [String] {
        EditorControlCatalogue.hostParameters(on: .finalcut).filter { $0.host.fxplugID != nil }.map(\.host.label)
    }

    static func dynamicMenuCount(_ menu: EditorDynamicMenu) -> Int {
        switch menu {
        case .gauges: return FilmFormat.presets.count
        case .papers: return PrintPaper.allCases.count
        default: return 0
        }
    }

    static func fxplugIDsHeader() -> String {
        var lines = ["#ifndef FOTUFILM_PARAMETER_IDS_H", "#define FOTUFILM_PARAMETER_IDS_H", "", "enum {"]
        var seen: Set<Int> = []
        for entry in fxplugEntries() where !entry.symbol.isEmpty && !seen.contains(entry.id) {
            seen.insert(entry.id)
            lines.append("    \(entry.symbol) = \(entry.id),")
        }
        for group in EditorControlCatalogue.hostGroupOrder {
            guard let id = group.fxplugID else { continue }
            lines.append("    kFotufilmParam_\(group.rawValue.prefix(1).uppercased() + group.rawValue.dropFirst())Group = \(id),")
        }
        for id in EditorControlCatalogue.retiredFxplugIDs {
            lines.append("    kFotufilmParam_Retired\(id) = \(id),")
        }
        lines.append("    kFotufilmParam_TextureStageFirst = \(EditorControlCatalogue.fxplugTextureStageIDs.lowerBound),")
        lines.append("    kFotufilmParam_TextureStageLimit = \(EditorControlCatalogue.fxplugTextureStageIDs.upperBound + 1),")
        lines.append("};")
        lines.append("")
        lines.append("#endif")
        return lines.joined(separator: "\n") + "\n"
    }

    static func fxplugParametersJSON() -> String {
        let entries = fxplugEntries()
        var paths: [String: String] = [:]
        var publicIDs: [Int] = []
        var persistedOnly: [Int] = []
        for entry in entries {
            if entry.published {
                paths["\(entry.id)"] = entry.groupID.map { "\($0)/\(entry.id)" } ?? "\(entry.id)"
                publicIDs.append(entry.id)
            } else {
                persistedOnly.append(entry.id)
            }
        }
        publicIDs.append(10001)
        paths["10001"] = "10001"
        let object: [String: Any] = [
            "public": publicIDs.sorted(),
            "persistedOnly": persistedOnly.sorted(),
            "paths": paths,
            "textureStageFirst": EditorControlCatalogue.fxplugTextureStageIDs.lowerBound,
            "textureStageLimit": EditorControlCatalogue.fxplugTextureStageIDs.upperBound + 1,
            "textureStageCount": TextureStages.ordered.count,
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    static func xmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func motionNumber(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    static func motionTemplate() -> String {
        let entries = fxplugEntries()
        var publish: [String] = []
        for entry in entries where entry.published {
            let path = entry.groupID.map { "./\($0)/\(entry.id)" } ?? "./\(entry.id)"
            publish.append("      <target object=\"9001001\" channel=\"\(path)\" name=\"\(xmlEscape(entry.label))\"/>")
        }
        publish.append("      <target object=\"9001001\" channel=\"./10001\" name=\"Mix\"/>")

        var filter: [String] = []
        func parameterLine(_ entry: FxplugEntry, indent: String) -> String {
            let flags: String
            switch entry.kind {
            case "double": flags = "12901679120"
            case "integer": flags = "12901679121"
            case "choice", "menu": flags = "12901744656"
            default: flags = "12901679104"
            }
            let value = entry.kind == "hiddenString" || entry.kind == "label" ? "" : motionNumber(entry.value)
            return "\(indent)<parameter name=\"\(xmlEscape(entry.label))\" id=\"\(entry.id)\" flags=\"\(flags)\" default=\"\(value)\" value=\"\(value)\"/>"
        }
        for entry in entries where entry.groupID == nil && entry.published {
            filter.append(parameterLine(entry, indent: "          "))
        }
        for group in EditorControlCatalogue.hostGroupOrder where group.parent == nil {
            guard let groupID = group.fxplugID else { continue }
            let members = entries.filter { $0.groupID == groupID }
            guard !members.isEmpty else { continue }
            filter.append("          <parameter name=\"\(xmlEscape(group.label))\" id=\"\(groupID)\" flags=\"8594198560\">")
            filter.append("            <foldFlags>\(group.fxplugCollapsed ? 15 : 4)</foldFlags>")
            for entry in members { filter.append(parameterLine(entry, indent: "            ")) }
            filter.append("          </parameter>")
        }
        for entry in entries where entry.groupID == nil && !entry.published {
            filter.append(parameterLine(entry, indent: "          "))
        }
        filter.append("          <parameter name=\"Mix\" id=\"10001\" flags=\"12901679104\" default=\"1\" value=\"1\"/>")
        filter.append("          <parameter name=\"Flip\" id=\"10002\" flags=\"12905938976\" default=\"0\" value=\"0\"/>")
        filter.append("          <parameter name=\"Input Points\" id=\"10003\" flags=\"12905938976\" default=\"1\" value=\"1\"/>")

        return MotionTemplateSkeleton.text
            .replacingOccurrences(of: "@PUBLISH@", with: publish.joined(separator: "\n"))
            .replacingOccurrences(of: "@FILTER@", with: filter.joined(separator: "\n"))
    }


    static func webControls() -> String {
        var entries: [String] = []
        var index = 0
        for control in controls where control.offered(on: .web) {
            guard let web = control.web, let scale = control.kind.scale else { continue }
            let unit: String
            switch scale.unit {
            case .stops, .stopsFromOff: unit = "ev"
            case .multiplier: unit = "×"
            case .percent: unit = "%"
            default: unit = ""
            }
            let signed = scale.unit == .signed || scale.unit == .stops
            let step = scale.unit == .stops ? 0.25 : 0.05
            let kind: String
            switch web {
            case .configSlot(_, let transform): kind = transform.rawValue
            case .grainScale: kind = "grain"
            }
            entries.append("  { key: '\(control.field.rawValue)', index: \(index), label: '\(control.title)', "
                           + "unit: '\(unit)', min: \(scale.range.lowerBound), max: \(scale.range.upperBound), "
                           + "step: \(step), def: \(scale.neutral), signed: \(signed), kind: '\(kind)' },")
            index += 1
        }
        return "export const CONTROLS = [\n" + entries.joined(separator: "\n") + "\n]\n"
    }

    static func wasmControls() -> String {
        var slots: [String] = []
        for control in controls where control.offered(on: .web) {
            guard let web = control.web else { continue }
            switch web {
            case .configSlot(let slot, _): slots.append("    \(slot),")
            case .grainScale: slots.append("    -1,")
            }
        }
        return "static const int32_t kFotufilmWasmControlSlots[] = {\n" + slots.joined(separator: "\n")
            + "\n};\nstatic const int32_t kFotufilmWasmControlCount = \(slots.count);\n"
    }


    static func htmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func documentedDefault(_ control: EditorControl) -> String {
        switch control.kind {
        case .slider(let scale), .chips(let scale, _):
            return scale.unit.format(scale.neutral).isEmpty ? String(scale.neutral) : scale.unit.format(scale.neutral)
        case .toggle(let on):
            return on ? "On" : "Off"
        case .curve:
            return "Flat"
        case .menu(.fixed(let choices)):
            return choices.first?.label ?? ""
        case .menu(.dynamic(let menu)):
            switch menu {
            case .stocks: return "Starting stock"
            case .gauges: return "Match the Film"
            case .papers: return PrintPaper.editorDefault.name
            case .viewingLights: return "Medium reference"
            case .shutterTimes: return "Off"
            case .lensProfiles: return "Matched"
            case .negativeViewings: return NegativeViewing.allCases.first?.name ?? ""
            case .meterings: return LensFilterCompensation.throughTheLens.label
            case .lensFilters, .diffusionFamilies: return "None"
            case .diffusionGrades: return DiffusionFilter.Grade.quarter.rawValue
            case .stages: return PipelineStage.full.name
            case .colourSpaces: return "Auto (from host)"
            case .textureStages: return "All"
            case .pushConditions: return "Reference"
            }
        case .takeover:
            return ""
        }
    }

    static func appRows(for group: EditorControlGroup) -> String {
        var rows: [String] = []
        for control in controls where control.group == group
            && (control.offered(on: .app) || control.offered(on: .desktop)) {
            let text = control.documentation ?? control.detail
            rows.append("<tr><td>\(htmlEscape(control.title))</td><td>\(htmlEscape(text))</td>"
                        + "<td>\(htmlEscape(documentedDefault(control)))</td></tr>")
        }
        return rows.joined(separator: "\n")
    }

    static func hostRows() -> String {
        var rows: [String] = []
        for entry in hostEntries(on: .resolve) {
            guard let control = entry.control, let host = control.host else { continue }
            let hint = host.hint.replacingOccurrences(of: "\n\n", with: " ")
            let label = control.kind.curve != nil ? "Return Spectrum" : host.label
            rows.append("<tr><td>\(htmlEscape(label))</td><td>\(htmlEscape(hint))</td></tr>")
        }
        return rows.joined(separator: "\n")
    }

    static func documentationRegions() -> [String: String] {
        var regions: [String: String] = [:]
        for group in EditorControlGroup.allCases where group != .pipeline {
            regions[group.rawValue] = appRows(for: group)
        }
        regions["resolve"] = hostRows()
        return regions
    }

    static func resolveReadmeTable() -> String {
        var rows: [String] = []
        for entry in hostEntries(on: .resolve) {
            guard let control = entry.control, let host = control.host else { continue }
            let label = control.kind.curve != nil ? "Return Spectrum" : host.label
            let sentence = host.hint.split(separator: ".").first.map { String($0) + "." } ?? host.hint
            rows.append("<tr><td>\(htmlEscape(label))</td><td>\(htmlEscape(host.group.topLevel.label))</td>"
                        + "<td>\(htmlEscape(sentence))</td></tr>")
        }
        return rows.joined(separator: "\n")
    }


    struct KotlinField {
        let name: String
        let type: String
        let defaultValue: String
        let control: EditorControl?
    }

    static func kotlinKeyedFields() -> [KotlinField] {
        controls.compactMap { control in
            guard case .edit = control.scope, let key = control.persistence.key else { return nil }
            switch control.kind {
            case .slider(let scale), .chips(let scale, _):
                let stored = control.persistence.encoding!.stored(fromDisplayed: scale.neutral)
                return KotlinField(name: key, type: "Double", defaultValue: kotlinDouble(stored), control: control)
            case .toggle(let on):
                return KotlinField(name: key, type: "Boolean", defaultValue: on ? "true" : "false", control: control)
            case .curve(let curve):
                let values = curve.restingValues.map(kotlinDouble).joined(separator: ", ")
                return KotlinField(name: key, type: "List<Double>", defaultValue: "listOf(\(values))", control: control)
            case .menu, .takeover:
                return nil
            }
        }
    }

    static let kotlinBespokeFields: [KotlinField] = [
        KotlinField(name: "stockID", type: "String", defaultValue: "StockLibrary.defaultID", control: nil),
        KotlinField(name: "chosenFormatID", type: "String?", defaultValue: "null", control: nil),
        KotlinField(name: "grainMottleShare", type: "Double?", defaultValue: "null", control: nil),
        KotlinField(name: "couplerGapReach", type: "List<Double>", defaultValue: "listOf(1.0, 1.0)", control: nil),
        KotlinField(name: "shutterSeconds", type: "Double?", defaultValue: "null", control: nil),
        KotlinField(name: "printLightKelvin", type: "Double?", defaultValue: "null", control: nil),
        KotlinField(name: "paper", type: "String", defaultValue: "\"\(PrintPaper.editorDefault.id)\"", control: nil),
        KotlinField(name: "paperFollowsStock", type: "Boolean", defaultValue: "false", control: nil),
        KotlinField(name: "enlarger", type: "String", defaultValue: "\"\(Enlarger.default.id)\"", control: nil),
        KotlinField(name: "seed", type: "Long", defaultValue: "0x46494C4DL", control: nil),
        KotlinField(name: "rotation", type: "Int", defaultValue: "0", control: nil),
        KotlinField(name: "crop", type: "Rect?", defaultValue: "null", control: nil),
    ]

    static func kotlinDouble(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 { return String(format: "%.1f", value) }
        return String(value)
    }

    static func kotlinEditState() -> String {
        let fields = kotlinKeyedFields() + kotlinBespokeFields
        var lines = [
            "package com.muastudio.fotufilm.engine",
            "",
            "import androidx.compose.runtime.Immutable",
            "import androidx.compose.ui.geometry.Rect",
            "",
            "object WhiteBalance {",
            "    const val NEUTRAL_KELVIN = \(WhiteBalance.neutralKelvin)f",
            "",
            "    fun kelvinToMired(kelvin: Float): Float = 1_000_000f / kelvin.coerceAtLeast(1f)",
            "    fun miredToKelvin(mired: Float): Float = 1_000_000f / mired.coerceAtLeast(1f)",
            "}",
            "",
            "@Immutable",
            "data class EditState(",
        ]
        for field in fields {
            lines.append("    val \(field.name): \(field.type) = \(field.defaultValue),")
        }
        lines += [
            ") {",
            "    val hasGeometryEdits: Boolean",
            "        get() = rotation != 0 || flipH || straighten != 0.0 || perspectiveV != 0.0 ||",
            "            perspectiveH != 0.0 || crop != null",
            "",
            "    val formatID: String",
            "        get() = chosenFormatID ?: FilmFormat.nativeID(stockID)",
            "",
            "    val format: FilmFormat",
            "        get() = FilmFormat.preset(formatID) ?: FilmFormat.still35",
            "",
            "    val followsStockGauge: Boolean get() = chosenFormatID == null",
            "",
            "    val stock: StockPreset? get() = StockLibrary.stock(stockID)",
            "",
            "    val temperatureKelvin: Double",
            "        get() = WhiteBalance.miredToKelvin(temperatureMired.toFloat()).toDouble()",
            "",
            "    val couplerReach: Double get() = couplerGapReach.firstOrNull() ?: 1.0",
            "",
            "    fun selectingFormat(id: String) = copy(chosenFormatID = id)",
            "",
            "    fun followingStockGauge() = copy(chosenFormatID = null)",
            "",
            "    fun resettingGeometry() = copy(rotation = 0, flipH = false, straighten = 0.0,",
            "        perspectiveV = 0.0, perspectiveH = 0.0, crop = null)",
            "",
            "    fun rerollingGrain() = copy(seed = java.util.Random().nextLong())",
            "",
            "    val developSignature: Int",
            "        get() = listOf<Any?>(",
        ]
        let signature = fields.filter { $0.name != "crop" && $0.name != "rotation" && $0.name != "straighten" }
        lines.append("            " + signature.map(\.name).joined(separator: ", ") + ",")
        lines += [
            "        ).hashCode()",
            "",
            "    companion object {",
            "        val defaults = EditState()",
            "    }",
            "}",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    static func kotlinConstant(_ field: EditorControlField) -> String {
        var out = ""
        for character in field.rawValue {
            if character.isUppercase { out.append("_") }
            out.append(character.uppercased())
        }
        return out
    }

    static func kotlinString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$") + "\""
    }

    static func kotlinControls() -> String {
        var lines = [
            "package com.muastudio.fotufilm.engine",
            "",
            "enum class ControlGroup(val title: String) {",
        ]
        for group in EditorControlGroup.allCases {
            lines.append("    \(group.rawValue.uppercased())(\(kotlinString(group.title))),")
        }
        lines += ["}", "", "enum class ControlSection(val title: String, val group: ControlGroup) {"]
        for section in EditorControlSection.allCases {
            lines.append("    \(upperSnake(section.rawValue))(\(kotlinString(section.title)), ControlGroup.\(section.group.rawValue.uppercased())),")
        }
        lines += ["}", "", "enum class ControlUnit {"]
        for unit in [EditorControlUnit.multiplier, .stops, .stopsFromOff, .signed, .percent, .years, .seconds,
                     .degrees, .kelvin, .micrometers, .millimetres, .none] {
            lines.append("    \(upperSnake(unit.rawValue)),")
        }
        lines += ["}", "", "enum class ControlAvailability {"]
        for availability in [EditorControlAvailability.always, .film, .colourNegative, .printStage,
                             .statedReciprocity, .couplerGeometry, .interlayerInhibition, .measuredDevelopment] {
            lines.append("    \(upperSnake(availability.rawValue)),")
        }
        lines += ["}", "", "enum class StoredEncoding {"]
        for encoding in [StoredEncoding.same, .miredFromWarmth, .duvFromPadTint, .scaleFromStops] {
            lines.append("    \(upperSnake(encoding.rawValue)),")
        }
        lines += ["}", "", "enum class ControlField {"]
        for control in controls { lines.append("    \(kotlinConstant(control.field)),") }
        lines += [
            "}",
            "",
            "data class MenuChoice(val id: String, val label: String, val detail: String, val value: Double?)",
            "",
            "sealed class ControlKind {",
            "    data class Slider(",
            "        val min: Double, val max: Double, val neutral: Double, val unit: ControlUnit,",
            "        val stops: List<Double>, val admittedMin: Double, val admittedMax: Double,",
            "    ) : ControlKind()",
            "    data class Chips(val slider: Slider, val choices: List<MenuChoice>) : ControlKind()",
            "    data class Toggle(val restingOn: Boolean) : ControlKind()",
            "    data class Menu(val choices: List<MenuChoice>?, val dynamic: String?) : ControlKind()",
            "    data class Curve(",
            "        val handles: List<Double>, val domainMin: Double, val domainMax: Double,",
            "        val min: Double, val max: Double, val neutral: Double, val unit: ControlUnit,",
            "    ) : ControlKind()",
            "    object Takeover : ControlKind()",
            "}",
            "",
            "data class ControlDescriptor(",
            "    val field: ControlField,",
            "    val title: String,",
            "    val detail: String,",
            "    val section: ControlSection,",
            "    val kind: ControlKind,",
            "    val availability: ControlAvailability,",
            "    val foldsUnder: ControlField?,",
            "    val persistedKey: String?,",
            "    val encoding: StoredEncoding,",
            "    val offeredOnAndroid: Boolean,",
            ") {",
            "    val group: ControlGroup get() = section.group",
            "}",
            "",
            "object EditorControls {",
            "    val all: List<ControlDescriptor> = listOf(",
        ]
        for control in controls {
            let kind: String
            switch control.kind {
            case .slider(let scale):
                kind = kotlinSlider(scale)
            case .chips(let scale, let choices):
                let list = choices.map {
                    "MenuChoice(\(kotlinString(EditorMenuChoice.slug($0.label))), \(kotlinString($0.label)), \"\", \(kotlinDouble($0.value)))"
                }.joined(separator: ", ")
                kind = "ControlKind.Chips(\(kotlinSlider(scale)), listOf(\(list)))"
            case .toggle(let on):
                kind = "ControlKind.Toggle(\(on ? "true" : "false"))"
            case .menu(.fixed(let choices)):
                let list = choices.map {
                    "MenuChoice(\(kotlinString($0.id)), \(kotlinString($0.label)), \(kotlinString($0.detail)), \($0.value.map(kotlinDouble) ?? "null"))"
                }.joined(separator: ", ")
                kind = "ControlKind.Menu(listOf(\(list)), null)"
            case .menu(.dynamic(let menu)):
                kind = "ControlKind.Menu(null, \(kotlinString(menu.rawValue)))"
            case .curve(let curve):
                kind = "ControlKind.Curve(listOf(\(curve.handles.map(kotlinDouble).joined(separator: ", "))), "
                    + "\(kotlinDouble(curve.domain.lowerBound)), \(kotlinDouble(curve.domain.upperBound)), "
                    + "\(kotlinDouble(curve.range.lowerBound)), \(kotlinDouble(curve.range.upperBound)), "
                    + "\(kotlinDouble(curve.neutral)), ControlUnit.\(upperSnake(curve.unit.rawValue)))"
            case .takeover:
                kind = "ControlKind.Takeover"
            }
            lines.append("        ControlDescriptor(")
            lines.append("            ControlField.\(kotlinConstant(control.field)), \(kotlinString(control.title)), \(kotlinString(control.detail)),")
            lines.append("            ControlSection.\(upperSnake(control.section.rawValue)), \(kind),")
            lines.append("            ControlAvailability.\(upperSnake(control.availability.rawValue)), "
                         + "\(control.foldsUnder.map { "ControlField." + kotlinConstant($0) } ?? "null"), "
                         + "\(control.persistence.key.map(kotlinString) ?? "null"), "
                         + "StoredEncoding.\(upperSnake((control.persistence.encoding ?? .same).rawValue)), "
                         + "\(control.offered(on: .android) ? "true" : "false"),")
            lines.append("        ),")
        }
        lines += [
            "    )",
            "",
            "    fun control(field: ControlField): ControlDescriptor = all.first { it.field == field }",
            "",
            "    fun offered(stock: StockPreset?): List<ControlDescriptor> =",
            "        all.filter { it.offeredOnAndroid && admits(it.availability, stock) }",
            "",
            "    fun offered(section: ControlSection, stock: StockPreset?): List<ControlDescriptor> =",
            "        offered(stock).filter { it.section == section }",
            "",
            "    fun admits(availability: ControlAvailability, stock: StockPreset?): Boolean = when (availability) {",
            "        ControlAvailability.ALWAYS -> true",
            "        ControlAvailability.FILM -> stock != null",
            "        ControlAvailability.COLOUR_NEGATIVE -> stock != null && !stock.isMonochrome && !stock.isReversal",
            "        ControlAvailability.PRINT_STAGE -> stock != null && !stock.isReversal",
            "        ControlAvailability.STATED_RECIPROCITY -> false",
            "        ControlAvailability.COUPLER_GEOMETRY -> stock != null && !stock.isMonochrome",
            "        ControlAvailability.INTERLAYER_INHIBITION -> stock != null && !stock.isMonochrome",
            "        ControlAvailability.MEASURED_DEVELOPMENT -> false",
            "    }",
            "}",
            "",
            "fun EditState.displayed(field: ControlField): Double? = when (field) {",
        ]
        for control in controls {
            guard let key = control.persistence.key, control.kind.scale != nil else { continue }
            let encoding = control.persistence.encoding ?? .same
            lines.append("    ControlField.\(kotlinConstant(control.field)) -> ControlTransforms.displayed(\(key), StoredEncoding.\(upperSnake(encoding.rawValue)))")
        }
        lines.append("    ControlField.COUPLER_REACH -> couplerReach")
        lines += ["    else -> null", "}", "", "fun EditState.flag(field: ControlField): Boolean? = when (field) {"]
        for control in controls {
            guard let key = control.persistence.key, case .toggle = control.kind else { continue }
            lines.append("    ControlField.\(kotlinConstant(control.field)) -> \(key)")
        }
        lines += ["    else -> null", "}", "", "fun EditState.curve(field: ControlField): List<Double>? = when (field) {"]
        for control in controls {
            guard let key = control.persistence.key, case .curve = control.kind else { continue }
            lines.append("    ControlField.\(kotlinConstant(control.field)) -> \(key)")
        }
        lines += ["    else -> null", "}", "", "fun EditState.withDisplayed(field: ControlField, value: Double): EditState = when (field) {"]
        for control in controls {
            guard let key = control.persistence.key, control.kind.scale != nil else { continue }
            let encoding = control.persistence.encoding ?? .same
            lines.append("    ControlField.\(kotlinConstant(control.field)) -> copy(\(key) = ControlTransforms.stored(value, StoredEncoding.\(upperSnake(encoding.rawValue))))")
        }
        lines.append("    ControlField.COUPLER_REACH -> copy(couplerGapReach = listOf(value, value))")
        lines += ["    else -> this", "}", "", "fun EditState.withFlag(field: ControlField, value: Boolean): EditState = when (field) {"]
        for control in controls {
            guard let key = control.persistence.key, case .toggle = control.kind else { continue }
            lines.append("    ControlField.\(kotlinConstant(control.field)) -> copy(\(key) = value)")
        }
        lines += ["    else -> this", "}", "", "fun EditState.withCurve(field: ControlField, value: List<Double>): EditState = when (field) {"]
        for control in controls {
            guard let key = control.persistence.key, case .curve = control.kind else { continue }
            lines.append("    ControlField.\(kotlinConstant(control.field)) -> copy(\(key) = value)")
        }
        lines += ["    else -> this", "}", ""]
        lines += [
            "fun EditState.isMoved(descriptor: ControlDescriptor): Boolean = when (val kind = descriptor.kind) {",
            "    is ControlKind.Slider -> displayed(descriptor.field)?.let { kotlin.math.abs(it - kind.neutral) > (kind.max - kind.min) * 1e-4 } ?: false",
            "    is ControlKind.Chips -> displayed(descriptor.field)?.let { kotlin.math.abs(it - kind.slider.neutral) > (kind.slider.max - kind.slider.min) * 1e-4 } ?: false",
            "    is ControlKind.Toggle -> flag(descriptor.field)?.let { it != kind.restingOn } ?: false",
            "    is ControlKind.Curve -> curve(descriptor.field)?.any { kotlin.math.abs(it - kind.neutral) > (kind.max - kind.min) * 1e-4 } ?: false",
            "    else -> false",
            "}",
            "",
            "fun EditState.resetting(descriptor: ControlDescriptor): EditState = when (val kind = descriptor.kind) {",
            "    is ControlKind.Slider -> withDisplayed(descriptor.field, kind.neutral)",
            "    is ControlKind.Chips -> withDisplayed(descriptor.field, kind.slider.neutral)",
            "    is ControlKind.Toggle -> withFlag(descriptor.field, kind.restingOn)",
            "    is ControlKind.Curve -> withCurve(descriptor.field, kind.handles.map { kind.neutral })",
            "    else -> this",
            "}",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    static func kotlinSlider(_ scale: EditorControlScale) -> String {
        "ControlKind.Slider(\(kotlinDouble(scale.range.lowerBound)), \(kotlinDouble(scale.range.upperBound)), "
            + "\(kotlinDouble(scale.neutral)), ControlUnit.\(upperSnake(scale.unit.rawValue)), "
            + "listOf(\(scale.stops.map(kotlinDouble).joined(separator: ", "))), "
            + "\(kotlinDouble(scale.admitted.lowerBound)), \(kotlinDouble(scale.admitted.upperBound)))"
    }

    static func upperSnake(_ camel: String) -> String {
        var out = ""
        for character in camel {
            if character.isUppercase { out.append("_") }
            out.append(character.uppercased())
        }
        return out
    }

    static func kotlinJson() -> String {
        var lines = [
            "package com.muastudio.fotufilm.engine",
            "",
            "import org.json.JSONArray",
            "import org.json.JSONObject",
            "",
            "object EditStateJson {",
            "    fun encode(state: EditState): JSONObject {",
            "        val json = JSONObject()",
        ]
        for field in kotlinKeyedFields() {
            switch field.type {
            case "List<Double>":
                lines.append("        json.put(\(kotlinString(field.name)), JSONArray(state.\(field.name)))")
            default:
                lines.append("        json.put(\(kotlinString(field.name)), state.\(field.name))")
            }
        }
        lines += [
            "        json.put(\"stockID\", state.stockID)",
            "        state.chosenFormatID?.let { json.put(\"chosenFormatID\", it) }",
            "        state.grainMottleShare?.let { json.put(\"grainMottleShare\", it) }",
            "        json.put(\"couplerGapReach\", JSONArray(state.couplerGapReach))",
            "        state.shutterSeconds?.let { json.put(\"shutterSeconds\", it) }",
            "        state.printLightKelvin?.let { json.put(\"printLightKelvin\", it) }",
            "        json.put(\"paper\", state.paper)",
            "        json.put(\"paperFollowsStock\", state.paperFollowsStock)",
            "        json.put(\"enlarger\", state.enlarger)",
            "        json.put(\"seed\", state.seed)",
            "        json.put(\"rotation\", state.rotation)",
            "        state.crop?.let {",
            "            json.put(\"crop\", JSONArray(listOf(JSONArray(listOf(it.left, it.top)), JSONArray(listOf(it.width, it.height)))))",
            "        }",
            "        return json",
            "    }",
            "",
            "    fun decode(json: JSONObject): EditState {",
            "        var state = EditState()",
        ]
        for field in kotlinKeyedFields() {
            let name = field.name
            switch field.type {
            case "Double":
                lines.append("        if (json.has(\(kotlinString(name)))) state = state.copy(\(name) = json.getDouble(\(kotlinString(name))))")
            case "Boolean":
                lines.append("        if (json.has(\(kotlinString(name)))) state = state.copy(\(name) = json.getBoolean(\(kotlinString(name))))")
            default:
                lines.append("        doubles(json, \(kotlinString(name)))?.takeIf { it.size == state.\(name).size }?.let { state = state.copy(\(name) = it) }")
            }
        }
        lines += [
            "        if (json.has(\"stockID\")) state = state.copy(stockID = json.getString(\"stockID\"))",
            "        if (json.has(\"chosenFormatID\")) state = state.copy(chosenFormatID = json.optString(\"chosenFormatID\", null))",
            "        if (json.has(\"grainMottleShare\")) state = state.copy(grainMottleShare = json.getDouble(\"grainMottleShare\"))",
            "        doubles(json, \"couplerGapReach\")?.let { state = state.copy(couplerGapReach = it) }",
            "        if (json.has(\"shutterSeconds\")) state = state.copy(shutterSeconds = json.getDouble(\"shutterSeconds\"))",
            "        if (json.has(\"printLightKelvin\")) state = state.copy(printLightKelvin = json.getDouble(\"printLightKelvin\"))",
            "        if (json.has(\"paper\")) state = state.copy(paper = json.getString(\"paper\"))",
            "        if (json.has(\"paperFollowsStock\")) state = state.copy(paperFollowsStock = json.getBoolean(\"paperFollowsStock\"))",
            "        if (json.has(\"enlarger\")) state = state.copy(enlarger = json.getString(\"enlarger\"))",
            "        if (json.has(\"seed\")) state = state.copy(seed = json.getLong(\"seed\"))",
            "        if (json.has(\"rotation\")) state = state.copy(rotation = ((json.getInt(\"rotation\") % 4) + 4) % 4)",
            "        json.optJSONArray(\"crop\")?.let { crop ->",
            "            val origin = crop.getJSONArray(0)",
            "            val size = crop.getJSONArray(1)",
            "            val left = origin.getDouble(0).toFloat()",
            "            val top = origin.getDouble(1).toFloat()",
            "            state = state.copy(crop = androidx.compose.ui.geometry.Rect(left, top, left + size.getDouble(0).toFloat(), top + size.getDouble(1).toFloat()))",
            "        }",
            "        return state",
            "    }",
            "",
            "    private fun doubles(json: JSONObject, key: String): List<Double>? {",
            "        val array = json.optJSONArray(key) ?: return null",
            "        return List(array.length()) { array.getDouble(it) }",
            "    }",
            "}",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    static func kotlinTransforms() -> String {
        [
            "package com.muastudio.fotufilm.engine",
            "",
            "import kotlin.math.ln",
            "import kotlin.math.max",
            "import kotlin.math.min",
            "import kotlin.math.pow",
            "",
            "object ControlTransforms {",
            "    const val OFF_STOPS = \(kotlinDouble(EditorControlUnit.offStops))",
            "    val neutralMired = \(kotlinDouble(WarmthAxis.neutralMired))",
            "    const val COOL_MIRED = \(kotlinDouble(WarmthAxis.coolMired))",
            "    const val WARM_MIRED = \(kotlinDouble(WarmthAxis.warmMired))",
            "",
            "    fun warmthFromMired(mired: Double): Double {",
            "        val warmth = if (mired >= neutralMired) (mired - neutralMired) / (WARM_MIRED - neutralMired)",
            "        else (mired - neutralMired) / (neutralMired - COOL_MIRED)",
            "        return min(max(warmth, -1.0), 1.0)",
            "    }",
            "",
            "    fun miredFromWarmth(warmth: Double): Double =",
            "        if (warmth > 0) neutralMired + warmth * (WARM_MIRED - neutralMired)",
            "        else neutralMired + warmth * (neutralMired - COOL_MIRED)",
            "",
            "    fun padTintFromDuv(tint: Double): Double = min(max(tint / 100.0, -1.0), 1.0)",
            "",
            "    fun duvFromPadTint(value: Double): Double = value * 100.0",
            "",
            "    fun stopsFromScale(scale: Double): Double =",
            "        if (scale <= 0.0) OFF_STOPS else max(ln(scale) / ln(2.0), OFF_STOPS)",
            "",
            "    fun scaleFromStops(stops: Double): Double = if (stops <= OFF_STOPS) 0.0 else 2.0.pow(stops)",
            "",
            "    fun displayed(stored: Double, encoding: StoredEncoding): Double = when (encoding) {",
            "        StoredEncoding.SAME -> stored",
            "        StoredEncoding.MIRED_FROM_WARMTH -> warmthFromMired(stored)",
            "        StoredEncoding.DUV_FROM_PAD_TINT -> padTintFromDuv(stored)",
            "        StoredEncoding.SCALE_FROM_STOPS -> stopsFromScale(stored)",
            "    }",
            "",
            "    fun stored(displayed: Double, encoding: StoredEncoding): Double = when (encoding) {",
            "        StoredEncoding.SAME -> displayed",
            "        StoredEncoding.MIRED_FROM_WARMTH -> miredFromWarmth(displayed)",
            "        StoredEncoding.DUV_FROM_PAD_TINT -> duvFromPadTint(displayed)",
            "        StoredEncoding.SCALE_FROM_STOPS -> scaleFromStops(displayed)",
            "    }",
            "",
            "    fun padPosition(value: Double, slider: ControlKind.Slider): Double {",
            "        val span = if (value >= slider.neutral) slider.max - slider.neutral else slider.neutral - slider.min",
            "        if (span <= 0.0) return 0.0",
            "        return min(max((value - slider.neutral) / span, -1.0), 1.0)",
            "    }",
            "",
            "    fun padValue(position: Double, slider: ControlKind.Slider): Double {",
            "        val span = if (position >= 0.0) slider.max - slider.neutral else slider.neutral - slider.min",
            "        return slider.neutral + min(max(position, -1.0), 1.0) * span",
            "    }",
            "",
            "    fun format(value: Double, unit: ControlUnit): String = when (unit) {",
            "        ControlUnit.MULTIPLIER -> String.format(\"%.2f×\", value)",
            "        ControlUnit.STOPS -> String.format(\"%+.1f EV\", value)",
            "        ControlUnit.STOPS_FROM_OFF -> if (value <= OFF_STOPS) \"Off\" else String.format(\"%+.1f EV\", value)",
            "        ControlUnit.SIGNED -> String.format(\"%+.2f\", value)",
            "        ControlUnit.PERCENT -> String.format(\"%.0f%%\", value * 100)",
            "        ControlUnit.YEARS -> if (value == 0.0) \"Fresh\" else String.format(\"%.0f yr\", value)",
            "        ControlUnit.SECONDS -> if (value >= 1) String.format(\"%.0f s\", value) else String.format(\"%.2f s\", value)",
            "        ControlUnit.DEGREES -> String.format(\"%+.1f°\", value)",
            "        ControlUnit.KELVIN -> String.format(\"%.0f K\", value)",
            "        ControlUnit.MICROMETERS -> String.format(\"%.0f µm\", value)",
            "        ControlUnit.MILLIMETRES -> String.format(\"%.0f mm\", value)",
            "        ControlUnit.NONE -> \"\"",
            "    }",
            "}",
        ].joined(separator: "\n") + "\n"
    }
}
