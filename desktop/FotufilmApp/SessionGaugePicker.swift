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

/// The gauge, chosen by eye: the same photograph as each one would have given it, from Super 8 to
/// 4x5.
final class GaugePickerView: SessionView {
    private let model: DesktopEditorModel
    private let previews = GaugePreviewCache()
    private let debounce = Debounce()
    private let grid = FlowGridView(tileSize: CGSize(width: 62, height: 78),
                                    spacing: 10)
    private var tiles: [(id: String, view: PreviewTileButton)] = []
    private let followNote = makeFootnote("")
    private var followButton: SessionButton!
    private let detailToggle = SessionToggle(description: "Magnified detail")
    private var showsDetail = true
    private var lastKey: PreviewKey?

    private static let shortNames = [
        "super8": "Super 8", "16mm": "16 mm", "super35": "Super 35",
        "35mm": "35 mm", "120": "120", "4x5": "4×5",
    ]

    init(model: DesktopEditorModel) {
        self.model = model
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        followButton = SessionButton(title: "Match the Film") { [weak self] in
            self?.followTapped()
        }

        for entry in FilmFormat.presets {
            let id = entry.id
            let tile = PreviewTileButton(
                title: Self.shortNames[id] ?? entry.format.name,
                help: entry.format.name
            ) { [weak self] in
                self?.model.edit.selectFormat(id)
                self?.refresh()
            }
            grid.addSubview(tile)
            tiles.append((id, tile))
        }

        let detailRow = SessionView()
        detailRow.translatesAutoresizingMaskIntoConstraints = false
        let detailLabel = makeLabel("Magnified Detail", size: 12)
        detailToggle.isOn = true
        detailToggle.onChange = { [weak self] _ in self?.detailChanged() }
        detailRow.addSubview(detailLabel)
        detailRow.addSubview(detailToggle)

        followButton.isHidden = true

        let stack = makeStack(.vertical, spacing: 10)
        stack.addArrangedSubview(grid)
        stack.addArrangedSubview(detailRow)
        stack.addArrangedSubview(followButton)
        stack.addArrangedSubview(followNote)
        let enlargementNote = makeFootnote(
            "Smaller film formats are enlarged more, so the same film shows "
            + "coarser grain and softer highlights.")
        stack.addArrangedSubview(enlargementNote)
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // Constrain wrapping labels to the stack width so their intrinsic width does not
            // force a single line.
            followNote.widthAnchor.constraint(equalTo: stack.widthAnchor),
            enlargementNote.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailLabel.leadingAnchor.constraint(
                equalTo: detailRow.leadingAnchor),
            detailLabel.centerYAnchor.constraint(
                equalTo: detailRow.centerYAnchor),
            detailToggle.trailingAnchor.constraint(
                equalTo: detailRow.trailingAnchor),
            detailToggle.centerYAnchor.constraint(
                equalTo: detailRow.centerYAnchor),
            detailRow.heightAnchor.constraint(
                greaterThanOrEqualTo: detailToggle.heightAnchor),
        ])
        refresh()
    }

    private func detailChanged() {
        showsDetail = detailToggle.isOn
        detailToggle.setHelp(showsDetail
            ? "Showing a magnified detail, where the film format tells"
            : "Showing the whole frame")
        refresh()
    }

    private func followTapped() {
        model.edit.followStockGauge()
        refresh()
    }

    private struct PreviewKey: Equatable {
        var state: EditState
        var token: UUID
        var detail: Bool
        var hasSource: Bool

        static func == (a: Self, b: Self) -> Bool {
            var left = a.state, right = b.state
            left.followStockGauge()
            right.followStockGauge()
            return left == right && a.token == b.token
                && a.detail == b.detail && a.hasSource == b.hasSource
        }
    }

    func refresh() {
        let selected = model.edit.selectedFormatID(sensor: model.sensorFrame)
        for (id, tile) in tiles {
            tile.setSelected(id == selected)
            tile.thumbnail.image = previews.images[id]
        }

        let following = model.edit.followsStockGauge
        followNote.isHidden = !following
        followButton.isHidden = following
        if following {
            let what = model.sensorFrame == nil
                ? "Following the film" : "Following the camera"
            followNote.textValue =
                "\(what). \(model.edit.gaugeFollowingNote(sensor: model.sensorFrame))"
        } else {
            followButton.title = model.sensorFrame == nil
                ? "Match the Film" : "Match the Camera"
            followButton.setHelp(model.sensorFrame == nil
                ? "Use each film’s native format"
                : "Cut the film to the frame this camera exposed")
        }

        let key = PreviewKey(state: model.edit, token: model.canvasResetToken,
                             detail: showsDetail,
                             hasSource: model.previewSource != nil)
        guard key != lastKey else { return }
        lastKey = key
        debounce.run(milliseconds: 650) { [weak self] in
            guard let self else { return }
            previews.refresh(source: model.previewSource, state: model.edit,
                             token: model.canvasResetToken, detail: showsDetail)
        }
    }
}
