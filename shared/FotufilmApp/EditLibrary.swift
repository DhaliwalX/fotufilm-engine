import CoreGraphics
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

#if canImport(FotufilmCore)
import FotufilmCore
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
    }

    private static let recordWriter = RecordWriter()
    private var nextRecordRevision: UInt64 = 0
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

        var directory: URL { EditLibrary.root.appendingPathComponent(id) }
        var thumbnailURL: URL {
            directory.appendingPathComponent(EditLibrary.thumbName)
        }
        /// The untouched bytes this edit develops from — absent for entries that only point at
        /// their media.
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
                             isVideo: record.isVideo ?? false)
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

    /// Puts a clip's grade on the shelf without its bytes: the record and the identifier of the
    /// library asset it develops, and nothing else.
    func create(linkedAsset identifier: String,
                edit: EditState) async -> String? {
        let id = UUID().uuidString
        let dir = Self.root.appendingPathComponent(id)
        let record = Record(created: .now, modified: .now, rawTypeHint: nil,
                            assetIdentifier: identifier, edit: edit,
                            isVideo: true)
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
                             rawTypeHint: nil,
                             assetIdentifier: identifier,
                             thumbStamp: record.modified,
                             stockID: edit.stockID,
                             isVideo: true), at: 0)
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
                            isVideo: entry.isVideo ? true : nil)
        guard let data = try? Self.encode(record) else { return false }
        nextRecordRevision &+= 1
        let revision = nextRecordRevision
        let url = entry.directory.appendingPathComponent(Self.recordName)
        let result = await Self.recordWriter.write(data, to: url,
                                                   revision: revision)
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
                             stockName: FilmChoice.name(for: edit.stockID),
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

    /// Everything a reopen needs: the original bytes and the saved state.
    func load(id: String) async -> (data: Data, rawTypeHint: String?,
                                    edit: EditState)? {
        let dir = Self.root.appendingPathComponent(id)
        return await Task.detached(priority: .userInitiated) {
            guard let record = Self.readRecord(in: dir),
                  let data = try? Data(contentsOf:
                    dir.appendingPathComponent(Self.originalName))
            else { return nil }
            return (data, record.rawTypeHint, record.edit.openableByPurchase())
        }.value
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

/// The persisted form of an edit.
extension EditState: Codable {
    private enum CodingKeys: String, CodingKey {
        case stockID, chosenFormatID, sourceInterpretation,
             exposure, temperatureMired, captureIlluminantKelvin,
             filmLightKelvin, tint,
             highlights, shadows, localTone, saturation, vibrance,
             grain, grainMottleShare, discGrain,
             halation, halationColour, halationSpectrum,
             couplers, couplerGapReach, couplerSelf,
             printCorrection, paper, paperFollowsStock, seed,
             push, bleach, expiredYears, shutterSeconds, printLightKelvin,
             rotation, flipH, straighten, perspectiveV, perspectiveH,
             crop, grade, encodedGrade,
             lensCorrectionEnabled, lensProfileID, lensProfileAmount,
             lensAdjustment,
             lensFilterIDs, lensFilterMetering
    }

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stockID = try c.decodeIfPresent(String.self, forKey: .stockID) ?? stockID
        chosenFormatID = try c.decodeIfPresent(String.self, forKey: .chosenFormatID)
        sourceInterpretation = try c.decodeIfPresent(
            FilmSourceInterpretation.self, forKey: .sourceInterpretation)
            ?? sourceInterpretation
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? exposure
        temperatureMired = try c.decodeIfPresent(
            Double.self, forKey: .temperatureMired) ?? temperatureMired
        captureIlluminantKelvin = try c.decodeIfPresent(
            Double.self, forKey: .captureIlluminantKelvin)
        filmLightKelvin = try c.decodeIfPresent(Double.self, forKey: .filmLightKelvin)
        tint = try c.decodeIfPresent(Double.self, forKey: .tint) ?? tint
        highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? highlights
        shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? shadows
        localTone = try c.decodeIfPresent(Bool.self, forKey: .localTone) ?? localTone
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? saturation
        vibrance = try c.decodeIfPresent(Double.self, forKey: .vibrance) ?? vibrance
        grain = try c.decodeIfPresent(Double.self, forKey: .grain) ?? grain
        grainMottleShare = try c.decodeIfPresent(Double.self,
                                                 forKey: .grainMottleShare)
        discGrain = try c.decodeIfPresent(Bool.self, forKey: .discGrain) ?? discGrain
        halation = try c.decodeIfPresent(Double.self, forKey: .halation) ?? halation
        halationColour = try c.decodeIfPresent(
            Double.self, forKey: .halationColour) ?? halationColour
        // Discard stored curves with a different handle count instead of interpolating them.
        // The flat curve preserves the state used before this control existed.
        if let drawn = try c.decodeIfPresent([Double].self,
                                             forKey: .halationSpectrum),
           drawn.count == halationSpectrum.count {
            halationSpectrum = drawn
        }
        couplers = try c.decodeIfPresent(Double.self, forKey: .couplers) ?? couplers
        couplerGapReach = try c.decodeIfPresent(
            [Double].self, forKey: .couplerGapReach) ?? couplerGapReach
        couplerSelf = try c.decodeIfPresent(
            Double.self, forKey: .couplerSelf) ?? couplerSelf
        printCorrection = try c.decodeIfPresent(
            Double.self, forKey: .printCorrection) ?? printCorrection
        paper = try c.decodeIfPresent(String.self, forKey: .paper)
            .flatMap(PrintPaper.preset(id:)) ?? .photo
        // Older records stored a concrete medium and therefore preserve that choice. New edits
        // write the following flag explicitly.
        paperFollowsStock = try c.decodeIfPresent(
            Bool.self, forKey: .paperFollowsStock) ?? false
        seed = try c.decodeIfPresent(UInt64.self, forKey: .seed) ?? seed
        push = try c.decodeIfPresent(Double.self, forKey: .push) ?? push
        bleach = try c.decodeIfPresent(Double.self, forKey: .bleach) ?? bleach
        expiredYears = try c.decodeIfPresent(
            Double.self, forKey: .expiredYears) ?? expiredYears
        shutterSeconds = try c.decodeIfPresent(Double.self,
                                               forKey: .shutterSeconds)
        printLightKelvin = try c.decodeIfPresent(
            Double.self, forKey: .printLightKelvin)
        // Folded back into the quarter turn it means, because nothing downstream
        // survives a rotation outside 0...3: the frame panel's reading multiplies
        // it by 90, which traps on a record carrying anything near Int's ends. A
        // shelf record can arrive from another device, so the range is checked
        // here rather than assumed. `%` never traps for a positive divisor, so
        // this is safe for every Int the file can hold.
        rotation = ((try c.decodeIfPresent(Int.self, forKey: .rotation)
                     ?? rotation) % 4 + 4) % 4
        flipH = try c.decodeIfPresent(Bool.self, forKey: .flipH) ?? flipH
        straighten = try c.decodeIfPresent(Double.self, forKey: .straighten) ?? straighten
        perspectiveV = try c.decodeIfPresent(
            Double.self, forKey: .perspectiveV) ?? perspectiveV
        perspectiveH = try c.decodeIfPresent(
            Double.self, forKey: .perspectiveH) ?? perspectiveH
        crop = try c.decodeIfPresent(CGRect.self, forKey: .crop)
        grade = try c.decodeIfPresent(ColorGrade.self, forKey: .grade) ?? grade
        encodedGrade = try c.decodeIfPresent(
            Bool.self, forKey: .encodedGrade) ?? encodedGrade
        lensCorrectionEnabled = try c.decodeIfPresent(
            Bool.self, forKey: .lensCorrectionEnabled) ?? lensCorrectionEnabled
        lensProfileID = try c.decodeIfPresent(String.self,
                                              forKey: .lensProfileID)
        lensProfileAmount = try c.decodeIfPresent(
            Double.self, forKey: .lensProfileAmount) ?? lensProfileAmount
        lensAdjustment = try c.decodeIfPresent(
            LensAdjustment.self, forKey: .lensAdjustment) ?? lensAdjustment
        lensFilterIDs = try c.decodeIfPresent(
            [String].self, forKey: .lensFilterIDs) ?? lensFilterIDs
        // Through the raw value so a record from a newer build naming a metering this build
        // does not know falls back to the default instead of failing the whole edit.
        lensFilterMetering = try c.decodeIfPresent(
            String.self, forKey: .lensFilterMetering)
            .flatMap(LensFilterCompensation.init(rawValue:)) ?? lensFilterMetering
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(stockID, forKey: .stockID)
        try c.encodeIfPresent(chosenFormatID, forKey: .chosenFormatID)
        try c.encode(sourceInterpretation, forKey: .sourceInterpretation)
        try c.encode(exposure, forKey: .exposure)
        try c.encode(temperatureMired, forKey: .temperatureMired)
        try c.encodeIfPresent(captureIlluminantKelvin,
                              forKey: .captureIlluminantKelvin)
        try c.encodeIfPresent(filmLightKelvin, forKey: .filmLightKelvin)
        try c.encode(tint, forKey: .tint)
        try c.encode(highlights, forKey: .highlights)
        try c.encode(shadows, forKey: .shadows)
        try c.encode(localTone, forKey: .localTone)
        try c.encode(saturation, forKey: .saturation)
        try c.encode(vibrance, forKey: .vibrance)
        try c.encode(grain, forKey: .grain)
        try c.encodeIfPresent(grainMottleShare, forKey: .grainMottleShare)
        try c.encode(discGrain, forKey: .discGrain)
        try c.encode(halation, forKey: .halation)
        try c.encode(halationColour, forKey: .halationColour)
        try c.encode(halationSpectrum, forKey: .halationSpectrum)
        try c.encode(couplers, forKey: .couplers)
        try c.encode(couplerGapReach, forKey: .couplerGapReach)
        try c.encode(couplerSelf, forKey: .couplerSelf)
        try c.encode(printCorrection, forKey: .printCorrection)
        try c.encode(paper.id, forKey: .paper)
        try c.encode(paperFollowsStock, forKey: .paperFollowsStock)
        try c.encode(seed, forKey: .seed)
        try c.encode(push, forKey: .push)
        try c.encode(bleach, forKey: .bleach)
        try c.encode(expiredYears, forKey: .expiredYears)
        try c.encodeIfPresent(shutterSeconds, forKey: .shutterSeconds)
        try c.encodeIfPresent(printLightKelvin, forKey: .printLightKelvin)
        try c.encode(rotation, forKey: .rotation)
        try c.encode(flipH, forKey: .flipH)
        try c.encode(straighten, forKey: .straighten)
        try c.encode(perspectiveV, forKey: .perspectiveV)
        try c.encode(perspectiveH, forKey: .perspectiveH)
        try c.encodeIfPresent(crop, forKey: .crop)
        try c.encode(grade, forKey: .grade)
        try c.encode(encodedGrade, forKey: .encodedGrade)
        try c.encode(lensCorrectionEnabled, forKey: .lensCorrectionEnabled)
        try c.encodeIfPresent(lensProfileID, forKey: .lensProfileID)
        try c.encode(lensProfileAmount, forKey: .lensProfileAmount)
        try c.encode(lensAdjustment, forKey: .lensAdjustment)
        try c.encode(lensFilterIDs, forKey: .lensFilterIDs)
        try c.encode(lensFilterMetering.rawValue, forKey: .lensFilterMetering)
    }
}
