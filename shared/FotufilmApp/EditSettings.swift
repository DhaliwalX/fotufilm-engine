import Foundation
#if canImport(FotufilmEditModel)
import FotufilmEditModel
#endif

/// Part of an edit, carried to another photograph by Copy Settings or kept as a preset: the edit
/// it was taken from, and the inspector sections that travel with it.
struct EditSettings: Equatable {
    var sections: Set<EditorControlSection>
    var edit: EditState
}

extension EditSettings: Codable {
    private enum CodingKeys: String, CodingKey { case sections, edit }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A section a later version added is skipped rather than refusing the whole preset.
        sections = Set(try c.decode([String].self, forKey: .sections)
            .compactMap(EditorControlSection.init(rawValue:)))
        edit = try c.decode(EditState.self, forKey: .edit)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(EditorControlSection.transferable.filter(sections.contains).map(\.rawValue),
                     forKey: .sections)
        try c.encode(edit, forKey: .edit)
    }
}

extension EditState {
    /// The section each stored key travels in. Nil keys are the photograph's own and never
    /// travel: the grain pattern, and what the camera recorded about the capture.
    static let keySections: [String: EditorControlSection?] = {
        var sections = [String: EditorControlSection?]()
        for (control, key) in cataloguedKeys { sections[key] = control.section }
        for (key, section) in bespokeKeySections { sections[key] = section }
        return sections
    }()

    static let bespokeKeySections: [String: EditorControlSection?] = [
        "stockID": .filmStock, "chosenFormatID": .filmStock,
        "grainModel": .filmGrain, "grainMottleShare": .filmGrain,
        "halationReturnRatio": .filmEmulsion, "couplerGapReach": .filmEmulsion,
        "shutterSeconds": .filmLab,
        "lensFilterIDs": .lensGlass, "lensFilterMetering": .lensGlass,
        "lensProfileID": .lensCorrection, "lensAdjustment": .lensCorrection,
        "sourceLightIndex": .lightBalance,
        "grade": .lightGrade,
        "paper": .printPaper, "paperFollowsStock": .printPaper, "printFrame": .printPaper,
        "negativeViewing": .printPaper, "digitalReference": .printPaper, "printLightKelvin": .printPaper,
        "enlarger": .printLamp, "printerProfile": .printLamp,
        "rotation": .frameGeometry, "crop": .frameGeometry, "cornerCrop": .frameGeometry,
        "selective": .frameLocal,
        "seed": nil, "captureIlluminantKelvin": nil, "filmLightKelvin": nil,
    ]

    /// These sections of this edit, to paste elsewhere.
    func settings(_ sections: Set<EditorControlSection>) -> EditSettings {
        EditSettings(sections: sections, edit: self)
    }

    /// This edit with the sections `settings` carries taken from its edit, key by stored key, so
    /// a section moves exactly what saving and reopening the edit would.
    func pasting(_ settings: EditSettings) throws -> EditState {
        let film = settings.edit.stockID
        // A stale film stays with the edit it was saved in; it is not handed to another photograph.
        if settings.sections.contains(.filmStock), !StockPreset.isNoFilm(film),
           !StockPreset.all.contains(where: { $0.id == film }) {
            throw EditSettingsError.filmNotInstalled
        }
        let encoder = JSONEncoder()
        guard var merged = try JSONSerialization.jsonObject(with: encoder.encode(self)) as? [String: Any],
              let source = try JSONSerialization.jsonObject(
                with: encoder.encode(settings.edit)) as? [String: Any]
        else { return self }
        for case let (key, section?) in Self.keySections where settings.sections.contains(section) {
            merged[key] = source[key]
        }
        var pasted = try JSONDecoder().decode(
            EditState.self, from: JSONSerialization.data(withJSONObject: merged))
        // Only a made selection is stored; one still being made stays with its photograph.
        if !settings.sections.contains(.frameLocal) { pasted.selective = selective }
        return pasted
    }
}

enum EditSettingsError: LocalizedError {
    case filmNotInstalled

    var errorDescription: String? { "The film in these settings is not installed." }
}

/// A named set of settings kept to apply to any photograph.
struct EditPreset: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var settings: EditSettings
}

/// The settings last copied and the presets saved, shared by every editor window.
@MainActor
final class EditSettingsStore {
    static let shared = EditSettingsStore()

    /// Posted when the presets change, for surfaces that list them.
    static let didChange = Notification.Name("EditSettingsStore.didChange")

    /// What Copy Settings took. Kept for this session only, as a clipboard is.
    var copied: EditSettings?

    private struct Stored: Codable {
        var presets: [EditPreset] = []
        var sections: [String]?
    }

    private var stored = Stored()
    private var loaded = false
    private var writer: Task<Void, Never>?

    var presets: [EditPreset] {
        load()
        return stored.presets
    }

    /// The sections the chooser ticked last, or the default ones.
    var chosenSections: Set<EditorControlSection> {
        get {
            load()
            guard let sections = stored.sections else {
                return Set(EditorControlSection.transferable.filter(\.transfersByDefault))
            }
            return Set(sections.compactMap(EditorControlSection.init(rawValue:)))
        }
        set {
            load()
            stored.sections = EditorControlSection.transferable.filter(newValue.contains).map(\.rawValue)
            persist()
        }
    }

    func copy(_ edit: EditState, sections: Set<EditorControlSection>) {
        chosenSections = sections
        copied = edit.settings(sections)
    }

    func savePreset(named name: String, from edit: EditState, sections: Set<EditorControlSection>) {
        load()
        chosenSections = sections
        let preset = EditPreset(name: name, settings: edit.settings(sections))
        // A name already in the list is replaced in place, as saving over a file is.
        if let index = stored.presets.firstIndex(where: { $0.name == name }) {
            stored.presets[index] = preset
        } else {
            stored.presets.append(preset)
        }
        stored.presets.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        changed()
    }

    func deletePreset(_ id: EditPreset.ID) {
        load()
        stored.presets.removeAll { $0.id == id }
        changed()
    }

    private func changed() {
        persist()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: Self.file),
              let decoded = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        stored = decoded
    }

    private func persist() {
        let snapshot = stored
        writer?.cancel()
        writer = Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(
                at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: Self.file, options: .atomic)
        }
    }

    /// Beside the shelf, as the film preferences are.
    private nonisolated static var file: URL {
        EditLibrary.localRoot.deletingLastPathComponent()
            .appendingPathComponent("EditPresets.json")
    }
}
