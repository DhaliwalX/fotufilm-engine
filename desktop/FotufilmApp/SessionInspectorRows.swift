import Foundation

#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmEditModel)
import FotufilmEditModel
#endif

@MainActor
struct InspectorRowFactory {
    let model: DesktopEditorModel
    let adjustment: (String, ClosedRange<Double>, @escaping (Double) -> String,
                     @escaping () -> Double, @escaping (Double) -> Void) -> SliderRow
    let bespoke: (EditorControl) -> [FormRowView]

    var activeStock: FilmStock? {
        model.edit.hasFilm ? model.edit.stock : nil
    }

    func controls(in section: EditorControlSection) -> [EditorControl] {
        EditorControlCatalogue.controls(in: section, for: activeStock, on: .desktop)
    }

    func rows(in section: EditorControlSection) -> [FormRowView] {
        controls(in: section).flatMap(rows(for:))
    }

    func rows(for control: EditorControl) -> [FormRowView] {
        let made = makeRows(for: control)
        #if !canImport(UIKit)
        if let row = made.first(where: { !($0 is NoteRow) }) {
            row.addHelp { control.detail }
        }
        #endif
        return made
    }

    private func makeRows(for control: EditorControl) -> [FormRowView] {
        switch control.kind {
        case .slider(let scale):
            return [slider(control, scale: scale)]
        case .chips(let scale, let choices):
            return [PopUpRow<Double>(
                control.title,
                options: choices.map { (title: $0.label, value: $0.value) },
                get: { [model] in model.edit.value(of: control.field) ?? scale.neutral },
                set: { [model] value in
                    var next = model.edit
                    next.setValue(value, of: control.field)
                    model.edit = next
                })]
        case .toggle:
            return [toggle(control)]
        case .curve(let curve):
            return [self.curve(control, curve: curve)]
        case .menu(.fixed(let choices)):
            if control.field == .enlarger { return bespoke(control) }
            return [menu(control, choices: choices)]
        case .menu(.dynamic), .takeover:
            return bespoke(control)
        }
    }

    func slider(_ control: EditorControl, scale: EditorControlScale) -> SliderRow {
        let field = control.field
        return adjustment(control.title, scale.range, scale.unit.format,
                          { [model] in model.edit.value(of: field) ?? scale.neutral },
                          { [model] value in
                              var next = model.edit
                              next.setValue(scale.stops.isEmpty ? value : Self.snapped(value, to: scale.stops),
                                            of: field)
                              model.edit = next
                          })
    }

    static func snapped(_ value: Double, to stops: [Double]) -> Double {
        stops.min { abs($0 - value) < abs($1 - value) } ?? value
    }

    func toggle(_ control: EditorControl) -> ToggleRow {
        let field = control.field
        return ToggleRow(
            control.title,
            get: { [model] in model.edit.flag(of: field) ?? false },
            set: { [model] value in
                var next = model.edit
                next.setFlag(value, of: field)
                model.edit = next
            })
    }

    func curve(_ control: EditorControl, curve: EditorControlCurve) -> ControlCurveFormRow {
        let field = control.field
        return ControlCurveFormRow(
            control.title, curve: curve,
            get: { [model] in model.edit.curve(of: field) ?? curve.restingValues },
            set: { [model] values in
                var next = model.edit
                next.setCurve(values, of: field)
                model.edit = next
            },
            began: { [weak model] in model?.beginContinuousEdit() },
            ended: { [weak model] in model?.endContinuousEdit() })
    }

    func menu(_ control: EditorControl, choices: [EditorMenuChoice]) -> FormRowView {
        switch control.field {
        case .sceneLight:
            return PopUpRow<Int>(
                control.title,
                options: choices.enumerated().map { (title: $1.label, value: $0) },
                get: { [model] in model.edit.sourceLightIndex },
                set: { [model] in model.edit.sourceLightIndex = $0 })
        case .grainMottle:
            return PopUpRow<Double?>(
                control.title,
                options: choices.map { (title: $0.label, value: $0.value) },
                get: { [model] in model.edit.grainMottleShare },
                set: { [model] in model.edit.grainMottleShare = $0 })
        case .rotation:
            return PopUpRow<Int>(
                control.title,
                options: choices.map { (title: $0.label, value: Int($0.value ?? 0)) },
                get: { [model] in model.edit.rotation },
                set: { [model] in model.edit.rotation = $0 })
        default:
            return PopUpRow<Int>(
                control.title,
                options: choices.enumerated().map { (title: $1.label, value: $0) },
                get: { 0 },
                set: { _ in })
        }
    }
}
