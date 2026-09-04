import CoreGraphics

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// Stacks, scrolling columns and tab strips: the three pieces of arrangement the session uses over
// and over, each of which the two frameworks spell differently enough to be worth saying once.

#if canImport(UIKit)
typealias PlatformStackView = UIStackView
#else
typealias PlatformStackView = NSStackView
#endif

/// Which way a stack runs, and how its children line up across it.
enum StackAxis { case vertical, horizontal }
enum StackAlignment { case leading, center, trailing, firstBaseline, fill }

func makeStack(_ axis: StackAxis, spacing: CGFloat = 0,
               alignment: StackAlignment = .leading) -> PlatformStackView {
    let stack = PlatformStackView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.spacing = spacing
    #if canImport(UIKit)
    stack.axis = axis == .vertical ? .vertical : .horizontal
    switch alignment {
    case .leading: stack.alignment = axis == .vertical ? .leading : .top
    case .center: stack.alignment = .center
    case .trailing: stack.alignment = axis == .vertical ? .trailing : .bottom
    case .firstBaseline: stack.alignment = .firstBaseline
    case .fill: stack.alignment = .fill
    }
    #else
    stack.orientation = axis == .vertical ? .vertical : .horizontal
    switch alignment {
    case .leading: stack.alignment = axis == .vertical ? .leading : .top
    // AppKit names the centring axis rather than the idea, so which one is meant depends on the way
    // the stack runs: a column is centred across its width, a row across its height.
    case .center: stack.alignment = axis == .vertical ? .centerX : .centerY
    case .trailing: stack.alignment = axis == .vertical ? .trailing : .bottom
    case .firstBaseline: stack.alignment = .firstBaseline
    case .fill: stack.alignment = axis == .vertical ? .width : .height
    }
    #endif
    return stack
}

/// A column of content taller than the space it is in.
///
/// The two scroll views are built from opposite ends — AppKit hangs a document view inside a clip
/// view, UIKit lays content out against two layout guides — so this owns the difference and hands
/// back the one thing the panels want: a vertical stack to put rows in.
final class ScrollColumn: SessionView {
    /// Where rows go.
    let column: PlatformStackView

    /// What the column stands on, for the rare caller that has to put something *behind* the rows —
    /// the film list's travelling highlight is one layer under all of them.
    let content = SessionView()

    #if canImport(UIKit)
    private let scroll = UIScrollView()
    #else
    private let scroll = NSScrollView()
    #endif

    /// - Parameters:
    ///   - inset: how far the rows are held off the column's sides.
    ///   - pad: the same, above the first row and below the last.
    ///   - bottom: extra room under the content, so the last row clears the window's edge.
    init(inset: CGFloat = 14, pad: CGFloat = 8, bottom: CGFloat = 14,
         spacing: CGFloat = 18, alignment: StackAlignment = .leading,
         showsScroller: Bool = true) {
        column = makeStack(.vertical, spacing: spacing, alignment: alignment)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        #if canImport(UIKit)
        scroll.alwaysBounceVertical = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = showsScroller
        scroll.contentInset.bottom = bottom
        scroll.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.trailingAnchor),
            content.topAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.bottomAnchor),
            content.widthAnchor.constraint(
                equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])
        #else
        scroll.hasVerticalScroller = showsScroller
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottom,
                                            right: 0)
        scroll.documentView = content
        content.widthAnchor.constraint(
            equalTo: scroll.contentView.widthAnchor).isActive = true
        #endif

        content.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor,
                                            constant: inset),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor,
                                             constant: -inset),
            column.topAnchor.constraint(equalTo: content.topAnchor,
                                        constant: pad),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor,
                                           constant: -pad),
        ])
    }

    /// Back to the first row — a new tab starts at its own beginning, not at the last one's
    /// scroll position.
    func scrollToTop() {
        #if canImport(UIKit)
        scroll.setContentOffset(
            CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
        #else
        content.scroll(.zero)
        #endif
    }
}

/// The inspector's tab strip: a row of glyphs, one of them current.
final class SessionTabStrip: SessionView {
    var onSelect: ((Int) -> Void)?

    #if canImport(UIKit)
    private let control = UISegmentedControl()
    #else
    private let control = NSSegmentedControl()
    #endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: leadingAnchor),
            control.trailingAnchor.constraint(equalTo: trailingAnchor),
            control.topAnchor.constraint(equalTo: topAnchor),
            control.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        #if canImport(UIKit)
        control.addTarget(self, action: #selector(picked), for: .valueChanged)
        #else
        control.segmentStyle = .texturedRounded
        control.trackingMode = .selectOne
        control.target = self
        control.action = #selector(picked)
        #endif
    }

    /// Each tab is a symbol and the name a pointer or a screen reader gets.
    func setTabs(_ tabs: [(symbol: String, title: String)]) {
        #if canImport(UIKit)
        control.removeAllSegments()
        for (index, tab) in tabs.enumerated() {
            control.insertSegment(with: Symbol.image(tab.symbol,
                                                     description: tab.title),
                                  at: index, animated: false)
            control.setAccessibilityLabel(tab.title, forSegmentAt: index)
        }
        #else
        control.segmentCount = tabs.count
        for (index, tab) in tabs.enumerated() {
            control.setImage(Symbol.image(tab.symbol, description: tab.title),
                             forSegment: index)
            control.setWidth(0, forSegment: index)
            control.setToolTip(tab.title, forSegment: index)
        }
        #endif
    }

    /// Each tab is a word, for the places where a glyph would be a riddle: "Light" and "This film"
    /// are not things there are symbols for.
    func setTitles(_ titles: [String]) {
        #if canImport(UIKit)
        control.removeAllSegments()
        for (index, title) in titles.enumerated() {
            control.insertSegment(withTitle: title, at: index, animated: false)
        }
        #else
        control.segmentCount = titles.count
        for (index, title) in titles.enumerated() {
            control.setLabel(title, forSegment: index)
            control.setWidth(0, forSegment: index)
        }
        #endif
    }

    var selectedIndex: Int {
        get {
            #if canImport(UIKit)
            return control.selectedSegmentIndex
            #else
            return control.selectedSegment
            #endif
        }
        set {
            #if canImport(UIKit)
            guard control.numberOfSegments > newValue else { return }
            control.selectedSegmentIndex = newValue
            #else
            guard control.segmentCount > newValue else { return }
            control.selectedSegment = newValue
            #endif
        }
    }

    /// How many tabs are up, so a caller can tell whether the strip still describes the session.
    var count: Int {
        #if canImport(UIKit)
        return control.numberOfSegments
        #else
        return control.segmentCount
        #endif
    }

    var isEnabled: Bool {
        get { control.isEnabled }
        set { control.isEnabled = newValue }
    }

    @objc private func picked() { onSelect?(selectedIndex) }
}

#if canImport(UIKit)
private extension UISegmentedControl {
    func setAccessibilityLabel(_ label: String, forSegmentAt index: Int) {
        // UIKit has no per-segment label, so the whole strip carries the current one; a tab's name
        // is spoken by the panel it opens.
        if selectedSegmentIndex == index { accessibilityLabel = label }
    }
}
#endif
