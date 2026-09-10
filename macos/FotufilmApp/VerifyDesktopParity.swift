import AppKit
import CoreGraphics
import CoreImage
import ImageIO

#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmEditModel)
import FotufilmEditModel
#endif

/// Runs in-app desktop parity checks for rendering, inspector controls, and export options.
/// Usage: `Fotufilm --demo --verify-parity`, or `--verify-selective` for the selection regressions.
/// Checks inspect rendered output, not only state changes.
enum VerifyDesktopParity {
    @discardableResult
    @MainActor static func runIfRequested() -> Bool {
        let selectiveOnly = ProcessInfo.processInfo.arguments.contains("--verify-selective")
        guard selectiveOnly || ProcessInfo.processInfo.arguments.contains("--verify-parity")
        else { return false }
        Task { @MainActor in
            guard let editor = await editor() else {
                print("verify-parity FAIL: no editor window appeared")
                exit(1)
            }
            let model = editor.model
            guard await settle(model) != nil else {
                print("verify-parity FAIL: the sample never developed")
                exit(1)
            }
            var failures = 0
            let requested = selectiveOnly ? checks.filter { $0.name.contains("select") || $0.name.contains("mask") } : checks
            for check in requested {
                model.reset()
                model.setShowsNegative(false)
                _ = await settle(model)
                let result = await check.run(editor)
                switch result {
                case .pass(let note):
                    print("  PASS  \(check.name) — \(note)")
                case .fail(let why):
                    print("  FAIL  \(check.name) — \(why)")
                    failures += 1
                }
            }
            print(failures == 0
                ? "verify-parity PASS"
                : "verify-parity FAIL: \(failures) of \(requested.count)")
            exit(failures == 0 ? 0 : 1)
        }
        return true
    }

    // MARK: - The checks

    enum Outcome {
        case pass(String)
        case fail(String)
    }

    struct Check {
        let name: String
        let run: @MainActor (DesktopEditorViewController) async -> Outcome
    }

