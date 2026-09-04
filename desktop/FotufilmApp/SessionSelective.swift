import CoreGraphics
import CoreImage
import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Where the selective composite is drawn.
///
/// The develops themselves come out of `FilmRender` and are already Display P3; all this context
/// does is lay one over the other through the mask, so it wants the print's own space rather than
/// the engine's linear working one.
enum SelectiveRender {
    static let space = CGColorSpace(name: CGColorSpace.displayP3)!
    static let context = CIContext(options: [
        .workingColorSpace: space,
        .cacheIntermediates: false,
    ])
}

/// Builds desktop selective-grade controls using shared `SelectiveState` and `SelectiveMask`.
/// Selective state is session-only and is not persisted or applied to exports.
@MainActor
enum SelectiveSection {
    static func sections(model: DesktopEditorModel,
                         adjustment: (String, ClosedRange<Double>,
                                      @escaping (Double) -> String,
                                      @escaping () -> Double,
                                      @escaping (Double) -> Void) -> SliderRow)
        -> [FormSectionView] {
        var sections: [FormSectionView] = []

        let selection = FormSectionView(title: "Selection")
        selection.add(PopUpRow<SelectiveState.MaskKind>(
            "Select By",
            options: [(title: "Color", value: .color),
                      (title: "Light", value: .light),
                      (title: "Subject", value: .subject)],
            get: { [model] in model.selective.kind },
            set: { [model] in model.selective.kind = $0 }))

        if model.selective.kind == .subject {
            selection.add(NoteRow { [model] in
                guard model.subjectsSettled else {
                    return "Looking for a subject in the photograph…"
                }
                let count = model.subjectReading?.allInstances.count ?? 0
                switch count {
                case 0: return "Nothing in this photograph reads as a subject."
                case 1: return "One subject lifted from the background."
                default: return "\(count) subjects lifted from the background."
                }
            })
            selection.add(adjustment(
                "Edge", -1...1, { String(format: "%+.0f", $0 * 100) },
                { [model] in model.selective.subjectEdge },
                { [model] in model.selective.subjectEdge = $0 }))
            selection.add(adjustment(
                "Feather", 0...1, { String(format: "%.0f%%", $0 * 100) },
                { [model] in model.selective.subjectFeather },
                { [model] in model.selective.subjectFeather = $0 }))
        } else {
            selection.add(ButtonRow(
                model.isSamplingSelection ? "Click the Photo…" : "Sample a Point",
                symbol: "eyedropper",
                enabled: { [model] in model.hasPhoto }) { [model] in
                    model.isSamplingSelection.toggle()
                })
            selection.add(SwatchRow(
                "Sampled",
                colour: { [model] in
                    guard model.selective.samplePoint != nil else { return nil }
                    return (model.selective.sampleRed,
                            model.selective.sampleGreen,
                            model.selective.sampleBlue)
                }))
            selection.add(adjustment(
                "Range", 0.05...0.6, { String(format: "%.0f%%", $0 * 100) },
                { [model] in model.selective.range },
                { [model] in model.selective.range = $0 }))
            selection.add(adjustment(
                "Softness", 0.05...1, { String(format: "%.0f%%", $0 * 100) },
                { [model] in model.selective.softness },
                { [model] in model.selective.softness = $0 }))
        }

        selection.add(ToggleRow(
            "Show Mask",
            get: { [model] in model.showsSelectionMask },
            set: { [model] in model.showsSelectionMask = $0 }))
        selection.add(ButtonRow("Clear Selection", destructive: true,
                                enabled: { [model] in model.hasSelection }) {
            [model] in model.clearSelection()
        })
        sections.append(selection)

        let light = FormSectionView(title: "Selection Light")
        light.add(adjustment(
            "Exposure", -3...3, { String(format: "%+.2f", $0) },
            { [model] in model.selective.edit.exposure },
            { [model] in model.selective.edit.exposure = $0 }))
        light.add(adjustment(
            "Highlights", -1...1, { String(format: "%+.0f", $0 * 100) },
            { [model] in model.selective.edit.highlights },
            { [model] in model.selective.edit.highlights = $0 }))
        light.add(adjustment(
            "Shadows", -1...1, { String(format: "%+.0f", $0 * 100) },
            { [model] in model.selective.edit.shadows },
            { [model] in model.selective.edit.shadows = $0 }))
        let mired = ClosedRange(
            uncheckedBounds: (Double(WhiteBalance.miredRange.lowerBound),
                              Double(WhiteBalance.miredRange.upperBound)))
        light.add(adjustment(
            "Temperature", mired,
            { String(format: "%.0f K", WhiteBalance.miredToKelvin(Float($0))) },
            { [model] in model.selective.edit.temperatureMired },
            { [model] in model.selective.edit.temperatureMired = $0 }))
        light.add(adjustment(
            "Tint",
            ClosedRange(uncheckedBounds:
                (Double(WhiteBalance.tintRange.lowerBound),
                 Double(WhiteBalance.tintRange.upperBound))),
            { String(format: "%+.0f", $0) },
            { [model] in model.selective.edit.tint },
            { [model] in model.selective.edit.tint = $0 }))
        light.add(adjustment(
            "Saturation", 0...2, { String(format: "%+.0f", ($0 - 1) * 100) },
            { [model] in model.selective.edit.saturation },
            { [model] in model.selective.edit.saturation = $0 }))
        light.add(ButtonRow(
            "Match the Photograph",
            enabled: { [model] in model.selective.edit != model.edit }) {
                [model] in model.selective.edit = model.edit
            })
        sections.append(light)

        let note = FormSectionView(title: nil)
        note.add(NoteRow { [model] in
            if model.selective.kind != .subject,
               model.selective.samplePoint == nil {
                return "Sample a point to say what the selection is made of — a colour to pick every pixel like it, or a light to pick everything as bright as it. The selection's own develop is laid over the photograph wherever the two match."
            }
            return "The selection is a way of looking at the photograph rather than part of the edit: it is not saved with the document, and an export develops the photograph without it."
        })
        sections.append(note)
        return sections
    }
}

