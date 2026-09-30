import Foundation

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// The user's own films (`mine.fotufilmpack`, a `local` pack) and the `community` packs they were
/// sent, which are stored exactly as they arrived so passing one along hands over the sender's own
/// bytes.
enum CustomStockStore {
    static let mineID = FilmPackLibrary.ownFilmsPackID

    /// Application Support rather than Documents, which is what file sharing exposes.
    static var directory: URL {
        let url = FilmPackLibrary.directory
        try? FileManager.default.createDirectory(at: url,
                                                 withIntermediateDirectories: true)
        return url
    }

    static func packFiles() -> [URL] { FilmPackLibrary.packFiles(in: directory) }

    /// Called by `StockPacks`, which owns when a reload happens.
    static var incompatiblePacks: [String] = []

    static var macAppVersion: String? {
        #if os(macOS)
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        #else
        return nil
        #endif
    }

    static func publish() {
        incompatiblePacks = []
        FilmStockPack.installedSealedPackURLs = packFiles().filter { url in
            do {
                _ = try FilmPackContainer.open(Data(contentsOf: url), macAppVersion: macAppVersion)
                return true
            } catch let error as FilmPackRelease.Failure {
                incompatiblePacks.append("\(url.deletingPathExtension().lastPathComponent): \(error)")
                return false
            } catch {
                return true // Normal loader reports other errors; local keys may arrive later.
            }
        }
    }

    enum StoreError: Error, CustomStringConvertible {
        case duplicateID(String)

        public var description: String {
            switch self {
            case let .duplicateID(id):
                return "You already have a film called '\(id)'."
            }
        }
    }

    static func mine() -> [FilmStockDefinition] {
        guard let data = try? Data(contentsOf: url(forPack: mineID)),
              let manifest = try? FilmPackContainer.open(data).manifest
        else { return [] }
        return manifest.stocks.sorted { $0.id < $1.id }
    }

    static func save(_ definition: FilmStockDefinition,
                     replacingExisting: Bool = false) throws {
        try definition.validate()
        var stocks = mine()
        if let index = stocks.firstIndex(where: { $0.id == definition.id }) {
            guard replacingExisting else { throw StoreError.duplicateID(definition.id) }
            stocks[index] = definition
        } else {
            stocks.append(definition)
        }
        try writeMine(stocks)
    }

    static func delete(stockID: String) throws {
        let stocks = mine().filter { $0.id != stockID }
        if stocks.isEmpty {
            try? FileManager.default.removeItem(at: url(forPack: mineID))
        } else {
            try writeMine(stocks)
        }
    }

    private static func writeMine(_ stocks: [FilmStockDefinition]) throws {
        StockPacks.ensureLocalKey()
        let data = try FilmStockPack.sealForThisDevice(
            stocks, packID: mineID, name: "My Films")
        try data.write(to: url(forPack: mineID), options: [.atomic])
    }

    typealias ImportResult = FilmPackLibrary.ImportResult

    /// Accepts and refuses exactly what every Fotufilm app does (`FilmPackLibrary.install`).
    @discardableResult
    static func importPack(from source: URL) throws -> ImportResult {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        let result = try FilmPackLibrary.install(contentsOf: source, in: directory,
                                                 macAppVersion: macAppVersion)
        StockPacks.refresh()
        return result
    }

    static func deletePack(packID: String) throws {
        try FilmPackLibrary.remove(packID: packID, in: directory)
        StockPacks.refresh()
    }

    /// `stockIDs` are the loaded (qualified) ids.
    static func exportFile(stockIDs: [String], name: String,
                           author: String? = nil) throws -> URL {
        let packID = "pack-" + UUID().uuidString.prefix(8).lowercased()
        let data = try FilmStockPack.sealForSharing(
            stockIDs: stockIDs, packID: packID, name: name, author: author)

        let safe = name.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: "-")
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(safe.isEmpty ? "films" : safe).\(FilmStockPack.sealedPathExtension)")
        try? FileManager.default.removeItem(at: file)
        try data.write(to: file, options: [.atomic])
        return file
    }

    private static func url(forPack packID: String) -> URL {
        FilmPackLibrary.url(forPack: packID, in: directory)
    }
}
