import AppKit
import CoreImage
import UniformTypeIdentifiers

/// Stages the negative separately so cancellation never replaces the current photograph.
@MainActor
final class NegativeImportController: NSWindowController {
    private let model: DesktopEditorModel
    private let data: Data
    private let filename: String
    private let rawHint: String?
    private let canvas = NegativeBorderCanvas()
    private let status = NSTextField(wrappingLabelWithString: "Loading negative…")
    private let mode = NSPopUpButton()
    private let encoding = NSPopUpButton()
    private let importButton = NSButton(title: "Import Positive", target: nil, action: nil)
    private let previewButton = NSButton(title: "Preview Positive", target: nil, action: nil)
    private var decoded: CIImage?
    private var border: SIMD3<Float>?
    private var revision = UUID()
    private var busy = false
    private var stocks: [StockPreset] = []
    var onClose: (() -> Void)?
    var onImport: (() -> Void)?

    init(data: Data, filename: String, model: DesktopEditorModel) {
        self.data = data
        self.filename = filename
        let type = UTType(filenameExtension: (filename as NSString).pathExtension)
        rawHint = type?.conforms(to: .rawImage) == true ? type?.identifier : nil
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Import Scanned Negative — \(filename)"
        window.minSize = NSSize(width: 660, height: 520)
        let root = NSView()
        window.contentView = root
        let title = NSTextField(labelWithString: "Drag over clear, unexposed film to sample the border.")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let note = NSTextField(wrappingLabelWithString:
            "Keep the film border visible. Avoid lettering, sprocket holes and the holder. Colour conversion is approximate; choose the closest film below. Pixels outside the conversion range appear black.")
        note.textColor = .secondaryLabelColor
        stocks = StockPreset.all.filter { !$0.stock.isReversal && ProAccess.allowsStock($0.id) }
        mode.addItems(withTitles: stocks.map(\.name))
        if let index = stocks.firstIndex(where: { $0.id == model.edit.stockID }) {
            mode.selectItem(at: index)
        }
        mode.target = self; mode.action = #selector(settingsChanged)
        mode.setAccessibilityLabel("Negative film model")
        encoding.addItems(withTitles: ["Use File Colour Profile", "Linear Samples"])
        encoding.target = self; encoding.action = #selector(decode)
        encoding.setAccessibilityLabel("Scan encoding")
        encoding.isEnabled = !RawDecode.isRaw(data: data, identifierHint: rawHint)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelImport))
        cancel.keyEquivalent = "\u{1b}"
        importButton.target = self; importButton.action = #selector(importPositive)
        previewButton.target = self; previewButton.action = #selector(previewPositive)
        let negative = NSButton(title: "Show Negative", target: self, action: #selector(showNegative))
        let controls = NSStackView(views: [encoding, mode, negative, previewButton])
        controls.spacing = 10
        let buttons = NSStackView(views: [cancel, importButton])
        buttons.spacing = 10
        for v in [title, note, controls, canvas, status, buttons] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            note.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            note.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            controls.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 12),
            controls.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
            canvas.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 12),
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            canvas.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -12),
            status.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            status.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
        canvas.setAccessibilityLabel("Film border sampling area")
        canvas.onSample = { [weak self] rect in self?.sample(rect) }
        decode()
    }

    required init?(coder: NSCoder) { fatalError("not in a nib") }

    private func updateButtons() {
        importButton.isEnabled = !busy && border != nil && !stocks.isEmpty
        previewButton.isEnabled = importButton.isEnabled
        mode.isEnabled = !busy
        encoding.isEnabled = !busy && !RawDecode.isRaw(data: data, identifierHint: rawHint)
        canvas.isSamplingEnabled = !busy
    }

    @objc private func decode() {
        revision = UUID()
        let token = revision, data = data, hint = rawHint, linear = encoding.indexOfSelectedItem == 1
        border = nil; decoded = nil; canvas.selection = nil
        busy = true; updateButtons(); status.stringValue = "Decoding negative…"
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try NegativeScanImport.decode(data: data, identifierHint: hint, linearSamples: linear) }
            }.value
            guard revision == token else { return }
            busy = false
            switch result {
            case .success(let image):
                decoded = image
                showNegative()
                status.stringValue = "Drag a small rectangle over the clear film border."
            case .failure(let error): status.stringValue = error.localizedDescription
            }
            updateButtons()
        }
    }

    private func sample(_ rect: CGRect) {
        guard !busy, let decoded else { return }
        do {
            border = try NegativeScanImport.sampleBorder(image: decoded, rect: rect)
            status.stringValue = "Border sampled. Preview the positive, or import and adjust its four crop corners."
        } catch {
            border = nil
            status.stringValue = error.localizedDescription
        }
        updateButtons()
    }

    @objc private func settingsChanged() { showNegative() }

    @objc private func showNegative() {
        guard !busy, let decoded else { return }
        canvas.image = Self.preview(decoded)
        canvas.showsPositive = false
        canvas.needsDisplay = true
    }

    @objc private func previewPositive() { convert(importing: false) }
    @objc private func importPositive() { convert(importing: true) }

    private func convert(importing: Bool) {
        guard !busy, let decoded, let border,
              stocks.indices.contains(mode.indexOfSelectedItem) else { return }
        let stock = stocks[mode.indexOfSelectedItem].stock
        let token = revision
        busy = true; updateButtons()
        status.stringValue = importing ? "Converting full-resolution negative…" : "Rendering positive preview…"
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<(CIImage, Data?), Error> in
                Result {
                    let input = importing ? decoded : Self.reduced(decoded)
                    let image = try NegativeScanImport.positive(image: input, border: border, stock: stock)
                    var data: Data?
                    if importing {
                        let space = CGColorSpace(name: CGColorSpace.displayP3)!
                        data = CIContext().tiffRepresentation(of: image, format: .RGBA16, colorSpace: space)
                        guard data != nil else { throw NegativeScanImport.Failure.conversion }
                    }
                    return (image, data)
                }
            }.value
            guard revision == token else { return }
            busy = false; updateButtons()
            switch result {
            case .success(let (image, bytes)):
                if let bytes {
                    var edit = EditState()
                    edit.stockID = StockPreset.noFilmID
                    edit.cornerCrop = QuadrilateralCrop()
                    model.openPhoto(data: bytes, name: "\(filename) — Positive", rawHint: nil, initialEdit: edit)
                    onImport?()
                    finish()
                } else {
                    canvas.image = Self.preview(image)
                    canvas.showsPositive = true
                    canvas.needsDisplay = true
                    status.stringValue = "Approximate positive. Import to adjust the crop and tone. Show Negative to sample again."
                }
            case .failure(let error): status.stringValue = error.localizedDescription
            }
        }
    }

    nonisolated private static func reduced(_ image: CIImage) -> CIImage {
        let scale = min(1, 1400 / max(image.extent.width, image.extent.height))
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    nonisolated private static func preview(_ image: CIImage) -> NSImage? {
        let image = reduced(image)
        guard let cg = CIContext().createCGImage(image, from: image.extent,
            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return nil }
        return NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
    }

    @objc private func cancelImport() { finish() }
    private func finish() {
        revision = UUID()
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        close()
        onClose?()
    }
}

