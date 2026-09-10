import Foundation

enum HostParameterKindCode: Int32 {
    case double = 0
    case integer = 1
    case boolean = 2
    case choice = 3
    case menu = 4
    case label = 5
    case hiddenString = 6
    case pushButton = 7
    case group = 8
    case textureToggles = 9
}

enum HostMenuCode: Int32 {
    case none = 0
    case stocks = 1
    case gauges = 2
    case papers = 3
    case stages = 4
    case lensFilters = 5
    case meterings = 6
    case diffusionFamilies = 7
    case diffusionGrades = 8
    case negativeViewings = 9
    case colourSpaces = 10
    case pushConditions = 11
    case textureStages = 12
    case lensProfiles = 13
    case shutterTimes = 14
    case viewingLights = 15

    init(_ menu: EditorDynamicMenu) {
        switch menu {
        case .stocks: self = .stocks
        case .gauges: self = .gauges
        case .papers: self = .papers
        case .stages: self = .stages
        case .lensFilters: self = .lensFilters
        case .meterings: self = .meterings
        case .diffusionFamilies: self = .diffusionFamilies
        case .diffusionGrades: self = .diffusionGrades
        case .negativeViewings: self = .negativeViewings
        case .colourSpaces: self = .colourSpaces
        case .pushConditions: self = .pushConditions
        case .textureStages: self = .textureStages
        case .lensProfiles: self = .lensProfiles
        case .shutterTimes: self = .shutterTimes
        case .viewingLights: self = .viewingLights
        }
    }
}

struct HostFlags {
    static let animates: Int32 = 1
    static let secret: Int32 = 2
    static let persistent: Int32 = 4
    static let opensExpanded: Int32 = 8
    static let composed: Int32 = 16
    static let zeroLeavesEngineDefault: Int32 = 32
    static let collapsedInFinalCut: Int32 = 64
}

struct HostEntry {
    let kind: HostParameterKindCode
    let name: String
    let label: String
    let hint: String
    let parent: String
    let group: HostGroup?
    let slot: Int32
    let fxplugID: Int32
    let fxplugGroupID: Int32
    let menu: HostMenuCode
    let minimum: Double
    let maximum: Double
    let hardMaximum: Double
    let value: Double
    let delta: Double
    let scale: Double
    let offset: Double
    let flags: Int32
    let choices: [String]
    let choiceValues: [Double]
    let field: EditorControlField?
}

enum HostLayout {
    static let resolve = layout(on: .resolve)
    static let finalcut = layout(on: .finalcut)

    static func entries(on surface: EditorSurface) -> [HostEntry] {
        surface == .finalcut ? finalcut : resolve
    }

    static func layout(on surface: EditorSurface) -> [HostEntry] {
        var entries: [HostEntry] = []
        let top = EditorControlCatalogue.auxiliaries
            .filter { $0.group == nil && $0.surfaces.contains(surface) }
            .filter { surface != .finalcut || $0.fxplugID != nil }
            .sorted { $0.order < $1.order }
        for auxiliary in top where auxiliary.order < 100 { entries.append(entry(auxiliary, surface: surface)) }
        let members = ControlsExport.hostEntries(on: surface)
        for group in EditorControlCatalogue.hostGroupOrder {
            let grouped: [(group: HostGroup, order: Int, control: EditorControl?, auxiliary: HostAuxiliary?)]
            if surface == .finalcut {
                guard group.parent == nil, group.fxplugID != nil else { continue }
                grouped = members.filter { $0.group.topLevel == group }
            } else {
                grouped = members.filter { $0.group == group }
            }
            entries.append(groupEntry(group))
            for member in grouped {
                if let control = member.control, let host = control.host {
                    entries += controlEntries(control, host: host, surface: surface)
                } else if let auxiliary = member.auxiliary {
                    entries.append(entry(auxiliary, surface: surface))
                }
            }
        }
        for auxiliary in top where auxiliary.order >= 100 { entries.append(entry(auxiliary, surface: surface)) }
        return entries
    }

    static func groupEntry(_ group: HostGroup) -> HostEntry {
        HostEntry(kind: .group, name: group.ofxName, label: group.label, hint: "",
                  parent: group.parent?.ofxName ?? "", group: group, slot: -1,
                  fxplugID: Int32(group.fxplugID ?? -1), fxplugGroupID: Int32(group.topLevel.fxplugID ?? -1),
                  menu: .none, minimum: 0, maximum: 0, hardMaximum: 0, value: 0, delta: 0, scale: 1, offset: 0,
                  flags: (group.opensExpanded ? HostFlags.opensExpanded : 0)
                      | (group.fxplugCollapsed ? HostFlags.collapsedInFinalCut : 0),
                  choices: [], choiceValues: [], field: nil)
    }

