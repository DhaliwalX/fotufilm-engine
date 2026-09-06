import CoreGraphics
#if canImport(FotufilmCore)
import FotufilmCore
#endif
// The script builds compile the whole app as one module, where these types are already in scope and
// there is no such module to import; the Xcode build takes them from the package.
#if canImport(FotufilmEditModel)
import FotufilmEditModel
#endif

/// How a catalogued control reaches the edit it drives.
enum EditControlAccess {
    case number(read: (EditState) -> Double,
                write: (inout EditState, Double) -> Void)
    case flag(read: (EditState) -> Bool,
              write: (inout EditState, Bool) -> Void)
    /// A named choice or a surface of its own — the film, the paper, the crop. The panel wires these
    /// to the menus and takeovers that already exist, so all the catalogue wants from them is
    /// whether the photographer has said anything.
    case bespoke(isMoved: (EditState) -> Bool)
    /// A curve drawn against an axis: a row of heights rather than one.
    case curve(read: (EditState) -> [Double],
               write: (inout EditState, [Double]) -> Void)
    /// Engine input that does not yet have edit-state storage. No current control uses this case.
    case unstored(String)
}

extension EditorControlField {
    /// The one place a control's storage is written down.
    ///
    /// Exhaustive on purpose. A case added to `EditorControlField` — including one struck from
    /// `EditorControlCatalogue.pending` as it is surfaced — does not compile until its storage is
    /// named here, which is what keeps the catalogue and the edit from drifting apart.
    var access: EditControlAccess {
        switch self {

        // MARK: The light the film was given

        case .exposure:
            return .number(read: { $0.exposure },
                           write: { $0.exposure = $1 })
        case .warmth:
            return .number(
                read: { UndertoneAxis.warmth(fromMired: $0.temperatureMired) },
                write: { $0.temperatureMired = UndertoneAxis.mired(fromWarmth: $1) })
        case .tint:
            return .number(read: { UndertoneAxis.padTint(fromDuv: $0.tint) },
                           write: { $0.tint = UndertoneAxis.duv(fromPadTint: $1) })
        case .highlights:
            return .number(read: { $0.highlights },
                           write: { $0.highlights = $1 })
        case .shadows:
            return .number(read: { $0.shadows }, write: { $0.shadows = $1 })
        case .localTone:
            return .flag(read: { $0.localTone }, write: { $0.localTone = $1 })
        case .saturation:
            return .number(read: { $0.saturation },
                           write: { $0.saturation = $1 })
        case .vibrance:
            return .number(read: { $0.vibrance }, write: { $0.vibrance = $1 })

        // MARK: The emulsion, and the lab's order form

        case .stock:
            return .bespoke { $0.stockID != EditState.defaults.stockID }
        case .gauge:
            return .bespoke { !$0.followsStockGauge }
        case .grain:
            return .number(read: { $0.grain }, write: { $0.grain = $1 })
        case .halation:
            // The row is stops, the edit is a multiple of the stock's authored look. Converted
            // here for the same reason warmth and tint are: the storage is the engine's unit and
            // the row's is the photographer's, and one exhaustive switch is where the two meet.
            return .number(
                read: { HalationAmount.stops(fromScale: $0.halation) },
                write: { $0.halation = HalationAmount.scale(fromStops: $1) })
        case .halationColour:
            return .number(read: { $0.halationColour },
                           write: { $0.halationColour = $1 })
        case .halationSpectrum:
            return .curve(read: { $0.halationSpectrum },
                          write: { $0.halationSpectrum = $1 })
        case .couplers:
            return .number(read: { $0.couplers }, write: { $0.couplers = $1 })
        case .push:
            return .number(read: { $0.push }, write: { $0.push = $1 })
        case .bleach:
            return .number(read: { $0.bleach }, write: { $0.bleach = $1 })
        case .expired:
            return .number(read: { $0.expiredYears },
                           write: { $0.expiredYears = $1 })
        case .grainMottle:
            return .bespoke { $0.grainMottleShare != nil }
        case .grainModel:
            return .flag(read: { $0.discGrain }, write: { $0.discGrain = $1 })
        case .couplerReach:
            return .number(read: { $0.couplerReach },
                           write: { $0.couplerReach = $1 })
        case .couplerSelf:
            return .number(read: { $0.couplerSelf },
                           write: { $0.couplerSelf = $1 })
        case .shutter:
            return .bespoke { $0.shutterSeconds != nil }

        // MARK: The print, and the grade over it

        case .paper:
            return .bespoke { !$0.paperFollowsStock }
        case .printLight:
            return .bespoke { $0.printLightKelvin != nil }
        case .printCorrection:
            return .number(read: { $0.printCorrection },
                           write: { $0.printCorrection = $1 })
        case .gradeSpace:
            return .flag(read: { $0.encodedGrade },
                         write: { $0.encodedGrade = $1 })

        case .gradeShadowsWarmth: return Self.grade(\.shadows.balanceX)
        case .gradeShadowsTint: return Self.grade(\.shadows.balanceY)
        case .gradeShadowsLevel: return Self.grade(\.shadows.level)
        case .gradeMidtonesWarmth: return Self.grade(\.midtones.balanceX)
        case .gradeMidtonesTint: return Self.grade(\.midtones.balanceY)
        case .gradeMidtonesLevel: return Self.grade(\.midtones.level)
        case .gradeHighlightsWarmth: return Self.grade(\.highlights.balanceX)
        case .gradeHighlightsTint: return Self.grade(\.highlights.balanceY)
        case .gradeHighlightsLevel: return Self.grade(\.highlights.level)

        // MARK: The frame

        case .crop:
            return .bespoke { $0.crop != nil || $0.cornerCrop != nil }
        case .straighten:
            return .number(read: { $0.straighten },
                           write: { $0.straighten = $1 })
        case .perspectiveVertical:
            return .number(read: { $0.perspectiveV },
                           write: { $0.perspectiveV = $1 })
        case .perspectiveHorizontal:
            return .number(read: { $0.perspectiveH },
                           write: { $0.perspectiveH = $1 })
        case .rotation:
            return .bespoke { $0.rotation != 0 }
        case .flip:
            return .flag(read: { $0.flipH }, write: { $0.flipH = $1 })
        case .lensCorrection:
            return .flag(read: { $0.lensCorrectionEnabled },
                         write: { $0.lensCorrectionEnabled = $1 })
        case .lensProfile:
            return .bespoke { $0.lensProfileID != nil }
        case .lensAmount:
            return .number(read: { $0.lensProfileAmount },
                           write: { $0.lensProfileAmount = $1 })
        case .selective:
            // The selection lives on the editor (`SelectiveState`) rather than on the edit, so the
            // edit cannot say whether it has been used.
            return .bespoke { _ in false }
        }
    }

