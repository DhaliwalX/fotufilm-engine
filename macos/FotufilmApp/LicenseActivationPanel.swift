import AppKit

private final class VerticallyCenteredTextFieldCell: NSTextFieldCell {
    private func centeredTextFrame(in frame: NSRect) -> NSRect {
        let textHeight = ceil((font ?? NSFont.systemFont(ofSize: 13)).boundingRectForFont.height)
        return NSRect(
            x: frame.minX + 12,
            y: frame.midY - textHeight / 2,
            width: max(frame.width - 24, 0),
            height: textHeight)
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        centeredTextFrame(in: super.drawingRect(forBounds: rect))
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView,
                       editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: centeredTextFrame(in: rect), in: controlView,
                   editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView,
                         editor textObj: NSText, delegate: Any?, start selStart: Int,
                         length selLength: Int) {
        super.select(withFrame: centeredTextFrame(in: rect), in: controlView,
                     editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}

/// The window shown before the direct-download build has a valid activation certificate.
///
/// It deliberately owns no editor model: while this controller is on screen there is no hidden
/// editing session accepting drops, opening files, or developing a sample behind the activation
/// UI. A successful server activation is the only transition into the editor.
@MainActor
final class LicenseGateViewController: NSViewController, NSTextFieldDelegate {
    var onActivated: (() -> Void)?

    private let keyField = NSTextField()
    private let activateButton = NSButton()
    private let messageLabel = NSTextField(labelWithString: "")
    private var submittedKey: String?

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        view = root

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        root.addSubview(stack)

        let wordmark = makeWordmark()
        stack.addArrangedSubview(wordmark)
        stack.setCustomSpacing(34, after: wordmark)

        let title = label("Activate Fotufilm", size: 24, weight: .semibold,
                          color: NSColor(white: 0.96, alpha: 1))
        stack.addArrangedSubview(title)

        let explanation = label(
            "Purchase or retrieve your license in the browser. Fotufilm activates "
                + "automatically after checkout.",
            size: 13, color: NSColor(white: 0.62, alpha: 1))
        explanation.alignment = .center
        explanation.maximumNumberOfLines = 2
        explanation.lineBreakMode = .byWordWrapping
        explanation.usesSingleLineMode = false
        explanation.preferredMaxLayoutWidth = 380
        stack.addArrangedSubview(explanation)
        stack.setCustomSpacing(24, after: explanation)

        keyField.cell = VerticallyCenteredTextFieldCell(textCell: "")
        keyField.translatesAutoresizingMaskIntoConstraints = false
        let keyFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        keyField.font = keyFont
        keyField.placeholderAttributedString = NSAttributedString(
            string: "FOTU-XXXX-XXXX-XXXX-XXXX-XXXX",
            attributes: [
                .foregroundColor: NSColor(white: 0.38, alpha: 1),
                .font: keyFont,
            ])
        keyField.alignment = .center
        keyField.isBordered = false
        keyField.drawsBackground = false
        keyField.textColor = NSColor(white: 0.95, alpha: 1)
        keyField.focusRingType = .none
        keyField.wantsLayer = true
        keyField.layer?.backgroundColor = NSColor(white: 0.085, alpha: 1).cgColor
        keyField.layer?.cornerRadius = 8
        keyField.setAccessibilityLabel("Fotufilm license key")
        keyField.delegate = self
        keyField.target = self
        keyField.action = #selector(activateEnteredKey)
        stack.addArrangedSubview(keyField)

        configurePrimaryButton()
        stack.addArrangedSubview(activateButton)

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = NSFont.systemFont(ofSize: 12)
        messageLabel.textColor = NSColor(white: 0.62, alpha: 1)
        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 2
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.usesSingleLineMode = false
        messageLabel.preferredMaxLayoutWidth = 380
        stack.addArrangedSubview(messageLabel)
        stack.setCustomSpacing(30, after: messageLabel)

        let deviceNote = label("One license activates up to five devices.", size: 11,
                               color: NSColor(white: 0.46, alpha: 1))
        stack.addArrangedSubview(deviceNote)

        let legalLinks = makeLegalLinks()
        stack.addArrangedSubview(legalLinks)

        let footer = label("Fotufilm by MUAStudio Inc.", size: 11,
                           color: NSColor(white: 0.38, alpha: 1))
        stack.addArrangedSubview(footer)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor,
                                           constant: 36),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor,
                                            constant: -36),
            keyField.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            wordmark.widthAnchor.constraint(equalToConstant: 150),
            wordmark.heightAnchor.constraint(equalToConstant: 32),
            explanation.widthAnchor.constraint(equalTo: keyField.widthAnchor),
            keyField.widthAnchor.constraint(equalToConstant: 380),
            keyField.heightAnchor.constraint(equalToConstant: 44),
            activateButton.widthAnchor.constraint(equalTo: keyField.widthAnchor),
            activateButton.heightAnchor.constraint(equalToConstant: 44),
            messageLabel.widthAnchor.constraint(equalTo: keyField.widthAnchor),
        ])

        updateMessageForStoredLicense()
    }

    func receiveLicenseKey(_ key: String) {
        keyField.stringValue = key
        guard let normalizedKey = normalizedCompleteKey(key) else {
            updatePrimaryAction()
            messageLabel.stringValue = "The license portal returned an invalid key."
            NSSound.beep()
            return
        }
        submittedKey = nil
        submit(key: normalizedKey)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(keyField)
    }

    private func makeWordmark() -> NSView {
        guard let url = Bundle.main.url(forResource: "FOTUFILM", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else {
            return label("fotufilm", size: 24, weight: .semibold,
                         color: NSColor(white: 0.95, alpha: 1))
        }
        image.isTemplate = true
        let imageView = NSImageView(image: image)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.contentTintColor = NSColor(white: 0.95, alpha: 1)
        imageView.setAccessibilityLabel("Fotufilm")
        return imageView
    }

    private func label(_ text: String, size: CGFloat,
                       weight: NSFont.Weight = .regular,
                       color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = NSFont.systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }

    private func makeLegalLinks() -> NSView {
        let links = [
            ("Terms", "https://fotufilm.com/terms.html"),
            ("Privacy", "https://fotufilm.com/privacy.html"),
            ("License Agreement", "https://fotufilm.com/license.html"),
        ].map { title, url in
            let button = NSButton(title: title, target: self, action: #selector(openLegalPage(_:)))
            button.translatesAutoresizingMaskIntoConstraints = false
            button.identifier = NSUserInterfaceItemIdentifier(url)
            button.isBordered = false
            button.focusRingType = .none
            button.attributedTitle = NSAttributedString(
                string: title,
                attributes: [
                    .foregroundColor: NSColor(white: 0.46, alpha: 1),
                    .font: NSFont.systemFont(ofSize: 10),
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ])
            return button
        }
        let stack = NSStackView(views: links)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 14
        return stack
    }

    private func configurePrimaryButton() {
        activateButton.translatesAutoresizingMaskIntoConstraints = false
        activateButton.isBordered = false
        activateButton.wantsLayer = true
        activateButton.layer?.backgroundColor = NSColor(white: 0.94, alpha: 1).cgColor
        activateButton.layer?.cornerRadius = 8
        activateButton.target = self
        updatePrimaryAction()
    }

    private func updatePrimaryAction() {
        let hasCompleteKey = normalizedCompleteKey(keyField.stringValue) != nil
        activateButton.attributedTitle = NSAttributedString(
            string: hasCompleteKey ? "Activate" : "Open License Portal",
            attributes: [
                .foregroundColor: NSColor.black,
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            ])
        activateButton.action = hasCompleteKey
            ? #selector(activateEnteredKey)
            : #selector(openLicensePortal)
    }

    private func updateMessageForStoredLicense() {
        let status = LicenseStore.status
        if let expiry = status.expiresAt, !status.isActive {
            messageLabel.stringValue = "This license expired on "
                + expiry.formatted(date: .long, time: .omitted) + "."
        } else {
            messageLabel.stringValue = "No account sign-in is required in the app."
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        submittedKey = nil
        updatePrimaryAction()
    }

    @objc private func activateEnteredKey() {
        guard let key = normalizedCompleteKey(keyField.stringValue) else {
            messageLabel.stringValue = "Paste the complete Fotufilm license key."
            NSSound.beep()
            return
        }
        submittedKey = nil
        submit(key: key)
    }

    private func submit(key: String) {
        guard keyField.isEnabled else { return }
        submittedKey = key
        setWorking(true)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await LicenseStore.activate(key: key)
                messageLabel.stringValue = "Activated."
                onActivated?()
            } catch {
                messageLabel.stringValue = error.localizedDescription
                setWorking(false)
            }
        }
    }

    private func normalizedCompleteKey(_ value: String) -> String? {
        let compact = value.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        let alphabet = CharacterSet(charactersIn: "23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
        guard compact.hasPrefix("FOTU"), compact.count == 24,
              compact.dropFirst(4).unicodeScalars.allSatisfy(alphabet.contains) else {
            return nil
        }
        let characters = Array(compact.dropFirst(4))
        let groups = stride(from: 0, to: characters.count, by: 4).map {
            String(characters[$0..<min($0 + 4, characters.count)])
        }
        return "FOTU-" + groups.joined(separator: "-")
    }

    @objc private func openLicensePortal() {
        guard let url = LicenseStore.purchaseURL else {
            messageLabel.stringValue = "The license portal is unavailable in this build."
            return
        }
        NSWorkspace.shared.open(url)
        messageLabel.stringValue = "Complete the purchase in your browser. Fotufilm will activate automatically."
    }

    @objc private func openLegalPage(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue, let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }

    private func setWorking(_ working: Bool) {
        keyField.isEnabled = !working
        activateButton.isEnabled = !working
        guard working else {
            updatePrimaryAction()
            return
        }
        activateButton.attributedTitle = NSAttributedString(
            string: "Activating…",
            attributes: [
                .foregroundColor: NSColor(white: 0.35, alpha: 1),
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            ])
        activateButton.action = nil
        messageLabel.stringValue = "Checking this license key…"
    }
}

@MainActor
final class LicenseWindowController: NSWindowController {
    private let gate: LicenseGateViewController

    init(onActivated: @escaping () -> Void) {
        let gate = LicenseGateViewController()
        self.gate = gate
        gate.onActivated = onActivated
        gate.preferredContentSize = NSSize(width: 560, height: 560)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Fotufilm"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentViewController = gate
        window.setContentSize(gate.preferredContentSize)
        window.tabbingMode = .disallowed
        window.center()
        super.init(window: window)
    }

    func receiveLicenseKey(_ key: String) {
        showWindow(nil)
        gate.receiveLicenseKey(key)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not in a nib") }
}

@MainActor
enum LicenseActivationPanel {
    static func present(from window: NSWindow?, completion: (() -> Void)? = nil) {
        let alert = NSAlert()
        alert.messageText = LicenseStore.status.isActive
            ? "Fotufilm is activated"
            : "Activate Fotufilm"
        if let expiry = LicenseStore.status.expiresAt,
           LicenseStore.status.isActive {
            alert.informativeText = "This Mac is activated until \(expiry.formatted(date: .long, time: .omitted)). You can enter another license key below."
        } else {
            alert.informativeText = "Enter the license key from your Fotufilm account. No account sign-in is required in the app."
        }

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "FOTU-XXXX-XXXX-XXXX-XXXX-XXXX"
        field.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        alert.accessoryView = field
        alert.addButton(withTitle: "Activate")
        alert.addButton(withTitle: "Cancel")
        if LicenseStore.purchaseURL != nil { alert.addButton(withTitle: "Buy a License…") }

        let handle: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertThirdButtonReturn,
               let url = LicenseStore.purchaseURL {
                NSWorkspace.shared.open(url)
                return
            }
            guard response == .alertFirstButtonReturn else { return }
            let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                presentError("Enter a Fotufilm license key.", from: window)
                return
            }
            Task { @MainActor in
                do {
                    let expiry = try await LicenseStore.activate(key: key)
                    let success = NSAlert()
                    success.messageText = "Fotufilm is activated"
                    success.informativeText = "This Mac is activated until \(expiry.formatted(date: .long, time: .omitted))."
                    success.addButton(withTitle: "Done")
                    present(success, from: window)
                    completion?()
                } catch {
                    presentError(error.localizedDescription, from: window)
                }
            }
        }
        present(alert, from: window, completion: handle)
    }

    private static func presentError(_ message: String, from window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Fotufilm was not activated"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        present(alert, from: window)
    }

    private static func present(_ alert: NSAlert, from window: NSWindow?,
                                completion: ((NSApplication.ModalResponse) -> Void)? = nil) {
        if let window {
            alert.beginSheetModal(for: window) { response in completion?(response) }
        } else {
            let response = alert.runModal()
            completion?(response)
        }
    }
}
