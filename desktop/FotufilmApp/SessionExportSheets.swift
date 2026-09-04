import AVFoundation
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

/// A sheet that reports when it has gone, so the editor can put the model's request back down.
protocol ExportSheet: AnyObject {
    var onClose: (() -> Void)? { get set }
}

/// One choice in an export sheet: a name, a line about it, and a tick when it is the one.
final class OptionRow: FormRowView {
    private let titleLabel: PlatformLabel
    private let detailLabel: PlatformLabel
    private let check = PlatformImageView()
    private let highlight = CALayer()
    private let choose: () -> Void
    private var available = true

    init(title: String, detail: String?, choose: @escaping () -> Void) {
        self.choose = choose
        titleLabel = makeLabel(title, size: 13)
        detailLabel = makeFootnote(detail ?? "")
        detailLabel.isHidden = detail == nil
        super.init(frame: .zero)

        highlight.backgroundColor = PlatformColor.primaryText
            .withAlphaComponent(0.08).cgColor
        highlight.cornerRadius = 7
        highlight.cornerCurve = .continuous
        highlight.opacity = 0
        backingLayer.addSublayer(highlight)

        check.image = Symbol.image("checkmark", description: "Selected")
        check.translatesAutoresizingMaskIntoConstraints = false
        check.opacity = 0
        #if canImport(UIKit)
        check.tintColor = .accent
        #else
        check.contentTintColor = .accent
        #endif

        let text = makeStack(.vertical, spacing: 2)
        text.addArrangedSubview(titleLabel)
        text.addArrangedSubview(detailLabel)

        // The gap between the name and its tick is a view that hugs nothing, so it is the one thing
        // in the row that stretches.
        let spacer = PlatformView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = makeStack(.horizontal, spacing: 12, alignment: .center)
        row.addArrangedSubview(text)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(check)
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            check.widthAnchor.constraint(equalToConstant: 14),
        ])
        #if canImport(UIKit)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = title
        #else
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAXLabel(title)
        #endif
    }

    override func layoutContents() {
        Motion.immediate {
            highlight.frame = bounds.insetBy(dx: -8, dy: -2)
        }
    }

    /// The tick does not blink on; it fades and settles, which appears as the choice moving rather
    /// than two rows changing independently.
    func setSelected(_ selected: Bool, animated: Bool = true) {
        guard (check.opacity > 0.5) != selected else { return }
        guard animated else {
            check.opacity = selected ? 1 : 0
            return
        }
        Motion.run(Motion.quick, curve: Motion.spring) { [check] in
            check.animated.opacity = selected ? 1 : 0
        }
        if selected {
            Motion.spring(check.backingLayer, key: "transform.scale",
                          from: 0.6, to: 1, damping: 12, stiffness: 260)
        }
        #if canImport(UIKit)
        accessibilityTraits = selected ? [.button, .selected] : .button
        #else
        setAccessibilitySelected(selected)
        #endif
    }

    /// The line under the title, which for the frame-rate rows only arrives once the clip has been
    /// read.
    func setDetail(_ text: String?) {
        detailLabel.textValue = text ?? ""
        detailLabel.isHidden = text == nil
    }

    func setAvailable(_ value: Bool) {
        guard available != value else { return }
        available = value
        Motion.run(Motion.quick) { [weak self] in
            self?.animated.opacity = value ? 1 : 0.45
        }
    }

    override func applyEnabled(_ enabled: Bool) {}

    private func press() {
        guard available, isRowEnabled else { return }
        Motion.run(0.08) { [highlight] in highlight.opacity = 1 }
    }

    private func release(at point: CGPoint?) {
        guard available, isRowEnabled else { return }
        Motion.run(Motion.quick, curve: Motion.exit) { [highlight] in
            highlight.opacity = 0
        }
        guard let point else { return }
        if bounds.insetBy(dx: -8, dy: -2).contains(point) { choose() }
    }

    #if canImport(UIKit)

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        press()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        release(at: touches.first?.location(in: self))
    }

    override func touchesCancelled(_ touches: Set<UITouch>,
                                   with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        release(at: nil)
    }

    override func accessibilityActivate() -> Bool {
        guard available, isRowEnabled else { return false }
        choose()
        return true
    }

    #else

    override func mouseDown(with event: NSEvent) { press() }

    override func mouseUp(with event: NSEvent) {
        release(at: convert(event.locationInWindow, from: nil))
    }

    override func accessibilityPerformPress() -> Bool {
        guard available, isRowEnabled else { return false }
        choose()
        return true
    }

    #endif
}

