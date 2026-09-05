# Plugin performance measurements

Current target: an uncached 3840 × 2160 frame in under 15 ms on this MacBook.
Current optimization work uses Halide AOT schedules and generated kernels.
The earlier measurements below used a 33.33 ms (30 fps) target.

## Resolve baseline — 2026-09-05

Measured in Resolve Studio 21.0.2.4 on an Apple M4 Pro (20 GPU cores, 24 GB memory).
Engine revision: `334d887919cc6f592ad1103997354f2193517c79`, release build,
Halide 22.0.0, bundled Starter Gold 200. Full stage, Realtime mode, 35 mm still
gauge, default effect strengths, explicit Rec.709 / Gamma 2.4 input/output.

The dedicated Fusion composition connects MediaIn → Fotufilm → MediaOut. Its
source is a ten-second 4K30 ProRes LT synthetic test pattern. Timeline resolution
and playback rate are 3840 × 2160 at 30 fps; render cache is disabled and original
media is selected. Fusion's image cache is purged before measurement.

`benchmark.py` requests three warm-up frames, followed by 60 distinct sequential
frames, and checks that Fotufilm actually evaluated each at full resolution.

| Measurement | Median | p95 |
| --- | ---: | ---: |
| Fotufilm node processing time | 338.92 ms | 366.19 ms |
| Complete scripting request | 431.09 ms | — |

All 60 node evaluations exceed 33.33 ms. These are frame-processing times, not
timeline playback fps. Other applications were open, so repeat measurements on
the same host are required before drawing conclusions about smaller differences.

One warm 24-frame plugin timing batch averaged 363.7 ms: host setup 24.5 ms,
input decode 8.6 ms, engine 226.7 ms, and CPU output conversion 103.9 ms.

The stock source build initially failed to find its bundled Starter directory
inside Resolve. The baseline used an explicit stock-directory environment setting;
the plugin resource discovery fix is measured separately from rendering changes.

Earlier delivery attempts that exported an unchanged source image were rejected:
their Fusion graph had not been activated for the timeline. They are not performance
evidence. Activate and save the composition and verify a processed frame before
using delivery/export measurements.

## Halide AOT row storage — 2026-09-05

The OFX test host loads the updated AOT renderer using Halide's standard runtime.
Full float Realtime variants can compute 256 output rows at a time and reuse
512-row circular intermediate buffers within the frame. The selector checks
spatial support and frame bounds; larger supports and other pipeline variants
retain the general schedule. Resolution, film equations, and float32 storage
remain unchanged.

Measured on the same M4 Pro, with the public Gold 200 stock, Full stage, 35 mm
still format, grain enabled, and DaVinci Intermediate host encoding. Each run
warms the renderer and then renders 24 distinct frame times at 3840 × 2160.
The general and windowed paths are selected in separate processes using
`FOTUFILM_AOT_WINDOWED=0` and the default setting respectively.

| OFX test-host render time | General AOT | Windowed AOT |
| --- | ---: | ---: |
| Median | 85.09 ms | 40.67 ms |
| p95 | 100.05 ms | 42.84 ms |
| Mean | 87.12 ms | 41.78 ms |
| Frames at or above 15 ms | 24 / 24 | 24 / 24 |

The final measured host frames match byte for byte. The regular Realtime and
Reference plugin correctness suites pass. The optional benchmark now records
median, p95, and frames at or over its budget, and restores frame time before
subsequent correctness checks. `FOTUFILM_BENCHMARK_BUDGET_MS` defaults to 15.

**The 15 ms target has not been reached.** These measurements exercise the actual
OFX render callback in the test host; they are not measurements inside Resolve.
A Resolve comparison remains required before claiming an in-host improvement.

To repeat the spatial-support regression check after generating the macOS AOT
kernels, export a public Starter fixture and run:

```sh
swift run -c release fotufilm --dump-wasm-pack build/window-fixture.fswp \
  --stock gold200 --pack-size 3840x2160
tools/verify-aot-windows.sh build/window-fixture.fswp
```

This compares 18 frames covering partial windows, odd dimensions, 4K, changing
input and grain seeds, the maximum supported spatial reach, and fallback cases.
All 18 outputs matched byte for byte in the recorded run.
