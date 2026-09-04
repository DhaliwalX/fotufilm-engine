import CoreImage
import CoreGraphics
import Metal
import MetalKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(FotufilmCore)
import FotufilmCore
#endif

extension VideoPreviewSimulator {
    /// Develops the paused frame at full resolution on the same queue the live frames use, so the
    /// two never interleave inside the engine.
    func developFullResolution(
        _ image: CGImage, stock: FilmStock,
        options: FotufilmEngine.Options, frameIndex: UInt64
    ) async -> (print: PlatformImage, original: PlatformImage)? {
        (await developFullResolutionImage(image, stock: stock,
                                          options: options,
                                          frameIndex: frameIndex))
            .map { (PlatformImage.from($0.print), PlatformImage.from($0.source)) }
    }

    /// The same, for a log clip's paused frame, which arrives scene-linear rather than as an image.
    func developFullResolution(
        _ frame: VideoPipeline.SceneLinearFrame, stock: FilmStock,
        options: FotufilmEngine.Options, frameIndex: UInt64
    ) async -> (print: PlatformImage, original: PlatformImage)? {
        (await developFullResolutionFrame(frame, stock: stock,
                                          options: options,
                                          frameIndex: frameIndex))
            .map { (PlatformImage.from($0.print), PlatformImage.from($0.source)) }
    }

    /// Develops one already-decoded still through a film — the editor's stock strip asking what the
    /// frame on screen would look like on each film in the pack.
    func developStill(_ image: CGImage, stock: FilmStock,
                      options: FotufilmEngine.Options) async -> PlatformImage? {
        (await developFullResolutionImage(image, stock: stock,
                                          options: options, frameIndex: 0))
            .map { PlatformImage.from($0.print) }
    }
}

/// The playback surface: an MTKView that polls the simulator for new source frames and aspect-fits
/// the latest developed print with Core Image, so the flat build scripts need no Metal compile step.
///
/// `MTKView` is one of the few pieces of the interface both frameworks spell the same way, so this
/// is shared whole; only where the drawable's colour space is set differs.
final class PlaybackSurfaceView: MTKView, MTKViewDelegate {
    private let simulator: VideoPreviewSimulator
    private let fills: Bool
    private lazy var commandQueue = device?.makeCommandQueue()
    private lazy var ciContext: CIContext? = device.map {
        CIContext(mtlDevice: $0, options: [
            .cacheIntermediates: false,
            .workingColorSpace: CGColorSpace(
                name: CGColorSpace.extendedLinearDisplayP3)!,
        ])
    }
    private let workingSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    init(simulator: VideoPreviewSimulator, fills: Bool = false,
         opaque: Bool = true) {
        self.simulator = simulator
        self.fills = fills
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        framebufferOnly = false
        preferredFramesPerSecond = 30
        colorPixelFormat = .bgra8Unorm
        delegate = self
        translatesAutoresizingMaskIntoConstraints = false
        // The colour space is set on the view on one platform and on its layer on the other; the
        // layer is the thing that carries it either way.
        #if canImport(UIKit)
        isOpaque = opaque
        backgroundColor = opaque ? .black : .clear
        (layer as? CAMetalLayer)?.colorspace = workingSpace
        #else
        wantsLayer = true
        layer?.isOpaque = opaque
        layer?.backgroundColor = opaque
            ? PlatformColor.black.cgColor : PlatformColor.clear.cgColor
        colorspace = workingSpace
        #endif
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not in a nib") }

    /// Installed only while the histogram is visible. Sampling every other displayed frame keeps
    /// the reading live without putting a bitmap readback on every playback frame.
    var onHistogramSample: (([[Int]]) -> Void)?
    private var histogramTick = 0
    private static let histogramSide = 128
    private var histogramBytes = [UInt8](
        repeating: 0, count: histogramSide * histogramSide * 4)

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        simulator.poll()
        guard let texture = simulator.frames.latest(),
              let drawable = currentDrawable,
              let ciContext, let commandQueue,
              let commands = commandQueue.makeCommandBuffer() else { return }
        var image = CIImage(mtlTexture: texture, options: [
            .colorSpace: workingSpace,
        ]) ?? CIImage.empty()
        image = image.oriented(.downMirrored)
        if simulator.displayOrientation != .up {
            image = image.oriented(simulator.displayOrientation)
        }

        let target = CGSize(width: drawable.texture.width,
                            height: drawable.texture.height)
        let fit = min(target.width / image.extent.width,
                      target.height / image.extent.height)
        let fill = max(target.width / image.extent.width,
                       target.height / image.extent.height)
        let scale = fills ? fill : fit
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        image = image.transformed(by: CGAffineTransform(
            translationX: (target.width - image.extent.width) / 2,
            y: (target.height - image.extent.height) / 2))
        let bounds = CGRect(origin: .zero, size: target)
        image = image.composited(over: CIImage(color: .black).cropped(to: bounds))

        ciContext.render(image, to: drawable.texture,
                         commandBuffer: commands, bounds: bounds,
                         colorSpace: workingSpace)
        commands.present(drawable)
        commands.commit()
        sampleHistogram(from: image, context: ciContext)
    }

    private func sampleHistogram(from image: CIImage, context: CIContext) {
        guard let onHistogramSample else { return }
        histogramTick += 1
        guard histogramTick.isMultiple(of: 2),
              image.extent.width > 0, image.extent.height > 0 else { return }

        let side = Self.histogramSide
        let scaled = image.transformed(by: CGAffineTransform(
            scaleX: CGFloat(side) / image.extent.width,
            y: CGFloat(side) / image.extent.height))
        let bounds = CGRect(x: scaled.extent.minX, y: scaled.extent.minY,
                            width: CGFloat(side), height: CGFloat(side))
        histogramBytes.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            context.render(scaled, toBitmap: base, rowBytes: side * 4,
                           bounds: bounds, format: .RGBA8,
                           colorSpace: workingSpace)
        }
        let bins = SessionHistogramPanelView.count(rgba: histogramBytes)
        DispatchQueue.main.async { onHistogramSample(bins) }
    }
}
