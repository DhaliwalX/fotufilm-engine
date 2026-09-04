import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmMetal)
import FotufilmMetal
#endif

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Where a developed file is written, and what is offered once it exists.
enum ExportDestination {
    #if os(macOS)
    static let asksAfterwards = false
    #else
    static let asksAfterwards = true
    #endif

    @MainActor
    static func url(named name: String, type: UTType,
                    preferredExtension: String? = nil) async -> URL? {
        let suffix = preferredExtension ?? type.preferredFilenameExtension ?? "dat"
        #if os(macOS)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = "\(name).\(suffix)"
        return await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
        #else
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name).\(suffix)")
        try? FileManager.default.removeItem(at: url)
        return url
        #endif
    }
}

/// The modal raised by every Render command.
enum RenderOptionsDestination: Identifiable {
    case photo
    case video(AVAsset)

    var id: String {
        switch self {
        case .photo: return "photo"
        case .video: return "video"
        }
    }
}

/// One output size the user can ask for, never larger than the source.
struct ExportSize: Identifiable, Equatable {
    let id: String
    let label: String
    /// Long edge in pixels; nil means the source's own resolution.
    let longEdge: Int?
    let pixels: CGSize
    var isAvailable = true

    var detail: String {
        let megapixels = pixels.width * pixels.height / 1_000_000
        return String(format: "%d × %d · %.1f MP",
                      Int(pixels.width.rounded()), Int(pixels.height.rounded()),
                      megapixels)
    }

    static func resolutionLimitWarning(in sizes: [ExportSize],
                                       selectedID: String) -> String? {
        guard let full = sizes.first(where: { $0.id == "full" }),
              !full.isAvailable else { return nil }
        guard let selected = sizes.first(where: {
            $0.id == selectedID && $0.isAvailable
        }) else {
            return "Resolution unavailable: This image exceeds this device’s safe "
                + "memory limit at every export size."
        }
        return "Resolution reduced: Full resolution exceeds this device’s safe memory "
            + "limit. \(selected.label) (\(selected.detail)) is selected instead, so "
            + "the export will contain fewer pixels."
    }

    /// `stock` is nil for a picture developing on no film, which holds no emulsion in memory: it
    /// streams in bands, so there is no size the engine could refuse.
    static func options(for source: CGSize, stock: FilmStock?,
                        options renderOptions: FotufilmEngine.Options,
                        exactMath: Bool = false) -> [ExportSize] {
        guard source.width > 0, source.height > 0 else { return [] }
        let longest = max(source.width, source.height)
        var sizes = [
            ExportSize(id: "full", label: "Full resolution",
                       longEdge: nil, pixels: source)
        ]
        for (name, fraction) in [("Large", 0.75), ("Medium", 0.5), ("Small", 0.25)] {
            let edge = Int((longest * fraction).rounded())
            guard edge >= 640, Double(edge) < Double(longest) - 1 else { continue }
            let scale = Double(edge) / longest
            sizes.append(ExportSize(
                id: name, label: name, longEdge: edge,
                pixels: CGSize(width: (source.width * scale).rounded(),
                               height: (source.height * scale).rounded())))
        }
        guard let stock else { return sizes }
        return sizes.map { proposed in
            var size = proposed
            size.isAvailable = HalideMetalFilmRenderer.canRender(
                width: Int(size.pixels.width), height: Int(size.pixels.height),
                stock: stock, options: renderOptions, exactMath: exactMath)
            return size
        }
    }
}

enum PhotoExportFormat: String, CaseIterable, Identifiable, Sendable {
    case jpeg, png, heic, tiff

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jpeg: return "JPEG"
        case .png: return "PNG"
        case .heic: return "HEIC"
        case .tiff: return "TIFF"
        }
    }

    var detail: String {
        switch self {
        case .jpeg: return "Display P3 SDR · compact and compatible"
        case .png: return "Display P3 SDR · lossless, larger file"
        case .heic: return "Display P3 SDR, or HDR when enabled"
        case .tiff: return "Display P3 SDR · lossless archival image"
        }
    }

    var fileExtension: String { rawValue == "jpeg" ? "jpg" : rawValue }

    var contentType: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .png: return .png
        case .heic: return .heic
        case .tiff: return .tiff
        }
    }
}

/// What the file picker offers. Original RAW is intentionally not an image format: it bypasses
/// development and copies the source container byte-for-byte.
enum PhotoExportChoice: String, CaseIterable, Identifiable, Sendable {
    case jpeg, png, heic, tiff, original

    var id: String { rawValue }
    var developedFormat: PhotoExportFormat? { PhotoExportFormat(rawValue: rawValue) }