/// The frame every export sheet stands in: a title, a scrolling column of sections, and the two
/// buttons that end it.
class ExportSheetController: SessionViewController, ExportSheet {
    var onClose: (() -> Void)?

    private let heading: String
    private var confirmButton: SessionButton!
    private var cancelButton: SessionButton!
    private let column = ScrollColumn(inset: 0, pad: 4, bottom: 8)

    init(heading: String) {
        self.heading = heading
        super.init()
        cancelButton = SessionButton(title: "Cancel") { [weak self] in
            self?.cancel(nil)
        }
        confirmButton = SessionButton(title: "Export",
                                      prominent: true) { [weak self] in
            self?.confirm()
        }
    }

    override func loadView() {
        let root = SessionView(frame: CGRect(x: 0, y: 0, width: 520,
                                             height: 620))

        let title = makeLabel(heading, size: 15, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(title)

        let gap = PlatformView()
        gap.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = makeStack(.horizontal, spacing: 10, alignment: .center)
        buttons.addArrangedSubview(gap)
        buttons.addArrangedSubview(cancelButton)
        buttons.addArrangedSubview(confirmButton)
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
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 500),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 500),
        ])
        view = root
    }

    /// Sections arrive one after another rather than all at once, so a sheet that has to read a
    /// video before it can say anything does not snap into place.
    func setSections(_ sections: [FormSectionView], animated: Bool = false) {
        for view in column.column.arrangedSubviews {
            column.column.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for section in sections {
            column.column.addArrangedSubview(section)
            section.widthAnchor.constraint(
                equalTo: column.column.widthAnchor).isActive = true
            if animated { section.appear(offset: 10) }
        }
    }

    var confirmTitle: String {
        get { confirmButton.title }
        set { confirmButton.title = newValue }
    }

    var canConfirm: Bool {
        get { confirmButton.isEnabled }
        set { confirmButton.isEnabled = newValue }
    }

    /// What the sheet does when Export is pressed. Subclasses override.
    func export() {}

    private func confirm() {
        export()
        close()
    }

    @objc func cancel(_ sender: Any?) { close() }

    private func close() {
        onClose?()
        onClose = nil
        #if canImport(UIKit)
        presentingViewController?.dismiss(animated: true)
        #else
        presentingViewController?.dismiss(self)
        #endif
    }
}

/// Resolution and file type for a developed photograph.
final class PhotoExportSheetController: ExportSheetController {
    private let sourceSize: CGSize
    private let state: EditState
    private let sensorFrame: SensorFrame?
    private let originalRAWAvailable: Bool
    private let render: (PhotoRenderRequest) -> Void

    private var sizes: [ExportSize] = []
    private var selectedSizeID = "full"
    private var format = PhotoExportChoice.jpeg
    private var quality = PhotoExportQuality.balanced
    private var hdr = AppSettings.storedStillDynamicRange == .hdr
    private var metadata = ExportMetadataPolicy.preserveWithoutLocation

    private var hdrAvailable: Bool {
        format == .heic && state.supportsHDROutput
    }

    private var sizeRows: [(id: String, row: OptionRow, available: Bool)] = []
    private var formatRows: [(format: PhotoExportChoice, row: OptionRow)] = []
    private var qualityRows: [(quality: PhotoExportQuality, row: OptionRow)] = []
    private var metadataRows: [(policy: ExportMetadataPolicy, row: OptionRow)] = []