private final class NegativeBorderCanvas: NSView {
    var image: NSImage?
    var selection: CGRect? { didSet { needsDisplay = true } }
    var onSample: ((CGRect) -> Void)?
    var showsPositive = false
    var isSamplingEnabled = true
    private var start: CGPoint?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var imageRect: CGRect {
        guard let image, image.size.width > 0, image.size.height > 0 else { return .zero }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        image?.draw(in: imageRect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        if let selection, !showsPositive {
            let f = imageRect
            let r = CGRect(x: f.minX + selection.minX * f.width, y: f.minY + selection.minY * f.height,
                           width: selection.width * f.width, height: selection.height * f.height)
            NSColor.systemYellow.withAlphaComponent(0.2).setFill(); r.fill()
            NSColor.systemYellow.setStroke()
            let path = NSBezierPath(rect: r); path.lineWidth = 2; path.stroke()
        }
    }
    private func unit(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil), f = imageRect
        return CGPoint(x: min(1, max(0, (p.x - f.minX) / max(f.width, 1))),
                       y: min(1, max(0, (p.y - f.minY) / max(f.height, 1))))
    }
    override func mouseDown(with event: NSEvent) {
        guard isSamplingEnabled, !showsPositive, image != nil,
              imageRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        start = unit(event)
        selection = nil
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let end = unit(event)
        selection = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                           width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
    override func mouseUp(with event: NSEvent) {
        guard start != nil else { return }
        mouseDragged(with: event)
        start = nil
        if let selection { onSample?(selection) }
    }
}
