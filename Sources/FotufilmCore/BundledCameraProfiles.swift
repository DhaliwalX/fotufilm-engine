import Foundation

/// Bundled camera spectral sensitivities: the Academy's measured dataset from
/// https://github.com/AcademySoftwareFoundation/rawtoaces-data (`data/camera/*.json`,
/// Apache-2.0), shipped verbatim and parsed into `CameraSpectralProfile`s on first lookup.
/// SwiftPM processes the files individually; app bundles retain the `CameraProfiles` directory.
///
/// The rawtoaces schema (0.1.0 / 1.0.0) is a `header` naming the camera and a
/// `spectral_data` block whose `index.main` lists the channel order (`R`, `G`, `B`) and whose
/// `data.main` maps wavelength — a string key in nanometres, 380–780 at 5 nm — to one relative
/// sensitivity per channel. Parsing is tolerant: a file that does not carry a usable record is
/// skipped rather than trusted, because a fabricated profile is worse than none.
extension CameraSpectralProfileStore {
    /// The profiles parsed out of the bundled dataset, loaded once, in filename order.
    /// Registration into the store happens separately (`loadBundledProfiles()`) so tests can
    /// inspect the parsed set without depending on registration order.
    static var bundledProfiles: [CameraSpectralProfile] { parsedBundledProfiles }

    /// Parses and registers the bundled profiles exactly once; thread-safe by the runtime's
    /// atomic static-let initialization. `profile(id:)`/`resolve` call this before answering so
    /// the dataset is simply *there* — no app startup ceremony. Explicitly registered profiles
    /// keep priority: a bundled profile never overwrites an id that is already present.
    public static func loadBundledProfiles() {
        _ = bundledRegistration
    }

    private static let bundledRegistration: Void = {
        // `registerIfAbsent`, not `profile(id:)` + `register`: the lookups call back into
        // `loadBundledProfiles()`, and re-entering this initializer would deadlock the
        // runtime's once-guard.
        for profile in parsedBundledProfiles {
            registerIfAbsent(profile)
        }
    }()

    private static let parsedBundledProfiles: [CameraSpectralProfile] = {
        guard let directory = bundledProfilesDirectory() else { return [] }
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return [] }
        return entries
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return parseRawtoacesProfile(data)
            }
    }()

    /// Where the shipped dataset lives, mirroring the reflectance-prior lookup: an explicit
    /// `FOTUFILM_RESOURCES` directory wins, then the package resource bundle, then the app
    /// bundle with the source tree as the headless-tool fallback.
    private static func bundledProfilesDirectory() -> URL? {
        if let configured = ProcessInfo.processInfo.environment["FOTUFILM_RESOURCES"] {
            let candidate = URL(fileURLWithPath: configured, isDirectory: true)
                .appendingPathComponent("CameraProfiles", isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path,
                                              isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate
            }
        }
        #if SWIFT_PACKAGE
        // Processed resources live at the bundle root. This also keeps a package
        // embedded through source links independent of its original checkout.
        return Bundle.module.resourceURL
        #else
        return Bundle.main.url(forResource: "CameraProfiles", withExtension: nil)
            ?? URL(fileURLWithPath: "Sources/FotufilmCore/CameraProfiles",
                   isDirectory: true)
        #endif
    }

    /// One rawtoaces camera file to one profile, or nil for anything that does not amount to a
    /// measured three-channel record. `JSONSerialization` rather than `Codable` because the
    /// wavelengths are dynamic dictionary keys and the schema has already moved once
    /// (0.1.0 → 1.0.0) without changing this shape.
    static func parseRawtoacesProfile(_ data: Data) -> CameraSpectralProfile? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = root["header"] as? [String: Any],
              let spectral = root["spectral_data"] as? [String: Any],
              let tables = spectral["data"] as? [String: Any],
              let main = tables["main"] as? [String: Any] else { return nil }

        func trimmed(_ key: String) -> String? {
            guard let value = header[key] as? String else { return nil }
            let cut = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return cut.isEmpty ? nil : cut
        }
        guard let make = trimmed("manufacturer"), let model = trimmed("model") else {
            return nil
        }

        // Channel order from `index.main`; R, G, B assumed only when the file says nothing.
        var order = ["R", "G", "B"]
        if let index = spectral["index"] as? [String: Any],
           let listed = index["main"] as? [Any] {
            let names = listed.compactMap { ($0 as? String)?.uppercased() }
            guard names.count == 3 else { return nil }
            order = names
        }
        guard let redChannel = order.firstIndex(of: "R"),
              let greenChannel = order.firstIndex(of: "G"),
              let blueChannel = order.firstIndex(of: "B") else { return nil }

        var samples: [(wavelength: Float, values: [Float])] = []
        for (key, value) in main {
            guard let wavelength = Float(key), let listed = value as? [Any],
                  listed.count == 3 else { return nil }
            let numbers = listed.compactMap { ($0 as? NSNumber)?.floatValue }
            guard numbers.count == 3, numbers.allSatisfy({ $0.isFinite }) else { return nil }
            samples.append((wavelength, numbers))
        }
        samples.sort { $0.wavelength < $1.wavelength }
        guard samples.count >= 2,
              zip(samples, samples.dropFirst())
                  .allSatisfy({ $0.wavelength < $1.wavelength }) else { return nil }

        return CameraSpectralProfile(
            id: bundledProfileID(make: make, model: model),
            make: make, model: model,
            wavelengths: samples.map(\.wavelength),
            red: samples.map { $0.values[redChannel] },
            green: samples.map { $0.values[greenChannel] },
            blue: samples.map { $0.values[blueChannel] })
    }

    /// The id a bundled camera registers under: a lowercase `make-model` slug — "Sony" +
    /// "ILCE-7M3" becomes `sony-ilce-7m3` — so ids are stable, filename-independent, and safe
    /// to write into sidecar files.
    static func bundledProfileID(make: String, model: String) -> String {
        let slug = (make + " " + model).lowercased().map { character in
            character.isLetter || character.isNumber ? String(character) : "-"
        }.joined()
        let parts = slug.split(separator: "-", omittingEmptySubsequences: true)
        return parts.joined(separator: "-")
    }
}
