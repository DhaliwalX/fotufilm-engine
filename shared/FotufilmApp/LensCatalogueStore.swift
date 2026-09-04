import Foundation

#if canImport(FotufilmCore)
import FotufilmCore
#endif

#if canImport(FotufilmImaging)
import FotufilmImaging
#endif

/// Loads bundled and imported lens profiles, with imported profiles taking precedence by ID.
/// The bundled catalogue is empty because only measured coefficients are accepted.
/// `tools/import-lensfun.swift` converts the CC-BY-SA Lensfun database into the supported format.
enum LensCatalogueStore {
    /// Where an imported catalogue is kept.
    static var importedURL: URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false) else { return nil }
        return support.appendingPathComponent("Fotufilm/lens-profiles.json")
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: LensCatalogue?

    /// The catalogue, read once and kept. Reading it is file work, and the render path asks for it
    /// on every photograph.
    static var shared: LensCatalogue {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let loaded = load()
        cached = loaded
        return loaded
    }

    /// Forgets what was read, so an import takes effect without a relaunch.
    static func reload() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    private static func load() -> LensCatalogue {
        var profiles: [LensProfile] = []
        if let url = Bundle.main.url(forResource: "lens-profiles",
                                     withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let bundled = try? LensCatalogue.load(from: data) {
            profiles = bundled.profiles
        }
        if let url = importedURL, let data = try? Data(contentsOf: url),
           let imported = try? LensCatalogue.load(from: data) {
            // An imported profile replaces a bundled one of the same identity rather than sitting
            // alongside it, so a match cannot depend on which was read first.
            var byID = Dictionary(profiles.map { ($0.id, $0) },
                                  uniquingKeysWith: { _, later in later })
            for profile in imported.profiles { byID[profile.id] = profile }
            profiles = Array(byID.values)
        }
        return LensCatalogue(profiles: profiles)
    }
}

/// What is going to be done about the lens, and where the numbers came from.
struct LensPlan {
    /// Where the measurement of the lens came from, as opposed to the photographer's own nudges.
    enum Measurement: Equatable {
        /// Nobody measured this lens: the sliders, if any, are the whole correction.
        case none
        /// A profile out of the catalogue.
        case profile(LensProfile)
        /// The file's own account of itself, read out of its DNG opcodes.
        case embedded
    }

    var stack = LensCorrectionStack([])
    var measurement: Measurement = .none
    /// Anything the file offered and this app refused, in words a person could be shown.
    var declined: [String] = []

    /// Whether a whole-lens measurement is in play, as opposed to nothing or a hand nudge.
    ///
    /// The decoder has its own lens correction, and for some cameras it is on by default. Two
    /// corrections of one barrel bend the frame back the other way, so when this app has a
    /// measurement of the whole lens it asks the decoder to stand down and applies its own. A hand
    /// nudge is not a measurement — it is "and a bit more than whatever I am looking at" — so it
    /// leaves the decoder alone.
    var supersedesDecoder: Bool { measurement != .none }

    /// Whether there is a measurement to show an Amount control for.
    var hasMeasurement: Bool { measurement != .none }

    /// What the lens panel says above its sliders, on either platform.
    ///
    /// Four situations look identical from the switch — corrected by a profile, corrected by the
    /// file itself, an unknown lens, a file that never said which lens — and a photographer can only
    /// act on the difference if it is written down. Anything the file offered and this app refused
    /// is named too, so an uncorrected frame is never a mystery.
    func note(for shot: LensShot?,
              catalogueIsEmpty: Bool = LensCatalogueStore.shared.isEmpty)
        -> String {
        switch measurement {
        case .profile(let profile):
            return profile.model
        case .embedded:
            return (["Using the correction stored in the file by the camera."]
                    + declined).joined(separator: " ")
        case .none:
            var note: String
            if let shot {
                note = catalogueIsEmpty
                    ? "No lens profiles are installed."
                    : "No profile for \(shot.lensModel)."
            } else {
                note = "This file didn’t record which lens took it."
            }
            for refusal in declined { note += " " + refusal }
            return note + " Use the sliders below."
        }
    }
}

extension EditState {
    /// Builds a correction from the catalogue or DNG opcodes, then applies manual adjustments.
    /// Catalogue profiles take precedence because they can include chromatic and falloff data.
    func lensPlan(for shot: LensShot?, dng: Data? = nil,
                  in catalogue: LensCatalogue = LensCatalogueStore.shared)
        -> LensPlan {
        guard lensCorrectionEnabled else { return LensPlan() }
        var plan = LensPlan()
        var stages: [LensCorrection] = []
        if let profile = resolvedLensProfile(for: shot, in: catalogue) {
            let measured = profile.correction(focalLength: shot?.focalLength,
                                              aperture: shot?.aperture)
            stages.append(measured.scaled(by: Float(lensProfileAmount)))
            plan.measurement = .profile(profile)
        } else if let dng, let embedded = DNGOpcodes.read(dng) {
            plan.declined = embedded.declined
            if !embedded.correction.isIdentity {
                stages.append(embedded.correction
                    .scaled(by: Float(lensProfileAmount)))
                plan.measurement = .embedded
            }
        }
        stages.append(lensAdjustment.correction)
        plan.stack = LensCorrectionStack(stages)
        return plan
    }

    /// Just the correction, for callers with nothing to say about where it came from.
    func lensCorrection(for shot: LensShot?, dng: Data? = nil,
                        in catalogue: LensCatalogue = LensCatalogueStore.shared)
        -> LensCorrectionStack {
        lensPlan(for: shot, dng: dng, in: catalogue).stack
    }

    /// The profile in play: the one pinned by hand if there is one, otherwise whatever the metadata
    /// matched.
    func resolvedLensProfile(
        for shot: LensShot?,
        in catalogue: LensCatalogue = LensCatalogueStore.shared
    ) -> LensProfile? {
        if let lensProfileID {
            return catalogue.profiles.first { $0.id == lensProfileID }
        }
        guard let shot else { return nil }
        return catalogue.match(shot)
    }
}