    var title: String {
        developedFormat?.title ?? "Original RAW"
    }

    var detail: String {
        developedFormat?.detail
            ?? "Untouched camera RAW; Fotufilm edits are not included"
    }
}

enum ExportMetadataPolicy: String, CaseIterable, Identifiable, Sendable {
    /// Carry camera, lens, exposure and location metadata.
    case preserve
    /// Carry capture metadata but omit location.
    case preserveWithoutLocation
    /// Write no source metadata.
    case strip

    var id: String { rawValue }

    var title: String {
        switch self {
        case .preserve: return "Include Location"
        case .preserveWithoutLocation: return "Capture Details"
        case .strip: return "No Metadata"
        }
    }

    var detail: String {
        switch self {
        case .preserve: return "Camera, exposure, lens, and location"
        case .preserveWithoutLocation: return "Camera, exposure, and lens; no location"
        case .strip: return "Remove source capture details"
        }
    }
}

enum DevelopedPhotoDelivery: Sendable {
    case sdr(PhotoExportFormat)
    case hdrHEIC(Rendered.HDRContainer)

    var format: PhotoExportFormat {
        switch self {
        case .sdr(let format): return format
        case .hdrHEIC: return .heic
        }
    }

    var hdrContainer: Rendered.HDRContainer? {
        guard case .hdrHEIC(let container) = self else { return nil }
        return container
    }
}

enum PhotoRenderRequest: Sendable {
    case original
    case developed(longEdge: Int?, delivery: DevelopedPhotoDelivery,
                   quality: PhotoExportQuality,
                   metadata: ExportMetadataPolicy)

    var longEdge: Int? {
        guard case .developed(let edge, _, _, _) = self else { return nil }
        return edge
    }

    var choice: PhotoExportChoice {
        switch self {
        case .original: return .original
        case .developed(_, let delivery, _, _):
            return PhotoExportChoice(rawValue: delivery.format.rawValue)!
        }
    }
}

enum PhotoExportQuality: String, CaseIterable, Identifiable, Sendable {
    case compact, balanced, maximum

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: return "Smaller File"
        case .balanced: return "Balanced"
        case .maximum: return "Best Quality"
        }
    }

    var detail: String {
        switch self {
        case .compact: return "Best for messages and the web"
        case .balanced: return "High quality with a smaller file"
        case .maximum: return "Least compression and the largest file"
        }
    }

    var compression: CGFloat {
        switch self {
        case .compact: return 0.78
        case .balanced: return 0.92
        case .maximum: return 1
        }
    }
}

enum VideoExportFormat: String, CaseIterable, Identifiable, Sendable, Codable {
    case quickTime, mpeg4, hevc10
    case appleProRes422Proxy, appleProRes422LT
    case appleProRes422, appleProRes422HQ
    case appleProRes4444, appleProRes4444XQ

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quickTime: return "QuickTime Movie"
        case .mpeg4: return "MPEG-4"
        case .hevc10: return "HEVC 10-bit"
        case .appleProRes422Proxy: return "Apple ProRes 422 Proxy"
        case .appleProRes422LT: return "Apple ProRes 422 LT"
        case .appleProRes422: return "Apple ProRes 422"
        case .appleProRes422HQ: return "Apple ProRes 422 HQ"
        case .appleProRes4444: return "Apple ProRes 4444"
        case .appleProRes4444XQ: return "Apple ProRes 4444 XQ"
        }
    }

    var detail: String {
        switch self {
        case .quickTime: return "H.264 or HEVC · .mov"
        case .mpeg4: return "H.264 or HEVC · .mp4"
        case .hevc10: return "10-bit 4:2:0 · compact .mp4"
        case .appleProRes422Proxy: return "10-bit 4:2:2 · smallest ProRes"
        case .appleProRes422LT: return "10-bit 4:2:2 · compact ProRes"
        case .appleProRes422: return "10-bit 4:2:2 · standard ProRes"
        case .appleProRes422HQ: return "10-bit 4:2:2 · highest-quality 422"
        case .appleProRes4444: return "12-bit 4:4:4 · mastering quality"
        case .appleProRes4444XQ: return "12-bit 4:4:4 · maximum ProRes quality"
        }
    }

    var isProRes: Bool {
        switch self {
        case .quickTime, .mpeg4, .hevc10: return false
        case .appleProRes422Proxy, .appleProRes422LT,
             .appleProRes422, .appleProRes422HQ,
             .appleProRes4444, .appleProRes4444XQ: return true
        }
    }

    var proResPrecision: String {
        switch self {
        case .appleProRes4444, .appleProRes4444XQ: return "12-bit 4:4:4"
        default: return "10-bit 4:2:2"
        }
    }

    var requiresMaximumDetail: Bool { isProRes || self == .hevc10 }

    static var availableCases: [Self] {
        #if os(macOS)
        if #available(macOS 15.0, *) { return allCases }
        return allCases.filter { $0 != .appleProRes4444XQ }
        #else
        return allCases.filter {
            $0 != .hevc10 && $0 != .appleProRes4444
                && $0 != .appleProRes4444XQ
        }
        #endif
    }

    func codec(hdr: Bool) -> VideoPipeline.ExportCodec {
        switch self {
        case .quickTime, .mpeg4: return hdr ? .hevc : .h264
        case .hevc10: return .hevc
        case .appleProRes422Proxy: return .proRes422Proxy
        case .appleProRes422LT: return .proRes422LT
        case .appleProRes422: return .proRes422
        case .appleProRes422HQ: return .proRes422HQ
        case .appleProRes4444: return .proRes4444
        case .appleProRes4444XQ: return .proRes4444XQ
        }
    }

    var fileExtension: String { self == .mpeg4 || self == .hevc10 ? "mp4" : "mov" }
    var contentType: UTType {
        self == .mpeg4 || self == .hevc10 ? .mpeg4Movie : .quickTimeMovie
    }
    var fileType: AVFileType {
        self == .mpeg4 || self == .hevc10 ? .mp4 : .mov
    }
}

