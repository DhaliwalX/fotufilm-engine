import CoreGraphics
import Foundation
import QuartzCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// The leading column: every installed stock, each showing the open picture developed on it.
///
/// Collapsed it is only the pictures — no names, no search, no footnote — because at that width a
/// name would be three letters and an ellipsis.
final class StockSidebarViewController: SessionViewController {
    private let model: DesktopEditorModel
    private let previews = StockPreviewCache()
    private let debounce = Debounce()

    /// The collapsed column's thumbnail, and with its padding the strip's own width.
    static let stripThumbnail: CGFloat = 44
    static let stripWidth: CGFloat = stripThumbnail + 16
    static let panelWidth: CGFloat = 236

    private let search = SessionSearchField(placeholder: "Search")
    private let list = ScrollColumn(inset: 8, pad: 4, bottom: 8, spacing: 2)
    private let strip = ScrollColumn(inset: 0, pad: 8, bottom: 8, spacing: 6,
                                     alignment: .center, showsScroller: false)
    private let footer = makeStack(.vertical, spacing: 4, alignment: .leading)
    private let emptyLabel = makeFootnote("")
    private let selection = CALayer()
    private lazy var makeFilm = SessionButton(
        title: "Film Workshop…", symbol: "wand.and.stars", borderless: true
    ) { [weak self] in
        self?.onOpenWorkshop?()
    }
    #if canImport(UIKit)
    private lazy var upgrade = SessionButton(
        title: "Unlock Fotufilm Pro…", symbol: "lock.open", prominent: true
    ) { [weak self] in
        self?.onUpgrade?()
    }
    #endif

