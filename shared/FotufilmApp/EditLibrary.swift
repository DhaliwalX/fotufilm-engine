import CoreGraphics
import Foundation
#if canImport(FotufilmImaging)
import FotufilmImaging
#endif
import ImageIO
import Observation
import UniformTypeIdentifiers

#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmEditModel)
import FotufilmEditModel
#endif

@MainActor
@Observable
final class EditLibrary {
    static let shared = EditLibrary()

    /// One serial disk writer for edit records.
    private actor RecordWriter {
        enum Result { case written, superseded, failed }
        private var newestRevision: [URL: UInt64] = [:]

        func write(_ data: Data, to url: URL, revision: UInt64) -> Result {
            guard revision >= newestRevision[url, default: 0] else {
                return .superseded
            }
            newestRevision[url] = revision
            do {
                try data.write(to: url, options: .atomic)
                return .written
            } catch {
                return .failed
            }
        }

        /// Rewrites the record on disk in place, after every write queued ahead of it.
        func rewrite(_ url: URL, revision: UInt64,
                     _ change: @Sendable (Data) -> Data?) -> Result {
            guard revision >= newestRevision[url, default: 0] else {
                return .superseded
            }
            guard let old = try? Data(contentsOf: url), let data = change(old) else {
                return .failed
            }
            return write(data, to: url, revision: revision)
        }
    }

    private static let recordWriter = RecordWriter()
    private var nextRecordRevision: UInt64 = 0
    /// Saves still on their way to the writer, by entry.
    private var pendingRecordWrites: [String: Int] = [:]
    private var newestAppliedRecordRevision: [String: UInt64] = [:]

    /// One edited photograph, as the gallery sees it.
    struct Entry: Identifiable, Equatable {
        let id: String
        let created: Date
        var modified: Date
        var rawTypeHint: String?
        /// The photo-library asset this edit came from, when it came from one.
        var assetIdentifier: String?
        /// Bumped when the thumbnail file is rewritten, so a grid cell knows
        /// to reload an image whose URL never changes.
        var thumbStamp: Date
        /// The film this edit is on, carried on the entry so the widget manifest can be built
        /// without reading every record back off disk.
        var stockID: String = ""
        /// Whether this entry only *points* at its media rather than keeping it.
        var isVideo = false
        /// A photograph whose original is the library asset's rather than a copy kept here.
        var linksOriginal = false
        /// A scanned negative's conversion, for an entry whose original is the scan.
        var scan: NegativeScanRecipe?

        var directory: URL { EditLibrary.root.appendingPathComponent(id) }
        var thumbnailURL: URL {
            directory.appendingPathComponent(EditLibrary.thumbName)
        }
        /// The untouched bytes this edit develops from — absent for entries that only point at
        /// their media: clips, and photographs that link their library original.
        var originalURL: URL {
            directory.appendingPathComponent(EditLibrary.originalName)
        }
    }

    private(set) var entries: [Entry] = []

    private(set) var developedAssets: Set<String> = []

    private struct Record: Codable {
        var version = 1
        var created: Date
        var modified: Date
        var rawTypeHint: String?
        var assetIdentifier: String?
        var edit: EditState
        /// Optional for backward compatibility because synthesized decoding ignores property defaults.
        var isVideo: Bool?
        /// The original is the library asset's; no copy is kept beside the record.
        var linksOriginal: Bool?
        /// The original is a scanned negative, converted by this recipe rather than `edit`.
        var scan: NegativeScanRecipe?
    }

    /// Where an entry's original lives.
    enum Original {
        case bytes(Data)
        /// The library asset with this identifier; the caller reads it from the library.
        case libraryAsset(String)
    }

    private nonisolated static let originalName = "original"
    private nonisolated static let recordName = "edit.json"
    private nonisolated static let thumbName = "thumb.jpg"
    private nonisolated static let developedName = "developed.json"

    /// The shelf: this device's, or the one in iCloud when that has been asked for and is actually
    /// available.
    private nonisolated static var root: URL {
        CloudShelf.root ?? localRoot
    }

