import XCTest
import FotufilmCore
@testable import FotufilmEditModel

final class EditorControlSurfaceTests: XCTestCase {
    private let all = EditorControlCatalogue.all

    func testEveryControlIsOfferedOrExplainedOnEverySurface() {
        for control in all {
            for surface in EditorSurface.allCases {
                let offered = control.surfaces.contains(surface)
                let explained = control.omitted[surface].map { !$0.isEmpty } ?? false
                XCTAssertTrue(offered != explained,
                              "\(control.field) on \(surface): offered \(offered), explained \(explained)")
            }
        }
    }

    func testHostSurfacesCarryAHostParameter() {
        for control in all {
            let onHost = control.surfaces.contains(.resolve) || control.surfaces.contains(.finalcut)
            XCTAssertEqual(onHost, control.host != nil, "\(control.field)")
            if control.surfaces.contains(.finalcut), control.host?.composed != true {
                XCTAssertNotNil(control.host?.fxplugID, "\(control.field) reaches Final Cut without an id")
            }
            if control.surfaces.contains(.resolve) == false, let host = control.host {
                XCTAssertNotNil(host.fxplugID, "\(control.field) has a host parameter no host offers")
            }
        }
    }

    func testCommandLineSurfacesCarryAFlag() {
        for control in all {
            XCTAssertEqual(control.surfaces.contains(.cli), control.commandLine != nil, "\(control.field)")
        }
        let flags = all.compactMap { $0.commandLine?.flag }
        XCTAssertEqual(flags.count, Set(flags).count, "a flag is spelled twice")
    }

    func testWebSurfacesCarryAConfigurationSlot() {
        for control in all where control.kind.scale != nil {
            XCTAssertEqual(control.surfaces.contains(.web), control.web != nil, "\(control.field)")
        }
    }

    func testBridgeSlotsAreDenseUniqueAndSymbolised() {
        let slots = EditorControlCatalogue.bridgeSlots
        XCTAssertEqual(slots.map(\.slot), Array(0..<EditorControlCatalogue.bridgeSlotCount))
        XCTAssertEqual(Set(slots.map(\.symbol)).count, slots.count)
        XCTAssertEqual(slots.first { $0.slot == 33 }?.symbol, "SCENE_ILLUMINANT")
        XCTAssertEqual(slots.first { $0.slot == 40 }?.symbol, "HALATION_700")
        XCTAssertEqual(slots.first { $0.slot == 49 }?.symbol, "HALATION_MODEL")
    }

    func testOfxNamesAndFxplugIDsAreUnique() {
        var names: [String] = []
        var ids: [Int] = []
        for control in all {
            guard let host = control.host else { continue }
            if let curve = control.kind.curve {
                names += curve.handles.map { host.ofxName + "\(Int($0))" }
            } else {
                names.append(host.ofxName)
            }
            if let id = host.fxplugID { ids.append(id) }
        }
        for auxiliary in EditorControlCatalogue.auxiliaries where auxiliary.surfaces.contains(.resolve) {
            names.append(auxiliary.ofxName)
        }
        for auxiliary in EditorControlCatalogue.auxiliaries {
            if let id = auxiliary.fxplugID, auxiliary.kind != .textureToggles { ids.append(id) }
        }
        for group in HostGroup.allCases { if let id = group.fxplugID { ids.append(id) } }
        XCTAssertEqual(names.count, Set(names).count, "OFX names repeat: \(names)")
        XCTAssertEqual(ids.count, Set(ids).count, "FxPlug ids repeat: \(ids.sorted())")
        for id in ids {
            XCTAssertFalse(EditorControlCatalogue.retiredFxplugIDs.contains(id), "\(id) is retired")
            XCTAssertFalse(EditorControlCatalogue.fxplugTextureStageIDs.contains(id),
                           "\(id) sits inside the texture-toggle block")
        }
    }

