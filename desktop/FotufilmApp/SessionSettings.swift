import Combine
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

/// Desktop editor for `AppSettings`. Changes are applied immediately; camera and library settings
/// are omitted because they do not apply on macOS.
final class SettingsSheetController: SessionViewController {
    var onClose: (() -> Void)?

    private let column = ScrollColumn(inset: 0, pad: 4, bottom: 8)
    private var rows: [FormRowView] = []
    private var sink: AnyCancellable?
    private var proSink: AnyCancellable?
    private var structure = ""

    private var settings: AppSettings { .shared }

    override func loadView() {
        let root = SessionView(frame: CGRect(x: 0, y: 0, width: 520,
                                             height: 640))

        let title = makeLabel("Settings", size: 15, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(title)

        let gap = PlatformView()
        gap.setContentHuggingPriority(.init(1), for: .horizontal)
        let done = SessionButton(title: "Done", prominent: true) { [weak self] in
            self?.close()
        }
        let buttons = makeStack(.horizontal, spacing: 10, alignment: .center)
        buttons.addArrangedSubview(gap)
        buttons.addArrangedSubview(done)
        root.addSubview(buttons)
        root.addSubview(column)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor,
                                           constant: 22),
            title.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor,
                                       constant: 20),
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor,
                                            constant: 22),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor,
                                             constant: -22),
            column.topAnchor.constraint(equalTo: title.bottomAnchor,
                                        constant: 14),
            column.bottomAnchor.constraint(equalTo: buttons.topAnchor,
                                           constant: -14),
            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor,
                                             constant: 22),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor,
                                              constant: -22),
            buttons.bottomAnchor.constraint(
                equalTo: root.safeAreaLayoutGuide.bottomAnchor, constant: -18),
        ])
        #if canImport(UIKit)
        // A form sheet uses this when there is room, but may shrink in Split View or Stage Manager.
        // Hard minimums made the same form clip and log broken constraints in those widths.
        preferredContentSize = root.frame.size
        #else
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 500),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 520),
        ])
        #endif
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        build()
        // A setting changed anywhere — the Film menu's own two switches, a reset — moves the
        // rows. The whole column is only rebuilt when its *shape* changes, which for this sheet
        // means the film model going back to the calibrated values and the restore row going
        // quiet with it.
        sink = settings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        proSink = NotificationCenter.default.publisher(for: .proAccessChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    private var structureSignature: String {
        "\(AppSettings.isFilmModelAdjusted)-\(ProAccess.isPro)-\(ProAccess.purchased)"
    }

    private func refresh() {
        if structureSignature != structure {
            build()
            return
        }
        rows.forEach { $0.refresh() }
    }

    private func build() {
        structure = structureSignature
        rows.removeAll()
        for view in column.column.arrangedSubviews {
            column.column.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for section in sections() {
            column.column.addArrangedSubview(section)
            section.widthAnchor.constraint(
                equalTo: column.column.widthAnchor).isActive = true
            rows.append(contentsOf: section.rows)
        }
    }

    private func sections() -> [FormSectionView] {
        var result: [FormSectionView] = []
        #if os(iOS)
        if !ProAccess.purchased { result.append(proPurchase()) }
        #endif
        result += [newPhotos(), output(), negativePreview(), filmModel()]
        result.append(reset())
        return result
    }

    #if os(iOS)
    private func proPurchase() -> FormSectionView {
        let section = FormSectionView(title: "Fotufilm Pro")
        section.add(ButtonRow("Unlock Fotufilm Pro…") {
            ProGate.present()
        })
        section.add(NoteRow(
            "One purchase opens \(ProCatalogue.unlockedFilmClaim) more films, "
                + "video development, the Lab, custom films, and lens filters."
        ))
        return section
    }
    #endif


    // MARK: - New photos

    private func newPhotos() -> FormSectionView {
        let section = FormSectionView(title: "New Photos")

        // Films this build cannot load are left out rather than shown locked: a starting film is
        // what every new photograph opens on, and one that will not load is a setting that
        // silently does nothing.
        let films = [(title: StockPreset.noFilmName, value: StockPreset.noFilmID)]
            + StockPreset.all.filter { ProAccess.allowsStock($0.id) }
                .map { (title: $0.name, value: $0.id) }
        section.add(PopUpRow<String>(
            "Starting Film", options: films,
            get: { AppSettings.shared.stockID },
            set: { AppSettings.shared.stockID = $0 }))

        let gauges = [(title: "Match the Film", value: String?.none)]
            + FilmFormat.presets.map {
                (title: $0.format.name, value: String?($0.id))
            }
        section.add(PopUpRow<String?>(
            "Film Format", options: gauges,
            get: { AppSettings.shared.formatID },
            set: { AppSettings.shared.formatID = $0 }))

        section.add(ToggleRow(
            "Suggest a Film Automatically",
            get: { AppSettings.shared.autoStock },
            set: { AppSettings.shared.autoStock = $0 }))
        section.add(NoteRow("Chooses a film for each photograph as it opens, learning from the films you keep. Your own choice always wins."))
        section.add(ButtonRow(
            "Forget What I’ve Taught It", destructive: true,
            enabled: { StockPreferenceStore.shared.hasLearnedAnything }) {
                StockPreferenceStore.shared.forget()
            })
        return section
    }

    // MARK: - Output

    private func output() -> FormSectionView {
        let section = FormSectionView(title: "Output")
        let ranges = AppSettings.DynamicRange.allCases.map {
            (title: $0 == .hdr ? "HDR" : "Standard", value: $0)
        }
        section.add(PopUpRow<AppSettings.DynamicRange>(
            "Photos", options: ranges,
            get: { AppSettings.shared.stillDynamicRange },
            set: { AppSettings.shared.stillDynamicRange = $0 }))
        section.add(PopUpRow<AppSettings.DynamicRange>(
            "Videos", options: ranges,
            get: { AppSettings.shared.videoDynamicRange },
            set: { AppSettings.shared.videoDynamicRange = $0 }))
        section.add(NoteRow("Standard works everywhere. HDR keeps the highlights the film developed above paper white, on a screen that can show them."))

        section.add(PopUpRow<AppSettings.RenderingMode>(
            "Photo Quality",
            options: AppSettings.RenderingMode.allCases.map {
                (title: $0.label, value: $0)
            },
            get: { AppSettings.shared.renderingMode },
            set: { AppSettings.shared.renderingMode = $0 }))
        section.add(PopUpRow<AppSettings.VideoDevelopQuality>(
            "Video Quality",
            options: AppSettings.VideoDevelopQuality.allCases.map {
                (title: $0.label, value: $0)
            },
            get: { AppSettings.shared.videoDevelopQuality },
            set: { AppSettings.shared.videoDevelopQuality = $0 }))
        section.add(PopUpRow<AppSettings.VideoExportBitrate>(
            "Video File Size",
            options: AppSettings.VideoExportBitrate.allCases.map {
                (title: $0.label, value: $0)
            },
            get: { AppSettings.shared.videoExportBitrate },
            set: { AppSettings.shared.videoExportBitrate = $0 }))
        section.add(NoteRow("Accurate evaluates the film’s curves exactly; fast interpolates them. Video quality decides whether a clip develops at its own resolution or at the fast road’s internal 1080p."))
        return section
    }

    // MARK: - Negative output and preview

    private func negativePreview() -> FormSectionView {
        let section = FormSectionView(title: "Negative")
        section.add(PopUpRow<NegativeViewing>(
            "Reading",
            options: NegativeViewing.allCases.map {
                (title: $0.name, value: $0)
            },
            get: { AppSettings.shared.negativeViewing },
            set: { AppSettings.shared.negativeViewing = $0 }))
        section.add(NoteRow("Controls negative output and Show Negative in the editor. A light box sets its lamp so the clear film base sits just under white and keeps the orange mask; a scanner divides by the film base, so the orange mask reads white."))
        return section
    }

    // MARK: - Film model

    private func filmModel() -> FormSectionView {
        let section = FormSectionView(title: "Film Model")
        section.add(ToggleRow(
            "Disc Grain",
            get: { AppSettings.shared.discGrainEnabled },
            set: { AppSettings.shared.discGrainEnabled = $0 }))
        section.add(ToggleRow(
            "Estimated Halation Shape",
            get: { AppSettings.shared.estimatedHalationEnabled },
            set: { AppSettings.shared.estimatedHalationEnabled = $0 }))

        section.add(couplerRow("Color Separation",
                               get: { AppSettings.shared.couplerRange },
                               set: { AppSettings.shared.couplerRange = $0 }))
        section.add(couplerRow(
            "Red–Green",
            get: { AppSettings.shared.couplerBarrierRedGreen },
            set: { AppSettings.shared.couplerBarrierRedGreen = $0 }))
        section.add(couplerRow(
            "Green–Blue",
            get: { AppSettings.shared.couplerBarrierGreenBlue },
            set: { AppSettings.shared.couplerBarrierGreenBlue = $0 }))
        section.add(couplerRow("Edge Contrast",
                               get: { AppSettings.shared.couplerSelf },
                               set: { AppSettings.shared.couplerSelf = $0 }))
        section.add(NoteRow("These apply to every film and start every new photograph, which then carries its own. Color separation moves both layer pairs together; set a pair on its own to separate them. Edge contrast is the subtle sharpening development itself creates."))
        section.add(ButtonRow(
            "Restore Film Model", destructive: true,
            enabled: { AppSettings.isFilmModelAdjusted }) {
                let settings = AppSettings.shared
                settings.resetCouplerGeometry()
                settings.discGrainEnabled = false
                settings.estimatedHalationEnabled =
                    AppSettings.defaultEstimatedHalationEnabled
            })
        return section
    }

    private func couplerRow(_ title: String, get: @escaping () -> Double,
                            set: @escaping (Double) -> Void) -> SliderRow {
        SliderRow(title, range: 0...3,
                  display: { String(format: "%.1f×", $0) },
                  get: get,
                  set: { set((($0 * 10).rounded()) / 10) },
                  began: {}, ended: {})
    }

    // MARK: - Reset

    private func reset() -> FormSectionView {
        let section = FormSectionView(title: nil)
        section.add(ButtonRow("Reset All Settings", destructive: true) {
            [weak self] in self?.confirmReset()
        })
        section.add(NoteRow("Restores Fotufilm’s original settings. Your photographs and edits are not changed."))
        return section
    }

    private func confirmReset() {
        #if canImport(UIKit)
        let alert = UIAlertController(
            title: "Reset All Settings?",
            message: "This restores Fotufilm’s original settings. Your photos and edits will not change.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Reset", style: .destructive) {
            _ in AppSettings.shared.reset()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
        #else
        let alert = NSAlert()
        alert.messageText = "Reset All Settings?"
        alert.informativeText = "This restores Fotufilm’s original settings. Your photos and edits will not change."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            AppSettings.shared.reset()
        }
        #endif
    }

    /// Escape. `NSResponder.cancelOperation` forwards to this selector, which is how the export
    /// sheets take it too — without it the sheet closes and the editor never hears, and the flag
    /// that keeps two sheets from standing at once stays raised for the rest of the session.
    ///
    /// A form sheet on the iPad is dismissed by dragging it down, which is not a responder
    /// message at all; `viewDidDisappear` below is what catches that, and it catches Escape as
    /// well. Both are here because the cost of missing either is the same: a session that will
    /// never open another sheet.
    #if canImport(UIKit)
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        finish()
    }
    #else
    @objc func cancel(_ sender: Any?) { close() }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        finish()
    }
    #endif

    private func finish() {
        onClose?()
        onClose = nil
    }

    private func close() {
        finish()
        #if canImport(UIKit)
        presentingViewController?.dismiss(animated: true)
        #else
        presentingViewController?.dismiss(self)
        #endif
    }
}