    #if os(macOS)
    private lazy var loadPack = SessionButton(
        title: "Load custom pack…", symbol: "folder", borderless: true
    ) {
        NSApp.sendAction(#selector(AppDelegate.importFilmPack(_:)), to: NSApp.delegate, from: nil)
    }
    #endif

    private var listRows: [(id: String, view: StockRowView)] = []
    private var stripTiles: [(id: String, view: PreviewTileButton)] = []
    private var filter = ""
    private var lastKey: PreviewKey?
    private var lastSelectionID: String?
    private var searchTop: NSLayoutConstraint?
    private var stripTop: NSLayoutConstraint?
    private var collapseRun = 0
    private var wantsEmptyLabel = false

    /// How far the column's contents are held below its own top edge. The column runs to the
    /// window's edge, and on the Mac the toolbar and the traffic lights are over that edge; this is
    /// what keeps a search field from sitting underneath them.
    var topInset: CGFloat = 0 {
        didSet {
            guard topInset != oldValue else { return }
            searchTop?.constant = topInset + 10
            stripTop?.constant = topInset
        }
    }

    var collapsed = false {
        didSet {
            guard collapsed != oldValue else { return }
            applyCollapsed(animated: true)
        }
    }

    init(model: DesktopEditorModel) {
        self.model = model
        super.init()
    }

    /// Opens the film workshop. Set by the editor, which owns presenting things.
    var onOpenWorkshop: (() -> Void)?
    /// Opens the App Store purchase on iOS.
    var onUpgrade: (() -> Void)?

    override func loadView() {
        let root = SessionView()
        search.onChange = { [weak self] _ in self?.searchChanged() }
        root.addSubview(search)
        root.addSubview(list)

        // The way into the workshop from the column the films are in. It is here rather than only
        // in the menu bar because the iPad has no menu bar, and making a film should not be a thing
        // only the Mac can reach. The iPad's purchase entry point shares the footer, where it stays
        // reachable without a keyboard.
        #if canImport(UIKit)
        footer.addArrangedSubview(upgrade)
        upgrade.heightAnchor.constraint(equalToConstant: 30).isActive = true
        #endif
        footer.addArrangedSubview(makeFilm)
        makeFilm.heightAnchor.constraint(equalToConstant: 30).isActive = true
        #if os(macOS)
        footer.addArrangedSubview(loadPack)
        loadPack.heightAnchor.constraint(equalToConstant: 30).isActive = true
        #endif
        for button in footer.arrangedSubviews {
            button.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
        }
        root.addSubview(footer)

        // The lit row is one layer that travels, rather than a fill that turns on in one row and
        // off in another: down a list of films that appears as a single movement.
        selection.backgroundColor = Chrome.selectionFill.cgColor
        selection.cornerRadius = 7
        selection.cornerCurve = .continuous
        selection.opacity = 0
        list.content.backingLayer.addSublayer(selection)

        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        root.addSubview(emptyLabel)

        strip.opacity = 0
        strip.isHidden = true
        root.addSubview(strip)

        let searchTop = search.topAnchor.constraint(equalTo: root.topAnchor,
                                                    constant: topInset + 10)
        let stripTop = strip.topAnchor.constraint(equalTo: root.topAnchor,
                                                  constant: topInset)
        self.searchTop = searchTop
        self.stripTop = stripTop

        NSLayoutConstraint.activate([
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor,
                                            constant: 10),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor,
                                             constant: -10),
            searchTop,
            list.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            list.topAnchor.constraint(equalTo: search.bottomAnchor,
                                      constant: 8),
            list.bottomAnchor.constraint(equalTo: footer.topAnchor,
                                         constant: -6),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor,
                                             constant: 10),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor,
                                              constant: -10),
            footer.bottomAnchor.constraint(
                equalTo: root.safeAreaLayoutGuide.bottomAnchor, constant: -10),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor,
                                                constant: 18),
            emptyLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor,
                                                 constant: -18),
            strip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stripTop,
            strip.bottomAnchor.constraint(
                equalTo: root.safeAreaLayoutGuide.bottomAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildStrip()
        buildList()
        // Said outright rather than left to the initial values, so the first layout starts from a
        // state the animated path can reason about.
        applyCollapsed(animated: false)
        refresh()
    }

    /// Re-reads the pack. Called when a film has been made, imported or deleted in the workshop:
    /// the column is a view of what is installed, and what is installed just changed.
    func reloadStocks() {
        for tile in stripTiles {
            strip.column.removeArrangedSubview(tile.view)
            tile.view.removeFromSuperview()
        }
        stripTiles.removeAll()
        buildStrip()
        buildList()
        refresh()
    }

    private func searchChanged() {
        let next = search.text
        guard next != filter else { return }
        filter = next
        buildList()
        refresh()
    }

    private var matches: [FilmChoice] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return FilmChoice.editorWall }
        return FilmChoice.editorWall.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.subtitle.localizedCaseInsensitiveContains(query)
        }
    }

    private func buildList() {
        for view in list.column.arrangedSubviews {
            list.column.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        listRows.removeAll()
        lastSelectionID = nil

        for preset in matches {
            let id = preset.id
            let locked = !ProAccess.allowsStock(id)
            let row = StockRowView(choice: preset, locked: locked) {
                [weak self] in
                self?.choose(id)
            }
            list.column.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.column.widthAnchor)
                .isActive = true
            listRows.append((id, row))
        }

        // Normal always stands, so an empty pack is a footnote rather than an empty column.
        if StockPreset.all.isEmpty, filter.isEmpty {
            emptyLabel.textValue = "Install a stock pack to develop on film."
            wantsEmptyLabel = true
        } else if listRows.isEmpty {
            emptyLabel.textValue = "Nothing matches “\(filter)”."
            wantsEmptyLabel = true
        } else {
            wantsEmptyLabel = false
        }
        emptyLabel.isHidden = collapsed || !wantsEmptyLabel

        // The rows arrive together rather than one at a time: this is a filter being applied, not a
        // list being loaded.
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = Motion.quick
        list.column.backingLayer.add(fade, forKey: "rows")
    }

    private func buildStrip() {
        for preset in FilmChoice.editorWall {
            let id = preset.id
            let tile = PreviewTileButton(title: "", help: preset.name) {
                [weak self] in
                self?.choose(id)
            }
            tile.setLocked(!ProAccess.allowsStock(id))
            strip.column.addArrangedSubview(tile)
            NSLayoutConstraint.activate([
                tile.widthAnchor.constraint(
                    equalToConstant: Self.stripThumbnail),
                tile.heightAnchor.constraint(
                    equalToConstant: Self.stripThumbnail),
            ])
            stripTiles.append((id, tile))
        }
    }

    private func applyCollapsed(animated: Bool) {
        // The other column is also showing search and a footnote, neither of which belongs in the
        // strip, so they arrive and leave with it.
        let showing: [PlatformView] = collapsed ? [strip] : [list, search, footer]
        let hiding: [PlatformView] = collapsed
            ? [list, search, footer, emptyLabel] : [strip]
        for view in showing { view.isHidden = false }
        if !collapsed { emptyLabel.isHidden = !wantsEmptyLabel }

        collapseRun += 1
        let run = collapseRun
        guard animated else {
            for view in showing { view.opacity = 1 }
            emptyLabel.opacity = collapsed ? 0 : 1
            hiding.forEach { $0.isHidden = true; $0.opacity = 0 }
            return
        }
        let empty = emptyLabel
        let expanding = !collapsed
        Motion.run(Motion.panel * 0.6) {
            for view in showing { view.animated.opacity = 1 }
            if expanding { empty.animated.opacity = 1 }
            for view in hiding { view.animated.opacity = 0 }
        } completion: { [weak self] in
            // Ignore stale completions after a newer layout request.
            guard let self, run == self.collapseRun else { return }
            for view in hiding { view.isHidden = true }
        }
    }

    private struct PreviewKey: Equatable {
        var state: EditState
        var token: UUID
        var hasSource: Bool

        static func == (a: Self, b: Self) -> Bool {
            var left = a.state, right = b.state
            left.stockID = ""
            right.stockID = ""
            return left == right && a.token == b.token
                && a.hasSource == b.hasSource
        }
    }

    func refresh() {
        #if canImport(UIKit)
        // TestFlight and Xcode builds remain complimentary but still expose the purchase sheet for
        // App Review. Only an owned transaction removes the entry point.
        upgrade.isHidden = ProAccess.purchased
        #endif
        let selectedID = model.edit.stockID
        // The chosen film shows the canvas's own print until its small copy has been developed, so
        // the column is never blank about the one thing the user just clicked.
        let standIn = model.processed

        for (id, row) in listRows {
            row.thumbnail.image = previews.images[id]
                ?? (id == selectedID ? standIn : nil)
            row.setSelected(id == selectedID)
        }
        for (id, tile) in stripTiles {
            tile.thumbnail.image = previews.images[id]
                ?? (id == selectedID ? standIn : nil)
            tile.setSelected(id == selectedID)
        }
        moveSelection(to: selectedID)

        let key = PreviewKey(state: model.edit, token: model.canvasResetToken,
                             hasSource: model.previewSource != nil)
        guard key != lastKey else { return }
        lastKey = key
        // The first pass is immediate — an opened photograph should fill the column — and every
        // pass after it waits for the controls to settle.
        let wait = previews.images.isEmpty ? 0 : 650
        debounce.run(milliseconds: wait) { [weak self] in
            guard let self else { return }
            previews.refresh(source: model.previewSource, state: model.edit,
                             token: model.canvasResetToken)
        }
    }

    private func choose(_ id: String) {
        #if canImport(UIKit)
        guard ProGate.allowStock(id) else { return }
        #endif
        model.edit.stockID = id
        refresh()
    }

    private func moveSelection(to id: String) {
        guard let row = listRows.first(where: { $0.id == id })?.view else {
            selection.opacity = 0
            lastSelectionID = nil
            return
        }
        list.content.layoutNow()
        let frame = list.content.convert(row.bounds, from: row)
            .insetBy(dx: -4, dy: 0)
        let first = lastSelectionID == nil
        lastSelectionID = id
        if first {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            selection.frame = frame
            selection.opacity = 1
            CATransaction.commit()
            return
        }
        Motion.spring(selection, key: "position",
                      from: Box.point(CGPoint(x: selection.frame.midX,
                                              y: selection.frame.midY)),
                      to: Box.point(CGPoint(x: frame.midX, y: frame.midY)),
                      damping: 20, stiffness: 300)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selection.bounds = CGRect(origin: .zero, size: frame.size)
        selection.opacity = 1
        CATransaction.commit()
    }
}

