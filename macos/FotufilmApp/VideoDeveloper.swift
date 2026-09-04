import AVFoundation
import AppKit
import CoreGraphics
import CoreImage

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// The macOS face of the shared `VideoPipeline` — the same frame loop, the
/// same colorimetry, the same retiming as the phone.
enum VideoDeveloper {
    typealias Failure = VideoPipeline.Failure
    typealias CancelFlag = VideoPipeline.CancelFlag

    /// A single still for the on-screen preview, taken from early in the clip.
    static func posterFrame(of asset: AVAsset) async -> NSImage? {
        (await VideoPipeline.posterFrame(of: asset)).map {
            NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
        }
    }

    /// One decoded source frame near the playhead, tone-mapped and oriented
    /// for display, bounded to `longestSide` on its longer edge.
    static func sourceFrame(
        of asset: AVAsset,
        at seconds: TimeInterval,
        longestSide: CGFloat,
        encoding: VideoSourceEncoding = .standard
    ) async -> CGImage? {
        await VideoPipeline.sourceFrame(of: asset, at: seconds,
                                        longestSide: longestSide,
                                        encoding: encoding)
    }

    /// One decoded source frame near the playhead as scene-linear Rec.2020 float. Used by explicit
    /// camera encodings and standard deep/HDR clips; nil for shallow SDR.
    static func sceneLinearFrame(
        of asset: AVAsset,
        at seconds: TimeInterval,
        longestSide: CGFloat,
        encoding: VideoSourceEncoding
    ) async -> VideoPipeline.SceneLinearFrame? {
        await VideoPipeline.sceneLinearFrame(of: asset, at: seconds,
                                             longestSide: longestSide,
                                             encoding: encoding)
    }

    /// Develops `asset` into `outputURL`.
    static func export(
        from asset: AVAsset, to outputURL: URL,
        stock: FilmStock, options: FotufilmEngine.Options,
        longEdge: Int? = nil,
        developLongEdge: Int? = nil,
        frameRate: Int? = nil,
        fileType: AVFileType = .mov,
        codec: VideoPipeline.ExportCodec? = nil,
        sourceEncoding: VideoSourceEncoding = .standard,
        camera: CameraIdentity? = nil,
        sceneCCT: Float? = nil,
        hdr: Bool? = nil,
        fast: Bool? = nil,
        includeAudio: Bool = true,
        progress: @escaping @Sendable (Double, Int, Int) -> Void,
        preview: @escaping @Sendable (NSImage) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws {
        let requestedHDR = hdr ?? (AppSettings.storedVideoDynamicRange == .hdr)
        let isHDR = requestedHDR
            && PrintPaper.screen.supportsHDRDelivery(for: stock)
        try await VideoPipeline.export(
            from: asset, to: outputURL, stock: stock, options: options,
            longEdge: longEdge,
            developLongEdge: developLongEdge
                ?? (fast.map { $0 ? AppSettings.VideoDevelopQuality.fast : .full }
                    ?? AppSettings.storedVideoDevelopQuality).developLongEdge,
            frameRate: frameRate, fileType: fileType,
            codec: codec ?? (isHDR ? .hevc : .h264),
            sourceEncoding: sourceEncoding,
            camera: camera, sceneCCT: sceneCCT,
            hdr: isHDR,
            bitsPerPixel: codec?.isProRes == true ? nil
                : AppSettings.storedVideoExportBitrate.bitsPerPixel(hdr: isHDR),
            includeAudio: includeAudio,
            progress: progress,
            preview: { cgImage, rotation in
                preview(image(cgImage, oriented: rotation))
            },
            isCancelled: isCancelled)
    }

    private static let previewContext = CIContext(options: [.cacheIntermediates: false])

    private static func image(
        _ cgImage: CGImage, oriented orientation: CGImagePropertyOrientation
    ) -> NSImage {
        var final = cgImage
        if orientation != .up,
           let space = CGColorSpace(name: CGColorSpace.displayP3) {
            let oriented = CIImage(cgImage: cgImage).oriented(orientation)
            if let rotated = previewContext.createCGImage(
                oriented, from: oriented.extent, format: .RGBA8, colorSpace: space) {
                final = rotated
            }
        }
        return NSImage(cgImage: final,
                       size: NSSize(width: final.width, height: final.height))
    }
}
