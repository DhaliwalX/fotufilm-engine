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

/// Which band a pad belongs to, and so what its two axes and its wash mean.
enum GradeBandStyle {
    case shadows, midtones, highlights

    /// The name of the colour a balance is tilted toward, for the readout and for anyone listening
    /// rather than looking.
    static func cast(x: Float, y: Float) -> String {
        let horizontal = x > 0 ? "Warm" : "Cool"
        let vertical = y > 0 ? "Green" : "Magenta"
        if abs(x) > 0 && abs(y) > 0 {
            return abs(x) >= abs(y) ? "\(horizontal) \(vertical.lowercased())"
                                    : "\(vertical) \(horizontal.lowercased())"
        }
        return abs(x) > 0 ? horizontal : vertical
    }

    /// The wash under the dots.
    var ground: PlatformColor {
        switch self {
        case .shadows: return PlatformColor(white: 0.10, alpha: 1)
        case .midtones: return PlatformColor(white: 0.17, alpha: 1)
        case .highlights: return PlatformColor(white: 0.26, alpha: 1)
        }
    }

    /// How strongly the colour axes are washed in.
    var washOpacity: CGFloat {
        switch self {
        case .shadows: return 0.62
        case .midtones: return 0.55
        case .highlights: return 0.46
        }
    }

    /// The level slider's gradient: what more of the band's level looks like, which is a different
    /// thing per band — lifting the shadows opens the black end, lifting the highlights carries
    /// white past where it was.
    var levelColors: [PlatformColor] {
        switch self {
        case .shadows:
            return [.black, PlatformColor(white: 0.38, alpha: 1)]
        case .midtones:
            return [PlatformColor(white: 0.12, alpha: 1),
                    PlatformColor(white: 0.45, alpha: 1),
                    PlatformColor(white: 0.78, alpha: 1)]
        case .highlights:
            return [PlatformColor(white: 0.35, alpha: 1), .white]
        }
    }
}

/// The grade, as the phone's deck draws it: a dotted two-axis pad over a wash that says what its
/// axes mean, and a gradient slider under it for the band's level.
final class GradeDeckView: SessionView {
    private let model: DesktopEditorModel
    private var bands: [BandView] = []

