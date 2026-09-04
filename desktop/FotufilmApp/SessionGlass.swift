import CoreGraphics
import QuartzCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Cross-platform glass panel using Liquid Glass on OS 26 and blurred material on older systems.
/// Liquid Glass supplies its own rim and shadow, so fallback decorations are disabled there.
final class GlassPanelView: SessionView {
    /// The panel's own content. It sits *above* the glass rather than inside it, so a developed
    /// thumbnail or a coloured instrument keeps the colours it was given instead of being taken as
    /// something for the material to make legible.
    let content = PlatformView()

    /// Nil means the material decides — which, under Liquid Glass, means the rim it draws itself.
    var cornerRadius: CGFloat {
        didSet {
            guard cornerRadius != oldValue else { return }
            applyShape()
        }
    }

    /// A colour poured into the glass, for a surface that has to carry reading matter over a
    /// photograph.
    var tint: PlatformColor? {
        didSet {
            guard tint != oldValue else { return }
            applyMaterial()
        }
    }

    #if canImport(UIKit)
    private let effect = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    #else
    private let fallback = NSVisualEffectView()
    private let border = CALayer()
    private var glass: NSView?
    #endif

    init(radius: CGFloat = Chrome.panelRadius) {
        cornerRadius = radius
        super.init(frame: .zero)
        buildMaterial()

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyMaterial()
        applyShape()
    }

    #if canImport(UIKit)

    private func buildMaterial() {
        effect.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        effect.isUserInteractionEnabled = false
        insertSubview(effect, at: 0)
        clipsToBounds = false
    }

    private func applyMaterial() {
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect()
            glass.tintColor = tint
            effect.effect = glass
        } else {
            effect.effect = UIBlurEffect(style: .systemMaterial)
            effect.contentView.backgroundColor = tint
            layer.borderWidth = 0.5
            layer.borderColor = Chrome.panelBorder.cgColor
        }
    }

    private func applyShape() {
        if #available(iOS 26.0, *) {
            effect.cornerConfiguration = .corners(radius: .fixed(cornerRadius))
        } else {
            layer.cornerRadius = cornerRadius
            layer.cornerCurve = .continuous
            clipsToBounds = cornerRadius > 0
        }
        content.layer.cornerRadius = cornerRadius
        content.layer.cornerCurve = .continuous
        content.clipsToBounds = cornerRadius > 0
    }

    override func layoutContents() {
        effect.frame = bounds
    }

    #else

    private func buildMaterial() {
        layer?.masksToBounds = false
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.autoresizingMask = [.width, .height]
            addSubview(glass, positioned: .below, relativeTo: nil)
            self.glass = glass
        } else {
            fallback.material = .hudWindow
            fallback.blendingMode = .withinWindow
            fallback.state = .active
            fallback.wantsLayer = true
            fallback.autoresizingMask = [.width, .height]
            fallback.layer?.masksToBounds = true
            addSubview(fallback, positioned: .below, relativeTo: nil)

            // The rim and the lift the older material does not have. Under Liquid Glass both are
            // the material's own, and drawing them again would double them.
            border.borderWidth = 0.5
            border.borderColor = Chrome.panelBorder.cgColor
            layer?.addSublayer(border)
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.18
            layer?.shadowRadius = 12
            layer?.shadowOffset = CGSize(width: 0, height: -4)
        }
    }

    private func applyMaterial() {
        if #available(macOS 26.0, *), let glass = glass as? NSGlassEffectView {
            glass.tintColor = tint
        } else {
            fallback.layer?.backgroundColor = tint?.cgColor
        }
    }

    private func applyShape() {
        if #available(macOS 26.0, *), let glass = glass as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
        } else {
            fallback.layer?.cornerRadius = cornerRadius
            fallback.layer?.cornerCurve = .continuous
            border.cornerRadius = cornerRadius
            border.cornerCurve = .continuous
        }
        content.wantsLayer = true
        content.layer?.cornerRadius = cornerRadius
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = cornerRadius > 0
    }

    override func layoutContents() {
        // The border never animates its own bounds behind an animating panel.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        border.frame = bounds
        CATransaction.commit()
    }

    #endif
}