    private var resolutionWarning: String? {
        guard format != .original else { return nil }
        return ExportSize.resolutionLimitWarning(
            in: sizes, selectedID: selectedSizeID)
    }

    init(sourceSize: CGSize, state: EditState, sensorFrame: SensorFrame?,
         originalRAWAvailable: Bool,
         render: @escaping (PhotoRenderRequest) -> Void) {
        self.sourceSize = sourceSize
        self.state = state
        self.sensorFrame = sensorFrame
        self.originalRAWAvailable = originalRAWAvailable
        self.render = render
        super.init(heading: "Export Photo")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Normal mode has no stock memory limit, so pass the optional stock through.
        sizes = ExportSize.options(
            for: sourceSize, stock: state.stock,
            options: state.options(sensor: sensorFrame),
            exactMath: AppSettings.effectiveRenderingMode == .accurate)
        selectedSizeID = (sizes.first { $0.isAvailable } ?? sizes.first)?.id
            ?? "full"
        build()
        sync()
    }

    private func build() {
        var sections: [FormSectionView] = []

        if ExportPresetStore.hasPhoto {
            let section = FormSectionView(title: nil)
            section.add(ButtonRow("Use Last Export Settings",
                                  bordered: false) { [weak self] in
                self?.usePreviousSettings()
            })
            sections.append(section)
        }

        let resolution = FormSectionView(title: "Resolution")
        sizeRows = sizes.map { size in
            let detail = size.isAvailable
                ? size.detail : "\(size.detail) · Exceeds safe memory limit"
            let row = OptionRow(title: size.label, detail: detail) {
                [weak self] in
                self?.selectedSizeID = size.id
                self?.sync()
            }
            resolution.add(row)
            return (size.id, row, size.isAvailable)
        }
        sections.append(resolution)

        if resolutionWarning != nil {
            resolutionWarningSection = FormSectionView(title: nil)
            let note = NoteRow { [weak self] in self?.resolutionWarning ?? "" }
            resolutionWarningNote = note
            resolutionWarningSection?.add(note)
            if let resolutionWarningSection { sections.append(resolutionWarningSection) }
        }

        let fileType = FormSectionView(title: "File Type")
        formatRows = PhotoExportChoice.allCases.map { candidate in
            let detail = candidate == .original && !originalRAWAvailable
                ? "Available when the source is camera RAW"
                : candidate.detail
            let row = OptionRow(title: candidate.title, detail: detail) {
                [weak self] in
                self?.format = candidate
                self?.sync()
            }
            fileType.add(row)
            return (candidate, row)
        }
        sections.append(fileType)

        fileSizeSection = FormSectionView(title: "File Size")
        qualityRows = PhotoExportQuality.allCases.map { candidate in
            let row = OptionRow(title: candidate.title,
                                detail: candidate.detail) { [weak self] in
                self?.quality = candidate
                self?.sync()
            }
            fileSizeSection?.add(row)
            return (candidate, row)
        }
        if let fileSizeSection { sections.append(fileSizeSection) }

        pictureSection = FormSectionView(title: "Picture")
        pictureSection?.add(ToggleRow("HDR Highlights") { [weak self] in
            self?.hdr ?? false
        } set: { [weak self] value in
            self?.hdr = value
            self?.sync()
        })
        let note = NoteRow { [weak self] in
            self?.hdr == true
                ? "HDR keeps bright highlights on compatible screens. "
                    + "The HEIC stays a normal photograph everywhere else."
                : "The photograph is written exactly as the print renders "
                    + "on a standard screen."
        }
        pictureNote = note
        pictureSection?.add(note)
        if let pictureSection { sections.append(pictureSection) }

        metadataSection = FormSectionView(title: "Metadata")
        metadataRows = ExportMetadataPolicy.allCases.map { policy in
            let row = OptionRow(title: policy.title, detail: policy.detail) {
                [weak self] in
                self?.metadata = policy
                self?.sync()
            }
            metadataSection?.add(row)
            return (policy, row)
        }
        if let metadataSection { sections.append(metadataSection) }

        dngNote = FormSectionView(title: nil)
        dngNote?.add(NoteRow {
            "Copies the original camera RAW file. Fotufilm edits and the resolution "
                + "setting are not included."
        })
        if let dngNote { sections.append(dngNote) }

        setSections(sections)
    }

