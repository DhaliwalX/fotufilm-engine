import Foundation

#if canImport(FotufilmCore)
import FotufilmCore
#endif

public struct ControlsManifest: Codable, Equatable {
    public struct Scale: Codable, Equatable {
        public let min: Double
        public let max: Double
        public let neutral: Double
        public let unit: String
        public let stops: [Double]
        public let admittedMin: Double
        public let admittedMax: Double
    }

    public struct Curve: Codable, Equatable {
        public let handles: [Double]
        public let domainMin: Double
        public let domainMax: Double
        public let min: Double
        public let max: Double
        public let neutral: Double
        public let unit: String
    }

    public struct Choice: Codable, Equatable {
        public let id: String
        public let label: String
        public let detail: String
        public let value: Double?
    }

    public struct Host: Codable, Equatable {
        public let slot: Int?
        public let slotSymbol: String?
        public let ofxName: String
        public let fxplugID: Int?
        public let group: String
        public let label: String
        public let hint: String
        public let kind: String
        public let min: Double?
        public let max: Double?
        public let hardMax: Double?
        public let value: Double?
        public let delta: Double?
        public let choices: [Choice]?
        public let dynamicMenu: String?
        public let paramScale: Double
        public let paramOffset: Double
        public let bridge: String
        public let clampMin: Double?
        public let clampMax: Double?
        public let zeroLeavesEngineDefault: Bool
        public let composed: Bool
        public let animates: Bool
        public let secret: Bool
        public let order: Int
    }

    public struct Control: Codable, Equatable {
        public let field: String
        public let title: String
        public let detail: String
        public let documentation: String?
        public let group: String
        public let section: String
        public let kind: String
        public let scale: Scale?
        public let curve: Curve?
        public let chips: [Choice]?
        public let restingOn: Bool?
        public let choices: [Choice]?
        public let dynamicMenu: String?
        public let availability: String
        public let foldsUnder: String?
        public let scope: String
        public let settingKey: String?
        public let persistedKey: String?
        public let storedEncoding: String?
        public let storedNeutral: Double?
        public let binding: String?
        public let drives: [String]
        public let surfaces: [String]
        public let omitted: [String: String]
        public let host: Host?
        public let webConfigSlot: String?
        public let webTransform: String?
        public let commandLineFlag: String?
        public let commandLinePlaceholder: String?
        public let commandLineHelp: String?
        public let commandLineGeneric: Bool?
        public let commandLineMin: Double?
        public let commandLineMax: Double?
    }

    public struct Auxiliary: Codable, Equatable {
        public let ofxName: String
        public let fxplugID: Int?
        public let group: String?
        public let label: String
        public let hint: String?
        public let kind: String
        public let text: String?
        public let choices: [String]?
        public let value: Int?
        public let persistent: Bool?
        public let surfaces: [String]
        public let order: Int
    }

    public struct Group: Codable, Equatable {
        public let id: String
        public let ofxName: String
        public let label: String
        public let parent: String?
        public let opensExpanded: Bool
        public let fxplugID: Int?
        public let fxplugCollapsed: Bool
    }

    public struct Section: Codable, Equatable {
        public let id: String
        public let title: String
        public let group: String
        public let groupTitle: String
    }

    public let version: Int
    public let bridgeSlotCount: Int
    public let bridgeSlots: [String]
    public let retiredFxplugIDs: [Int]
    public let textureStageFirstFxplugID: Int
    public let textureStageLimitFxplugID: Int
    public let sections: [Section]
    public let hostGroups: [Group]
    public let controls: [Control]
    public let auxiliaries: [Auxiliary]

    public static var current: ControlsManifest {
        ControlsManifest(
            version: 1,
            bridgeSlotCount: EditorControlCatalogue.bridgeSlotCount,
            bridgeSlots: EditorControlCatalogue.bridgeSlots.map(\.symbol),
            retiredFxplugIDs: EditorControlCatalogue.retiredFxplugIDs,
            textureStageFirstFxplugID: EditorControlCatalogue.fxplugTextureStageIDs.lowerBound,
            textureStageLimitFxplugID: EditorControlCatalogue.fxplugTextureStageIDs.upperBound + 1,
            sections: EditorControlSection.allCases.map {
                Section(id: $0.rawValue, title: $0.title, group: $0.group.rawValue, groupTitle: $0.group.title)
            },
            hostGroups: EditorControlCatalogue.hostGroupOrder.map {
                Group(id: $0.rawValue, ofxName: $0.ofxName, label: $0.label, parent: $0.parent?.rawValue,
                      opensExpanded: $0.opensExpanded, fxplugID: $0.fxplugID, fxplugCollapsed: $0.fxplugCollapsed)
            },
            controls: EditorControlCatalogue.all.map(Control.init),
            auxiliaries: EditorControlCatalogue.auxiliaries.map(Auxiliary.init))
    }

    public static func encoded(_ manifest: ControlsManifest = current) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try! encoder.encode(manifest)
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}

extension ControlsManifest.Choice {
    init(_ choice: EditorMenuChoice) {
        self.init(id: choice.id, label: choice.label, detail: choice.detail, value: choice.value)
    }

    init(_ choice: EditorControlChoice) {
        self.init(id: EditorMenuChoice.slug(choice.label), label: choice.label, detail: "", value: choice.value)
    }
}

