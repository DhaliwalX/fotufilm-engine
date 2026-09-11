import Foundation

/// Exercises the actual app edit state, persistence and decoded-scene cache boundary.
enum VerifySourceIlluminant {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--verify-source-illuminant") else { return }
        do {
            var edit = EditState()
            edit.captureIlluminantKelvin = 4960
            edit.filmLightKelvin = 4960 // acquisition metadata from a camera client
            precondition(edit.sourceLightIndex == 0)
            precondition(edit.options.sceneIlluminantKelvin == nil)
            precondition(edit.options.sceneIlluminantChromaticity == nil)
            let decodedKey = FilmRender.SceneKey(state: edit, longEdge: 1024)
            let encoder = JSONEncoder(), decoder = JSONDecoder()
            let savedNative = try decoder.decode(EditState.self, from: encoder.encode(edit))
            precondition(savedNative.sourceLightIndex == 0)
            precondition(savedNative.options.sceneIlluminantKelvin == nil)

            for (selection, kelvin) in [(1, 6504.0), (2, 5500), (3, 3200), (4, 2856), (5, 4960)] {
                edit.sourceLightIndex = selection
                edit.sourceLightKelvin = 4960
                precondition(edit.options.sceneIlluminantKelvin == Float(kelvin))
                precondition(edit.captureIlluminantKelvin == 4960)
                precondition(FilmRender.SceneKey(state: edit, longEdge: 1024) == decodedKey)
                let restored = try decoder.decode(EditState.self, from: encoder.encode(edit))
                precondition(restored.sourceLightIndex == selection)
                precondition(restored.sourceLightKelvin == 4960)
                precondition(restored.options.sceneIlluminantKelvin == Float(kelvin))
            }
            edit.sourceLightIndex = 0
            for id in ["vision500t", "vision250d"] {
                edit.stockID = id
                guard let stock = edit.stock else { preconditionFailure("missing fixture stock") }
                precondition(edit.options.resolvedSceneIlluminant(
                    referenceKelvin: stock.referenceIlluminantKelvin).kelvin
                    == stock.referenceIlluminantKelvin)
            }
            let legacy = try decoder.decode(EditState.self,
                from: Data(#"{"filmLightKelvin":3200}"#.utf8))
            precondition(legacy.sourceLightIndex == 5)
            precondition(legacy.options.sceneIlluminantKelvin == 3200)
            precondition(legacy.captureIlluminantKelvin == 3200)
            var legacyWithCapture = try decoder.decode(EditState.self,
                from: Data(#"{"filmLightKelvin":3200,"captureIlluminantKelvin":4960}"#.utf8))
            precondition(legacyWithCapture.captureIlluminantKelvin == 3200)
            legacyWithCapture.sourceLightIndex = 0
            let resetLegacy = try decoder.decode(EditState.self, from: encoder.encode(legacyWithCapture))
            precondition(resetLegacy.options.sceneIlluminantKelvin == nil)
            precondition(resetLegacy.captureIlluminantKelvin == 3200)
            let oldDefault = try decoder.decode(EditState.self, from: Data("{}".utf8))
            precondition(oldDefault.options.sceneIlluminantKelvin == nil)
            for invalid in [#"{"sourceLightIndex":99}"#,
                            #"{"sourceLightKelvin":999}"#,
                            #"{"sourceLightKelvin":25001}"#] {
                precondition((try? decoder.decode(EditState.self, from: Data(invalid.utf8))) == nil)
            }
            print("source-illuminant: native default, presets, custom, reset, stock switching, persistence, migration and decode-cache isolation passed")
            exit(0)
        } catch {
            print("source-illuminant: \(error)")
            exit(1)
        }
    }
}