    static func entry(_ auxiliary: HostAuxiliary, surface: EditorSurface) -> HostEntry {
        var kind = HostParameterKindCode.label
        var text = ""
        var choices: [String] = []
        var value = 0.0
        var flags: Int32 = 0
        switch auxiliary.kind {
        case .label(let line, _): kind = .label; text = line
        case .hiddenString: kind = .hiddenString
        case .pushButton: kind = .pushButton
        case .choice(let list, let resting, let persistent):
            kind = .choice; choices = list; value = Double(resting)
            if persistent { flags |= HostFlags.persistent }
        case .textureToggles: kind = .textureToggles; value = 1
        }
        if case .hiddenString = auxiliary.kind { flags |= HostFlags.persistent }
        return HostEntry(kind: kind, name: auxiliary.ofxName, label: auxiliary.label,
                         hint: auxiliary.hint ?? text, parent: auxiliary.group?.ofxName ?? "",
                         group: auxiliary.group, slot: -1, fxplugID: Int32(auxiliary.fxplugID ?? -1),
                         fxplugGroupID: Int32(auxiliary.group?.topLevel.fxplugID ?? -1), menu: .none,
                         minimum: 0, maximum: 0, hardMaximum: 0, value: value, delta: 0, scale: 1, offset: 0,
                         flags: flags, choices: choices, choiceValues: choices.map { _ in 0 }, field: nil)
    }

    static func controlEntries(_ control: EditorControl, host: HostParameter,
                               surface: EditorSurface) -> [HostEntry] {
        // The mask has a bridge slot, but its UI is the auxiliary's per-stage toggles.
        // Defining a second menu would expose an unused choice beside those toggles.
        if control.field == .textureStages { return [] }
        var flags: Int32 = HostFlags.persistent
        if host.animates { flags |= HostFlags.animates }
        if host.secret { flags |= HostFlags.secret }
        if host.composed { flags |= HostFlags.composed }
        if host.zeroLeavesEngineDefault { flags |= HostFlags.zeroLeavesEngineDefault }
        var kind = HostParameterKindCode.double
        var menu = HostMenuCode.none
        var minimum = 0.0, maximum = 0.0, hardMaximum = 0.0, value = 0.0, delta = 0.01
        var choices: [String] = []
        var choiceValues: [Double] = []
        switch host.kind {
        case .double(let lower, let upper, let resting, let hard, let step):
            minimum = lower; maximum = upper; hardMaximum = hard ?? upper; value = resting; delta = step
        case .integer(let lower, let upper, let resting):
            kind = .integer; minimum = Double(lower); maximum = Double(upper); hardMaximum = maximum
            value = Double(resting); delta = 1
        case .boolean(let resting):
            kind = .boolean; value = resting ? 1 : 0
        case .choice(let list, let resting):
            value = Double(resting)
            switch list {
            case .fixed(let fixed):
                kind = .choice
                choices = fixed.map(\.label)
                choiceValues = fixed.map { $0.value ?? -1 }
            case .dynamic(let dynamic):
                kind = .menu
                menu = HostMenuCode(dynamic)
            }
        }
        let base = HostEntry(kind: kind, name: host.ofxName, label: host.label, hint: host.hint,
                             parent: host.group.ofxName, group: host.group, slot: Int32(host.slot ?? -1),
                             fxplugID: Int32(host.fxplugID ?? -1),
                             fxplugGroupID: Int32(host.group.topLevel.fxplugID ?? -1), menu: menu,
                             minimum: minimum, maximum: maximum, hardMaximum: hardMaximum, value: value,
                             delta: delta, scale: host.paramScale, offset: host.paramOffset, flags: flags,
                             choices: choices, choiceValues: choiceValues, field: control.field)
        guard let curve = control.kind.curve, let slot = host.slot else { return [base] }
        return curve.handles.enumerated().map { index, nm in
            HostEntry(kind: .double, name: host.ofxName + "\(Int(nm))", label: "\(Int(nm)) " + host.label,
                      hint: host.hint, parent: host.group.ofxName, group: host.group, slot: Int32(slot + index),
                      fxplugID: -1, fxplugGroupID: base.fxplugGroupID, menu: .none,
                      minimum: curve.range.lowerBound, maximum: curve.range.upperBound,
                      hardMaximum: curve.range.upperBound, value: curve.neutral, delta: 0.01, scale: 1, offset: 0,
                      flags: flags, choices: [], choiceValues: [], field: control.field)
        }
    }
}