    /// Each of these stands for a hole the desktop session had: something the phone could do and
    /// the Mac could not, or something the Mac offered and then silently refused.
    static let checks: [Check] = [
        Check(name: "catalogued edits survive saving") { editor in
            var edit = editor.model.edit
            for control in EditorControlCatalogue.all {
                if let scale = control.kind.scale {
                    edit.setValue(scale.range.upperBound, of: control.field)
                } else if case .toggle(let resting) = control.kind {
                    edit.setFlag(!resting, of: control.field)
                } else if let curve = control.kind.curve {
                    edit.setCurve(curve.handles.map { _ in 0.5 }, of: control.field)
                }
            }
            edit.grainMottleShare = 0.45
            edit.couplerGapReach = [0.5, 1.5]
            edit.printLightKelvin = 2856
            edit.enlarger = .condenser
            do {
                let restored = try JSONDecoder().decode(EditState.self, from: JSONEncoder().encode(edit))
                guard restored == edit else { return .fail("saving changed an edit's values") }
                guard restored.options.grade == edit.grade,
                      restored.options.halationScale == Float(edit.halation),
                      restored.options.couplerGapReachScales == [0.5, 1.5] else {
                    return .fail("restored controls changed their engine units")
                }
                return .pass("all stored controls and composite values round-trip")
            } catch {
                return .fail(String(describing: error))
            }
        },

        Check(name: "film controls refresh when the stock changes") { editor in
            let model = editor.model
            let panels: [InspectorViewController] = [InspectorPanel.film, .adjustments, .development].map {
                let panel = InspectorViewController(model: model)
                panel.panel = $0
                _ = panel.view
                return panel
            }
            for preset in StockPreset.all {
                model.edit.stockID = preset.id
                panels.forEach { $0.refresh() }
                let found = Set(panels.flatMap { words(in: $0.view) })
                let offered = titles(in: .filmGrain, for: model)
                    + titles(in: .filmEmulsion, for: model) + titles(in: .filmLab, for: model)
                let missing = offered.filter { !shows(found, $0) }
                guard missing.isEmpty else {
                    return .fail("\(preset.id): missing \(missing.joined(separator: ", "))")
                }
                if !preset.stock.hasMeasuredDevelopmentResponse, shows(found, "Push") {
                    return .fail("\(preset.id): kept the previous film's Push control")
                }
                if !preset.stock.isMonochrome && !preset.stock.isReversal {
                    guard shows(found, "Half"), shows(found, "Full") else {
                        return .fail("bleach bypass lost its named choices")
                    }
                }
            }
            return .pass("each installed film offers its own controls")
        },

        Check(name: "output controls follow the chosen medium") { editor in
            let model = editor.model
            guard let preset = StockPreset.all.first(where: {
                !$0.stock.isMonochrome && !$0.stock.isReversal
            }) else { return .fail("no colour negative is installed") }
            model.edit.stockID = preset.id
            model.edit.paperFollowsStock = false
            let panel = InspectorViewController(model: model)
            panel.panel = .print
            _ = panel.view
            panel.viewDidLoad()
            for paper in PrintPaper.choices(for: preset.stock) {
                model.edit.paper = paper
                panel.refresh()
                let found = words(in: panel.view)
                guard shows(found, "Enlarger") == Enlarger.illuminates(stock: preset.stock, paper: paper),
                      shows(found, "Channel Contrast Match") == paper.acceptsPrintCorrection,
                      shows(found, "Viewing Illuminant") == paper.acceptsViewingIlluminant else {
                    return .fail("\(paper.id): offered controls the medium ignores or hid active controls")
                }
            }
            return .pass("print, scan and screen controls match the selected medium")
        },

        Check(name: "no film develops") { editor in
            let model = editor.model
            guard let before = await settle(model) else {
                return .fail("no print to start from")
            }
            model.edit.stockID = StockPreset.noFilmID
            guard let after = await settle(model) else {
                return .fail("choosing Normal left no print at all")
            }
            let moved = distance(before, after)
            guard moved > 0.002 else {
                return .fail("the print did not change (Δ \(reading(moved))) — "
                    + "the develop was never submitted")
            }
            return .pass("Δ \(reading(moved)) against the film's print")
        },

        Check(name: "no film exports") { editor in
            let model = editor.model
            model.edit.stockID = StockPreset.noFilmID
            _ = await settle(model)
            let sheet = PhotoExportSheetController(
                sourceSize: model.sourcePixelSize, state: model.edit,
                sensorFrame: model.sensorFrame,
                originalRAWAvailable: model.originalRAWAvailable) { _ in }
            _ = sheet.view
            let labels = words(in: sheet.view)
            guard labels.contains(where: {
                $0.hasPrefix("FULL RESOLUTION")
            }) else {
                return .fail("the export sheet offered no resolutions on Normal")
            }
            return .pass("\(labels.count) labels, resolutions among them")
        },

        Check(name: "a fitted filter reaches the print") { editor in
            let model = editor.model
            guard let before = await settle(model) else {
                return .fail("no print to start from")
            }
            // Three stops of neutral density, metered as though the exposure were fixed: the one
            // combination that is unambiguously visible, because through-the-lens metering would
            // put every stop of it straight back.
            model.edit.lensFilterMetering = .none
            model.edit.lensFilterIDs = ["nd09"]
            guard let after = await settle(model) else {
                return .fail("the filter left no print")
            }
            let dropped = luma(before) - luma(after)
            guard dropped > 0.02 else {
                return .fail("the print did not darken (Δluma \(reading(dropped)))")
            }
            return .pass("darkened by \(reading(dropped)) luma")
        },

        Check(name: "perspective reaches the print") { editor in
            let model = editor.model
            guard let before = await settle(model) else {
                return .fail("no print to start from")
            }
            model.edit.perspectiveV = 8
            guard let after = await settle(model) else {
                return .fail("the keystone left no print")
            }
            let moved = distance(before, after)
            guard moved > 0.002 else {
                return .fail("the print did not change (Δ \(reading(moved)))")
            }
            return .pass("Δ \(reading(moved))")
        },

        Check(name: "the negative can be shown") { editor in
            let model = editor.model
            guard model.canShowNegative else {
                return .fail("the sample's film reports no negative to show")
            }
            guard let print = await settle(model) else {
                return .fail("no print to start from")
            }
            model.setShowsNegative(true)
            guard let negative = await settle(model) else {
                return .fail("showing the negative left no picture")
            }
            let moved = distance(print, negative)
            model.setShowsNegative(false)
            guard moved > 0.05 else {
                return .fail("the picture barely moved (Δ \(reading(moved)))")
            }
            return .pass("Δ \(reading(moved)) from the print")
        },

        Check(name: "auto adjust solves") { editor in
            let model = editor.model
            _ = await settle(model)
            guard model.canAutoAdjust else {
                return .fail("Auto refused a decoded photograph on a loaded film")
            }
            model.toggleAutoAdjust()
            guard model.autoAdjustActive else {
                return .fail("Auto did not engage")
            }
            _ = await settle(model)
            // Disengaging keeps the solved values, which is the phone's rule.
            let solved = (model.edit.exposure, model.edit.highlights,
                          model.edit.shadows)
            model.toggleAutoAdjust()
            guard !model.autoAdjustActive else {
                return .fail("Auto would not let go")
            }
            guard (model.edit.exposure, model.edit.highlights,
                   model.edit.shadows) == solved else {
                return .fail("letting go put the solved values back")
            }
            return .pass(String(format: "EV %+.2f, highlights %+.2f, shadows %+.2f",
                                solved.0, solved.1, solved.2))
        },

        Check(name: "the crop panel offers perspective") { editor in
            rows(of: .crop, model: editor.model,
                 expecting: titles(in: .frameGeometry, for: editor.model))
        },

        Check(name: "the development stage offers chemistry and grain") { editor in
            rows(of: .development, model: editor.model,
                 expecting: ["Grain", "Development"] + titles(in: .filmGrain, for: editor.model)
                     + titles(in: .filmLab, for: editor.model).filter { $0 != "Expired" && $0 != "Long Exposure" })
        },

        Check(name: "the desktop offers the mobile emulsion controls") { editor in
            let model = editor.model
            guard let preset = StockPreset.all.first(where: {
                !$0.stock.isMonochrome && !$0.stock.isReversal
                    && $0.stock.couplerGeometry != nil
            }) else {
                return .fail("no colour-negative film with coupler geometry is installed")
            }
            model.edit.stockID = preset.id
            let film = rows(of: .film, model: model,
                            expecting: ["Film Format", "Expired", "Halo Colour",
                                        "Return Spectrum"])
            if case .fail = film { return film }
            let develop = rows(of: .development, model: model,
                               expecting: ["Disc Grain", "Separation", "Edge Contrast"])
            if case .fail = develop { return develop }
            let expose = rows(of: .adjustments, model: model,
                              expecting: ["Exposure", "Regional", "Grade", "Encoded Grade"])
            if case .fail = expose { return expose }
            return rows(of: .print, model: model,
                        expecting: ["Output Medium", "Export Photo…"])
        },

        Check(name: "disc grain is an edit, not only a setting") { editor in
            let model = editor.model
            guard let silver = StockPreset.all.first(where: {
                $0.stock.grainDensityLaw == .silver
            }) else {
                return .fail("no silver-grain film is installed")
            }
            model.edit.stockID = silver.id
            model.edit.grain = 2
            model.edit.discGrain = false
            let appSetting = AppSettings.storedDiscGrainEnabled

            // A bundled sample is too small to resolve an individual grain at any offered gauge.
            // Ask the same engine invocation at a scale where the two models are distinct instead.
            let frameHeight: Float = 1.2
            let format = FilmFormat(name: "grain parity", frameHeightMM: frameHeight)
            let side = Int(frameHeight * 2 / silver.stock.grainSizeMM)
            var clumpOptions = model.edit.options(sensor: model.sensorFrame)
            clumpOptions.format = format
            let clump = FilmEngineInvocation(
                stock: silver.stock, options: clumpOptions, width: side, height: side)

            model.edit.discGrain = true
            var discOptions = model.edit.options(sensor: model.sensorFrame)
            discOptions.format = format
            let discs = FilmEngineInvocation(
                stock: silver.stock, options: discOptions, width: side, height: side)
            guard clump.featureMask & FilmEngineFeature.discGrain == 0,
                  discs.featureMask & FilmEngineFeature.discGrain != 0 else {
                return .fail("the per-photo choice did not reach the engine instruction")
            }
            guard AppSettings.storedDiscGrainEnabled == appSetting else {
                return .fail("the photo changed the app-wide starting preference")
            }
            return .pass("the photo selected the disc engine variant independently")
        },

        Check(name: "the exposure stage offers lens filters") { editor in
            rows(of: .adjustments, model: editor.model,
                 expecting: ["Filters", "Add Filter", "Lens Correction"])
        },

        Check(name: "the film panel drops the emulsion on Normal") { editor in
            let model = editor.model
            model.edit.stockID = StockPreset.noFilmID
            let panel = InspectorViewController(model: model)
            panel.panel = .film
            _ = panel.view
            panel.viewDidLoad()
            let showing = words(in: panel.view)
            guard !shows(showing, "Halation"), !shows(showing, "Expired") else {
                return .fail("the film's own controls were still offered")
            }
            // And the gauge row must stop naming a film that is not loaded.
            guard !showing.contains(where: { $0.contains("THIS FILM USES") })
            else {
                return .fail("the gauge note still speaks of a loaded film")
            }
            panel.panel = .development
            let development = words(in: panel.view)
            guard !shows(development, "Push"), !shows(development, "Mottle") else {
                return .fail("development controls remained available on Normal")
            }
            let expose = rows(of: .adjustments, model: model,
                              expecting: ["Exposure", "Grade"])
            if case .fail = expose { return expose }
            return rows(of: .print, model: model,
                        expecting: ["Output", "Export Photo…"])
        },

        Check(name: "a selection reaches the print") { editor in
            let model = editor.model
            guard let ground = await settle(model) else {
                return .fail("no print to start from")
            }
            model.isSelectiveMode = true
            defer { model.isSelectiveMode = false }
            // The panel develops the picture the sampler reads from as it opens; a click before
            // that lands is deliberately not spent, so wait for it the way a hand would.
            _ = await settle(model)
            // Somewhere off-centre, so the sample is a colour the chart actually carries rather
            // than whatever happens to sit under the middle.
            model.sampleSelection(atUnit: CGPoint(x: 0.2, y: 0.2))
            guard model.selective.samplePoint != nil else {
                return .fail("the sampler read nothing off the photograph")
            }
            model.selective.range = 0.4
            model.selective.edit.exposure = 2
            guard let composite = await settle(model) else {
                return .fail("the composite left no picture")
            }
            let moved = distance(ground, composite)
            guard moved > 0.002 else {
                return .fail("the selection's develop never reached the print "
                    + "(Δ \(reading(moved)))")
            }
            // And it must be a *selection*, not the whole frame: a mask that selected everything
            // would be indistinguishable from moving the photograph's own exposure.
            var whole = model.edit
            whole.selective = nil
            whole.exposure = 2
            model.isSelectiveMode = false
            model.edit = whole
            guard let everything = await settle(model) else {
                return .fail("the whole-frame comparison left no print")
            }
            let against = distance(composite, everything)
            guard against > 0.002 else {
                return .fail("the selection covered the whole frame")
            }
            return .pass("Δ \(reading(moved)) from the ground, "
                + "Δ \(reading(against)) from the same edit everywhere")
        },

        Check(name: "the mask can be seen") { editor in
            let model = editor.model
            model.isSelectiveMode = true
            defer {
                model.showsSelectionMask = false
                model.isSelectiveMode = false
            }
            _ = await settle(model)
            model.sampleSelection(atUnit: CGPoint(x: 0.2, y: 0.2))
            guard let blended = await settle(model) else {
                return .fail("no composite to start from")
            }
            model.showsSelectionMask = true
            guard let mask = await settle(model) else {
                return .fail("showing the mask left no picture")
            }
            let moved = distance(blended, mask)
            guard moved > 0.02 else {
                return .fail("the mask looked like the blend "
                    + "(Δ \(reading(moved)))")
            }
            return .pass("Δ \(reading(moved)) from the blend")
        },

        Check(name: "the mask lands where the click did") { editor in
            let model = editor.model
            // With the frame cropped, a mask read off the decoded *file* and stretched to the
            // print no longer lines up with it. Reading it
            // off the scene's own plain develop is what makes this check pass.
            // Crop coordinates start at the bottom. Keep both probes in the coloured
            // upper half of the demo chart; its lower gray ramp has identical chroma.
            model.edit.crop = CGRect(x: 0.08, y: 0.52, width: 0.44, height: 0.44)
            _ = await settle(model)
            model.isSelectiveMode = true
            defer {
                model.showsSelectionMask = false
                model.isSelectiveMode = false
            }
            _ = await settle(model)
            let point = CGPoint(x: 0.22, y: 0.22)
            model.sampleSelection(atUnit: point)
            guard model.selective.samplePoint != nil else {
                return .fail("the sampler read nothing off the photograph")
            }
            model.selective.range = 0.12
            model.selective.softness = 0.3
            model.showsSelectionMask = true
            guard let mask = await settle(model) else {
                return .fail("showing the mask left no picture")
            }
            let near = window(mask, at: point)
            let far = window(mask, at: CGPoint(x: 1 - point.x, y: 1 - point.y))
            guard near > far + 0.1 else {
                return .fail("the mask is no brighter where the click landed "
                    + "(\(reading(near)) against \(reading(far)))")
            }
            return .pass("\(reading(near)) under the click, "
                + "\(reading(far)) opposite it")
        },

        Check(name: "selective edits survive leaving, history and reopening") { editor in
            let model = editor.model
            model.isSelectiveMode = true
            _ = await settle(model)
            model.sampleSelection(atUnit: CGPoint(x: 0.2, y: 0.2))
            model.beginContinuousEdit()
            model.selective.range = 0.3
            model.selective.edit.exposure = 2
            model.endContinuousEdit()
            guard let visible = await settle(model), let saved = model.edit.selective else {
                return .fail("the selection never entered saved edit state")
            }
            model.isSelectiveMode = false
            guard let closed = await settle(model), distance(visible, closed) < 0.0001 else {
                return .fail("leaving Selective changed the print")
            }
            model.undo()
            guard model.edit.selective != saved, let undone = await settle(model),
                  distance(visible, undone) > 0.002 else {
                return .fail("undo did not restore the previous selective print")
            }
            model.redo()
            guard model.edit.selective == saved, model.selective == saved,
                  let redone = await settle(model), distance(visible, redone) < 0.0001 else {
                return .fail("redo did not restore selection controls and pixels")
            }
            do {
                let restored = try JSONDecoder().decode(EditState.self,
                    from: JSONEncoder().encode(model.edit))
                guard restored == model.edit, let data = model.photoSource?.data else {
                    return .fail("saved selection did not round-trip")
                }
                guard await model.editSession.persistBeforeClose() else {
                    return .fail("closing could not save the selective edit")
                }
                let reopened = DesktopEditorModel()
                reopened.openPhoto(data: data, name: "Selective regression", rawHint: nil)
                guard let print = await settle(reopened), distance(visible, print) < 0.0001,
                      reopened.edit == restored, reopened.selective == saved else {
                    return .fail("reopened state matches: \(reopened.edit == restored); "
                        + "selection matches: \(reopened.selective == saved); "
                        + "pixel difference: \(reopened.processed.flatMap(cgImage).map { reading(distance(visible, $0)) } ?? "no print")")
                }
                model.isSelectiveMode = true
                model.clearSelection()
                model.isSelectiveMode = false
                guard model.edit.selective == nil else { return .fail("Clear kept a saved selection") }
                return .pass("closing, undo, redo, JSON, reopening and Clear preserve the expected state")
            } catch { return .fail(String(describing: error)) }
        },

        Check(name: "selective photo exports retain masks and 16-bit HDR") { editor in
            guard let source = editor.model.photoSource else { return .fail("missing source") }
            return await Task.detached {
                var base = EditState()
                base.stockID = StockPreset.noFilmID
                base.crop = CGRect(x: 0.08, y: 0.1, width: 0.8, height: 0.8)
                base.rotation = 1
                let maskExtent = CGRect(x: 0, y: 0, width: 64, height: 64)
                let black = CIImage(color: .black).cropped(to: maskExtent)
                let white = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 64))
                guard let maskData = SubjectMask.encoded(white.composited(over: black)),
                      let scene = FilmRender.scene(source: source, state: base, longEdge: 384),
                      let ground = FilmRender.develop(scene, state: base, hdr: true, dynamicRange: .hdr),
                      let oldJSON = try? JSONDecoder().decode(EditState.self, from: Data("{}".utf8)),
                      oldJSON.selective == nil else { return .fail("could not prepare export fixture") }
                for kind in [SelectiveState.MaskKind.color, .light, .subject] {
                    var selection = SelectiveState(base: base)
                    selection.kind = kind
                    selection.samplePoint = CGPoint(x: 0.2, y: 0.2)
                    selection.sampleRed = 0.5
                    selection.sampleGreen = 0.25
                    selection.sampleBlue = 0.2
                    selection.range = 0.6
                    selection.edit.exposure = 2
                    selection.subjectMask = kind == .subject ? maskData : nil
                    var state = base
                    state.selective = selection
                    guard let data = try? JSONEncoder().encode(state),
                          let saved = try? JSONDecoder().decode(EditState.self, from: data), saved == state,
                          let preview = FilmRender.develop(scene, state: saved, collectHistogram: true,
                              hdr: true, dynamicRange: .hdr),
                          let exported = FilmRender.render(source: source, state: saved, longEdge: 384,
                              hdr: true, dynamicRange: .hdr),
                          exported.image.bitsPerComponent == 16,
                          exported.hdrImage?.bitsPerComponent == 16,
                          distance(preview.image.image, exported.image) < 0.0001,
                          distance(ground.image.image, exported.image) > 0.002,
                          preview.histogram?.count == 3, preview.hdrHistogram?.count == 3 else {
                        return .fail("\(kind.rawValue) lost its mask, precision, histogram or preview/export agreement")
                    }
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("fotufilm-selective-\(UUID().uuidString).tiff")
                    defer { try? FileManager.default.removeItem(at: url) }
                    guard exported.write(to: url, format: .tiff, quality: 1, metadata: .strip),
                          let file = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let image = CGImageSourceCreateImageAtIndex(file, 0, nil),
                          image.bitsPerComponent == 16, distance(image, exported.image) < 0.0001 else {
                        return .fail("\(kind.rawValue) TIFF did not preserve the selective pixels")
                    }
                    if let directory = ProcessInfo.processInfo.environment["FOTUFILM_VERIFY_OUTPUT"] {
                        let folder = URL(fileURLWithPath: directory, isDirectory: true)
                        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        guard ground.image.write(to: folder.appendingPathComponent("selective-ground.png"),
                                  format: .png, quality: 1, metadata: .strip),
                              exported.write(to: folder.appendingPathComponent("selective-\(kind.rawValue).png"),
                                  format: .png, quality: 1, metadata: .strip) else {
                            return .fail("could not write selective render evidence")
                        }
                    }
                    var changed = saved
                    changed.rotation = 2
                    changed.exposure = -1
                    let local = selection.edit.applying(to: changed)
                    guard local.rotation == 2, local.crop == changed.crop,
                          local.exposure == 2, local.selective == nil else {
                        return .fail("local adjustments replaced current frame settings")
                    }
                }
                return .pass("Color, Light and Subject round-trip, match preview/export, and retain 16-bit SDR/HDR")
            }.value
        },

        Check(name: "selective light, color and grade controls reach rendered pixels") { editor in
            guard let source = editor.model.photoSource else { return .fail("missing source") }
            return await Task.detached {
                var base = EditState()
                base.stockID = StockPreset.noFilmID
                guard let scene = FilmRender.scene(source: source, state: base, longEdge: 192),
                      let ground = FilmRender.develop(scene, state: base, dynamicRange: .sdr)?.image.image,
                      let mask = SubjectMask.encoded(CIImage(color: .white)
                          .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))) else {
                    return .fail("could not prepare local control fixture")
                }
                let controls: [(String, (inout SelectiveDevelop) -> Void)] = [
                    ("Exposure", { $0.exposure = 1 }),
                    ("Highlights", { $0.highlights = -1 }),
                    ("Shadows", { $0.shadows = 1 }),
                    ("Temperature", { $0.temperatureMired += 70 }),
                    ("Tint", { $0.tint = 40 }),
                    ("Saturation", { $0.saturation = 0.2 }),
                    ("Vibrance", { $0.vibrance = 1 }),
                    ("Shadows warmth", { $0.grade.shadows.balanceX = 0.6 }),
                    ("Shadows tint", { $0.grade.shadows.balanceY = 0.6 }),
                    ("Shadows level", { $0.grade.shadows.level = 0.5 }),
                    ("Midtones warmth", { $0.grade.midtones.balanceX = 0.6 }),
                    ("Midtones tint", { $0.grade.midtones.balanceY = 0.6 }),
                    ("Midtones level", { $0.grade.midtones.level = 0.5 }),
                    ("Highlights warmth", { $0.grade.highlights.balanceX = 0.6 }),
                    ("Highlights tint", { $0.grade.highlights.balanceY = 0.6 }),
                    ("Highlights level", { $0.grade.highlights.level = 0.5 }),
                ]
                for (name, change) in controls {
                    var selection = SelectiveState(base: base)
                    selection.kind = .subject
                    selection.subjectMask = mask
                    selection.subjectFeather = 0
                    change(&selection.edit)
                    var state = base
                    state.selective = selection
                    guard let data = try? JSONEncoder().encode(state),
                          let saved = try? JSONDecoder().decode(EditState.self, from: data),
                          let local = FilmRender.develop(scene, state: saved, dynamicRange: .sdr)?.image.image,
                          let whole = FilmRender.develop(scene, state: selection.edit.applying(to: base),
                              dynamicRange: .sdr)?.image.image else {
                        return .fail("\(name) could not be restored or rendered")
                    }
                    let agreement = distance(local, whole), change = distance(local, ground)
                    guard agreement < 0.001, change > 0.0005 else {
                        return .fail("\(name): difference from whole-frame edit \(reading(agreement)); "
                            + "change from neutral \(reading(change))")
                    }
                }
                return .pass("all 16 light, color and three-band grade values survive saving and affect the print")
            }.value
        },

        Check(name: "saved subject masks follow frame geometry") { editor in
            guard let source = editor.model.photoSource else { return .fail("missing source") }
            return await Task.detached {
                let black = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
                let white = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 64))
                guard let data = SubjectMask.encoded(white.composited(over: black)),
                      let mask = SubjectMask.decoded(data) else { return .fail("mask did not round-trip") }
                var base = EditState()
                base.stockID = StockPreset.noFilmID
                let context = CIContext(options: [.workingColorSpace: NSNull()])
                for (crop, expected) in [
                    (CGRect(x: 0, y: 0, width: 0.4, height: 1), 1.0),
                    (CGRect(x: 0.6, y: 0, width: 0.4, height: 1), 0.0)
                ] {
                    base.crop = crop
                    guard let scene = FilmRender.scene(source: source, state: base, longEdge: 128),
                          let placed = scene.placeSelectionMask?(mask),
                          let image = context.createCGImage(placed, from: placed.extent,
                              format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!),
                          abs(luma(image) - expected) < 0.02 else {
                        return .fail("saved subject mask stretched across a crop")
                    }
                }
                base.crop = nil
                base.rotation = 1
                guard let scene = FilmRender.scene(source: source, state: base, longEdge: 128),
                      let placed = scene.placeSelectionMask?(mask),
                      let image = context.createCGImage(placed, from: placed.extent,
                          format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!),
                      abs(window(image, at: CGPoint(x: 0.5, y: 0.2))
                        - window(image, at: CGPoint(x: 0.5, y: 0.8))) > 0.9 else {
                    return .fail("rotation did not turn the subject mask with the photo")
                }
                return .pass("saved subject coverage follows left/right crops and quarter-turn rotation")
            }.value
        },

        Check(name: "the selective panel offers a selection") { editor in
            rows(of: .selective, model: editor.model,
                 expecting: ["Selection", "Select By", "Sample a Point",
                             "Range", "Softness", "Show Mask",
                             "Selection Light"])
        },

        Check(name: "settings group the controls in native tabs") { _ in
            let settings = MacSettingsWindowController()
            guard settings.tabs.tabStyle == .toolbar,
                  settings.window?.sheetParent == nil,
                  settings.tabs.tabViewItems.map(\.label) == ["General", "Output", "Film Model"] else {
                return .fail("settings did not create an independent window with three toolbar tabs")
            }
            let expected = [
                ["New Photos", "Starting Film", "Reset All Settings"],
                ["Photos", "Video", "Photo Quality", "Video Quality", "Negative"],
                ["Grain", "Halation", "Color Separation", "Disc Grain", "Red–Green", "Edge Contrast"],
            ]
            for (index, labels) in expected.enumerated() {
                settings.tabs.selectedTabViewItemIndex = index
                guard let controller = settings.tabs.tabViewItems[index].viewController else {
                    return .fail("settings tab \(index) has no controls")
                }
                let showing = words(in: controller.view)
                let missing = labels.filter { !shows(showing, $0) }
                guard missing.isEmpty else {
                    return .fail("missing \(missing.joined(separator: ", "))")
                }
                guard !showing.contains("Done") else {
                    return .fail("settings still use a modal Done button")
                }
            }
            return .pass("General, Output, and Film Model expose all settings without a modal sheet")
        },

        Check(name: "the RGB histogram reads the print") { editor in
            guard let image = editor.model.processed else {
                return .fail("no print to read")
            }
            let bins = SessionHistogramPanelView.count(image)
            guard bins.count == 3, bins.allSatisfy({ $0.count == 64 }) else {
                return .fail("the reading was not three 64-bin channels")
            }
            let totals = bins.map { $0.reduce(0, +) }
            guard totals.allSatisfy({ $0 == 128 * 128 }) else {
                return .fail("the channels did not read the whole reduced frame")
            }
            return .pass("three channels, \(totals[0]) samples each")
        },

        Check(name: "edit history can jump to an earlier state") { editor in
            let model = editor.model
            model.editSession.clearHistory()
            let opened = model.edit
            model.edit.exposure += 0.75
            guard model.history.count == 2, model.historyIndex == 1 else {
                return .fail("the edit was not added to the timeline")
            }
            model.goToHistory(0)
            guard model.edit == opened, model.historyIndex == 0 else {
                return .fail("choosing Opened did not restore the edit")
            }
            guard await settle(model) != nil else {
                return .fail("restoring history left no print")
            }
            return .pass("restored Opened from \(model.history.count) states")
        },
    ]

    /// Builds one inspector tab on its own and reads the names off its rows.
    @MainActor
    private static func titles(in section: EditorControlSection,
                               for model: DesktopEditorModel) -> [String] {
        let stock = model.edit.hasFilm ? model.edit.stock : nil
        return EditorControlCatalogue.controls(in: section, for: stock, on: .desktop)
            .filter { $0.foldsUnder == nil && $0.kind.curve == nil && $0.kind != .takeover }
            .map(\.title)
    }

    @MainActor
    private static func rows(of panel: InspectorPanel,
                             model: DesktopEditorModel,
                             expecting: [String]) -> Outcome {
        let inspector = InspectorViewController(model: model)
        inspector.panel = panel
        _ = inspector.view
        inspector.viewDidLoad()
        let found = words(in: inspector.view)
        let missing = expecting.filter { !shows(found, $0) }
        guard missing.isEmpty else {
            return .fail("missing \(missing.joined(separator: ", "))")
        }
        return .pass(expecting.joined(separator: ", "))
    }

    // MARK: - Reading the session back

    /// The editor, once the window carrying it is up.
    @MainActor
    private static func editor() async -> DesktopEditorViewController? {
        for _ in 1...40 {
            if let found = NSApp.windows.lazy.compactMap({
                $0.contentViewController as? DesktopEditorViewController
            }).first {
                return found
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    /// Waits until rendering is idle with no pending work, then returns the canvas image.
    @MainActor
    private static func settle(_ model: DesktopEditorModel,
                               timeout: TimeInterval = 30) async -> CGImage? {
        let deadline = Date().addingTimeInterval(timeout)
        // Long enough for the change to have been submitted at all: `isProcessing` is false in the
        // instant between the write and the loop picking it up.
        try? await Task.sleep(for: .milliseconds(400))
        while Date() < deadline {
            if !model.isProcessing, let image = model.processed {
                // The settle timer replaces a drag's draft with the real develop; waiting through
                // it means the picture read back is the full-resolution one.
                try? await Task.sleep(for: .milliseconds(250))
                if !model.isProcessing { return cgImage(image) }
                continue
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return model.processed.flatMap(cgImage)
    }

    private static func cgImage(_ image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    // MARK: - Reading a picture

    private static func distance(_ a: CGImage, _ b: CGImage) -> Double {
        let left = samples(a), right = samples(b)
        guard !left.isEmpty, left.count == right.count else { return 0 }
        var total = 0.0
        for (x, y) in zip(left, right) {
            total += abs(x.x - y.x) + abs(x.y - y.y) + abs(x.z - y.z)
        }
        return total / Double(left.count * 3)
    }

    private static func luma(_ image: CGImage) -> Double {
        let taken = samples(image)
        guard !taken.isEmpty else { return 0 }
        let sum = taken.reduce(SIMD3<Double>()) { $0 + $1 }
        let mean = sum / Double(taken.count)
        return 0.2627 * mean.x + 0.6780 * mean.y + 0.0593 * mean.z
    }

    private static func window(_ image: CGImage, at point: CGPoint,
                               radius: Double = 0.06) -> Double {
        guard let data = image.dataProvider?.data as Data?,
              image.width > 0, image.height > 0 else { return 0 }
        let componentBytes = image.bitsPerComponent / 8
        guard componentBytes == 1 || componentBytes == 2 else { return 0 }
        let pixelBytes = image.bitsPerPixel / 8
        let rowBytes = image.bytesPerRow
        let x0 = Int(max(point.x - radius, 0) * Double(image.width - 1))
        let x1 = Int(min(point.x + radius, 1) * Double(image.width - 1))
        let y0 = Int(max(point.y - radius, 0) * Double(image.height - 1))
        let y1 = Int(min(point.y + radius, 1) * Double(image.height - 1))
        guard x1 > x0, y1 > y0 else { return 0 }
        let stepX = max((x1 - x0) / 16, 1)
        let stepY = max((y1 - y0) / 16, 1)
        var total = 0.0
        var taken = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for y in stride(from: y0, through: y1, by: stepY) {
                for x in stride(from: x0, through: x1, by: stepX) {
                    var pixel = SIMD3<Double>()
                    for channel in 0..<3 {
                        let offset = y * rowBytes + x * pixelBytes
                            + channel * componentBytes
                        guard offset + componentBytes <= raw.count else { continue }
                        pixel[channel] = componentBytes == 2
                            ? Double(raw.loadUnaligned(fromByteOffset: offset,
                                                       as: UInt16.self)) / 65535
                            : Double(raw[offset]) / 255
                    }
                    total += 0.2627 * pixel.x + 0.6780 * pixel.y
                        + 0.0593 * pixel.z
                    taken += 1
                }
            }
        }
        return taken > 0 ? total / Double(taken) : 0
    }

    private static let grid = 64

    private static func samples(_ image: CGImage) -> [SIMD3<Double>] {
        guard let data = image.dataProvider?.data as Data?,
              image.width > 0, image.height > 0 else { return [] }
        let componentBytes = image.bitsPerComponent / 8
        let pixelBytes = image.bitsPerPixel / 8
        let rowBytes = image.bytesPerRow
        guard componentBytes == 1 || componentBytes == 2 else { return [] }
        var taken: [SIMD3<Double>] = []
        taken.reserveCapacity(grid * grid)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for gy in 0..<grid {
                let y = (image.height - 1) * gy / max(grid - 1, 1)
                for gx in 0..<grid {
                    let x = (image.width - 1) * gx / max(grid - 1, 1)
                    var pixel = SIMD3<Double>()
                    for channel in 0..<3 {
                        let offset = y * rowBytes + x * pixelBytes
                            + channel * componentBytes
                        guard offset + componentBytes <= raw.count else { continue }
                        pixel[channel] = componentBytes == 2
                            ? Double(raw.loadUnaligned(fromByteOffset: offset,
                                                       as: UInt16.self)) / 65535
                            : Double(raw[offset]) / 255
                    }
                    taken.append(pixel)
                }
            }
        }
        return taken
    }

    private static func reading(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    /// Every word a built panel is showing, so a check can ask whether a row exists without
    /// reaching into the panel's private list of them.
    ///
    /// Upper-cased on the way in, and matched that way. A section's heading is a `CapsLabel`,
    /// which carries its words as an attributed string that has already been upper-cased and
    /// tracked — its `stringValue` is empty, so a walker that reads only that finds every row in
    /// a panel and none of the headings above them. That is not a hypothetical: it is what the
    /// first run of these checks did, and it made a check that asserts a section is *absent* pass
    /// for the wrong reason.
    @MainActor
    private static func words(in view: NSView) -> Set<String> {
        var found: Set<String> = []
        func note(_ text: String) {
            guard !text.isEmpty else { return }
            found.insert(text.uppercased())
        }
        func walk(_ view: NSView) {
            if let field = view as? NSTextField {
                note(field.stringValue)
                note(field.attributedStringValue.string)
            }
            if let button = view as? NSButton {
                note(button.title)
                note(button.attributedTitle.string)
            }
            if let popUp = view as? NSPopUpButton {
                for title in popUp.itemTitles { note(title) }
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(view)
        return found
    }

    private static func shows(_ words: Set<String>, _ text: String) -> Bool {
        words.contains(text.uppercased())
    }
}
