# Halide engine structure

- `Stages/` defines shared image-formation expressions without schedules.
- `Graph/Frame.h` assembles development and printing through a backend interface.
- `Schedule/Cpu.h` and `Schedule/Gpu.h` place and store the graph's intermediate values.
- `Pipeline/Cpu.h` and `Pipeline/Gpu.h` expose pipeline builders to both JIT hosts and AOT
  generators. `Pipeline/GpuBackend.h` applies GPU placement and precision policy to the graph.
- The top-level `.cpp` files implement runtime entry points, buffer ownership, and pipeline caches.
  Generators include the pipeline headers directly rather than including runtime `.cpp` files.

`FotufilmResolvedFrameParams.h` resolves packed configuration values into host scalars without
requiring the Halide compiler. JIT hosts bind those values through `FrameParams`; AOT adapters
pass them in the generated functions' argument order. Adapter-specific contracts, such
as standalone development ending before the enlarger, remain explicit at the call site.

GPU hosts resolve `GpuConfiguration` once, including diagnostic environment overrides, and each
pipeline retains an immutable copy. AOT generators supply their device and precision defaults
explicitly. A schedule owns its folded-store collection, so independent graph builds do not
share construction state. All resolved compilation options participate in the frame cache key.

For changes here, run `bash tools/test-stages.sh`, relevant release Swift tests, and `swift build`.
Changes to AOT bindings or construction also need generator compilation and
`tools/verify-aot-parity.sh`. The packed configuration and variant manifests remain authoritative;
regenerate their headers with the scripts named in the repository's `AGENTS.md`.

Regenerate CPU WebAssembly kernels together with their adapter after changing the extended
argument list. The unused legacy mottle-sigma argument has been removed; current grain fields
read their per-layer sigmas from the packed configuration. Public C entry points and the packed
configuration layout are unchanged.

The Android CPU generator includes lens diffusion, grain mottling and enlarger MTF.
Regenerate its kernels and adapter together: these stages use the extended develop arguments.
`bash tools/verify-android-aot.sh` builds that same generator and adapter for the host and compares
64 cases against CPU JIT, including each stage, all four print variants, standalone negatives,
tile origins, additional RGB/donor record exposure, closed gates and invalid fields. It uses only the public example stock and needs no Android device or emulator.
This checks shared pipeline construction and bindings; it does not measure Android runtime or performance.

`FilmRecordExposure` supplies an optional interleaved four-record exposure field to combined
Legacy CPU processing. The Swift writer receives absolute tile coordinates and a zeroed buffer;
the field joins the scene after lens diffusion and the camera gate, before film optics. Lens-glare
measurement remains based on lens light alone. The extra 16 bytes per tile pixel count toward the
CPU intermediate-memory estimate. The generic input carries no host-specific exposure model.

Regenerate Android kernels with their adapter after this argument change. Ordinary calls bind a
single disabled zero pixel. Other AOT generators keep their existing argument list; unsupported
additional-exposure calls return an error. Layered Transport and separate pipeline stages do not
accept this input through `processChecked`.


`fotufilm_halide_process_region` develops an apron-bearing input tile into compact
output planes containing only its interior. The virtual frame bounds, tile origin,
configuration, seed and photographic exposure field have the same meaning as
`fotufilm_halide_process_tile_with_exposure`; only destination storage differs.
Callers provide whole-frame tone/glare measurements and enough spatial apron. The
CPU JIT and Android CPU adapters support combined film development with linear
output through this entry point; separate stages, no-film and encoded output are
rejected explicitly. Other adapters
return an error. It does not implement source decoding or an application viewport.
The existing frame-output tile API still serves full-frame strip/tile assembly.

Compact-output verification includes guard values around every output plane,
nonzero tile/interior origins, optional RGB/donor exposure, invalid rectangles,
and comparison with whole-frame development under global metering and seeded grain.
The Android parity harness exercises compact output in all four print variants.