    private var fileSizeSection: FormSectionView?
    private var resolutionWarningSection: FormSectionView?
    private var resolutionWarningNote: NoteRow?
    private var pictureSection: FormSectionView?
    private var pictureNote: NoteRow?
    private var metadataSection: FormSectionView?
    private var dngNote: FormSectionView?

    private func sync() {
        for entry in sizeRows {
            entry.row.setSelected(entry.id == selectedSizeID)
            entry.row.setAvailable(entry.available && format != .original)
        }
        for entry in formatRows {
            entry.row.setSelected(entry.format == format)
            entry.row.setAvailable(entry.format != .original || originalRAWAvailable)
        }
        for entry in qualityRows {
            entry.row.setSelected(entry.quality == quality)
        }
        for entry in metadataRows {
            entry.row.setSelected(entry.policy == metadata)
        }
        resolutionWarningNote?.refresh()
        setSectionShown(resolutionWarningSection, resolutionWarning != nil)
        setSectionShown(fileSizeSection, format == .jpeg || format == .heic)
        setSectionShown(pictureSection, hdrAvailable)
        pictureNote?.refresh()
        setSectionShown(dngNote, format == .original)
        setSectionShown(metadataSection, format != .original)

        confirmTitle = format == .original ? "Export Original" : "Export"
        let sizeReady = sizes.first { $0.id == selectedSizeID }?
            .isAvailable == true
        canConfirm = format == .original ? originalRAWAvailable : sizeReady
    }

    private func setSectionShown(_ section: FormSectionView?, _ shown: Bool) {
        guard let section, section.isHidden == shown else { return }
        if shown {
            section.isHidden = false
            section.appear(offset: 8)
        } else {
            Motion.run(Motion.quick, curve: Motion.exit) {
                section.animated.opacity = 0
            } completion: {
                section.isHidden = true
                section.opacity = 1
            }
        }
    }

    private func usePreviousSettings() {
        guard let preset = ExportPresetStore.photo() else { return }
        format = preset.format != .original || originalRAWAvailable
            ? preset.format : .jpeg
        quality = preset.quality
        hdr = preset.hdr
        metadata = preset.metadata
        if let matching = sizes.first(where: {
            $0.id == preset.resolutionID && $0.isAvailable
        }) {
            selectedSizeID = matching.id
        } else if let matching = sizes.first(where: {
            $0.longEdge == preset.longEdge && $0.isAvailable
        }) {
            selectedSizeID = matching.id
        } else {
            selectedSizeID = (sizes.first { $0.isAvailable } ?? sizes.first)?
                .id ?? "full"
        }
        sync()
    }

    override func export() {
        let size = sizes.first { $0.id == selectedSizeID }
        let request: PhotoRenderRequest
        if format == .original {
            request = .original
        } else {
            request = .developed(
                longEdge: size?.longEdge,
                delivery: hdr && hdrAvailable
                    ? .hdrHEIC(AppSettings.stillHDRContainer)
                    : .sdr(format.developedFormat!),
                quality: quality,
                metadata: metadata)
        }
        ExportPresetStore.savePhoto(request, resolutionID: selectedSizeID)
        render(request)
    }
}

/// Resolution, cadence, and container for a developed clip.
final class VideoExportSheetController: ExportSheetController {
    private let asset: AVAsset
    private let render: (VideoRenderRequest) -> Void

