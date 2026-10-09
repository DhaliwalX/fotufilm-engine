import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmImaging)
import FotufilmImaging
#endif

/// Everything the host asks of the operating system, gathered in one place so a port supplies
/// its own services and the rest of the host stays the same. A missing service turns its feature
/// off: `capabilities` tells the editor what this build can do.
///
/// macOS fills it in `HostPlatform+Apple.swift` and Linux in `HostPlatform+Linux.swift`; a
/// Windows port adds its own file that sets `HostPlatform.current` from the services it has (for
/// example libraw/libheif decoding, a D3D developer, the desktop clipboard).
struct HostPlatform {
    /// Turns a photograph file into scene-linear light.
    var decoder: HostImageDecoder?
    /// Small pictures of stills not yet opened, for the photo strip (`HostThumbnails.swift`);
    /// without it an unopened photograph shows its name until it is opened.
    var thumbnails: HostThumbnailer?
    /// Reduces a photograph to a preview or export size as the platform's own editor does;
    /// without it the portable box filter (`AreaResample`) reduces.
    var resampler: HostResampler?
    /// Writes stills to files.
    var encoder: HostStillEncoder?
    /// Copy Photo.
    var clipboard: HostClipboard?
    /// Finds the subjects in a picture for a subject selection.
    var subjects: HostSubjectDetector?
    /// Draws print frames.
    var frames: HostFrameCompositor?
    /// Develops on a GPU; the portable Halide CPU developer is used without one.
    var developer: HostDeveloper?
    /// Opens movies (`HostVideo.swift`); without it the editor declines them.
    var videoSource: HostVideoSourceFactory?
    /// Writes movies.
    var videoWriter: HostVideoWriterFactory?
    /// Develops a movie's frames several at a time on the GPU (`HostVideoDevelop.swift`);
    /// without it an export develops frame by frame through `developer`.
    var videoDeveloper: HostVideoDeveloper?
    /// Installs the plug-ins for other editors (`HostPlugins.swift`).
    var plugins: HostPluginInstaller?
    /// Hashes stills for the identity their edit is kept under (`HostFileIdentity.swift`);
    /// without it a file is known by its name, size and date.
    var fileDigest: HostFileDigest?
    /// Where community film packs are installed (`HostFilmPacks.swift`); without it the editor
    /// offers no Import Film Pack.
    var filmPacks: HostFilmPackLibrary?
    /// Reads scanned negatives as the apps do (`HostNegativeScan`); without it a scan opens
    /// through `decoder`, with its file's colour profile.
    var scans: HostScanDecoder?
    /// The app's own releases (`HostUpdates.swift`): without it the editor offers no Check for
    /// Updates.
    var updates: HostUpdateChannel?

    static let current: HostPlatform = {
        #if canImport(ImageIO) && canImport(CoreImage)
        return .apple
        #elseif os(Linux)
        return .linux
        #else
        return HostPlatform()
        #endif
    }()

    /// What the editor may offer with these services (`window.fotufilmNativeTransport
    /// .capabilities`, read by web/src/backend/macos/host.js).
    var capabilities: [String: Any] {
        [
            "importPath": decoder != nil,
            "thumbnails": thumbnails != nil,
            // Scanned negatives open as documents, read as the edit's film and printed.
            "negativeScans": decoder != nil || scans != nil,
            "subjectSelection": subjects != nil,
            "copyImage": clipboard != nil,
            "printFrames": frames != nil,
            "imageExportTypes": encoder?.types.sorted() ?? [],
            "hdrExport": encoder?.writesHDR ?? false,
            // An Accurate still's Film grain is laid crystal by crystal over the whole frame, not
            // from the tiles, which takes seconds a photo.
            "filmGrainFrames": FilmGrain.laysFrameGrain,
            // Export All: the open photographs into one folder, pipelined (`exportBatch`).
            "batchExport": decoder != nil && encoder != nil,
            "filmSuggestion": true,
            // Check for Updates: a release feed, and a digest to verify what it downloads.
            "updates": updates != nil && fileDigest != nil,
            "video": videoSource != nil && videoWriter != nil,
            "videoExportTypes": videoWriter?.formats.map(\.json) ?? [],
            "videoBitrates": HostVideoBitrate.allCases.map { ["id": $0.rawValue, "label": $0.label] },
            "videoFrameRates": hostVideoFrameRates,
            // Video Quality, Full or Fast (`HostVideoProcessing`): Fast needs the pipelined
            // develop's hybrid road.
            "videoProcessing": videoSource != nil && videoWriter != nil && videoDeveloper != nil,
            // The plug-ins this platform installs, `{id, name}`, for the native menu and the
            // editor's plug-ins dialog; their state is asked for with `plugins`.
            "plugins": plugins?.catalogue.map { ["id": $0.id, "name": $0.name] } ?? [],
            "filmPacks": filmPacks != nil,
        ].merging(developer == nil ? [:] : [
            // A GPU developer answers a full preview within a frame or two: the editor may keep
            // full-size previews while an edit moves and refine sooner (web/src/preview-budget.js).
            "previewBudget": ["settleMs": 80, "initialInteractiveEdge": 1200,
                              "maxInteractiveEdge": 1600, "detailDelayMs": 60],
        ]) { current, _ in current }
    }
}

/// Decodes a photograph file the way the CLI and the apps do: RAW with its camera profile, HDR
/// sources with the range they recorded, upright.
protocol HostImageDecoder {
    func decode(_ url: URL) throws -> HostImage
}

/// Decodes scanned negatives with no rendering choices of its own, as the apps'
/// `NegativeScanImport` does, and measures photographs of a bare light source.
protocol HostScanDecoder {
    /// The scan in linear Rec. 2020: through the file's colour profile, its samples read as
    /// linear light where it has none, a camera RAW with every rendering choice off.
    func decodeScan(_ url: URL) throws -> HostImage
    /// The unevenness of the light a photograph of the bare light source shows.
    func measureLight(_ url: URL) throws -> NegativeLightFrame
}

/// Reduces scene-linear RGBA.
protocol HostResampler {
    /// Interleaved RGBA at exactly `targetWidth` x `targetHeight`, or nil to leave it to the
    /// portable reduction.
    func reduce(_ rgba: [Float], width: Int, height: Int,
                to targetWidth: Int, _ targetHeight: Int) -> [Float]?
}

/// Finds the subjects standing in front of a picture.
protocol HostSubjectDetector {
    /// Instance labels for 8-bit Display P3 pixels, or nil when there is no subject.
    func detect(_ pixels: [UInt8], width: Int, height: Int) -> HostSubject?
}

/// Draws a print frame around a developed picture.
protocol HostFrameCompositor {
    /// The framed picture from 8-bit Display P3 pixels, in the same form.
    func frame(_ pixels: [UInt8], width: Int, height: Int,
               configuration: PrintFrameConfiguration) -> (pixels: [UInt8], width: Int, height: Int)?
}

extension HostImage {
    /// Decodes with the platform's decoder.
    static func open(_ url: URL) throws -> HostImage {
        guard let decoder = HostPlatform.current.decoder else {
            throw HostEngine.Failure(description: "This build has no image decoder.")
        }
        return try decoder.decode(url)
    }
}