extension ControlsManifest.Host {
    init(_ host: HostParameter) {
        var kindName = host.kind.typeName
        var min: Double?, max: Double?, hardMax: Double?, value: Double?, delta: Double?
        var choices: [ControlsManifest.Choice]?
        var dynamicMenu: String?
        switch host.kind {
        case .double(let lower, let upper, let resting, let hard, let step):
            min = lower; max = upper; hardMax = hard; value = resting; delta = step
        case .integer(let lower, let upper, let resting):
            min = Double(lower); max = Double(upper); value = Double(resting)
        case .boolean(let resting):
            value = resting ? 1 : 0
        case .choice(let menu, let resting):
            value = Double(resting)
            switch menu {
            case .fixed(let list): choices = list.map(ControlsManifest.Choice.init)
            case .dynamic(let dynamic): dynamicMenu = dynamic.rawValue; kindName = "menu"
            }
        }
        self.init(slot: host.slot, slotSymbol: host.slotSymbol, ofxName: host.ofxName, fxplugID: host.fxplugID,
                  group: host.group.rawValue, label: host.label, hint: host.hint, kind: kindName,
                  min: min, max: max, hardMax: hardMax, value: value, delta: delta, choices: choices,
                  dynamicMenu: dynamicMenu, paramScale: host.paramScale, paramOffset: host.paramOffset,
                  bridge: host.bridge.rawValue, clampMin: host.clamp?.lowerBound, clampMax: host.clamp?.upperBound,
                  zeroLeavesEngineDefault: host.zeroLeavesEngineDefault, composed: host.composed,
                  animates: host.animates, secret: host.secret, order: host.order)
    }
}

extension ControlsManifest.Control {
    init(_ control: EditorControl) {
        var scale: ControlsManifest.Scale?
        var curve: ControlsManifest.Curve?
        var chips: [ControlsManifest.Choice]?
        var restingOn: Bool?
        var choices: [ControlsManifest.Choice]?
        var dynamicMenu: String?
        switch control.kind {
        case .slider(let s):
            scale = ControlsManifest.Scale(s)
        case .chips(let s, let list):
            scale = ControlsManifest.Scale(s)
            chips = list.map(ControlsManifest.Choice.init)
        case .toggle(let on):
            restingOn = on
        case .menu(.fixed(let list)):
            choices = list.map(ControlsManifest.Choice.init)
        case .menu(.dynamic(let menu)):
            dynamicMenu = menu.rawValue
        case .curve(let c):
            curve = ControlsManifest.Curve(handles: c.handles, domainMin: c.domain.lowerBound,
                                           domainMax: c.domain.upperBound, min: c.range.lowerBound,
                                           max: c.range.upperBound, neutral: c.neutral, unit: c.unit.rawValue)
        case .takeover:
            break
        }
        var scopeName = "edit"
        var settingKey: String?
        switch control.scope {
        case .edit: scopeName = "edit"
        case .global(let key): scopeName = "global"; settingKey = key
        case .hostOnly: scopeName = "hostOnly"
        }
        var webSlot: String?, webTransform: String?
        switch control.web {
        case .configSlot(let slot, let transform): webSlot = slot; webTransform = transform.rawValue
        case .grainScale: webSlot = "FOTUFILM_CONFIG_GRAIN"; webTransform = "grain"
        case nil: break
        }
        self.init(field: control.field.rawValue, title: control.title, detail: control.detail,
                  documentation: control.documentation, group: control.group.rawValue,
                  section: control.section.rawValue, kind: control.kind.typeName, scale: scale, curve: curve,
                  chips: chips, restingOn: restingOn, choices: choices, dynamicMenu: dynamicMenu,
                  availability: control.availability.rawValue, foldsUnder: control.foldsUnder?.rawValue,
                  scope: scopeName, settingKey: settingKey, persistedKey: control.persistence.key,
                  storedEncoding: control.persistence.encoding?.rawValue, storedNeutral: control.storedNeutral,
                  binding: control.binding.map { "\($0)" }, drives: control.drives,
                  surfaces: EditorSurface.allCases.filter { control.surfaces.contains($0) }.map(\.rawValue),
                  omitted: Dictionary(uniqueKeysWithValues: control.omitted.map { ($0.key.rawValue, $0.value) }),
                  host: control.host.map(ControlsManifest.Host.init), webConfigSlot: webSlot,
                  webTransform: webTransform, commandLineFlag: control.commandLine?.flag,
                  commandLinePlaceholder: control.commandLine?.placeholder,
                  commandLineHelp: control.commandLine?.help, commandLineGeneric: control.commandLine?.generic,
                  commandLineMin: control.commandLine?.range?.lowerBound,
                  commandLineMax: control.commandLine?.range?.upperBound)
    }
}

extension ControlsManifest.Scale {
    init(_ scale: EditorControlScale) {
        self.init(min: scale.range.lowerBound, max: scale.range.upperBound, neutral: scale.neutral,
                  unit: scale.unit.rawValue, stops: scale.stops, admittedMin: scale.admitted.lowerBound,
                  admittedMax: scale.admitted.upperBound)
    }
}

extension ControlsManifest.Auxiliary {
    init(_ auxiliary: HostAuxiliary) {
        var kindName = ""
        var text: String?, choices: [String]?, value: Int?, persistent: Bool?
        switch auxiliary.kind {
        case .label(let line, _): kindName = "label"; text = line
        case .hiddenString: kindName = "hiddenString"
        case .pushButton: kindName = "pushButton"
        case .choice(let list, let resting, let persists):
            kindName = "choice"; choices = list; value = resting; persistent = persists
        case .textureToggles: kindName = "textureToggles"
        }
        self.init(ofxName: auxiliary.ofxName, fxplugID: auxiliary.fxplugID, group: auxiliary.group?.rawValue,
                  label: auxiliary.label, hint: auxiliary.hint, kind: kindName, text: text, choices: choices,
                  value: value, persistent: persistent,
                  surfaces: EditorSurface.allCases.filter { auxiliary.surfaces.contains($0) }.map(\.rawValue),
                  order: auxiliary.order)
    }
}
