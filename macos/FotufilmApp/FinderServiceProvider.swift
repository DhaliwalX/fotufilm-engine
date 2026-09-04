import AppKit
import UniformTypeIdentifiers

/// Receives Finder's Services pasteboard and hands one selected photo or video to the app's
/// existing file-open route. Fotufilm is a single-session editor, so the service states that
/// boundary instead of silently choosing among several selected files.
final class FinderServiceProvider: NSObject {
    private let open: ([URL]) -> Void

    init(open: @escaping ([URL]) -> Void) {
        self.open = open
    }

    @objc func openInFotufilm(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error errorPointer: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        let urls = (pasteboard.readObjects(
            forClasses: [NSURL.self], options: options) ?? [])
            .compactMap { $0 as? URL }
            .filter(Self.isSupportedMedia)

        guard urls.count == 1, let url = urls.first else {
            errorPointer.pointee = urls.isEmpty
                ? "Choose a photo or video to open in Fotufilm."
                : "Fotufilm opens one photo or video at a time."
            return
        }

        DispatchQueue.main.async { [open] in
            open([url])
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private static func isSupportedMedia(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let resourceType = try? url.resourceValues(
            forKeys: [.contentTypeKey]).contentType
        let type = resourceType ?? UTType(filenameExtension: url.pathExtension)
        return type?.conforms(to: .image) == true
            || type?.conforms(to: .movie) == true
    }
}