private func hostEntry(_ surface: Int32, _ index: Int32) -> HostEntry? {
    let entries = HostLayout.entries(on: surface == 1 ? .finalcut : .resolve)
    guard entries.indices.contains(Int(index)) else { return nil }
    return entries[Int(index)]
}

private func writeOut(_ value: String, _ out: UnsafeMutablePointer<CChar>?, _ capacity: Int32) -> Int32 {
    guard let out, capacity > 0 else { return -1 }
    let bytes = Array(value.utf8)
    guard bytes.count + 1 <= Int(capacity) else { return -1 }
    for (i, byte) in bytes.enumerated() { out[i] = CChar(bitPattern: byte) }
    out[bytes.count] = 0
    return Int32(bytes.count)
}

@_cdecl("fotufilm_bridge_host_parameter_count")
func fotufilm_bridge_host_parameter_count(_ surface: Int32) -> Int32 {
    Int32(HostLayout.entries(on: surface == 1 ? .finalcut : .resolve).count)
}

@_cdecl("fotufilm_bridge_host_parameter_kind")
func fotufilm_bridge_host_parameter_kind(_ surface: Int32, _ index: Int32) -> Int32 {
    hostEntry(surface, index)?.kind.rawValue ?? -1
}

@_cdecl("fotufilm_bridge_host_parameter_slot")
func fotufilm_bridge_host_parameter_slot(_ surface: Int32, _ index: Int32) -> Int32 {
    hostEntry(surface, index)?.slot ?? -1
}

@_cdecl("fotufilm_bridge_host_parameter_menu")
func fotufilm_bridge_host_parameter_menu(_ surface: Int32, _ index: Int32) -> Int32 {
    hostEntry(surface, index)?.menu.rawValue ?? 0
}

@_cdecl("fotufilm_bridge_host_parameter_flags")
func fotufilm_bridge_host_parameter_flags(_ surface: Int32, _ index: Int32) -> Int32 {
    hostEntry(surface, index)?.flags ?? 0
}

@_cdecl("fotufilm_bridge_host_parameter_fxplug_id")
func fotufilm_bridge_host_parameter_fxplug_id(_ surface: Int32, _ index: Int32) -> Int32 {
    hostEntry(surface, index)?.fxplugID ?? -1
}

@_cdecl("fotufilm_bridge_host_parameter_fxplug_group")
func fotufilm_bridge_host_parameter_fxplug_group(_ surface: Int32, _ index: Int32) -> Int32 {
    hostEntry(surface, index)?.fxplugGroupID ?? -1
}

@_cdecl("fotufilm_bridge_host_parameter_minimum")
func fotufilm_bridge_host_parameter_minimum(_ surface: Int32, _ index: Int32) -> Double {
    hostEntry(surface, index)?.minimum ?? 0
}

@_cdecl("fotufilm_bridge_host_parameter_maximum")
func fotufilm_bridge_host_parameter_maximum(_ surface: Int32, _ index: Int32) -> Double {
    hostEntry(surface, index)?.maximum ?? 0
}

@_cdecl("fotufilm_bridge_host_parameter_hard_maximum")
func fotufilm_bridge_host_parameter_hard_maximum(_ surface: Int32, _ index: Int32) -> Double {
    hostEntry(surface, index)?.hardMaximum ?? 0
}

@_cdecl("fotufilm_bridge_host_parameter_default")
func fotufilm_bridge_host_parameter_default(_ surface: Int32, _ index: Int32) -> Double {
    hostEntry(surface, index)?.value ?? 0
}

@_cdecl("fotufilm_bridge_host_parameter_delta")
func fotufilm_bridge_host_parameter_delta(_ surface: Int32, _ index: Int32) -> Double {
    hostEntry(surface, index)?.delta ?? 0
}

@_cdecl("fotufilm_bridge_host_parameter_scale")
func fotufilm_bridge_host_parameter_scale(_ surface: Int32, _ index: Int32) -> Double {
    hostEntry(surface, index)?.scale ?? 1
}