    init(model: DesktopEditorModel) {
        self.model = model
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let stack = makeStack(.vertical, spacing: 22)
        addSubview(stack)

        let entries: [(String, WritableKeyPath<ColorGrade, ColorGrade.Band>,
                       GradeBandStyle)] = [
            ("Shadows", \.shadows, .shadows),
            ("Midtones", \.midtones, .midtones),
            ("Highlights", \.highlights, .highlights),
        ]
        for (title, path, style) in entries {
            let band = BandView(title: title, style: style, model: model,
                                path: path)
            stack.addArrangedSubview(band)
            band.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            bands.append(band)
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    func refresh() { bands.forEach { $0.refresh() } }

    /// One band: a caption with its reading, the pad, and the level under it.
    private final class BandView: SessionView {
        private let caption: CapsLabel
        private let reading: CapsLabel
        private let pad: GradePadView
        private let level: GradeLevelView
        private let model: DesktopEditorModel
        private let path: WritableKeyPath<ColorGrade, ColorGrade.Band>

        init(title: String, style: GradeBandStyle, model: DesktopEditorModel,
             path: WritableKeyPath<ColorGrade, ColorGrade.Band>) {
            self.model = model
            self.path = path
            caption = CapsLabel(title)
            reading = CapsLabel("", dim: true)
            pad = GradePadView(style: style)
            level = GradeLevelView(style: style)
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false

            reading.alignment = .right
            reading.opacity = 0
            pad.translatesAutoresizingMaskIntoConstraints = false
            level.translatesAutoresizingMaskIntoConstraints = false

            addSubview(caption)
            addSubview(reading)
            addSubview(pad)
            addSubview(level)

            pad.band = { [weak self] in self?.value ?? ColorGrade.Band() }
            pad.write = { [weak self] in self?.setValue($0) }
            pad.began = { [weak model] in model?.beginContinuousEdit() }
            pad.ended = { [weak model] in model?.endContinuousEdit() }
            level.read = { [weak self] in self?.value.level ?? 0 }
            level.write = { [weak self] newLevel in
                guard let self else { return }
                var band = value
                band.level = newLevel
                setValue(band)
            }
            level.began = { [weak model] in model?.beginContinuousEdit() }
            level.ended = { [weak model] in model?.endContinuousEdit() }

            NSLayoutConstraint.activate([
                caption.leadingAnchor.constraint(equalTo: leadingAnchor),
                caption.topAnchor.constraint(equalTo: topAnchor),
                reading.trailingAnchor.constraint(equalTo: trailingAnchor),
                reading.firstBaselineAnchor.constraint(
                    equalTo: caption.firstBaselineAnchor),
                reading.leadingAnchor.constraint(
                    greaterThanOrEqualTo: caption.trailingAnchor, constant: 8),
                pad.leadingAnchor.constraint(equalTo: leadingAnchor),
                pad.trailingAnchor.constraint(equalTo: trailingAnchor),
                pad.topAnchor.constraint(equalTo: caption.bottomAnchor,
                                         constant: 10),
                pad.heightAnchor.constraint(equalToConstant: 168),
                level.leadingAnchor.constraint(equalTo: leadingAnchor),
                level.trailingAnchor.constraint(equalTo: trailingAnchor),
                level.topAnchor.constraint(equalTo: pad.bottomAnchor,
                                           constant: 10),
                level.heightAnchor.constraint(equalToConstant: 24),
                level.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            setAXLabel("\(title) grade")
            refresh()
        }

        private var value: ColorGrade.Band { model.edit.grade[keyPath: path] }

        private func setValue(_ band: ColorGrade.Band) {
            model.edit.grade[keyPath: path] = band
            refresh()
        }

        func refresh() {
            let band = value
            pad.refresh()
            level.refresh()
            let neutral = band.isNeutral
            if !neutral { reading.caption = readout(band) }
            let wanted: CGFloat = neutral ? 0 : 1
            if abs(reading.opacity - wanted) > 0.01 {
                Motion.run(Motion.quick) { [reading] in
                    reading.animated.opacity = wanted
                }
            }
        }

        private func readout(_ band: ColorGrade.Band) -> String {
            var parts: [String] = []
            if band.balanceX != 0 || band.balanceY != 0 {
                parts.append(GradeBandStyle.cast(x: band.balanceX,
                                                 y: band.balanceY))
            }
            if band.level != 0 {
                parts.append(String(format: "%+.0f", band.level * 100))
            }
            return parts.joined(separator: " · ")
        }
    }
}

/// The two-axis pad: warm against cool across, green against magenta up, over a wash that reports it,
/// with a dot grid for scale and a hollow ring at neutral so the way back is visible from anywhere
/// on it.
///
/// The session draws top-down on both platforms, so "up" here is a smaller y — the one place the
/// flip has to be said out loud, since a balance of +1 in green is at the top of the pad and the
/// top of the pad is y = 0.
final class GradePadView: DragTarget {
    private let style: GradeBandStyle
    private let knob = CALayer()
    private let inset: CGFloat = 18

    var band: () -> ColorGrade.Band = { ColorGrade.Band() }
    var write: ((ColorGrade.Band) -> Void)?
    var began: (() -> Void)?
    var ended: (() -> Void)?

    init(style: GradeBandStyle) {
        self.style = style
        super.init(frame: .zero)
        backingLayer.cornerRadius = 22
        backingLayer.cornerCurve = .continuous
        backingLayer.masksToBounds = true

        knob.backgroundColor = PlatformColor.white.cgColor
        knob.cornerRadius = 7.5
        knob.bounds = CGRect(x: 0, y: 0, width: 15, height: 15)
        knob.shadowColor = PlatformColor.black.cgColor
        knob.shadowOpacity = 0.5
        knob.shadowRadius = 3
        knob.shadowOffset = CGSize(width: 0, height: -1)
        backingLayer.addSublayer(knob)

        #if canImport(UIKit)
        isAccessibilityElement = true
        #else
        setAccessibilityElement(true)
        #endif
        setAXLabel("Color balance pad")

        onDragBegan = { [weak self] point in
            guard let self else { return }
            began?()
            liftKnob(true)
            place(point)
        }
        onDragMoved = { [weak self] point in self?.place(point) }
        onDragEnded = { [weak self] _ in
            guard let self else { return }
            liftKnob(false)
            ended?()
        }
    }

    override func draw(_ rect: CGRect) {
        style.ground.setFill()
        PlatformBezierPath(rect: bounds).fill()

        let wash = style.washOpacity
        // Cool on the left, warm on the right.
        Draw.gradient(in: bounds, colors: [
            PlatformColor(red: 0.35, green: 0.5, blue: 0.75, alpha: wash),
            PlatformColor(red: 0.35, green: 0.5, blue: 0.75, alpha: 0),
            PlatformColor(red: 0.9, green: 0.55, blue: 0.2, alpha: 0),
            PlatformColor(red: 0.9, green: 0.55, blue: 0.2, alpha: wash),
        ], locations: [0, 0.5, 0.5, 1],
                      from: CGPoint(x: bounds.minX, y: bounds.midY),
                      to: CGPoint(x: bounds.maxX, y: bounds.midY))
        // Green at the top, magenta at the bottom.
        Draw.gradient(in: bounds, colors: [
            PlatformColor(red: 0.4, green: 0.75, blue: 0.35, alpha: wash * 0.9),
            PlatformColor(red: 0.4, green: 0.75, blue: 0.35, alpha: 0),
            PlatformColor(red: 0.75, green: 0.3, blue: 0.55, alpha: 0),
            PlatformColor(red: 0.75, green: 0.3, blue: 0.55, alpha: wash * 0.9),
        ], locations: [0, 0.5, 0.5, 1],
                      from: CGPoint(x: bounds.midX, y: bounds.minY),
                      to: CGPoint(x: bounds.midX, y: bounds.maxY))

        let columns = 11, rows = 9
        for row in 0..<rows {
            for column in 0..<columns {
                let fx = CGFloat(column) / CGFloat(columns - 1)
                let fy = CGFloat(row) / CGFloat(rows - 1)
                let point = CGPoint(x: inset + fx * (bounds.width - inset * 2),
                                    y: inset + fy * (bounds.height - inset * 2))
                let onAxis = column == columns / 2 || row == rows / 2
                PlatformColor.white.withAlphaComponent(onAxis ? 0.65 : 0.38)
                    .setFill()
                PlatformBezierPath(ovalIn: CGRect(x: point.x - 1.5,
                                                  y: point.y - 1.5,
                                                  width: 3, height: 3)).fill()
            }
        }

        // The way back, visible from anywhere on the pad.
        let ring = PlatformBezierPath(ovalIn: CGRect(x: bounds.midX - 4.5,
                                                     y: bounds.midY - 4.5,
                                                     width: 9, height: 9))
        ring.lineWidth = 1.4
        PlatformColor.white.withAlphaComponent(0.8).setStroke()
        ring.stroke()
    }

    override func layoutContents() {
        placeKnob()
    }

    func refresh() { placeKnob() }

    private func placeKnob() {
        let value = band()
        let spanX = bounds.width / 2 - inset
        let spanY = bounds.height / 2 - inset
        let position = CGPoint(
            x: bounds.midX + CGFloat(value.balanceX) * spanX,
            y: bounds.midY - CGFloat(value.balanceY) * spanY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        knob.position = position
        CATransaction.commit()
        let reading = value.balanceX == 0 && value.balanceY == 0
            ? "Neutral"
            : GradeBandStyle.cast(x: value.balanceX, y: value.balanceY)
        #if canImport(UIKit)
        accessibilityValue = reading
        #else
        setAccessibilityValue(reading)
        #endif
    }

    private func liftKnob(_ lifted: Bool) {
        let scale: CGFloat = lifted ? 1.35 : 1
        Motion.spring(knob, key: "transform.scale",
                      from: knob.value(forKeyPath: "transform.scale") ?? 1,
                      to: scale, damping: 12, stiffness: 260)
        Motion.run(Motion.quick) { [knob] in
            knob.shadowRadius = lifted ? 6 : 3
            knob.shadowOpacity = lifted ? 0.55 : 0.5
            knob.shadowOffset = CGSize(width: 0, height: lifted ? -2 : -1)
        }
    }

    private func place(_ location: CGPoint) {
        let spanX = bounds.width / 2 - inset
        let spanY = bounds.height / 2 - inset
        guard spanX > 0, spanY > 0 else { return }
        var nx = Float((location.x - bounds.width / 2) / spanX)
        var ny = Float((bounds.height / 2 - location.y) / spanY)
        nx = min(max(nx, -1), 1)
        ny = min(max(ny, -1), 1)
        if abs(nx) < 0.06, abs(ny) < 0.06 {
            nx = 0; ny = 0
        }
        var value = band()
        value.balanceX = nx
        value.balanceY = ny
        write?(value)
        placeKnob()
    }
}

/// The capsule under the pad: a gradient showing what more of the level looks like, a white knob
/// riding on it, and a well at neutral.
final class GradeLevelView: DragTarget {
    private let style: GradeBandStyle

    var read: () -> Float = { 0 }
    var write: ((Float) -> Void)?
    var began: (() -> Void)?
    var ended: (() -> Void)?

    init(style: GradeBandStyle) {
        self.style = style
        super.init(frame: .zero)
        #if canImport(UIKit)
        isAccessibilityElement = true
        backgroundColor = .clear
        #else
        setAccessibilityElement(true)
        #endif
        setAXLabel("Level")

        onDragBegan = { [weak self] point in
            guard let self else { return }
            began?()
            place(point)
        }
        onDragMoved = { [weak self] point in self?.place(point) }
        onDragEnded = { [weak self] _ in self?.ended?() }
    }

    func refresh() {
        redraw()
        let reading = String(format: "%+.0f", read() * 100)
        #if canImport(UIKit)
        accessibilityValue = reading
        #else
        setAccessibilityValue(reading)
        #endif
    }

    override func draw(_ rect: CGRect) {
        let height = bounds.height
        let capsule = PlatformBezierPath.rounded(bounds, radius: height / 2)
        Draw.inState {
            capsule.addClip()
            Draw.gradient(in: bounds, colors: style.levelColors,
                          from: CGPoint(x: bounds.minX, y: bounds.midY),
                          to: CGPoint(x: bounds.maxX, y: bounds.midY))
        }

        capsule.lineWidth = 0.5
        PlatformColor.white.withAlphaComponent(0.12).setStroke()
        capsule.stroke()

        // The well at neutral.
        PlatformColor.white.withAlphaComponent(0.35).setFill()
        PlatformBezierPath(rect: CGRect(x: bounds.midX - 0.5,
                                        y: bounds.midY - height * 0.25,
                                        width: 1, height: height * 0.5)).fill()

        let fraction = CGFloat((read() + 1) / 2)
        let diameter = height - 4
        let x = 2 + fraction * (bounds.width - height)
        let knob = CGRect(x: x, y: 2, width: diameter, height: diameter)
        Draw.shadowed(color: PlatformColor.black.withAlphaComponent(0.45),
                      blur: 2, offset: CGSize(width: 0, height: 1)) {
            PlatformColor.white.setFill()
            PlatformBezierPath(ovalIn: knob).fill()
        }
    }

    private func place(_ location: CGPoint) {
        let height = bounds.height
        let usable = max(bounds.width - height, 1)
        let fraction = min(max((location.x - height / 2) / usable, 0), 1)
        var next = Float(fraction) * 2 - 1
        if abs(next) < 0.04 { next = 0 }
        write?(next)
        refresh()
    }
}
