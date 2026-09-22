# WebGPU performance and image quality

Production WebGPU uses hardware float32 arithmetic and the same Halide film graph
as native GPU rendering. Software binary32 emulation remains in the explicit math
probes. GPU display kernels use the shared shoulder, colour matrix, transfer and
dither functions, then pack RGBA8 or RGBA16 into 32-bit storage words. Only those
encoded pixels are read back; linear float output remains available for diagnostics.

The WebGPU runtime caches storage buffers under its context lock, with at most
64 entries and 128 MiB retained. Queue ordering protects reuse after submitted
commands; device teardown releases its cache. New allocations retain validation
and out-of-memory checks. Error-scope callbacks are started together before waiting.

The compiler patch also handles `pow(0, exponent)` explicitly. WGSL's built-in
requires a positive base; the old translation produced incorrect donor-layer
shadows with fractional release exponents. See the [WGSL specification](https://www.w3.org/TR/WGSL/#pow-builtin).

## Reproduce

Build with `tools/build-halide.sh --webgpu` and `tools/build-webgpu-wasm.sh`.
Existing packs and the CPU reference runtime must match the source configuration.
Start the web development server, then run these commands sequentially on an
otherwise idle Mac:

```sh
node tools/benchmark-webgpu.mjs http://127.0.0.1:5173/ build/webgpu-performance.json
bash tools/benchmark-native-metal.sh build/webgpu-performance.json.pack
node tools/test-webgpu-quality.mjs \
  'http://127.0.0.1:5173/test/quality.html?stocks=all' build/webgpu-quality.json
```

The browser benchmark emits a frame pack containing its actual post-control
configuration, tables and seed. The native benchmark reads that fixture and uses
the same synthetic scene-linear source. Native table mode is enabled for the
non-exact run; both native modes preserve float input/output. Keep fixtures,
reports, runtime binaries and compiler output in ignored build directories.

Report the median of warm frames separately from frame zero. Browser `wall` includes
source copying, film rendering, display encoding, readback and tile assembly.
Its `kernel` includes the GPU display pass and readback. Native timing returns
linear float pixels and excludes display encoding. This is a comparison of the
rendering paths, not an equal-output microbenchmark or a universal device guarantee.

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
