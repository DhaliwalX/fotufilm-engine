import Foundation

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// The user's own films (`mine.fotufilmpack`, a `local` pack) and the `community` packs they were
/// sent, which are stored exactly as they arrived so passing one along hands over the sender's own
/// bytes.
enum CustomStockStore {
    static let mineID = "mine"

    /// Application Support rather than Documents, which is what file sharing exposes.
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        #if FOTUFILM_SOURCE_BUILD
        let url = base.appendingPathComponent("FotufilmSource/CustomPacks", isDirectory: true)
        #else
        let url = base.appendingPathComponent("CustomPacks", isDirectory: true)
        #endif
        try? FileManager.default.createDirectory(at: url,
                                                 withIntermediateDirectories: true)
        return url
    }

    static func packFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]))?
            .filter { $0.pathExtension == FilmStockPack.sealedPathExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    }

    /// Called by `StockPacks`, which owns when a reload happens.
    static func publish() {
        FilmStockPack.installedSealedPackURLs = packFiles()
    }

    enum StoreError: Error, CustomStringConvertible {
        case duplicateID(String)
        case notFound(String)
        case notShareable
        case unreadable(String)

        public var description: String {
            switch self {
            case let .duplicateID(id):
                return "You already have a film called '\(id)'."
            case let .notFound(id):
                return "No pack called '\(id)'."
            case .notShareable:
                return "Only films you made or were given can be shared."
            case let .unreadable(reason):
                return reason
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

    struct ImportResult {
        var packID: String
        var name: String
        var stockNames: [String]
        var replacedExisting: Bool
    }

    @discardableResult
    static func importPack(from source: URL) throws -> ImportResult {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }

        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= FilmPackContainer.fileLimit else {
            throw StoreError.unreadable("That pack is too large to be a film pack.")
        }
        let data = try Data(contentsOf: source)

        let head = try FilmPackContainer.peek(data)
        guard head.kind == .community else {
            throw StoreError.unreadable(
                head.kind == .vault
                    ? "That pack is part of an app rather than something to import."
                    : "That pack was made for a single device and cannot be moved.")
        }

        let manifest = try FilmPackContainer.open(data).manifest
        guard !manifest.stocks.isEmpty else {
            throw StoreError.unreadable("That pack has no films in it.")
        }
        for stock in manifest.stocks { try stock.validate() }
        guard manifest.packID != mineID else {
            throw StoreError.unreadable("That pack collides with your own films.")
        }
        try FilmStockDefinition.checkPackID(manifest.packID)

        let destination = url(forPack: manifest.packID)
        let replaced = FileManager.default.fileExists(atPath: destination.path)
        try data.write(to: destination, options: [.atomic])
        StockPacks.refresh()

        return ImportResult(packID: manifest.packID, name: manifest.name,
                            stockNames: manifest.stocks.map(\.name),
                            replacedExisting: replaced)
    }

    static func deletePack(packID: String) throws {
        let url = url(forPack: packID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StoreError.notFound(packID)
        }
        try FileManager.default.removeItem(at: url)
        StockPacks.refresh()
    }

    /// `stockIDs` are the loaded (qualified) ids. `sealForSharing` is what
    /// refuses anything the user did not make or receive.
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
        directory.appendingPathComponent(
            "\(packID).\(FilmStockPack.sealedPathExtension)")
    }
}

extension FilmStockDefinition {
    /// A pack id becomes part of a file name, so it is held to the same characters a stock id is.
    static func checkPackID(_ packID: String) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !packID.isEmpty, packID.count <= 64,
              packID.unicodeScalars.allSatisfy(allowed.contains) else {
            throw CustomStockStore.StoreError.unreadable(
                "That pack's identifier is not one this app will store.")
        }
    }
}