    func testTheShippedHostIdentitiesAreUnchanged() {
        let shipped: [EditorControlField: (String, Int?, Int)] = [
            .exposure: ("exposure", 6, 0), .warmth: ("temperature", 7, 1), .tint: ("tint", 8, 2),
            .highlights: ("highlights", 9, 3), .shadows: ("shadows", 10, 4),
            .saturation: ("saturation", 12, 5), .vibrance: ("vibrance", 13, 6),
            .grain: ("grain", 14, 7), .halation: ("halation", 15, 8), .couplers: ("couplers", 19, 9),
            .printCorrection: ("printCorrection", 20, 10), .localTone: ("localTone", 11, 11),
            .push: ("push", 22, 12), .bleach: ("bleachBypass", 23, 13), .expired: ("expired", 24, 14),
            .printLight: ("printLight", 25, 15), .stage: ("stage", 1, 16),
            .textureStages: ("textureSelection", nil, 17), .flare: ("flare", 18, 18),
            .estimatedHalation: ("estimatedHalation", 16, 19), .halationColour: ("halationColour", 17, 20),
            .lensFilter1: ("lensFilter1", 73, 21), .lensFilter2: ("lensFilter2", 74, 22),
            .lensFilter3: ("lensFilter3", 75, 23), .metering: ("metering", 76, 24),
            .diffusion: ("diffusion", 77, 25), .diffusionGrade: ("diffusionGrade", 78, 26),
            .focalLength: ("focalLength", 79, 27), .negativeViewing: ("negativeViewing", 80, 28),
            .mottleOverride: ("mottleOverride", nil, 29), .mottleShare: ("mottleShare", nil, 30),
            .couplerReach: ("couplerReach", nil, 31), .couplerSelf: ("couplerSelf", nil, 32),
            .sceneLight: ("sceneLight", 93, 33), .halationSpectrum: ("halation", nil, 34),
            .filterCoating: ("filterCoating", nil, 41), .frameCoverage: ("frameCoverage", nil, 42),
            .grainModel: ("grainModel", nil, 43), .shutter: ("shutterSeconds", nil, 44),
            .renderMode: ("renderMode", nil, 45), .grainAnimation: ("grainAnimation", nil, 46),
            .couplerRedGreen: ("couplerRedGreen", nil, 47), .couplerGreenBlue: ("couplerGreenBlue", nil, 48),
            .halationModel: ("halationModel", 88, 49),
        ]
        for (field, identity) in shipped {
            let host = EditorControlCatalogue.control(field)?.host
            XCTAssertEqual(host?.ofxName, identity.0, "\(field)")
            XCTAssertEqual(host?.fxplugID, identity.1, "\(field)")
            XCTAssertEqual(host?.slot, identity.2, "\(field)")
        }
        for (field, identity) in [EditorControlField.stock: ("stock", 2), .gauge: ("format", 3),
                                  .paper: ("paper", 4), .colorSpace: ("colorSpace", 5), .seed: ("seed", 21)] {
            let host = EditorControlCatalogue.control(field)?.host
            XCTAssertEqual(host?.ofxName, identity.0)
            XCTAssertEqual(host?.fxplugID, identity.1)
            XCTAssertNil(host?.slot)
        }
    }

    func testHostDefaultsAgreeWithTheCatalogueNeutral() {
        for control in all {
            guard let host = control.host, let scale = control.kind.scale, !host.zeroLeavesEngineDefault,
                  case .double(_, _, let value, _, _) = host.kind else { continue }
            let canonical = host.bridge.canonical(fromBridge: (value * host.paramScale + host.paramOffset)
                                                  .rounded(toPlaces: 9))
            XCTAssertEqual(canonical, scale.neutral, accuracy: 1e-6, "\(control.field)")
        }
    }

    func testBridgeEncodingsRoundTrip() {
        for encoding in [BridgeEncoding.identity, .kelvinFromWarmth, .duvFromPadTint,
                         .multipleFromStops, .minusOne, .indexPlusOne] {
            for value in [-0.75, -0.25, 0.0, 0.25, 0.75, 1.0] {
                let bridge = encoding.bridge(fromCanonical: value)
                XCTAssertEqual(encoding.canonical(fromBridge: bridge), value, accuracy: 1e-6,
                               "\(encoding) at \(value)")
            }
        }
        XCTAssertEqual(BridgeEncoding.kelvinFromWarmth.bridge(fromCanonical: 0), 6504, accuracy: 0.01)
        XCTAssertEqual(BridgeEncoding.multipleFromStops.bridge(fromCanonical: 0), 1)
        XCTAssertEqual(BridgeEncoding.multipleFromStops.bridge(fromCanonical: EditorControlUnit.offStops), 0)
    }