struct VideoRenderRequest: Sendable, Codable {
    /// Long edge of the encoded frame; nil preserves source resolution.
    let longEdge: Int?
    /// Nil preserves the source cadence.
    let frameRate: Int?
    let format: VideoExportFormat
    /// Whether the delivery keeps highlight headroom or rolls it into a standard-range file.
    let hdr: Bool
    /// Whether the emulsion develops on the faster internal path.
    let fast: Bool
    /// False writes a silent movie and skips the source audio track.
    let includeAudio: Bool
}

/// The last confirmed delivery choices.
struct PhotoExportPreset: Sendable {
    let resolutionID: String
    let longEdge: Int?
    let format: PhotoExportChoice
    let quality: PhotoExportQuality
    let hdr: Bool
    let metadata: ExportMetadataPolicy
}

struct VideoExportPreset: Sendable {
    let resolutionID: String
    let longEdge: Int?
    let frameRate: Int?
    let format: VideoExportFormat
    let hdr: Bool
    let fast: Bool
    let includeAudio: Bool
}

enum ExportPresetStore {
    private enum Key {
        static let photoResolution = "fotufilm.export.photo.resolution"
        static let photoLongEdge = "fotufilm.export.photo.long-edge"
        static let photoFormat = "fotufilm.export.photo.format"
        static let photoQuality = "fotufilm.export.photo.quality"
        static let photoHDR = "fotufilm.export.photo.hdr"
        static let photoMetadata = "fotufilm.export.photo.metadata"
        static let videoResolution = "fotufilm.export.video.resolution"
        static let videoLongEdge = "fotufilm.export.video.long-edge"
        static let videoFrameRate = "fotufilm.export.video.frame-rate"
        static let videoFormat = "fotufilm.export.video.format"
        static let videoHDR = "fotufilm.export.video.hdr"
        static let videoFast = "fotufilm.export.video.fast"
        static let videoAudio = "fotufilm.export.video.audio"
    }

    private static let defaults = UserDefaults.standard

    static var hasPhoto: Bool {
        defaults.string(forKey: Key.photoFormat) != nil
    }

    static var hasVideo: Bool {
        defaults.string(forKey: Key.videoFormat) != nil
    }

    static func savePhoto(_ request: PhotoRenderRequest,
                          resolutionID: String) {
        defaults.set(resolutionID, forKey: Key.photoResolution)
        store(request.longEdge, forKey: Key.photoLongEdge)
        defaults.set(request.choice.rawValue, forKey: Key.photoFormat)
        if case .developed(_, let delivery, let quality, let metadata) = request {
            defaults.set(quality.rawValue, forKey: Key.photoQuality)
            defaults.set(delivery.hdrContainer != nil, forKey: Key.photoHDR)
            defaults.set(metadata.rawValue, forKey: Key.photoMetadata)
        } else {
            defaults.set(PhotoExportQuality.balanced.rawValue, forKey: Key.photoQuality)
            defaults.set(false, forKey: Key.photoHDR)
            defaults.set(ExportMetadataPolicy.preserveWithoutLocation.rawValue,
                         forKey: Key.photoMetadata)
        }
    }

