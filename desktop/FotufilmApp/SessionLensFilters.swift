import CoreGraphics
import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Desktop list editor for the ordered lens-filter stack.
/// Order affects air-gap veiling glare but not uniform absorption or diffusion exposure.

/// One fitted filter: what it is, what it does to white light, and the three things that can be
/// done to it.
final class FittedFilterRow: FormRowView {
    private let popUp: SessionPopUp
    private let swatch = FilterSwatchView()
    private let kind: PlatformLabel
    private let ids: [String]
    private let read: () -> String?

    /// - Parameters:
    ///   - index: the row's place in the stack, only so the accessibility label can say it.
    ///   - choose: the filter picked in this slot; `FilterChoice.noneID` takes the slot away.
    init(index: Int, count: Int, stock: FilmStock?,
         get: @escaping () -> String?,
         choose: @escaping (String) -> Void,
         move: @escaping (Int) -> Void,
         remove: @escaping () -> Void) {
        read = get
        var wall = FilterChoice.absorbing
            + FilterChoice.diffusion.filter { !FilterChoice.isNone($0.id) }
        // A filter no longer offered can still be fitted on an older edit. It keeps its own slot
        // in this menu, or the slot would name itself None while the picture still carries it.
        if let fitted = get(), !FilterChoice.isNone(fitted),
           !wall.contains(where: { $0.id == fitted }) {
            wall.append(FilterChoice(id: fitted,
                                     name: FilterChoice.name(for: fitted)))
        }
        ids = wall.map(\.id)
        popUp = SessionPopUp(description: "Filter \(index + 1)")
        kind = makeLabel("", size: 10, color: .secondaryText)
        super.init(frame: .zero)

        popUp.setOptions(wall.map(\.name))
        popUp.onPick = { [ids] picked in
            guard ids.indices.contains(picked) else { return }
            choose(ids[picked])
        }

        let up = IconButton(symbol: "chevron.up",
                            description: "Move filter nearer the lens",
                            size: 11) { move(-1) }
        let down = IconButton(symbol: "chevron.down",
                              description: "Move filter further from the lens",
                              size: 11) { move(1) }
        let bin = IconButton(symbol: "minus.circle",
                             description: "Take this filter off", size: 12,
                             action: remove)
        up.isEnabled = index > 0
        down.isEnabled = index < count - 1

        let arrows = makeStack(.horizontal, spacing: 2, alignment: .center)
        arrows.addArrangedSubview(up)
        arrows.addArrangedSubview(down)
        arrows.addArrangedSubview(bin)

        let text = makeStack(.vertical, spacing: 1)
        text.addArrangedSubview(popUp)
        text.addArrangedSubview(kind)

        let row = makeStack(.horizontal, spacing: 8, alignment: .center)
        row.addArrangedSubview(swatch)
        row.addArrangedSubview(text)
        row.addArrangedSubview(arrows)
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            swatch.widthAnchor.constraint(equalToConstant: 26),
            swatch.heightAnchor.constraint(equalToConstant: 26),
            up.widthAnchor.constraint(equalToConstant: 18),
            up.heightAnchor.constraint(equalToConstant: 18),
            down.widthAnchor.constraint(equalToConstant: 18),
            down.heightAnchor.constraint(equalToConstant: 18),
            bin.widthAnchor.constraint(equalToConstant: 18),
            bin.heightAnchor.constraint(equalToConstant: 18),
        ])
        swatch.stock = stock
        refresh()
    }

    override func refresh() {
        guard let id = read() else { return }
        if let index = ids.firstIndex(of: id), popUp.selectedIndex != index {
            popUp.selectedIndex = index
        }
        swatch.filterID = id
        // Which of the two things a filter can be, said rather than inferred from the swatch: a
        // dense ND and a black mist are both dark squares.
        kind.textValue = FilterChoice.isDiffusion(id)
            ? "Scatters" : "Absorbs"
    }
}

/// White light through one filter, as a strip — or, for a diffusion filter, which has no colour to
/// show, the halo it puts around a few bright points.
final class FilterSwatchView: SessionView {
    var filterID: String = FilterChoice.noneID {
        didSet {
            guard filterID != oldValue else { return }
            redraw()
        }
    }

