# CPU / WebGPU parity diagnostics

These probes compare output bits in the same float32 format. They require an actual
WebGPU device and do not count a CPU fallback as GPU coverage. Generated modules,
compiler output and reports belong in ignored build directories.

Build the patched compiler with `tools/build-halide.sh --webgpu`, then build with
the same toolchains used for the engine:

```sh
HALIDE_ROOT=/path/to/reference-halide \
FOTUFILM_WEBGPU_HALIDE=/path/to/webgpu-halide \
EMSDK_ROOT=/path/to/emsdk tools/build-webgpu-parity.sh
cd web
npm run dev
```

Open `/test/parity-math.html?count=1048576&revision=build-name` to compare the compiled
CPU and GPU versions of 14 operations. `revision` is propagated to the module and
its WASM file so a test cannot accidentally combine cached files from two builds.

Add `&software` to run the explicit rounding implementation in
`reference-math.wgsl` directly on WebGPU. The patched Halide compiler embeds this
same source when its target enables `StrictFloat`. Add `&suite=finite` to check the eight arithmetic
operations across finite bit patterns, including subnormals, zero, cancellation,
and overflow. The default suite exercises the transcendental functions on positive
inputs from approximately 0.000244 to 16. `seed` selects a reproducible random seed.

The shader mirrors Halide 22's float32 polynomial math with strict evaluation
order. Both CPU and GPU probes enable `StrictFloat`; an optimizing CPU build can
reassociate the same expressions and produce different bits. The shader does not use the device's `exp`, `log`,
`pow`, division, or square root. The CPU compiler's math differs from platform
libm, so a correctly rounded system `expf` is not an oracle for this comparison.
The generated CPU LLVM assembly is retained beside its archive for inspection.
The polynomial translation includes its upstream Halide license. A toolchain stamp
records the shader and compiler patch hashes; the build rejects a missing or stale
stamp instead of silently using ordinary WGSL arithmetic.

After building the actual engine and packs with `tools/build-wasm.sh`, open
`/test/parity.html?revision=build-name&grain=0` to compare a synthetic linear RGB
scene at every stage, before display transforms. `stocks=all`, `grain=1`,
`width`, `height`, and `exposure` vary the coverage. A successful operation probe
alone does not establish full-frame parity, native CPU parity, or cross-device
coverage.

`fixture` includes the full-frame synthetic input, post-control configuration, and
CPU result as base64 float32 data in the page's native-reference fixture. It also
records the stock, selected mask, seed, dimensions, and exact runtime URLs. This
allows the same inputs to be checked against a native reference build without
involving an image decoder or display conversion.
