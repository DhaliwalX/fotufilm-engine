# Print stocks

A print stock is the physical material developed film is printed onto: a colour paper, a
release print film or a positive paper. This page explains how print stocks are modelled and
how to add one.

## Model

| Type | Role |
| --- | --- |
| `PrintPaper` | The output a user chooses. Its raw value is the CLI and preset ID, and hosts persist its case order. It also covers outputs with no print material: Lab Scan, Telecine, Digital Reference and Negative. |
| `PrintStock` | One physical material, described in `PrintStockCatalogue.swift`: name, menu detail, process, three characteristic curves, spectra and, for release print film, its setup aims. |
| `PrintStock.Process` | The material's family. It decides how the print is exposed, viewed and timed, and which films and gauges can use it. |
| `PrintStock.Spectra` | Dye and layer-sensitivity spectra on the engine's 380–780 nm, 5 nm grid, derived from datasheet values by the family's rules. |

`PrintPaper.route` is the only place a case is tied to its material. Everything else reads the
stock or its process instead of switching on the case.

### Processes

| Process | Examples | Rules it implies |
| --- | --- | --- |
| `photoPaper` | Ektacolor Edge, Endura Premier, Crystal Archive | Negative film on still gauges. Reflection viewing under D50, with a visual setup trim solved under that lamp. Print borders. 0.004 mm printing blur. Layer sensitivities normalized per layer. |
| `releasePrintFilm` | Vision 2383, Vision 2393, ETERNA-CP | Negative film on motion-picture gauges. Projected under xenon and timed to gross Status A LAD aims through the additive printer. No borders. 0.003 mm printing blur. Inter-layer sensitivity scale kept. |
| `positivePaper` | Ilfochrome Classic CPS.1K and CLM.1K | Reversal film. Reflection viewing; more exposure gives a lighter print. Borders at maximum density. |

Choose the process that matches how the material is really used. If a new material does not
fit any of them, add a process instead of special-casing one stock.

## Adding a print stock

1. **Digitise the datasheet** into its own data file in `Sources/FotufilmCore`, such as
   `ExamplePaperSpectra.swift`. It holds an enum with the dye density, layer sensitivity and
   characteristic curves on the 380–780 nm grid at 5 nm steps. Document the source publication,
   its date and every approximation in its doc comments. Use only published manufacturer data
   in this repository. Data files written by an extractor are regenerated whole, so never add
   hand-written code to them.
2. **Describe the stock in `PrintStockCatalogue.swift`:**

   ```swift
   /// Maker's product name and publication, measured.
   static let examplePaper = PrintStock(
       name: "Maker Product Name",
       detail: "One sentence on how the print looks.",
       process: .photoPaper,
       curves: [ExamplePaperSpectra.redCurve, ExamplePaperSpectra.greenCurve,
                ExamplePaperSpectra.blueCurve],
       spectra: Spectra(dyeDensity: ExamplePaperSpectra.dyeDensity,
                        neutralAmounts: ExamplePaperSpectra.neutralAmounts,
                        layerSensitivity: ExamplePaperSpectra.layerSensitivity,
                        process: .photoPaper))
   ```

   - Pass `neutralAmounts` when the sheet plots each dye at its own peak. Pass nil when the
     sheet draws the dyes at the amounts that already form a neutral, as cine print sheets do.
   - Release print film also needs `releaseSetup:` with its published LAD aims and the density
     at which its sensitivity was measured.
   - A sheet that publishes one curve repeats it for all three records. If a sheet publishes no
     spectra, borrowing another stock's `spectra` is allowed only when the doc comment says so.
3. **Append a case to `PrintPaper`** after the last existing case. The raw value is the
   stable ID, for example `case examplePaper = "example-paper"`. Never reorder or reuse cases:
   plugin hosts persist the index.
4. **Map it in `PrintPaper.route`:** `case .examplePaper: return .print(.examplePaper)`.
5. **Regenerate the host and web controls:** `swift run fotufilm-controls`. Run
   `swift run fotufilm-controls --check` to confirm they are current.
6. **Optionally** set the stock as `nativePrintMedium` in the film stock JSON it was designed
   for. Update the `--paper` help text in `EditorControlCatalogue` and the user documentation.
   Add the stock to `NegativeScanRecipe.papers(for:)` if the scan editor should offer it.

Menus, strip choices, viewing lamps, printer timing, frame borders and reflection setup trims
follow from the process with no further changes.

## Verification

- `swift test -c release --filter PrintStockCatalogueTests` checks every stock's sheet data
  and its process rules.
- Run `swift test -c release --parallel`. Then render representative negatives on the new
  stock and confirm that CPU and Metal output agree.