    static func photo() -> PhotoExportPreset? {
        guard let resolutionID = defaults.string(forKey: Key.photoResolution),
              let format = defaults.string(forKey: Key.photoFormat)
                .flatMap(PhotoExportChoice.init(rawValue:)),
              let quality = defaults.string(forKey: Key.photoQuality)
                .flatMap(PhotoExportQuality.init(rawValue:))
        else { return nil }
        return PhotoExportPreset(
            resolutionID: resolutionID,
            longEdge: defaults.object(forKey: Key.photoLongEdge) as? Int,
            format: format,
            quality: quality,
            hdr: defaults.bool(forKey: Key.photoHDR),
            metadata: defaults.string(forKey: Key.photoMetadata)
                .flatMap(ExportMetadataPolicy.init(rawValue:))
                ?? .preserveWithoutLocation)
    }

    static func saveVideo(_ request: VideoRenderRequest,
                          resolutionID: String) {
        defaults.set(resolutionID, forKey: Key.videoResolution)
        store(request.longEdge, forKey: Key.videoLongEdge)
        store(request.frameRate, forKey: Key.videoFrameRate)
        defaults.set(request.format.rawValue, forKey: Key.videoFormat)
        defaults.set(request.hdr, forKey: Key.videoHDR)
        defaults.set(request.fast, forKey: Key.videoFast)
        defaults.set(request.includeAudio, forKey: Key.videoAudio)
    }

    static func video() -> VideoExportPreset? {
        guard let resolutionID = defaults.string(forKey: Key.videoResolution),
              let format = defaults.string(forKey: Key.videoFormat)
                .flatMap(VideoExportFormat.init(rawValue:)),
              defaults.object(forKey: Key.videoHDR) != nil,
              defaults.object(forKey: Key.videoFast) != nil,
              defaults.object(forKey: Key.videoAudio) != nil
        else { return nil }
        return VideoExportPreset(
            resolutionID: resolutionID,
            longEdge: defaults.object(forKey: Key.videoLongEdge) as? Int,
            frameRate: defaults.object(forKey: Key.videoFrameRate) as? Int,
            format: format,
            hdr: defaults.bool(forKey: Key.videoHDR),
            fast: defaults.bool(forKey: Key.videoFast),
            includeAudio: defaults.bool(forKey: Key.videoAudio))
    }

    private static func store(_ value: Int?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

extension Rendered {
    /// Encodes a developed still directly to its destination, avoiding a
    /// second full-size in-memory copy.
    @discardableResult
    func write(to url: URL, format: PhotoExportFormat,
               quality: CGFloat = 0.95,
               metadata policy: ExportMetadataPolicy) -> Bool {
        try? FileManager.default.removeItem(at: url)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, format.contentType.identifier as CFString, 1, nil)
        else { return false }
        var properties: [String: Any] = [:]
        if format == .jpeg || format == .heic {
            properties[kCGImageDestinationLossyCompressionQuality as String] = quality
        }
        if orientation != .up {
            properties[kCGImagePropertyOrientation as String] = orientation.rawValue
        }
        if let metadata = metadata(applying: policy) {
            properties.merge(metadata) { kept, _ in kept }
        }
        CGImageDestinationAddImage(
            destination, image,
            properties.isEmpty ? nil : properties as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }
}

/// One encoded size a clip can be delivered at.
struct VideoOutputSize: Identifiable, Equatable {
    let id: String
    let label: String
    let longEdge: Int?
    let pixels: CGSize

    var detail: String {
        "\(Int(pixels.width.rounded())) × \(Int(pixels.height.rounded()))"
    }

    static func options(for source: CGSize) -> [VideoOutputSize] {
        guard source.width > 0, source.height > 0 else { return [] }
        let longest = max(source.width, source.height)
        var result = [VideoOutputSize(id: "source", label: "Source",
                                     longEdge: nil, pixels: source)]
        for (label, edge) in [("4K", 3840), ("1440p", 2560),
                              ("1080p", 1920), ("720p", 1280)] {
            guard CGFloat(edge) < longest - 1 else { continue }
            let scale = CGFloat(edge) / longest
            result.append(VideoOutputSize(
                id: "\(edge)", label: label, longEdge: edge,
                pixels: CGSize(width: even(source.width * scale),
                               height: even(source.height * scale))))
        }
        return result
    }

    private static func even(_ value: CGFloat) -> CGFloat {
        CGFloat(max(2, Int(value.rounded()) / 2 * 2))
    }
}

/// What a finished export produced, and what it can still become.
struct ExportResult: Identifiable {
    let id = UUID()
    let url: URL
    let isVideo: Bool
    let contentType: UTType
    /// Something to look at, so the sheet is about the print rather than about a filename.
    let preview: PlatformImage?

}