    func testStoredEncodingsRoundTrip() {
        for encoding in [StoredEncoding.same, .miredFromWarmth, .duvFromPadTint, .scaleFromStops] {
            for value in [-1.0, -0.5, 0.0, 0.5, 1.0] {
                let stored = encoding.stored(fromDisplayed: value)
                XCTAssertEqual(encoding.displayed(fromStored: stored), value, accuracy: 1e-9,
                               "\(encoding) at \(value)")
            }
        }
        XCTAssertEqual(StoredEncoding.miredFromWarmth.stored(fromDisplayed: 0), WarmthAxis.neutralMired)
    }

    func testEveryBindingNamesARealOption() {
        let options = Set(Mirror(reflecting: FotufilmEngine.Options()).children.compactMap(\.label))
        for control in all {
            for name in (control.binding?.optionNames ?? []) + control.drives {
                XCTAssertTrue(options.contains(name), "\(control.field) drives \(name), which is not an option")
            }
            if let host = control.host, let binding = host.binding {
                for name in binding.optionNames {
                    XCTAssertTrue(options.contains(name), "\(control.field) host binding names \(name)")
                }
            }
        }
    }

    func testEveryBindingMovesTheOptions() {
        let resting = FotufilmEngine.Options()
        for control in all {
            guard let binding = control.binding else { continue }
            var moved = resting
            let value: EditorControlValue
            switch control.kind {
            case .slider(let scale), .chips(let scale, _):
                value = .number(scale.range.upperBound == scale.neutral ? scale.range.lowerBound
                                    : scale.range.upperBound)
            case .toggle(let restingOn): value = .flag(!restingOn)
            case .curve(let curve): value = .curve(curve.handles.map { _ in curve.range.upperBound })
            case .menu(.fixed(let choices)):
                value = .choice(choices.indices.last ?? 1)
            case .menu(.dynamic): value = .choice(1)
            case .takeover: value = .number(7)
            }
            binding.apply(value, to: &moved)
            XCTAssertNotEqual(describe(moved), describe(resting), "\(control.field) leaves the options untouched")
        }
    }

    private func describe(_ options: FotufilmEngine.Options) -> String {
        Mirror(reflecting: options).children.map { "\($0.label ?? ""):\($0.value)" }.joined(separator: "|")
    }

    func testPersistenceKeysAreUniqueAndEditScoped() {
        var keys: [String] = []
        for control in all {
            switch control.scope {
            case .edit:
                if let key = control.persistence.key { keys.append(key) }
            case .global, .hostOnly:
                XCTAssertEqual(control.persistence, .none, "\(control.field) persists but is not an edit")
            }
        }
        XCTAssertEqual(keys.count, Set(keys).count, "persisted keys repeat: \(keys)")
    }

    func testTheAppSurfaceKeepsItsShape() {
        let app = EditorControlCatalogue.controls(for: nil).map(\.field)
        XCTAssertFalse(app.contains(.stage))
        XCTAssertFalse(app.contains(.renderMode))
        XCTAssertFalse(app.contains(.flare))
        XCTAssertTrue(app.contains(.exposure))
        XCTAssertTrue(app.contains(.crop))
        XCTAssertEqual(EditorControlCatalogue.controls(in: .lensGlass, for: nil).count, 0)
    }

    func testFixedMenusHaveUniqueIDs() {
        for control in all {
            guard case .menu(.fixed(let choices)) = control.kind else { continue }
            let ids = choices.map(\.id)
            XCTAssertEqual(ids.count, Set(ids).count, "\(control.field) menu ids repeat")
            XCTAssertFalse(ids.contains(""), "\(control.field) has an empty menu id")
        }
    }

    func testHostGroupOrderCoversEveryGroup() {
        XCTAssertEqual(Set(EditorControlCatalogue.hostGroupOrder), Set(HostGroup.allCases))
        for group in HostGroup.allCases {
            guard let parent = group.parent else { continue }
            let parentIndex = EditorControlCatalogue.hostGroupOrder.firstIndex(of: parent)!
            let index = EditorControlCatalogue.hostGroupOrder.firstIndex(of: group)!
            XCTAssertLessThan(parentIndex, index, "\(group) is laid out before \(parent)")
        }
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let scale = pow(10.0, Double(places))
        return (self * scale).rounded() / scale
    }
}