/// One film in the column: its print, its name, and what it says for itself.
final class StockRowView: SessionView {
    let thumbnail = ThumbnailView()
    private let perform: () -> Void
    private let name: PlatformLabel
    private let hover = CALayer()
    #if !canImport(UIKit)
    private var tracking: NSTrackingArea?
    #endif

    init(choice: FilmChoice, locked: Bool, action: @escaping () -> Void) {
        perform = action
        name = makeLabel(choice.name, size: 13)
        super.init(frame: .zero)

        hover.cornerRadius = 7
        hover.cornerCurve = .continuous
        hover.backgroundColor = PlatformColor.clear.cgColor
        backingLayer.insertSublayer(hover, at: 0)

        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        thumbnail.setLocked(locked)
        addSubview(thumbnail)

        let text = makeStack(.vertical, spacing: 1)
        text.addArrangedSubview(name)
        if !choice.subtitle.isEmpty {
            text.addArrangedSubview(
                makeLabel(choice.subtitle, size: 11, color: .secondaryText))
        }
        addSubview(text)

        NSLayoutConstraint.activate([
            thumbnail.leadingAnchor.constraint(equalTo: leadingAnchor,
                                               constant: 6),
            thumbnail.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnail.widthAnchor.constraint(equalToConstant: 40),
            thumbnail.heightAnchor.constraint(equalToConstant: 40),
            text.leadingAnchor.constraint(equalTo: thumbnail.trailingAnchor,
                                          constant: 10),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor,
                                           constant: -8),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 48),
        ])
        setHelp(choice.subtitle.isEmpty ? choice.name
            : "\(choice.name) — \(choice.subtitle)")
        setAXLabel(locked ? "\(choice.name), requires Fotufilm Pro"
                         : choice.name)
        #if canImport(UIKit)
        accessibilityTraits = .button
        addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(tapped)))
        #else
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        #endif
    }

    override func layoutContents() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hover.frame = bounds.insetBy(dx: 2, dy: 1)
        CATransaction.commit()
    }

    func setSelected(_ selected: Bool) {
        // The thumbnail's own ring is left to the strip: in the list the lit row says it, and two
        // marks for one fact is one too many.
        #if canImport(UIKit)
        accessibilityTraits = selected ? [.button, .selected] : .button
        #else
        setAccessibilitySelected(selected)
        #endif
    }

    private func setHovered(_ hovered: Bool) {
        Motion.run(Motion.quick) { [hover] in
            hover.backgroundColor = hovered
                ? PlatformColor.primaryText.withAlphaComponent(0.06).cgColor
                : PlatformColor.clear.cgColor
        }
    }

    #if canImport(UIKit)

    @objc private func tapped() { perform() }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        setHovered(true)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        setHovered(false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>,
                                   with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        setHovered(false)
    }

    override func accessibilityActivate() -> Bool {
        perform()
        return true
    }

    #else

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited,
                                            .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }

    override func mouseExited(with event: NSEvent) { setHovered(false) }

    override func mouseUp(with event: NSEvent) {
        setHovered(false)
        guard bounds.contains(convert(event.locationInWindow, from: nil))
        else { return }
        perform()
    }

    override func accessibilityPerformPress() -> Bool {
        perform()
        return true
    }

    #endif
}