    private static func grade(
        _ path: WritableKeyPath<ColorGrade, Float>
    ) -> EditControlAccess {
        .number(read: { Double($0.grade[keyPath: path]) },
                write: { $0.grade[keyPath: path] = Float($1) })
    }
}

extension EditState {
    /// What the control stands at, where it stands at a number.
    func value(of field: EditorControlField) -> Double? {
        if case .number(let read, _) = field.access { return read(self) }
        return nil
    }

    mutating func setValue(_ value: Double, of field: EditorControlField) {
        guard case .number(_, let write) = field.access else { return }
        write(&self, value)
    }

    /// The heights the curve stands at, where the control is one.
    func curve(of field: EditorControlField) -> [Double]? {
        if case .curve(let read, _) = field.access { return read(self) }
        return nil
    }

    mutating func setCurve(_ values: [Double], of field: EditorControlField) {
        guard case .curve(_, let write) = field.access else { return }
        write(&self, values)
    }

    func flag(of field: EditorControlField) -> Bool? {
        if case .flag(let read, _) = field.access { return read(self) }
        return nil
    }

    mutating func setFlag(_ on: Bool, of field: EditorControlField) {
        guard case .flag(_, let write) = field.access else { return }
        write(&self, on)
    }

    /// Whether the photographer has moved this control off its resting value — what the panel badges
    /// a section with, and what a "what did I change" list is built from.
    func isMoved(_ field: EditorControlField) -> Bool {
        switch field.access {
        case .number(let read, _):
            guard let scale = EditorControlCatalogue.control(field)?.kind.scale
            else { return false }
            return scale.isMoved(read(self))
        case .flag(let read, _):
            guard case .toggle(let restingOn)? =
                    EditorControlCatalogue.control(field)?.kind
            else { return false }
            return read(self) != restingOn
        case .curve(let read, _):
            guard let curve = EditorControlCatalogue.control(field)?.kind.curve
            else { return false }
            return curve.isMoved(read(self))
        case .bespoke(let isMoved):
            return isMoved(self)
        case .unstored:
            return false
        }
    }

    /// Put one control back where it rests, leaving every other field of the edit alone.
    mutating func reset(_ field: EditorControlField) {
        guard let control = EditorControlCatalogue.control(field) else { return }
        switch field.access {
        case .number(_, let write):
            guard let scale = control.kind.scale else { return }
            write(&self, scale.neutral)
        case .flag(_, let write):
            guard case .toggle(let restingOn) = control.kind else { return }
            write(&self, restingOn)
        case .curve(_, let write):
            guard let curve = control.kind.curve else { return }
            write(&self, curve.restingValues)
        case .bespoke, .unstored:
            break
        }
    }

    /// Every control this edit has moved, in panel order, as the film can take them.
    func movedControls(for stock: FilmStock?) -> [EditorControl] {
        EditorControlCatalogue.controls(for: stock).filter { isMoved($0.field) }
    }
}
