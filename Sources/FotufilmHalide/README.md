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
pass them in the generated functions' existing argument order. Adapter-specific contracts, such
as standalone development ending before the enlarger, remain explicit at the call site.

GPU hosts resolve `GpuConfiguration` once, including diagnostic environment overrides, and each
pipeline retains an immutable copy. AOT generators supply their device and precision defaults
explicitly. A schedule owns its folded-store collection, so independent graph builds do not
share construction state. All resolved compilation options participate in the frame cache key.

For changes here, run `bash tools/test-stages.sh`, relevant release Swift tests, and `swift build`.
Changes to AOT bindings or construction also need generator compilation and
`tools/verify-aot-parity.sh`. The packed configuration and variant manifests remain authoritative;
regenerate their headers with the scripts named in the repository's `AGENTS.md`.