    var stock: FilmStock? {
        didSet { redraw() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backingLayer.cornerRadius = 5
        backingLayer.cornerCurve = .continuous
        backingLayer.masksToBounds = true
        backingLayer.borderWidth = 1
        backingLayer.borderColor = PlatformColor.primaryText
            .withAlphaComponent(0.12).cgColor
    }

    override func draw(_ rect: CGRect) {
        guard let context = Draw.context else { return }
        let width = max(Int(bounds.width), 1)
        let height = max(Int(bounds.height), 1)

        if FilterChoice.isNone(filterID) {
            context.setFillColor(PlatformColor.primaryText
                .withAlphaComponent(0.06).cgColor)
            context.fill(bounds)
            return
        }

        if let strip = FilterChoice.spectrumStrip(for: filterID,
                                                  samples: width) {
            let step = bounds.width / CGFloat(strip.count)
            for (index, colour) in strip.enumerated() {
                context.setFillColor(red: CGFloat(colour.x),
                                     green: CGFloat(colour.y),
                                     blue: CGFloat(colour.z), alpha: 1)
                context.fill(CGRect(x: CGFloat(index) * step, y: 0,
                                    width: step + 0.5, height: bounds.height))
            }
            return
        }

        if let bloom = FilterChoice.bloomStrip(for: filterID, stock: stock,
                                               width: width, height: height) {
            let step = bounds.width / CGFloat(width)
            let rowHeight = bounds.height / CGFloat(height)
            for y in 0..<height {
                for x in 0..<width {
                    let value = CGFloat(bloom[y * width + x])
                    context.setFillColor(red: value, green: value,
                                         blue: value, alpha: 1)
                    context.fill(CGRect(x: CGFloat(x) * step,
                                        y: CGFloat(y) * rowHeight,
                                        width: step + 0.5,
                                        height: rowHeight + 0.5))
                }
            }
            return
        }

        context.setFillColor(PlatformColor.primaryText
            .withAlphaComponent(0.06).cgColor)
        context.fill(bounds)
    }
}

/// The section the Lens panel puts the stack in, built from the edit and writing back to it.
///
/// Free of the inspector so the same list can be raised from anywhere that holds an edit; the
/// panel only has to hand over how to read and write one.
@MainActor
enum LensFilterSection {
    /// Every filter a slot may be set to, in the order the drawer is arranged: bare glass, the
    /// absorbing wall, then the diffusion families.
    static var wall: [FilterChoice] {
        FilterChoice.absorbing
            + FilterChoice.diffusion.filter { !FilterChoice.isNone($0.id) }
    }

    static func rows(model: DesktopEditorModel) -> [FormRowView] {
        var rows: [FormRowView] = []
        let fitted = model.edit.lensFilterIDs
        let stock = model.edit.stock

        for index in fitted.indices {
            rows.append(FittedFilterRow(
                index: index, count: fitted.count, stock: stock,
                get: { [model] in
                    let now = model.edit.lensFilterIDs
                    return now.indices.contains(index) ? now[index] : nil
                },
                choose: { [model] id in
                    guard model.edit.lensFilterIDs.indices.contains(index)
                    else { return }
                    if FilterChoice.isNone(id) {
                        model.edit.lensFilterIDs.remove(at: index)
                    } else {
                        model.edit.lensFilterIDs[index] = id
                    }
                },
                move: { [model] step in
                    var ids = model.edit.lensFilterIDs
                    let destination = index + step
                    guard ids.indices.contains(index),
                          ids.indices.contains(destination) else { return }
                    ids.swapAt(index, destination)
                    model.edit.lensFilterIDs = ids
                },
                remove: { [model] in
                    guard model.edit.lensFilterIDs.indices.contains(index)
                    else { return }
                    model.edit.lensFilterIDs.remove(at: index)
                }))
        }

        // The last row is always empty and always offers the whole drawer: picking from it fits
        // another filter in front of the ones already on. It reads back as "Add Filter" rather
        // than as whatever was just chosen, because what it chose is now a row of its own.
        let add = PopUpRow<String>(
            "Add Filter",
            options: [(title: "Add Filter…", value: FilterChoice.noneID)]
                + wall.filter { !FilterChoice.isNone($0.id) }
                    .map { (title: $0.name, value: $0.id) },
            get: { FilterChoice.noneID },
            set: { [model] id in
                guard !FilterChoice.isNone(id) else { return }
                model.edit.lensFilterIDs.append(id)
            })
        rows.append(add)

        let resolved = FilterChoice.resolve(fitted)
        if !resolved.absorbing.isEmpty {
            rows.append(PopUpRow<LensFilterCompensation>(
                "Metering",
                options: LensFilterCompensation.allCases.map {
                    (title: $0.label, value: $0)
                },
                get: { [model] in model.edit.lensFilterMetering },
                set: { [model] in model.edit.lensFilterMetering = $0 }))
        }
        if !fitted.isEmpty {
            rows.append(ButtonRow("Take Them All Off", destructive: true) {
                [model] in model.edit.lensFilterIDs = []
            })
        }
        return rows
    }

    /// What the section has to say for itself under the rows: how the exposure was set behind the
    /// stack, and the one case the engine cannot honour.
    static func note(for model: DesktopEditorModel) -> String {
        let fitted = model.edit.lensFilterIDs
        guard !fitted.isEmpty else {
            return "Filters go on in front of everything the film does — a conversion filter to change the light, a neutral density to open the lens, a mist to bloom the highlights."
        }
        let resolved = FilterChoice.resolve(fitted)
        var lines: [String] = []
        if !resolved.unusedDiffusion.isEmpty {
            lines.append("Only the first diffusion filter acts; the rest are ignored, because two halos compose as a convolution of their profiles and not as a product of their numbers.")
        }
        if !resolved.absorbing.isEmpty {
            lines.append(model.edit.lensFilterMetering.detail)
        }
        return lines.joined(separator: "\n\n")
    }
}

extension LensFilterCompensation {
    /// The line under the metering pop-up, in the inspector's own voice.
    var detail: String {
        switch self {
        case .none:
            return "The exposure was not changed, so the filter's light loss lands on the film as underexposure — a strobe metered before the filter went on, or any fixed manual exposure."
        case .throughTheLens:
            return "The camera metered through the filter, which is what a meter behind the lens does: a neutral density becomes exactly invisible, and a deep red still underexposes."
        case .filmSpeed:
            return "The published filter factor was applied, worked out against the emulsion's own sensitivities. It restores the green-sensitive record and only that one, which is what a filter factor is for."
        }
    }
}
