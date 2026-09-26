# WebGPU performance and image quality

Production WebGPU uses hardware float32 arithmetic and the same Halide film graph
as native GPU rendering. Software binary32 emulation remains in the explicit math
probes. GPU display kernels use the shared shoulder, colour matrix, transfer and
dither functions, then pack RGBA8 or RGBA16 into 32-bit storage words. Only those
encoded pixels are read back; linear float output remains available for diagnostics.

The WebGPU runtime caches storage buffers under its context lock, with at most
64 entries and twice the peak storage in use (at least 128 MiB) retained, so a
repeated frame creates no storage. Queue ordering protects reuse after submitted
commands; device teardown releases its cache. Kernel launches share one command
encoder and compute pass, submitted every four dispatches. One pair of error
scopes covers each batch and is popped at the next read back or sync, so
validation and out-of-memory errors are still reported. Bind groups and uniform
buffers are kept for repeated dispatches. Uploads go through mapped staging
buffers in 4 MB chunks instead of `writeBuffer`, which copied a 23 MB frame
three times slower in Chrome. Read backs map one staging buffer the size of the
copy. The browser aliases a float source in place of copying it into the wasm
heap. The input, configuration and exposure cube keep their device buffers
between frames, and the input is not uploaded again while the source and region
are unchanged.

The compiler patch also handles `pow(0, exponent)` explicitly. WGSL's built-in
requires a positive base; the old translation produced incorrect donor-layer
shadows with fractional release exponents. See the [WGSL specification](https://www.w3.org/TR/WGSL/#pow-builtin).

## Reproduce

Build with `tools/build-halide.sh --webgpu` and `tools/build-webgpu-wasm.sh`.
Existing packs and the CPU reference runtime must match the source configuration.
Start the web development server, then run these commands sequentially on an
otherwise idle Mac:

```sh
node tools/benchmark-webgpu.mjs http://127.0.0.1:5173/test/benchmark.html build/webgpu-performance.json
bash tools/benchmark-native-metal.sh build/webgpu-performance.json.pack
node tools/test-webgpu-quality.mjs \
  'http://127.0.0.1:5173/test/quality.html?stocks=all' build/webgpu-quality.json
```

The browser benchmark emits a frame pack containing its actual post-control
configuration, tables and seed. The native benchmark reads that fixture and uses
the same synthetic scene-linear source. Native table mode is enabled for the
non-exact run; both native modes preserve float input/output. Keep fixtures,
reports, runtime binaries and compiler output in ignored build directories.

Report the median of warm frames separately from frame zero. Each size runs twice:
`repeated` develops the same source again, as editing does, and `fresh` passes new
pixels every frame, as opening an image does. Browser `wall` includes source
upload, film rendering, display encoding, readback and tile assembly.
Its `kernel` includes the GPU display pass and readback. Native timing returns
linear float pixels and excludes display encoding. This is a comparison of the
rendering paths, not an equal-output microbenchmark or a universal device guarantee.

## Startup

Each film pipeline's WGSL holds all its kernels (color_float: 7.5 MB, 132 entry
points). Compiling a pipeline processes the whole module it names, so in Chrome
every kernel cost about 160 ms, however small, and a pipeline's kernels compiled
one at a time on first dispatch. The code generator now marks each kernel's
section. Each kernel compiles from the shared declarations and its own section,
and a frame's missing pipelines compile together: dispatches behind a pending
compile are recorded and encoded in order at the next submit.

Cold starts, fresh Chrome profile, Apple M4 Pro:

| | `main` | This change |
| --- | ---: | ---: |
| First Gold 200 frame, 960 × 540 | 8.75 s | 0.27 s |
| Editor warmup to Ready, first visit | 24.6 s | 1.4 s |
| Editor warmup to Ready, repeat visit | 9.0 s | 0.95 s |

A cold first frame is byte-identical to the warm frames after it.

## Local measurements, 26 September 2026

Chrome on an Apple M4 Pro, grain enabled. Medians of warm frames from two
alternating runs of the benchmark page, served from the `main` checkout and
from this change:

| Stock | Frame | Source | `main` | This change | Speed-up |
| --- | --- | --- | ---: | ---: | ---: |
| Gold 200 | 960 × 540 | repeated | 8.2 ms | 3.7 ms | 2.2× |
| Gold 200 | 1600 × 900 | repeated | 16.2 ms | 7.5 ms | 2.2× |
| Gold 200 | 1920 × 1080 | repeated | 24.7 ms | 11.1 ms | 2.2× |
| Gold 200 | 960 × 540 | fresh | 7.5 ms | 3.7 ms | 2.0× |
| Gold 200 | 1600 × 900 | fresh | 16.4 ms | 9.1 ms | 1.8× |
| Gold 200 | 1920 × 1080 | fresh | 26.2 ms | 13.0 ms | 2.0× |
| Normal | 960 × 540 | repeated | 3.2 ms | 1.1 ms | 2.9× |
| Normal | 1600 × 900 | repeated | 6.8 ms | 2.5 ms | 2.7× |
| Normal | 1920 × 1080 | repeated | 9.2 ms | 3.1 ms | 3.0× |
| Normal | 960 × 540 | fresh | 3.2 ms | 1.5 ms | 2.1× |
| Normal | 1600 × 900 | fresh | 6.8 ms | 3.5 ms | 2.0× |
| Normal | 1920 × 1080 | fresh | 9.1 ms | 4.8 ms | 1.9× |

At 1920 × 1080 a repeated Gold 200 frame spends about 10.5 ms waiting on the GPU
and under 1 ms encoding. A fresh frame adds the upload, about 1.5–1.9 ms for
23–33 MB. The blurs sum their data and weights in one loop, and decimated cells count
their taps analytically. Both give the same values as before.

The full 264-case run across 44 stocks passed: maximum linear error 0.000004411,
maximum 8-bit difference one level, maximum 16-bit difference two levels.

## Local measurements, 22 September 2026

Chrome on an Apple Metal 3 adapter, default Gold 200, grain enabled. Warm medians:

| Frame | Previous browser preview | Updated browser preview |
| --- | ---: | ---: |
| 960 × 540 | 129.6 ms | 10.7 ms |
| 1600 × 900 | 344.2 ms | 23.7 ms |
| 1920 × 1080 | 510.0 ms | 38.5 ms |

Normal at 1600 × 900 improved from 104.1 ms to 7.4 ms. The earlier native Metal
baseline at 1600 × 900 was about 21–28 ms; concurrent native test jobs made a later
repeat variable, so do not use that repeat as a speedup denominator. Cold shader
compilation still takes tens of seconds on some variants. The editor keeps CPU
previews available during warmup.

The full 264-case public/reference profile run passed before and after GPU display
encoding: maximum linear error 0.000004411, maximum 8-bit difference one level,
maximum 16-bit difference two levels. The quality harness checks three exposures,
grain on/off, sRGB and Display P3, and never substitutes CPU rendering for GPU
coverage. Viewport tests also compare full-frame crops with separately rendered
regions at both bit depths.

A further 36-case run covered the remaining six profiles in the complete editor
library and passed the same bounds. Together, these runs cover all 46 editor
films plus three reference examples.