    /// This device's own shelf, always.
    nonisolated static var localRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        #if os(macOS)
        return support.appendingPathComponent("Fotufilm", isDirectory: true)
            .appendingPathComponent("EditLibrary", isDirectory: true)
        #else
        return support.appendingPathComponent("EditLibrary", isDirectory: true)
        #endif
    }

    private var initialScan: Task<Void, Never>?

    private var cloudRescan: Task<Void, Never>?

    private init() {
        initialScan = Task { await refresh() }
        CloudShelf.watch { [weak self] in self?.scheduleCloudRescan() }
    }

    private func scheduleCloudRescan() {
        cloudRescan?.cancel()
        cloudRescan = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// Settles once the launch scan has read the shelf.
    func whenLoaded() async {
        await initialScan?.value
    }

    /// Reads the shelf off disk.
    func refresh() async {
        let inCloud = Self.root != Self.localRoot
        let (found, developed) = await Task.detached(priority: .utility) {
            () -> ([Entry], Set<String>) in
            let fm = FileManager.default
            let developed = (try? Data(contentsOf:
                    Self.root.appendingPathComponent(Self.developedName)))
                .flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) }
                ?? []
            guard let ids = try? fm.contentsOfDirectory(atPath: Self.root.path)
            else { return ([], developed) }
            let entries = ids.compactMap { id -> Entry? in
                let dir = Self.root.appendingPathComponent(id)
                if inCloud, !CloudShelf.isDownloaded(
                    dir.appendingPathComponent(Self.recordName)) {
                    CloudShelf.requestDownload(of: dir)
                    return nil
                }
                guard let record = Self.readRecord(in: dir) else { return nil }
                let thumb = dir.appendingPathComponent(Self.thumbName)
                let attributes = try? fm.attributesOfItem(atPath: thumb.path)
                let stamp = attributes?[.modificationDate] as? Date
                return Entry(id: id, created: record.created,
                             modified: record.modified,
                             rawTypeHint: record.rawTypeHint,
                             assetIdentifier: record.assetIdentifier,
                             thumbStamp: stamp ?? record.modified,
                             stockID: record.edit.stockID,
                             isVideo: record.isVideo ?? false,
                             linksOriginal: record.linksOriginal ?? false,
                             scan: record.scan)
            }
            .sorted { $0.modified > $1.modified }
            return (entries, developed)
        }.value
        developedAssets.formUnion(developed)
        let known = Set(entries.map(\.id))
        entries += found.filter { !known.contains($0.id) }
        if inCloud {
            let arrived = Set(found.map(\.id))
            entries.removeAll { entry in
                !arrived.contains(entry.id)
                    && !FileManager.default.fileExists(
                        atPath: entry.directory.path)
            }
        }
        entries.sort { $0.modified > $1.modified }
    }

    /// Puts a new photograph on the shelf: the original bytes and the state that develops them.
    func create(original: Data, rawTypeHint: String?,
                assetIdentifier: String? = nil,
                edit: EditState) async -> String? {
        let id = UUID().uuidString
        let dir = Self.root.appendingPathComponent(id)
        let record = Record(created: .now, modified: .now,
                            rawTypeHint: rawTypeHint,
                            assetIdentifier: assetIdentifier, edit: edit)
        let written = await Task.detached(priority: .utility) { () -> Bool in
            do {
                try FileManager.default.createDirectory(
                    at: dir, withIntermediateDirectories: true)
                try original.write(
                    to: dir.appendingPathComponent(Self.originalName),
                    options: .atomic)
                try Self.write(record, in: dir)
                return true
            } catch {
                try? FileManager.default.removeItem(at: dir)
                return false
            }
        }.value
        guard written else { return nil }
        entries.insert(Entry(id: id, created: record.created,
                             modified: record.modified,
                             rawTypeHint: record.rawTypeHint,
                             assetIdentifier: record.assetIdentifier,
                             thumbStamp: record.modified,
                             stockID: edit.stockID), at: 0)
        return id
    }

    /// Puts an edit on the shelf without its bytes: the record and the identifier of the library
    /// asset it develops, and nothing else. A clip is always kept this way; a photograph is when
    /// the shelf stays on this device, where the library it links is.
    func create(linkedAsset identifier: String, rawTypeHint: String? = nil,
                isVideo: Bool, edit: EditState) async -> String? {
        let id = UUID().uuidString
        let dir = Self.root.appendingPathComponent(id)
        let record = Record(created: .now, modified: .now, rawTypeHint: rawTypeHint,
                            assetIdentifier: identifier, edit: edit,
                            isVideo: isVideo ? true : nil,
                            linksOriginal: isVideo ? nil : true)
        let written = await Task.detached(priority: .utility) { () -> Bool in
            do {
                try FileManager.default.createDirectory(
                    at: dir, withIntermediateDirectories: true)
                try Self.write(record, in: dir)
                return true
            } catch {
                try? FileManager.default.removeItem(at: dir)
                return false
            }
        }.value
        guard written else { return nil }
        entries.insert(Entry(id: id, created: record.created,
                             modified: record.modified,
                             rawTypeHint: rawTypeHint,
                             assetIdentifier: identifier,
                             thumbStamp: record.modified,
                             stockID: edit.stockID,
                             isVideo: isVideo,
                             linksOriginal: !isVideo), at: 0)
        return id
    }

    /// Rewrites an entry's state.
    @discardableResult
    func save(id: String, edit: EditState) async -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            return false
        }
        var entry = entries[index]
        entry.modified = .now
        entry.stockID = edit.stockID
        let record = Record(created: entry.created, modified: entry.modified,
                            rawTypeHint: entry.rawTypeHint,
                            assetIdentifier: entry.assetIdentifier, edit: edit,
                            isVideo: entry.isVideo ? true : nil,
                            linksOriginal: entry.linksOriginal ? true : nil,
                            scan: entry.scan)
        return await write(record, for: entry, stockName: FilmChoice.name(for: edit.stockID))
    }

    /// Puts a scanned negative on the shelf: the scan's bytes and the recipe that converts it.
    func create(scan original: Data, rawTypeHint: String?,
                recipe: NegativeScanRecipe) async -> String? {
        var edit = EditState()
        edit.stockID = Self.stockID(of: recipe)
        guard let id = await create(original: original, rawTypeHint: rawTypeHint, edit: edit),
              let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        entries[index].scan = recipe
        return await save(id: id, scan: recipe) ? id : nil
    }

    /// Rewrites a scanned negative's recipe.
    @discardableResult
    func save(id: String, scan recipe: NegativeScanRecipe) async -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            return false
        }
        var entry = entries[index]
        entry.modified = .now
        entry.stockID = Self.stockID(of: recipe)
        entry.scan = recipe
        var edit = EditState()
        edit.stockID = entry.stockID
        let record = Record(created: entry.created, modified: entry.modified,
                            rawTypeHint: entry.rawTypeHint,
                            assetIdentifier: entry.assetIdentifier, edit: edit, scan: recipe)
        return await write(record, for: entry, stockName: "Negative scan")
    }

    /// The film a scan's entry names: the one it is read as, or none for an automatic conversion.
    private static func stockID(of recipe: NegativeScanRecipe) -> String {
        recipe.conversion == .film ? recipe.stockID : StockPreset.noFilmID
    }

    /// A scanned negative's bytes and recipe, for reopening it.
    func loadScan(id: String) async -> (original: Data, rawTypeHint: String?,
                                        recipe: NegativeScanRecipe)? {
        let dir = Self.root.appendingPathComponent(id)
        return await Task.detached(priority: .userInitiated) {
            guard let record = Self.readRecord(in: dir), let recipe = record.scan,
                  let data = try? Data(contentsOf: dir.appendingPathComponent(Self.originalName))
            else { return nil }
            return (data, record.rawTypeHint, recipe)
        }.value
    }

    /// Queues a record behind earlier saves and, once written, moves its entry to the front.
    private func write(_ record: Record, for entry: Entry, stockName: String) async -> Bool {
        let id = entry.id
        guard let data = try? Self.encode(record) else { return false }
        nextRecordRevision &+= 1
        let revision = nextRecordRevision
        let url = entry.directory.appendingPathComponent(Self.recordName)
        pendingRecordWrites[id, default: 0] += 1
        let result = await Self.recordWriter.write(data, to: url,
                                                   revision: revision)
        pendingRecordWrites[id, default: 1] -= 1
        switch result {
        case .failed:
            return false
        case .superseded:
            return true
        case .written:
            break
        }
        guard revision >= newestAppliedRecordRevision[id, default: 0] else {
            return true
        }
        newestAppliedRecordRevision[id] = revision
        guard let currentIndex = entries.firstIndex(where: { $0.id == id })
        else { return false }
        entries.remove(at: currentIndex)
        entries.insert(entry, at: 0)
        SpotlightIndex.index(id: entry.id,
                             stockName: stockName,
                             modified: entry.modified,
                             thumbnailURL: entry.thumbnailURL)
        publishRecents()
        return true
    }

    /// Keeps the latest print beside the entry, small, for the grid.
    func saveThumbnail(id: String, image: CGImage) async {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let url = entries[index].thumbnailURL
        let stamp = await Task.detached(priority: .utility) { () -> Date? in
            guard let data = Self.thumbnailJPEG(of: image, longEdge: 512)
            else { return nil }
            do {
                try data.write(to: url, options: .atomic)
                return .now
            } catch { return nil }
        }.value
        guard let stamp,
              let current = entries.firstIndex(where: { $0.id == id })
        else { return }
        entries[current].thumbStamp = stamp
        publishRecents()
    }

    /// The grid print, small: the render drawn down to `longEdge` and encoded as JPEG.
    private nonisolated static func thumbnailJPEG(of image: CGImage,
                                                  longEdge: CGFloat) -> Data? {
        let longest = CGFloat(max(image.width, image.height))
        let scale = min(1, longEdge / max(1, longest))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let thumb = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, thumb, [
            kCGImageDestinationLossyCompressionQuality: 0.8,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Everything a reopen needs: where the original is and the saved state. A copy kept here
    /// wins over a link, so an entry caught between the two still opens its own photograph.
    func load(id: String) async -> (original: Original, rawTypeHint: String?,
                                    edit: EditState)? {
        let dir = Self.root.appendingPathComponent(id)
        return await Task.detached(priority: .userInitiated) {
            guard let record = Self.readRecord(in: dir) else { return nil }
            let original: Original
            if let data = try? Data(contentsOf: dir.appendingPathComponent(Self.originalName)) {
                original = .bytes(data)
            } else if record.linksOriginal == true, let asset = record.assetIdentifier {
                original = .libraryAsset(asset)
            } else {
                return nil
            }
            return (original, record.rawTypeHint, record.edit.openableByPurchase())
        }.value
    }

    /// Drops the copy an entry keeps of a library original, leaving the link. The caller has
    /// checked the library still holds these very bytes. The record is marked first, so an
    /// interruption leaves a marked entry that still has its copy.
    func linkOriginal(id: String) async -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              !entries[index].isVideo, !entries[index].linksOriginal,
              entries[index].assetIdentifier != nil else { return false }
        let original = entries[index].originalURL
        guard await relink(id: id, linksOriginal: true) else { return false }
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: original)
        }.value
        return true
    }

    /// Keeps a copy of a linked entry's original again — for a shelf about to leave this device,
    /// and the library with it. The copy is written before the record forgets the link.
    func keepOriginal(id: String, data: Data) async -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              entries[index].linksOriginal else { return false }
        let original = entries[index].originalURL
        let written = await Task.detached(priority: .utility) { () -> Bool in
            (try? data.write(to: original, options: .atomic)) != nil
        }.value
        guard written else { return false }
        return await relink(id: id, linksOriginal: false)
    }

    /// Changes an entry's link on disk without touching its edit. Refused while a save is on its
    /// way, which would carry the old link; saves started from here on carry the new one.
    private func relink(id: String, linksOriginal: Bool) async -> Bool {
        guard pendingRecordWrites[id, default: 0] == 0,
              let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        entries[index].linksOriginal = linksOriginal
        nextRecordRevision &+= 1
        let url = entries[index].directory.appendingPathComponent(Self.recordName)
        let result = await Self.recordWriter.rewrite(url, revision: nextRecordRevision) { old in
            guard var record = Self.decode(old) else { return nil }
            record.linksOriginal = linksOriginal ? true : nil
            return try? Self.encode(record)
        }
        guard result == .failed else { return true }
        if let current = entries.firstIndex(where: { $0.id == id }) {
            entries[current].linksOriginal = !linksOriginal
        }
        return false
    }

    /// The newest edit made from a given library photograph, if one exists — `entries` is
    /// newest-first, so the first match is the one a tap on the photograph should reopen.
    func entry(forAsset identifier: String) -> Entry? {
        entries.first { $0.assetIdentifier == identifier && !$0.isVideo }
    }

    /// The grade kept for a clip, by the asset it belongs to.
    func linkedEntry(forAsset identifier: String) -> Entry? {
        entries.first { $0.assetIdentifier == identifier && $0.isVideo }
    }

    /// An entry's saved state on its own, with no original beside it — what a reopen needs when the
    /// media is the library's rather than ours.
    func loadEdit(id: String) async -> EditState? {
        let dir = Self.root.appendingPathComponent(id)
        return await Task.detached(priority: .userInitiated) {
            Self.readRecord(in: dir)?.edit.openableByPurchase()
        }.value
    }

    /// Whether a library asset has this app's mark on it: either an edit was made from it, or the
    /// app put it there in the first place.
    func isAppAsset(_ identifier: String) -> Bool {
        developedAssets.contains(identifier)
            || entries.contains { $0.assetIdentifier == identifier }
    }

    /// Every identifier the gallery should badge — the sources edits were
    /// made from and the prints the app saved.
    var appAssetIdentifiers: Set<String> {
        developedAssets.union(entries.compactMap(\.assetIdentifier))
    }

    /// Records that a save to Photos made this asset, and keeps the fact.
    func markDeveloped(assetIdentifier: String) {
        guard !assetIdentifier.isEmpty,
              developedAssets.insert(assetIdentifier).inserted else { return }
        let snapshot = developedAssets
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(
                at: Self.root, withIntermediateDirectories: true)
            try? data.write(to: Self.root.appendingPathComponent(Self.developedName),
                            options: .atomic)
        }
    }

    /// Takes an entry off the shelf, original and all.
    func delete(id: String) {
        entries.removeAll { $0.id == id }
        publishRecents()
        SpotlightIndex.remove(id: id)
        let dir = Self.root.appendingPathComponent(id)
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func publishRecents() {
        let newest = entries.prefix(RecentFrames.limit).map {
            (id: $0.id, stockName: FilmChoice.name(for: $0.stockID),
             modified: $0.modified, thumbnail: $0.thumbnailURL)
        }
        Task.detached(priority: .utility) {
            RecentFrames.publish(newest)
            await WidgetReload.recents()
        }
    }

    private nonisolated static func readRecord(in directory: URL) -> Record? {
        guard let data = try? Data(contentsOf:
                directory.appendingPathComponent(recordName))
        else { return nil }
        return decode(data)
    }

    private nonisolated static func decode(_ data: Data) -> Record? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Record.self, from: data)
    }

    private nonisolated static func write(_ record: Record,
                                          in directory: URL) throws {
        let data = try encode(record)
        try data.write(to: directory.appendingPathComponent(recordName),
                       options: .atomic)
    }

    private nonisolated static func encode(_ record: Record) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(record)
    }
}
