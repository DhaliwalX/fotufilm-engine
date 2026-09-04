import CoreGraphics
import QuartzCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The session's visual language, in one place: the radii and fills its surfaces are made of, the
/// lettering its decks are set in, and the handful of curves everything moves on.
///
/// One set of numbers for both machines. A panel on the iPad is the same panel as the one on the
/// Mac, at the same radius, moving on the same curve — the session should look like itself and not
/// like two ports of a third thing.
enum Chrome {
    /// A sheet, a card, a tile: anything that appears as a piece of paper on the glass.
    static let panelRadius: CGFloat = 16
    /// A readout floating over the picture: the advisory, the scrubber.
    static let barRadius: CGFloat = 22

    /// The wash behind the picture, so a print does not sit on the desktop's grey.
    static var canvasBackground: PlatformColor {
        PlatformColor.black.withAlphaComponent(0.06)
    }

    /// The hairline every floating surface is drawn with, which is what stops a glass panel from
    /// dissolving into a bright picture behind it.
    static var panelBorder: PlatformColor {
        PlatformColor.white.withAlphaComponent(0.08)
    }

    static var selectionFill: PlatformColor {
        PlatformColor.accent.withAlphaComponent(0.22)
    }
}

/// A cubic timing curve, written once as its two control points.
///
/// The two frameworks want the same four numbers in different wrappers — `CAMediaTimingFunction` on
/// one side, `UIViewPropertyAnimator`'s control points on the other — so the curve is kept as the
/// numbers and handed over in whichever shape is being asked for.
struct Curve {
    let first: CGPoint
    let second: CGPoint

    init(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
        first = CGPoint(x: x1, y: y1)
        second = CGPoint(x: x2, y: y2)
    }

    var timingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: Float(first.x), Float(first.y),
                              Float(second.x), Float(second.y))
    }
}

/// The curves. Every animation in the session comes from here, so the whole thing moves as one
/// object rather than as a dozen independently-tuned ones.
enum Motion {
    /// Panels arriving and leaving. Long enough to read as a movement, short enough that a toggle
    /// is not a wait.
    static let panel: TimeInterval = 0.34
    /// A control answering a click.
    static let quick: TimeInterval = 0.18
    /// A picture replacing a picture.
    static let crossfade: TimeInterval = 0.22
    /// The crop settling around what was just chosen.
    static let settle: TimeInterval = 0.35

    /// No overshoot, a slow start and a slower finish.
    static let smooth = Curve(0.25, 0.1, 0.25, 1)
    /// For anything that should feel picked up rather than switched on.
    static let spring = Curve(0.34, 1.2, 0.4, 1)
    /// Something leaving: quick at first, so the space it frees is available immediately.
    static let exit = Curve(0.4, 0, 1, 1)

    /// Runs `changes` on one of the curves above.
    ///
    /// Anything set inside takes the animation: frames and opacities directly, and constraint
    /// changes as long as the view they belong to is asked to lay out inside the block — which is
    /// what `layoutNow()` is for, and means the same thing on both platforms.
    static func run(_ duration: TimeInterval = Motion.quick,
                    curve: Curve = Motion.smooth,
                    _ changes: @escaping () -> Void,
                    completion: (() -> Void)? = nil) {
        #if canImport(UIKit)
        let animator = UIViewPropertyAnimator(duration: duration,
                                              controlPoint1: curve.first,
                                              controlPoint2: curve.second,
                                              animations: changes)
        if let completion { animator.addCompletion { _ in completion() } }
        animator.startAnimation()
        #else
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = curve.timingFunction
            context.allowsImplicitAnimation = true
            changes()
        }, completionHandler: completion)
        #endif
    }

    /// The same, without animating — for the first layout, where everything simply is where it is.
    static func immediate(_ changes: () -> Void) {
        #if canImport(UIKit)
        UIView.performWithoutAnimation(changes)
        #else
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            changes()
        }
        #endif
    }

    /// A spring on one layer property, for the movements a timing function cannot make convincing:
    /// a knob picked up, a selection sliding between rows.
    static func spring(_ layer: CALayer, key: String,
                       from: Any, to: Any,
                       damping: CGFloat = 14, stiffness: CGFloat = 220,
                       mass: CGFloat = 1) {
        let animation = CASpringAnimation(keyPath: key)
        animation.fromValue = from
        animation.toValue = to
        animation.damping = damping
        animation.stiffness = stiffness
        animation.mass = mass
        animation.duration = animation.settlingDuration
        animation.fillMode = .forwards
        layer.add(animation, forKey: key)
        layer.setValue(to, forKeyPath: key)
    }
}

extension PlatformView {
    /// The view to set a property on when the change should animate.
    ///
    /// UIKit animates whatever is set inside an animation block; AppKit wants the change sent to a
    /// proxy. Writing `animated.opacity = 1` says the same thing to both.
    var animated: Self {
        #if canImport(UIKit)
        return self
        #else
        return animator()
        #endif
    }

    /// Fades and lifts a view in, for something that has just become true.
    ///
    /// The lift is a layer translation rather than a change of origin, because most of what appears
    /// here is laid out by constraints — moving the frame of one of those only invites the next
    /// layout pass to move it back mid-animation.
    func appear(offset: CGFloat = 8, duration: TimeInterval = Motion.quick) {
        opacity = 0
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = -offset
        rise.toValue = 0
        rise.duration = duration
        rise.timingFunction = Motion.spring.timingFunction
        backingLayer.add(rise, forKey: "appear")
        Motion.run(duration, curve: Motion.spring) { [self] in
            animated.opacity = 1
        }
    }
}