@_cdecl("fotufilm_bridge_host_parameter_offset")
func fotufilm_bridge_host_parameter_offset(_ surface: Int32, _ index: Int32) -> Double {
    hostEntry(surface, index)?.offset ?? 0
}

@_cdecl("fotufilm_bridge_host_parameter_name")
func fotufilm_bridge_host_parameter_name(_ surface: Int32, _ index: Int32,
                                         _ out: UnsafeMutablePointer<CChar>?, _ capacity: Int32) -> Int32 {
    guard let entry = hostEntry(surface, index) else { return -1 }
    return writeOut(entry.name, out, capacity)
}

@_cdecl("fotufilm_bridge_host_parameter_label")
func fotufilm_bridge_host_parameter_label(_ surface: Int32, _ index: Int32,
                                          _ out: UnsafeMutablePointer<CChar>?, _ capacity: Int32) -> Int32 {
    guard let entry = hostEntry(surface, index) else { return -1 }
    return writeOut(entry.label, out, capacity)
}

@_cdecl("fotufilm_bridge_host_parameter_hint")
func fotufilm_bridge_host_parameter_hint(_ surface: Int32, _ index: Int32,
                                         _ out: UnsafeMutablePointer<CChar>?, _ capacity: Int32) -> Int32 {
    guard let entry = hostEntry(surface, index) else { return -1 }
    return writeOut(entry.hint, out, capacity)
}

@_cdecl("fotufilm_bridge_host_parameter_parent")
func fotufilm_bridge_host_parameter_parent(_ surface: Int32, _ index: Int32,
                                           _ out: UnsafeMutablePointer<CChar>?, _ capacity: Int32) -> Int32 {
    guard let entry = hostEntry(surface, index) else { return -1 }
    return writeOut(entry.parent, out, capacity)
}

@_cdecl("fotufilm_bridge_host_parameter_choice_count")
func fotufilm_bridge_host_parameter_choice_count(_ surface: Int32, _ index: Int32) -> Int32 {
    Int32(hostEntry(surface, index)?.choices.count ?? 0)
}

@_cdecl("fotufilm_bridge_host_parameter_choice")
func fotufilm_bridge_host_parameter_choice(_ surface: Int32, _ index: Int32, _ choice: Int32,
                                           _ out: UnsafeMutablePointer<CChar>?, _ capacity: Int32) -> Int32 {
    guard let entry = hostEntry(surface, index), entry.choices.indices.contains(Int(choice)) else { return -1 }
    return writeOut(entry.choices[Int(choice)], out, capacity)
}

@_cdecl("fotufilm_bridge_host_parameter_choice_value")
func fotufilm_bridge_host_parameter_choice_value(_ surface: Int32, _ index: Int32, _ choice: Int32) -> Double {
    guard let entry = hostEntry(surface, index), entry.choiceValues.indices.contains(Int(choice)) else { return -1 }
    return entry.choiceValues[Int(choice)]
}

@_cdecl("fotufilm_bridge_control_capabilities_mask_for")
func fotufilm_bridge_control_capabilities_mask_for(_ surface: Int32, _ index: Int32) -> Int32 {
    guard let field = hostEntry(surface, index)?.field,
          let control = EditorControlCatalogue.control(field) else { return 0 }
    return control.availability.capabilityBit ?? 0
}

enum BridgeOptions {
    static func apply(_ parameters: UnsafePointer<Float>, to options: inout FotufilmEngine.Options) {
        for control in EditorControlCatalogue.all {
            guard let host = control.host, let slot = host.slot, !host.composed else { continue }
            if let curve = control.kind.curve, let binding = control.binding {
                let handles = (0..<curve.handles.count).map { Double(parameters[slot + $0]) }
                binding.apply(.curve(handles), to: &options)
                continue
            }
            let raw = Double(parameters[slot])
            if host.zeroLeavesEngineDefault, raw == 0 { continue }
            var value: Double
            let binding: EngineBinding?
            if let override = host.binding {
                value = raw
                binding = override
            } else {
                value = host.bridge.canonical(fromBridge: raw)
                binding = control.binding
            }
            if let clamp = host.clamp { value = min(max(value, clamp.lowerBound), clamp.upperBound) }
            guard let binding else { continue }
            switch host.kind {
            case .boolean: binding.apply(.flag(value != 0), to: &options)
            case .choice: binding.apply(.choice(Int(value.rounded())), to: &options)
            case .double, .integer: binding.apply(.number(value), to: &options)
            }
        }
    }
}
