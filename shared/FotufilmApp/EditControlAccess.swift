import CoreGraphics
#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmEditModel)
import FotufilmEditModel
#endif

enum EditControlAccess {
    case number(WritableKeyPath<EditState, Double>)
    case optionalNumber(WritableKeyPath<EditState, Double?>)
    case flag(WritableKeyPath<EditState, Bool>)
    case curve(WritableKeyPath<EditState, [Double]>)
    case derived(read: (EditState) -> Double, write: (inout EditState, Double) -> Void)
    case bespoke(isMoved: (EditState) -> Bool)
    case unstored(String)
}

extension EditorControlField {
    var access: EditControlAccess {
        switch self {
        case .exposure: return .number(\.exposure)
        case .warmth: return .number(\.temperatureMired)
        case .tint: return .number(\.tint)
        case .highlights: return .number(\.highlights)
        case .shadows: return .number(\.shadows)
        case .localTone: return .flag(\.localTone)
        case .saturation: return .number(\.saturation)
        case .vibrance: return .number(\.vibrance)
        case .sceneLight, .sceneLightKelvin:
            return .unstored("the capture metadata names the scene light")

        case .stock:
            return .bespoke { $0.stockID != EditState.defaults.stockID }
        case .gauge:
            return .bespoke { !$0.followsStockGauge }
        case .frameCoverage:
            return .unstored("the crop tool removes pixels instead")
        case .grain: return .number(\.grain)
        case .grainMottle:
            return .bespoke { $0.grainMottleShare != nil }
        case .mottleOverride, .mottleShare:
            return .unstored("the Mottle menu carries the share")
        case .grainModel: return .flag(\.discGrain)
        case .grainAnimation:
            return .unstored("a still has no timeline")
        case .seed:
            return .bespoke { $0.seed != EditState.defaults.seed }
        case .halation: return .number(\.halation)
        case .halationColour: return .number(\.halationColour)
        case .halationSpectrum: return .curve(\.halationSpectrum)
        case .halationModel, .estimatedHalation:
            return .unstored("Film Model settings decide it for every photograph")
        case .couplers: return .number(\.couplers)
        case .couplerReach:
            return .derived(read: { $0.couplerReach }, write: { $0.couplerReach = $1 })
        case .couplerSelf: return .number(\.couplerSelf)
        case .couplerRedGreen:
            return .derived(read: { $0.couplerGapReach.first ?? 1 },
                            write: { edit, value in edit.couplerGapReach[0] = value })
        case .couplerGreenBlue:
            return .derived(read: { $0.couplerGapReach.count > 1 ? $0.couplerGapReach[1] : 1 },
                            write: { edit, value in
                                if edit.couplerGapReach.count < 2 {
                                    edit.couplerGapReach = [edit.couplerGapReach.first ?? 1, value]
                                } else {
                                    edit.couplerGapReach[1] = value
                                }
                            })
        case .chromaticFringeAmount: return .number(\.chromaticFringeAmount)
        case .chromaticFringeRadius: return .number(\.chromaticFringeRadius)
        case .push: return .number(\.push)
        case .bleach: return .number(\.bleach)
        case .expired: return .number(\.expiredYears)
        case .shutter:
            return .bespoke { $0.shutterSeconds != nil }

        case .lensFilter1, .lensFilter2, .lensFilter3:
            return .bespoke { !$0.lensFilterIDs.isEmpty }
        case .metering:
            return .bespoke { $0.lensFilterMetering != .throughTheLens }
        case .diffusion, .diffusionGrade:
            return .bespoke { FilterChoice.resolve($0.lensFilterIDs).diffusion != nil }
        case .focalLength:
            return .unstored("read from the capture metadata")
        case .flare:
            return .unstored("a photograph already carries its own lens's glare")
        case .filterCoating:
            return .unstored("the app's filters are multi-coated")
        case .lensCorrection: return .flag(\.lensCorrectionEnabled)
        case .lensProfile:
            return .bespoke { $0.lensProfileID != nil }
        case .lensAmount: return .number(\.lensProfileAmount)
        case .lensDistortion: return .number(\.lensAdjustment.distortion)
        case .lensVignetting: return .number(\.lensAdjustment.vignetting)
        case .lensRedCyan: return .number(\.lensAdjustment.redCyan)
        case .lensBlueYellow: return .number(\.lensAdjustment.blueYellow)

        case .paper:
            return .bespoke { !$0.paperFollowsStock }
        case .printLight:
            return .bespoke { $0.printLightKelvin != nil }
        case .enlarger:
            return .bespoke { $0.enlarger != .default }
        case .printCorrection: return .number(\.printCorrection)
        case .negativeViewing:
            return .unstored("Settings chooses the lightbox or scanner reading")
        case .gradeSpace: return .flag(\.encodedGrade)

        case .gradeShadowsWarmth: return Self.grade(.shadows, .warmth)
        case .gradeShadowsTint: return Self.grade(.shadows, .tint)
        case .gradeShadowsLevel: return Self.grade(.shadows, .level)
        case .gradeMidtonesWarmth: return Self.grade(.midtones, .warmth)
        case .gradeMidtonesTint: return Self.grade(.midtones, .tint)
        case .gradeMidtonesLevel: return Self.grade(.midtones, .level)
        case .gradeHighlightsWarmth: return Self.grade(.highlights, .warmth)
        case .gradeHighlightsTint: return Self.grade(.highlights, .tint)
        case .gradeHighlightsLevel: return Self.grade(.highlights, .level)

        case .crop:
            return .bespoke { $0.crop != nil || $0.cornerCrop != nil }
        case .straighten: return .number(\.straighten)
        case .perspectiveVertical: return .number(\.perspectiveV)
        case .perspectiveHorizontal: return .number(\.perspectiveH)
        case .rotation:
            return .bespoke { $0.rotation != 0 }
        case .flip: return .flag(\.flipH)
        case .selective:
            return .bespoke { _ in false }

        case .colorSpace, .stage, .textureStages, .renderMode:
            return .unstored("a plugin host's own setting")
        }
    }