    private var sizes: [VideoOutputSize] = []
    private var selectedSizeID = "source"
    private var sourceFrameRate = 0.0
    private var frameRate: Int?
    private var format = VideoExportFormat.quickTime
    private var hdr = AppSettings.storedVideoDynamicRange == .hdr
    private var fast = AppSettings.storedVideoDevelopQuality == .fast
    private var includeAudio = true
    private var loadFailed = false

    private var sizeRows: [(id: String, row: OptionRow)] = []
    private var rateRows: [(rate: Int?, row: OptionRow, label: String)] = []
    private var formatRows: [(format: VideoExportFormat, row: OptionRow)] = []
    private var pictureNote: NoteRow?
    private var processingRow: PopUpRow<Bool>?

    private let frameRates: [(label: String, rate: Int?)] = [
        ("Source", nil), ("16 fps", 16),
        ("18 fps", 18), ("24 fps", 24),
        ("25 fps", 25), ("30 fps", 30), ("60 fps", 60),
    ]

    init(asset: AVAsset, initialFrameRate: Int?,
         render: @escaping (VideoRenderRequest) -> Void) {
        self.asset = asset
        self.render = render
        frameRate = initialFrameRate
        super.init(heading: "Export Video")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        build()
        sync()
        Task { await loadVideoProperties() }
    }

    private func build() {
        var sections: [FormSectionView] = []

        if ExportPresetStore.hasVideo {
            let section = FormSectionView(title: nil)
            section.add(ButtonRow("Use Last Export Settings",
                                  bordered: false) { [weak self] in
                self?.usePreviousSettings()
            })
            sections.append(section)
        }

        resolutionSection = FormSectionView(title: "Resolution")
        resolutionSection?.add(NoteRow { [weak self] in
            self?.loadFailed == true
                ? "The video properties could not be read." : "Reading video…"
        })
        if let resolutionSection { sections.append(resolutionSection) }

        let rate = FormSectionView(title: "Frame Rate")
        rateRows = frameRates.map { candidate in
            let row = OptionRow(title: candidate.label, detail: nil) {
                [weak self] in
                self?.frameRate = candidate.rate
                self?.sync()
            }
            rate.add(row)
            return (candidate.rate, row, candidate.label)
        }
        sections.append(rate)

        let fileType = FormSectionView(title: "File Type")
        formatRows = VideoExportFormat.availableCases.map { candidate in
            let row = OptionRow(title: candidate.title,
                                detail: candidate.detail) { [weak self] in
                self?.format = candidate
                self?.sync()
            }
            fileType.add(row)
            return (candidate, row)
        }
        sections.append(fileType)

        let picture = FormSectionView(title: "Picture")
        picture.add(ToggleRow("HDR Highlights") { [weak self] in
            self?.hdr ?? false
        } set: { [weak self] value in
            self?.hdr = value
            self?.sync()
        })
        let processing = PopUpRow<Bool>(
            "Processing",
            options: [("Maximum Detail", false), ("Faster Export", true)]
        ) { [weak self] in
            guard let self else { return false }
            return hdr || format.requiresMaximumDetail ? false : fast
        } set: { [weak self] value in
            self?.fast = value
            self?.sync()
        }
        processingRow = processing
        picture.add(processing)
        let note = NoteRow { [weak self] in
            guard let self else { return "" }
            if format.isProRes {
                return hdr
                    ? "Apple ProRes writes a \(format.proResPrecision) "
                        + "QuickTime master "
                        + "with HDR highlights, Maximum Detail processing, "
                        + "and native Apple encoding."
                    : "Apple ProRes writes a \(format.proResPrecision) "
                        + "QuickTime master "
                        + "with Maximum Detail processing and native Apple "
                        + "encoding."
            }
            if format == .hevc10 {
                return hdr
                    ? "HEVC writes a compact 10-bit HDR movie with Maximum "
                        + "Detail processing."
                    : "HEVC writes a compact 10-bit SDR movie with Maximum "
                        + "Detail processing for smoother gradients."
            }
            return hdr
                ? "HDR keeps bright highlights on compatible screens "
                    + "and always uses full-quality film processing."
                : "Faster shortens exports while preserving output "
                    + "resolution, grain, and the final print."
        }
        pictureNote = note
        picture.add(note)
        sections.append(picture)

        let audio = FormSectionView(title: "Audio")
        audio.add(ToggleRow("Include Audio") { [weak self] in
            self?.includeAudio ?? true
        } set: { [weak self] value in
            self?.includeAudio = value
        })
        sections.append(audio)

        setSections(sections)
    }

