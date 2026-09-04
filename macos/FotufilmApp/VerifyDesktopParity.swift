import AppKit
import CoreGraphics

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Runs in-app desktop parity checks for rendering, inspector controls, and export options.
/// Usage: `Fotufilm --demo --verify-parity`. Checks inspect rendered output, not only state changes.
enum VerifyDesktopParity {
    @discardableResult
    @MainActor static func runIfRequested() -> Bool {
        guard ProcessInfo.processInfo.arguments.contains("--verify-parity")
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
            for check in checks {
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
                : "verify-parity FAIL: \(failures) of \(checks.count)")
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
                 expecting: ["Vertical", "Horizontal", "Straighten"])
        },

        Check(name: "the film panel offers the lab and the mottle") { editor in
            rows(of: .film, model: editor.model,
                 expecting: ["Character", "Grain Mottle", "Lab", "Push / Pull",
                             "Bleach Bypass", "Expired"])
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
                            expecting: ["Disc Grain", "Halo Colour",
                                        "Return Spectrum", "Separation",
                                        "Edge Contrast"])
            if case .fail = film { return film }
            return rows(of: .adjustments, model: model,
                        expecting: ["Regional", "Encoded Grade"])
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

        Check(name: "the lens panel offers filters") { editor in
            rows(of: .lens, model: editor.model,
                 expecting: ["Filters", "Add Filter", "Correct Lens"])
        },

        Check(name: "the film panel drops the emulsion on Normal") { editor in
            let model = editor.model
            model.edit.stockID = StockPreset.noFilmID
            let panel = InspectorViewController(model: model)
            panel.panel = .film
            _ = panel.view
            panel.viewDidLoad()
            let showing = words(in: panel.view)
            guard !shows(showing, "Character"), !shows(showing, "Lab") else {
                return .fail("the film's own controls were still offered")
            }
            guard shows(showing, "Output") else {
                return .fail("the output section went with them")
            }
            // And the gauge row must stop naming a film that is not loaded.
            guard !showing.contains(where: { $0.contains("THIS FILM USES") })
            else {
                return .fail("the gauge note still speaks of a loaded film")
            }
            return .pass("Character and Lab gone, Output kept, gauge note true")
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
            // print no longer lines up with it — the phone's takeover has that bug. Reading it
            // off the scene's own plain develop is what makes this check pass.
            model.edit.crop = CGRect(x: 0.08, y: 0.08, width: 0.44, height: 0.44)
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

        Check(name: "the selective panel offers a selection") { editor in
            rows(of: .selective, model: editor.model,
                 expecting: ["Selection", "Select By", "Sample a Point",
                             "Range", "Softness", "Show Mask",
                             "Selection Light"])
        },

        Check(name: "settings reach the film model") { editor in
            let sheet = SettingsSheetController()
            _ = sheet.view
            sheet.viewDidLoad()
            let showing = words(in: sheet.view)
            let wanted = ["New Photos", "Starting Film", "Output",
                          "Negative", "Film Model", "Disc Grain",
                          "Red–Green", "Edge Contrast"]
            let missing = wanted.filter { !shows(showing, $0) }
            guard missing.isEmpty else {
                return .fail("missing \(missing.joined(separator: ", "))")
            }
            return .pass("\(wanted.count) rows found")
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