    private static func grade(_ band: GradeBand, _ axis: GradeAxis) -> EditControlAccess {
        .derived(read: { Double($0.grade[keyPath: band.keyPath][keyPath: axis.keyPath]) },
                 write: { $0.grade[keyPath: band.keyPath][keyPath: axis.keyPath] = Float($1) })
    }
}

extension EditState {
    private static func encoding(of field: EditorControlField) -> StoredEncoding {
        EditorControlCatalogue.control(field)?.persistence.encoding ?? .same
    }

    func value(of field: EditorControlField) -> Double? {
        switch field.access {
        case .number(let path):
            return Self.encoding(of: field).displayed(fromStored: self[keyPath: path])
        case .derived(let read, _):
            return read(self)
        case .optionalNumber(let path):
            return self[keyPath: path]
        case .flag, .curve, .bespoke, .unstored:
            return nil
        }
    }

    mutating func setValue(_ value: Double, of field: EditorControlField) {
        switch field.access {
        case .number(let path):
            self[keyPath: path] = Self.encoding(of: field).stored(fromDisplayed: value)
        case .derived(_, let write):
            write(&self, value)
        case .optionalNumber(let path):
            self[keyPath: path] = value
        case .flag, .curve, .bespoke, .unstored:
            break
        }
    }

    func storedValue(of field: EditorControlField) -> Double? {
        if case .number(let path) = field.access { return self[keyPath: path] }
        return nil
    }

    mutating func setStoredValue(_ value: Double, of field: EditorControlField) {
        if case .number(let path) = field.access { self[keyPath: path] = value }
    }

    func curve(of field: EditorControlField) -> [Double]? {
        if case .curve(let path) = field.access { return self[keyPath: path] }
        return nil
    }

    mutating func setCurve(_ values: [Double], of field: EditorControlField) {
        if case .curve(let path) = field.access { self[keyPath: path] = values }
    }

    func flag(of field: EditorControlField) -> Bool? {
        if case .flag(let path) = field.access { return self[keyPath: path] }
        return nil
    }

    mutating func setFlag(_ on: Bool, of field: EditorControlField) {
        if case .flag(let path) = field.access { self[keyPath: path] = on }
    }

    func controlValue(of control: EditorControl) -> EditorControlValue? {
        switch control.kind {
        case .slider, .chips:
            return value(of: control.field).map { .number($0) }
        case .toggle:
            return flag(of: control.field).map { .flag($0) }
        case .curve:
            return curve(of: control.field).map { .curve($0) }
        case .menu, .takeover:
            return nil
        }
    }

    func isMoved(_ field: EditorControlField) -> Bool {
        guard let control = EditorControlCatalogue.control(field) else { return false }
        switch field.access {
        case .number, .derived, .optionalNumber:
            guard let scale = control.kind.scale, let value = value(of: field) else { return false }
            return scale.isMoved(value)
        case .flag(let path):
            guard case .toggle(let restingOn) = control.kind else { return false }
            return self[keyPath: path] != restingOn
        case .curve(let path):
            guard let curve = control.kind.curve else { return false }
            return curve.isMoved(self[keyPath: path])
        case .bespoke(let isMoved):
            return isMoved(self)
        case .unstored:
            return false
        }
    }

    mutating func reset(_ field: EditorControlField) {
        guard let control = EditorControlCatalogue.control(field) else { return }
        switch field.access {
        case .number, .derived, .optionalNumber:
            guard let scale = control.kind.scale else { return }
            setValue(scale.neutral, of: field)
        case .flag:
            guard case .toggle(let restingOn) = control.kind else { return }
            setFlag(restingOn, of: field)
        case .curve:
            guard let curve = control.kind.curve else { return }
            setCurve(curve.restingValues, of: field)
        case .bespoke, .unstored:
            break
        }
    }

    func movedControls(for stock: FilmStock?) -> [EditorControl] {
        EditorControlCatalogue.controls(for: stock).filter { isMoved($0.field) }
    }
}