    private var resolutionSection: FormSectionView?

    private func sync() {
        for entry in sizeRows { entry.row.setSelected(entry.id == selectedSizeID) }
        for entry in rateRows {
            entry.row.setSelected(entry.rate == frameRate)
            let available = entry.rate == nil || sourceFrameRate <= 0
                || Double(entry.rate ?? 0) <= sourceFrameRate.rounded(.up)
            entry.row.setAvailable(available)
        }
        for entry in formatRows { entry.row.setSelected(entry.format == format) }
        processingRow?.isRowEnabled = !hdr && !format.requiresMaximumDetail
        pictureNote?.refresh()
        canConfirm = !sizes.isEmpty
    }

    private func loadVideoProperties() async {
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video)
                .first else { throw CocoaError(.fileReadCorruptFile) }
            let natural = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let transformed = natural.applying(transform)
            let displaySize = CGSize(width: abs(transformed.width),
                                     height: abs(transformed.height))
            sourceFrameRate = Double(try await track.load(.nominalFrameRate))
            sizes = VideoOutputSize.options(for: displaySize)
            selectedSizeID = sizes.first?.id ?? "source"
        } catch {
            loadFailed = true
        }
        fillResolution()
        for entry in rateRows where entry.rate == nil {
            entry.row.setDetail(sourceFrameRate > 0
                ? String(format: "Keep original frame rate · %.2f fps",
                         sourceFrameRate)
                : nil)
        }
        sync()
    }

    private func fillResolution() {
        guard let resolutionSection, !sizes.isEmpty else {
            resolutionSection?.rows.first?.refresh()
            return
        }
        resolutionSection.replaceRows(sizes.map { size in
            let row = OptionRow(title: size.label, detail: size.detail) {
                [weak self] in
                self?.selectedSizeID = size.id
                self?.sync()
            }
            return row
        })
        sizeRows = zip(sizes, resolutionSection.rows).compactMap { size, row in
            (row as? OptionRow).map { (size.id, $0) }
        }
        for row in resolutionSection.rows { row.appear(offset: 6) }
    }

    private func usePreviousSettings() {
        guard let preset = ExportPresetStore.video() else { return }
        if let matching = sizes.first(where: { $0.id == preset.resolutionID }) {
            selectedSizeID = matching.id
        } else if let matching = sizes.first(where: {
            $0.longEdge == preset.longEdge
        }) {
            selectedSizeID = matching.id
        } else {
            selectedSizeID = sizes.first?.id ?? "source"
        }
        frameRate = preset.frameRate
        format = VideoExportFormat.availableCases.contains(preset.format)
            ? preset.format : .quickTime
        hdr = preset.hdr
        fast = preset.fast
        includeAudio = preset.includeAudio
        for section in [resolutionSection] {
            for row in section?.rows ?? [] { row.refresh() }
        }
        sync()
    }

    override func export() {
        let size = sizes.first { $0.id == selectedSizeID }
        let request = VideoRenderRequest(
            longEdge: size?.longEdge, frameRate: frameRate, format: format,
            hdr: hdr, fast: (hdr || format.requiresMaximumDetail) ? false : fast,
            includeAudio: includeAudio)
        ExportPresetStore.saveVideo(request, resolutionID: selectedSizeID)
        render(request)
    }
}
