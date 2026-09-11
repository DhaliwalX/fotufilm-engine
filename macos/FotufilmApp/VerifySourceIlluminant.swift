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
            typealias CameraLight = AppSettings.CameraFilmBalance
            precondition(CameraLight(storedValue: nil) == .stockNative)
            precondition(CameraLight(storedValue: "invalid") == .stockNative)
            precondition(CameraLight(storedValue: "film") == .film)
            for native: Float in [3200, 5500] {
                var cameraEdit = EditState()
                CameraLight.stockNative.applyCapture(to: &cameraEdit)
                let cameraDecodeKey = FilmRender.SceneKey(state: cameraEdit, longEdge: 1024)
                for light in CameraLight.allCases {
                    precondition(CameraLight(storedValue: light.rawValue) == light)
                    // Overwrite stale acquisition metadata, not just an empty default document.
                    cameraEdit.filmLightKelvin = 4300
                    light.applyCapture(to: &cameraEdit)
                    precondition(cameraEdit.captureIlluminantKelvin == 6504)
                    precondition(cameraEdit.filmLightKelvin == nil)
                    precondition(cameraEdit.options.sceneIlluminantKelvin == light.fixedKelvin)
                    precondition(FilmRender.SceneKey(state: cameraEdit, longEdge: 1024) == cameraDecodeKey)
                    // Source resolution passes through Float mireds; allow its sub-millikelvin round trip.
                    precondition(abs(cameraEdit.options.resolvedSceneIlluminant(referenceKelvin: native).kelvin
                                     - light.resolvedKelvin(reference: native)) < 0.001)
                    let saved = try decoder.decode(EditState.self, from: encoder.encode(cameraEdit))
                    precondition(saved.captureIlluminantKelvin == 6504)
                    precondition(saved.options.sceneIlluminantKelvin == light.fixedKelvin)
                }
            }
            for invalid in [#"{"sourceLightIndex":99}"#,
                            #"{"sourceLightKelvin":999}"#,
                            #"{"sourceLightKelvin":25001}"#] {
                precondition((try? decoder.decode(EditState.self, from: Data(invalid.utf8))) == nil)
            }
            print("source-illuminant: native default, presets, custom, reset, stock switching, persistence, migration, camera capture handoff and decode-cache isolation passed")
            exit(0)
        } catch {
            print("source-illuminant: \(error)")
            exit(1)
        }
    }
}