/// A colour beside its name — what the sampler picked, so it can be seen without turning the mask
/// on. Empty until something has been sampled.
final class SwatchRow: FormRowView {
    private let well = SessionView()
    private let value: PlatformLabel
    private let read: () -> (Double, Double, Double)?

    init(_ title: String, colour: @escaping () -> (Double, Double, Double)?) {
        read = colour
        value = makeLabel("", size: 11, color: .secondaryText,
                          monospacedDigits: true)
        super.init(frame: .zero)

        let name = makeLabel(title, size: 12)
        well.translatesAutoresizingMaskIntoConstraints = false
        well.backingLayer.cornerRadius = 5
        well.backingLayer.cornerCurve = .continuous
        well.backingLayer.borderWidth = 1
        well.backingLayer.borderColor = PlatformColor.primaryText
            .withAlphaComponent(0.12).cgColor

        addSubview(name)
        addSubview(value)
        addSubview(well)
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.topAnchor.constraint(equalTo: topAnchor),
            name.bottomAnchor.constraint(equalTo: bottomAnchor),
            well.trailingAnchor.constraint(equalTo: trailingAnchor),
            well.centerYAnchor.constraint(equalTo: centerYAnchor),
            well.widthAnchor.constraint(equalToConstant: 22),
            well.heightAnchor.constraint(equalToConstant: 16),
            value.trailingAnchor.constraint(equalTo: well.leadingAnchor,
                                            constant: -8),
            value.centerYAnchor.constraint(equalTo: centerYAnchor),
            value.leadingAnchor.constraint(
                greaterThanOrEqualTo: name.trailingAnchor, constant: 8),
        ])
        setAXLabel(title)
        refresh()
    }

    override func refresh() {
        guard let colour = read() else {
            well.backingLayer.backgroundColor = PlatformColor.primaryText
                .withAlphaComponent(0.06).cgColor
            value.textValue = "Nothing yet"
            return
        }
        well.backingLayer.backgroundColor = PlatformColor(
            red: colour.0, green: colour.1, blue: colour.2, alpha: 1).cgColor
        let reading = String(format: "%.0f, %.0f, %.0f", colour.0 * 255,
                             colour.1 * 255, colour.2 * 255)
        value.textValue = reading
    }

    override func applyEnabled(_ enabled: Bool) {}
}
