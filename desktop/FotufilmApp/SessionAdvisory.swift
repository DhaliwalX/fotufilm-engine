import CoreGraphics
import QuartzCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The quiet line in the bottom corner: what the app is doing, or what went wrong with what it was
/// asked to do.
///
/// Icon, then a title over a line of detail — a shape borrowed wholesale from the warnings Icon
/// Composer prints in its corner.
final class CanvasAdvisoryView: SessionView {
    private let model: DesktopEditorModel
    private let panel = GlassPanelView(radius: 14)
    private let icon = PlatformImageView()
    private let spinner = SessionSpinner()
    private let title = makeLabel("", size: 13, weight: .medium)
    private let detail = makeLabel("", size: 11, color: .secondaryText)
    private let progress = SessionProgressBar()
    private let trailingButton: SessionButton

    private var shown = false
    private var trailingTitle = ""

    private var state = ""

    init(model: DesktopEditorModel) {
        self.model = model
        var press: () -> Void = {}
        trailingButton = SessionButton(title: "", borderless: true) { press() }
        super.init(frame: .zero)
        press = { [weak self] in self?.trailingPressed() }

        opacity = 0
        // Hidden as well as transparent: a view at zero alpha is still in the accessibility tree,
        // and an advisory with nothing to say should not be there to be read out.
        isHidden = true

        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        icon.translatesAutoresizingMaskIntoConstraints = false
        #if canImport(UIKit)
        icon.contentMode = .scaleAspectFit
        #else
        icon.imageScaling = .scaleProportionallyDown
        #endif
        progress.isHidden = true
        trailingButton.isHidden = true

        let text = makeStack(.vertical, spacing: 1)
        text.addArrangedSubview(title)
        text.addArrangedSubview(detail)

        let row = makeStack(.horizontal, spacing: 9, alignment: .center)
        for view in [icon, spinner, text, progress, trailingButton] as [PlatformView] {
            row.addArrangedSubview(view)
        }
        panel.content.addSubview(row)

        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            panel.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            row.leadingAnchor.constraint(equalTo: panel.content.leadingAnchor,
                                         constant: 14),
            row.trailingAnchor.constraint(equalTo: panel.content.trailingAnchor,
                                          constant: -14),
            row.topAnchor.constraint(equalTo: panel.content.topAnchor,
                                     constant: 9),
            row.bottomAnchor.constraint(equalTo: panel.content.bottomAnchor,
                                        constant: -9),
            icon.widthAnchor.constraint(equalToConstant: 16),
            progress.widthAnchor.constraint(equalToConstant: 90),
        ])
    }

    private func trailingPressed() {
        if model.errorMessage != nil {
            model.errorMessage = nil
        } else {
            model.cancelExport()
        }
    }

    func refresh() {
        if let message = model.errorMessage {
            show(state: "error", symbol: "exclamationmark.triangle.fill",
                 tint: .systemYellow, title: "Couldn’t Complete Action",
                 detail: message, button: "Dismiss", progress: nil)
        } else if model.isExporting, model.hasVideo {
            let fraction = model.videoProgress
            show(state: "video", symbol: "film", tint: .secondaryText,
                 title: "Exporting Video",
                 detail: model.videoTotalFrames > 0
                     ? "\(Int(fraction * 100))% · frame \(model.videoFrame) of \(model.videoTotalFrames)"
                     : "\(Int(fraction * 100))%",
                 button: "Cancel", progress: fraction)
        } else if model.isExporting {
            show(state: "still", symbol: nil, tint: .secondaryText,
                 title: "Exporting",
                 detail: "Processing the photo at full size.",
                 button: nil, progress: nil)
        } else if model.isProcessing {
            show(state: "developing", symbol: nil, tint: .secondaryText,
                 title: "Developing",
                 detail: "The preview is being printed.",
                 button: nil, progress: nil)
        } else {
            hide()
        }
    }

    private func show(state: String, symbol: String?, tint: PlatformColor,
                      title: String, detail: String, button: String?,
                      progress fraction: Double?) {
        if self.state != state {
            self.state = state
            if let symbol {
                icon.image = Symbol.image(symbol, size: 13,
                                          description: title)
                #if canImport(UIKit)
                icon.tintColor = tint
                #else
                icon.contentTintColor = tint
                #endif
                icon.isHidden = false
                spinner.isSpinning = false
            } else {
                icon.isHidden = true
                spinner.isSpinning = true
            }
            trailingButton.isHidden = button == nil
            if let button, button != trailingTitle {
                trailingTitle = button
                trailingButton.title = button
            }
            progress.isHidden = fraction == nil
        }
        self.title.textValue = title
        self.detail.textValue = detail
        if let fraction { progress.fraction = fraction }
        setAXLabel("\(title). \(detail)")

        guard !shown else { return }
        shown = true
        isHidden = false
        // It rises into place rather than appearing: something has started, and the movement is
        // what reports it from the corner of the eye.
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = -10
        rise.toValue = 0
        rise.duration = Motion.quick
        rise.timingFunction = Motion.spring.timingFunction
        backingLayer.add(rise, forKey: "rise")
        Motion.run(Motion.quick) { [self] in animated.opacity = 1 }
    }

    private func hide() {
        guard shown else { return }
        shown = false
        state = ""
        spinner.isSpinning = false
        Motion.run(Motion.quick, curve: Motion.exit) { [self] in
            animated.opacity = 0
        } completion: { [weak self] in
            guard let self, !shown else { return }
            isHidden = true
        }
    }
}
