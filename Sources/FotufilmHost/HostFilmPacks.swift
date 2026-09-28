import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Where this person's community film packs are installed, supplied by the platform
/// (`HostPlatform.filmPacks`). What a pack must be to go in, and the words for refusing one, are
/// `FilmPackLibrary`'s, shared with the Mac app.
struct HostFilmPackLibrary {
    /// A per-user directory the host may write. macOS uses the Mac app's own custom store, so a
    /// pack added in either app shows in both and in the plugins; a Linux or Windows port names its
    /// own (for example under `$XDG_DATA_HOME` or `%APPDATA%`).
    var directory: URL
    /// The release a pack's `minimumMacAppVersion` is checked against.
    var appVersion: String
    /// Said after a pack is added: where else it now shows.
    var addedNote: String?
}

enum HostFilmPacks {
    /// Registers the container keys this build was given, once. The desktop build compiles the
    /// same key material the Mac app does (`cef/build-engine.sh`); a build without it opens only
    /// packs sealed with keys someone else registered, as the tests do.
    static let registerKeys: Void = {
        #if FOTUFILM_PACK_KEY_MATERIAL
        let keyring = FilmPackKeyring.shared
        if let vault = try? FilmPackKey(bytes: FilmPackKeyMaterial.vaultKey) {
            keyring.register(vault, kind: .vault, id: FilmPackKeyMaterial.vaultKeyID)
        }
        if let community = try? FilmPackKey(bytes: FilmPackKeyMaterial.communityKey) {
            keyring.register(community, kind: .community, id: FilmPackKeyMaterial.communityKeyID)
        }
        #endif
    }()

    /// Offers the installed community packs this release reads, as the plugins do, and reloads
    /// the films. `nil` offers none.
    static func publish(_ library: HostFilmPackLibrary?) {
        _ = registerKeys
        FilmStockPack.installedSealedPackURLs = library.map {
            FilmPackLibrary.compatibleCommunityPacks(in: $0.directory, macAppVersion: $0.appVersion)
        } ?? []
        FilmStockPack.reload()
    }
}

/// The editor's film-pack calls (`web/src/backend/macos/host.js`): list the installed community
/// packs, add one from a file or its bytes, remove one. Each change reloads the engine's films.
extension HostService {
    func filmPacks(_ method: String, parameters: [String: Any],
                   payload: UnsafeRawBufferPointer?) throws -> Answer {
        guard let library = engine.filmPacks else {
            throw HostEngine.Failure(description: "This host cannot install film packs.")
        }
        switch method {
        case "filmPacks":
            // The Mac app may have added or removed one since: the films follow, and `changed`
            // tells the page to ask for them again.
            let changed = FilmPackLibrary.compatibleCommunityPacks(
                in: library.directory, macAppVersion: library.appVersion)
                != FilmStockPack.installedSealedPackURLs
            if changed { filmsChanged() }
            return try answer(["packs": installed(library), "changed": changed,
                               "incompatible": incompatible(library)])
        case "importFilmPack":
            return try answer(importFilmPack(parameters, payload: payload, into: library))
        default:
            guard let packID = parameters["packID"] as? String,
                  FilmPackLibrary.installedCommunityPacks(
                    in: library.directory, macAppVersion: library.appVersion)
                    .contains(where: { $0.packID == packID }) else {
                throw HostEngine.Failure(description: FilmPackLibrary.Failure.notFound(
                    parameters["packID"] as? String ?? "").description)
            }
            try FilmPackLibrary.remove(packID: packID, in: library.directory)
            filmsChanged()
            return try answer(["packs": installed(library)])
        }
    }

    /// The answer the Mac app's alert gives: "Pack added" and "Name v1 — 3 films", "Pack not
    /// added" and why, or an update to ask for.
    private func importFilmPack(_ parameters: [String: Any], payload: UnsafeRawBufferPointer?,
                                into library: HostFilmPackLibrary) throws -> [String: Any] {
        // A file the host chose is read in place; a page without one sends the bytes.
        let file = (parameters["path"] as? String).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        var bytes: Data?
        if let payload, payload.count > 0 {
            bytes = Data(bytes: payload.baseAddress!, count: payload.count)
        } else if let text = parameters["data"] as? String {
            bytes = Data(base64Encoded: text)
        }
        guard file != nil || bytes != nil else {
            throw HostEngine.Failure(description: "The pack's bytes did not arrive.")
        }
        do {
            let result = try file.map {
                try FilmPackLibrary.install(contentsOf: $0, in: library.directory,
                                            macAppVersion: library.appVersion)
            } ?? FilmPackLibrary.install(bytes!, in: library.directory,
                                         macAppVersion: library.appVersion)
            filmsChanged()
            var message = result.summary
            if let note = library.addedNote { message += "\n\n" + note }
            return ["added": true, "title": result.title, "message": message,
                    "packID": result.packID, "replaced": result.replacedExisting,
                    "packs": installed(library)]
        } catch let FilmPackRelease.Failure.requiresMacApp(version) {
            return ["added": false, "update": true, "title": "Update Fotufilm to use this pack",
                    "message": FilmPackRelease.Failure.requiresMacApp(version).description]
        } catch {
            return ["added": false, "title": "Pack not added", "message": "\(error)"]
        }
    }

    /// Installed packs this release cannot read, each named as the Mac app's launch alert names
    /// it ("Pack: This pack needs Fotufilm 2.0 or later…").
    private func incompatible(_ library: HostFilmPackLibrary) -> [String] {
        FilmPackLibrary.packFiles(in: library.directory).compactMap { url in
            do {
                _ = try FilmPackContainer.open(Data(contentsOf: url),
                                               macAppVersion: library.appVersion)
                return nil
            } catch let failure as FilmPackRelease.Failure {
                return "\(url.deletingPathExtension().lastPathComponent): \(failure)"
            } catch {
                return nil
            }
        }
    }

    private func installed(_ library: HostFilmPackLibrary) -> [[String: Any]] {
        FilmPackLibrary.installedCommunityPacks(in: library.directory,
                                                macAppVersion: library.appVersion)
            .map { pack in
                var row: [String: Any] = ["packID": pack.packID, "name": pack.name,
                                          "films": pack.stockNames, "stocks": pack.stockIDs]
                if let version = pack.version { row["version"] = version }
                if let author = pack.author { row["author"] = author }
                if let problem = pack.problem { row["problem"] = problem }
                return row
            }
    }
}
