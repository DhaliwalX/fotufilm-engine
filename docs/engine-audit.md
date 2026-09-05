# Engine simplification audit

Scope: the engine repository, including portable simulation, Halide and Metal,
imaging, stock matching, editor models, the Mac app, both plugins, build tools,
the browser demo, documentation, and tests. The review used reference searches,
call-site inspection, format checks, builds, and rendering regression tests.

## Changes

| Area | Simplification |
| --- | --- |
| Rendering | Removed the unused native SDR/HDR LUT renderers, experimental hierarchical renderer, their dedicated tests and shader, and an unused capture entry point. |
| Spatial Metal | Removed three unreachable dispatch helpers, their parameter structures, shaders, and pipeline creation. |
| C bridge | Added a Clang module map and imported the actual C declarations, including AOT plugin contexts. Removed manually duplicated Swift function declarations. |
| Stock formats | Removed automatic 41-to-81-sample conversion and range-only coupler decoding. Require the current schema version. Use synthesized dye-family and colour-grade serialization. |
| Print models | Preserved existing paper names and identifiers. Removed film-name matching from the preview strip and the permanently zero lab-scan cast calculation and calibration command. |
| Installation | Shared bundle copying between OFX, FxPlug, and Motion templates. Removed duplicate deletion of the current OFX bundle under its supposed legacy name, including the obsolete preinstall script. Fixed the installation check to verify removal of an actual stale file. |
| Build and tests | Removed unused activation-test switches and the unreachable activation test. Reused Halide discovery and removed lookup of a nonexistent fetch script. Shortened obsolete build commentary. |
| Asset audit | Corrected 21 stale hashes after verifying the files were byte-identical to the existing merged source. Asset contents and golden images were unchanged. |

## Interfaces and formats

- `PrintPaper` retains its original Swift cases, CLI/JSON IDs, and display names.
  Each paper keeps its existing numerical model and saved selections still resolve.
- Still-film strips offer all three photo variants. Motion-picture strips offer
  all three projection variants and Telecine. An applicable declared native
  medium comes first. Reversal film uses Digital Reference.
- Imported sampled spectra must contain 81 samples, and coupler geometry must
  contain two interlayer transmissions. Incomplete colour grades are rejected.
- `FilmDyeFamily` now has string raw values matching its existing JSON values.
- The removed renderer APIs and `labScanReferenceSolve` are no longer available.
  Production camera and still processing use the full-frame and delivery renderers.
- Flat Swift builds must include `Sources/FotufilmHalide/include` in their module
  search path. The supplied scripts do so. Packed numerical configuration offsets
  and the C calling conventions remain unchanged.

## Validation

- Baseline: 997 release tests passed before changes.
- After simplification: 980 release tests passed with `swift test -c release --parallel`.
- After the final spatial-helper removal: 85 rendering, configuration, and golden
  image tests passed. All 41 focused format, print-selection, and grade tests passed.
- Debug Swift build and a build with `FOTUFILM_DISABLE_HALIDE=1` passed.
- Release Metal library compilation, Mac app and plugin bridge typechecking,
  OFX C++ syntax checks, and shell syntax checks passed.
- Installer-copy checks covered nested paths, apostrophes, replacement, failed
  source copying, and staging cleanup. The authorization AppleScript compiled.
- Source-boundary and Starter-pack regression checks passed. Changed public-page
  links resolve locally.

The packaged plugin harness was not completed: its AOT build requires generating
189 kernel variants. A JIT-linked substitute cannot exercise the plugin's AOT
execution contexts. Distribution signing, notarization, real-host UI behavior,
Linux, mobile, and browser runtime execution were not verified in this audit.

## Retained complexity

The CPU reference and production GPU paths have independent numerical tests and
serve different execution environments. Platform fallbacks support builds without
Halide, unavailable GPU resources, host-specific colour metadata, and supported OS
versions. Pack validation, resource lifetime checks, bounded caches, and request
ordering protect real inputs and asynchronous rendering. These remain part of the
implementation; reducing their line count alone would not simplify the supported
behavior.
