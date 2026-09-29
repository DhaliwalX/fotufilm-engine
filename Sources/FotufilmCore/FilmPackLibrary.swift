import Foundation

/// The import location shared by the Mac app and its plugins, and how a pack gets into it: every
/// app that installs packs (the Mac app, Fotufilm Desktop) accepts and refuses the same files with
/// the same words.
public enum FilmPackLibrary {
    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        #if FOTUFILM_SOURCE_BUILD
        return base.appendingPathComponent("FotufilmSource/CustomPacks", isDirectory: true)
        #else
        return base.appendingPathComponent("CustomPacks", isDirectory: true)
        #endif
    }

    /// The Mac app keeps the films a person makes under this id (`mine.fotufilmpack`, a `local`
    /// pack), so no imported pack may take it.
    public static let ownFilmsPackID = "mine"

    /// Plugins read imported community packs only. Device-local films and untrusted vaults
    /// are excluded, as are packs requiring a newer release of the app and plugins.
    public static func compatibleCommunityPacks(
        in directory: URL = directory, macAppVersion: String,
        keyring: FilmPackKeyring = .shared
    ) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles])) ?? []
        return entries.filter { url in
            guard url.pathExtension.lowercased() == FilmStockPack.sealedPathExtension,
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= FilmPackContainer.fileLimit,
                  let data = try? Data(contentsOf: url),
                  let header = try? FilmPackContainer.peek(data), header.kind == .community,
                  let pack = try? FilmPackContainer.open(data, keyring: keyring,
                                                        macAppVersion: macAppVersion),
                  !pack.manifest.stocks.isEmpty else { return false }
            return (try? pack.manifest.stocks.forEach { try $0.validate() }) != nil
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: Installing

    /// Why a pack was not added. A pack needing a newer app throws
    /// `FilmPackRelease.Failure.requiresMacApp` instead, which an app answers by offering an
    /// update; a file that is not a pack at all throws `FilmPackContainer.Failure`.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        case tooLarge
        case partOfAnApp
        case deviceBound
        case empty
        case collidesWithOwnFilms
        case unstorableID
        case notFound(String)

        public var description: String {
            switch self {
            case .tooLarge:
                return "That pack is too large to be a film pack."
            case .partOfAnApp:
                return "That pack is part of an app rather than something to import."
            case .deviceBound:
                return "That pack was made for a single device and cannot be moved."
            case .empty:
                return "That pack has no films in it."
            case .collidesWithOwnFilms:
                return "That pack collides with your own films."
            case .unstorableID:
                return "That pack's identifier is not one this app will store."
            case let .notFound(id):
                return "No pack called '\(id)'."
            }
        }
    }

    /// What an import added, as the apps report it.
    public struct ImportResult: Sendable {
        public var packID: String
        public var name: String
        public var stockNames: [String]
        public var version: String?
        /// A pack with the same id was there before and this one took its place.
        public var replacedExisting: Bool

        /// "Pack added" or "Pack updated".
        public var title: String { replacedExisting ? "Pack updated" : "Pack added" }

        /// "Name v1 — 3 films", or the film's own name when the pack carries one.
        public var summary: String {
            let films = stockNames.count == 1 ? stockNames[0] : "\(stockNames.count) films"
            return "\(name)\(version.map { " v\($0)" } ?? "") — \(films)"
        }
    }

    /// A community pack in the library, readable or not.
    public struct InstalledPack: Sendable {
        /// What the file is stored under, which `remove(packID:)` takes: the manifest's own id for
        /// anything `install` put there.
        public var packID: String
        public var name: String
        public var version: String?
        public var author: String?
        /// The films it carries, by name.
        public var stockNames: [String]
        /// The ids the films load under (`packID.stockID`).
        public var stockIDs: [String]
        public var url: URL
        /// Why its films are not offered (a newer app needed, the file damaged), or nil.
        public var problem: String?
    }

    public static func url(forPack packID: String, in directory: URL = directory) -> URL {
        directory.appendingPathComponent("\(packID).\(FilmStockPack.sealedPathExtension)")
    }

    /// Every sealed pack in the library, whatever its kind, in name order.
    public static func packFiles(in directory: URL = directory) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]))?
            .filter { $0.pathExtension == FilmStockPack.sealedPathExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    }

    /// A pack id becomes part of a file name, so it is held to the same characters a stock id is.
    public static func checkPackID(_ packID: String) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !packID.isEmpty, packID.count <= 64,
              packID.unicodeScalars.allSatisfy(allowed.contains) else {
            throw Failure.unstorableID
        }
    }

    /// Opens `data` as an import would take it: a community pack this release reads, carrying
    /// valid films under an id a file can be named for.
    public static func validateImport(_ data: Data, macAppVersion: String?,
                                      keyring: FilmPackKeyring = .shared) throws
        -> FilmPackManifest {
        guard data.count <= FilmPackContainer.fileLimit else { throw Failure.tooLarge }
        let head = try FilmPackContainer.peek(data)
        guard head.kind == .community else {
            throw head.kind == .vault ? Failure.partOfAnApp : Failure.deviceBound
        }
        let manifest = try FilmPackContainer.open(data, keyring: keyring,
                                                  macAppVersion: macAppVersion).manifest
        guard !manifest.stocks.isEmpty else { throw Failure.empty }
        for stock in manifest.stocks { try stock.validate() }
        guard manifest.packID != ownFilmsPackID else { throw Failure.collidesWithOwnFilms }
        try checkPackID(manifest.packID)
        return manifest
    }

    /// Stores a pack exactly as it arrived, so passing it along hands over the sender's own
    /// bytes. A pack with the same id is replaced.
    @discardableResult
    public static func install(_ data: Data, in directory: URL = directory,
                               macAppVersion: String?,
                               keyring: FilmPackKeyring = .shared) throws -> ImportResult {
        let manifest = try validateImport(data, macAppVersion: macAppVersion, keyring: keyring)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = url(forPack: manifest.packID, in: directory)
        let replaced = FileManager.default.fileExists(atPath: destination.path)
        // WASI has no temporary files, so it cannot write atomically.
        #if os(WASI)
        try data.write(to: destination)
        #else
        try data.write(to: destination, options: [.atomic])
        #endif
        return ImportResult(packID: manifest.packID, name: manifest.name,
                            stockNames: manifest.stocks.map(\.name), version: manifest.version,
                            replacedExisting: replaced)
    }

    /// Installs the pack file at `source`, refusing an oversized one before reading it.
    @discardableResult
    public static func install(contentsOf source: URL, in directory: URL = directory,
                               macAppVersion: String?,
                               keyring: FilmPackKeyring = .shared) throws -> ImportResult {
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= FilmPackContainer.fileLimit else { throw Failure.tooLarge }
        return try install(Data(contentsOf: source), in: directory,
                           macAppVersion: macAppVersion, keyring: keyring)
    }

    public static func remove(packID: String, in directory: URL = directory) throws {
        try checkPackID(packID)
        let url = url(forPack: packID, in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Failure.notFound(packID)
        }
        try FileManager.default.removeItem(at: url)
    }

    /// The community packs in the library, each with its films or with why they are not offered.
    public static func installedCommunityPacks(
        in directory: URL = directory, macAppVersion: String?,
        keyring: FilmPackKeyring = .shared
    ) -> [InstalledPack] {
        packFiles(in: directory).compactMap { url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size <= FilmPackContainer.fileLimit,
                  let data = try? Data(contentsOf: url),
                  let head = try? FilmPackContainer.peek(data), head.kind == .community
            else { return nil }
            let fileID = url.deletingPathExtension().lastPathComponent
            do {
                let manifest = try FilmPackContainer.open(data, keyring: keyring,
                                                          macAppVersion: macAppVersion).manifest
                var problem: String?
                if manifest.stocks.isEmpty {
                    problem = Failure.empty.description
                } else if let error = manifest.stocks.lazy.compactMap({ stock -> Error? in
                    do { try stock.validate(); return nil } catch { return error }
                }).first {
                    problem = "\(error)"
                }
                return InstalledPack(
                    packID: fileID, name: manifest.name, version: manifest.version,
                    author: manifest.author, stockNames: manifest.stocks.map(\.name),
                    stockIDs: manifest.stocks.map { "\(manifest.packID).\($0.id)" }, url: url,
                    problem: problem)
            } catch {
                // A decoder's trace means nothing to the person looking at the list.
                let problem: String
                if case FilmPackContainer.Failure.malformedPayload = error {
                    problem = "Its films cannot be read by this version of Fotufilm."
                } else {
                    problem = "\(error)"
                }
                return InstalledPack(packID: fileID, name: fileID, version: nil, author: nil,
                                     stockNames: [], stockIDs: [], url: url, problem: problem)
            }
        }
    }
}
