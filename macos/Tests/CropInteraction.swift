// A small native harness for the real CropCanvasView. The model double counts publishes,
// so a long drag must not wake the editor until release. No app, stock tables or GPU needed.
import AppKit
import QuartzCore

typealias PlatformColor = NSColor
typealias PlatformEdgeInsets = NSEdgeInsets
struct EditState: Equatable {
    var crop: CGRect?
    var cornerCrop: QuadrilateralCrop?
}
enum AspectOption {
    case free
    func ratio(for size: CGSize) -> CGFloat? { nil }
}
@MainActor final class DesktopEditorModel {
    var edit = EditState() { didSet { writes += 1 } }
    var writes = 0
    var begins = 0
    var ends = 0
    var processed: NSImage?
    var canvasResetToken = UUID()
    var cropAspect = AspectOption.free
    func beginContinuousEdit() { begins += 1 }
    func endContinuousEdit() { ends += 1 }
}
class DragTarget: NSView {
    override init(frame: CGRect) { super.init(frame: frame) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not in a nib") }
    var onDragBegan: ((CGPoint) -> Void)?
    var onDragMoved: ((CGPoint) -> Void)?
    var onDragEnded: ((CGPoint) -> Void)?
    func redraw() { needsDisplay = true }
    func setAXLabel(_ label: String) { setAccessibilityLabel(label) }
    func makeDisplayLink(target: Any, selector: Selector) -> CADisplayLink {
        displayLink(target: target, selector: selector)
    }
}
enum Draw {
    static var context: CGContext? { NSGraphicsContext.current?.cgContext }
    static func shadowed(color: NSColor, blur: CGFloat, offset: CGSize, _ body: () -> Void) { body() }
}
enum Motion { static let settle: Double = 0.2 }

@main enum CropInteractionChecks {
    @MainActor static func main() {
        let model = DesktopEditorModel()
        model.processed = NSImage(size: CGSize(width: 1000, height: 1000))
        model.edit.cornerCrop = QuadrilateralCrop()
        model.writes = 0
        let canvas = CropCanvasView(model: model)
        canvas.frame = CGRect(x: 0, y: 0, width: 1048, height: 1048)
        canvas.onDragBegan?(CGPoint(x: 24, y: 24))
        let start = CFAbsoluteTimeGetCurrent()
        for i in 1...1000 {
            canvas.onDragMoved?(CGPoint(x: 24 + Double(i) / 10, y: 24 + Double(i) / 5))
        }
        precondition(model.writes == 0 && model.begins == 0, "A drag published intermediate edits")
        canvas.onDragEnded?(CGPoint(x: 124, y: 224))
        precondition(model.writes == 1 && model.begins == 1 && model.ends == 1)
        precondition(model.edit.cornerCrop?.topLeft == CGPoint(x: 0.1, y: 0.2))
        precondition(model.edit.cornerCrop?.topRight == CGPoint(x: 1, y: 0))
        print("PASS: 1000 corner movements publish once; other corners unchanged (\(CFAbsoluteTimeGetCurrent() - start)s)")

        model.edit.cornerCrop = nil
        model.writes = 0
        canvas.onDragBegan?(CGPoint(x: 24, y: 24))
        for i in 1...1000 { canvas.onDragMoved?(CGPoint(x: 24 + Double(i) / 10, y: 24 + Double(i) / 5)) }
        precondition(model.writes == 0, "Rectangular drag published intermediate edits")
        canvas.onDragEnded?(CGPoint(x: 124, y: 224))
        precondition(model.writes == 1)
        precondition(abs(model.edit.crop!.width - 0.9) < 0.000001)
        print("PASS: rectangular crop also commits once")

        // A new photo opened during a drag must not inherit the old photo's draft.
        model.edit = EditState(cornerCrop: QuadrilateralCrop())
        canvas.onDragBegan?(CGPoint(x: 24, y: 24))
        canvas.onDragMoved?(CGPoint(x: 124, y: 224))
        model.canvasResetToken = UUID()
        model.writes = 0
        canvas.onDragEnded?(CGPoint(x: 124, y: 224))
        precondition(model.writes == 0)
        print("PASS: stale drag discarded when photograph changes")
    }
}
