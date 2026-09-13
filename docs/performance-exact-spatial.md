# Exact spatial preparation and copy/release fusion

The native Metal spatial executor prepares scratch geometry once per edit. Frame
encoding reuses that geometry when leasing scratch textures, avoiding repeated
array allocation and pyramid-size calculations. Changing an edit still prepares
a new geometry; in-flight frames retain their existing resources.

Preparation builds diffusion and halation scales only when those effects are
enabled. It selects the execution graph before baking the exact half-response
table, so a generic fallback avoids an unused 2 MiB texture and a blocking GPU
bake. Supported specialized graphs retain the same table and topology.

For general graphs with local inhibitor release, one Metal dispatch can both
copy optical light into the developer and extract released inhibitor. This saves
one dispatch and one full-frame RGBA16F read whenever a copy was required. The
kernel reads either the original exposure or the optical work texture. Work is
overwritten only after the current pixel's last optical read; no neighboring
pixel is read by this kernel. Already-positioned light, diffused inhibitor, and
optical-only exports retain their existing dispatches.

The fused operation writes both original half-precision intermediates. In
particular, inhibitor release remains a texture consumed by the unchanged
development kernel. This boundary matters: moving release into development or
specializing its arithmetic branches can change fast-math rounding. Grain hashes,
frame seeds, convolution order, curve evaluation, and output encoding retain
their existing implementations.

## Verification

The copy/release A/B test compares output bit patterns against the separate
copy and release dispatches. It exercises every finite Float16 input pattern in
each of four exposure records for analytic, donor-layer, and sampled-curve
fixtures. Additional cases cover odd image dimensions, partial tiles, optical
work reuse, local and diffused couplers, linear and nonlinear release, screened
adjacency, chromatic fringe, grain and mottle, reversal and monochrome stocks,
disabled effects, print output, repeated seeds, and frame-index wrapping.

These checks establish exact output for the tested inputs and execution
environment. They are not a proof over every possible image or GPU/compiler.
Existing full-frame, CPU/Metal, sampled-curve, and layered-transport regression
limits are unchanged.

Run the exact tests with:

```sh
swift test -c release --filter HandwrittenMetalSpatialExecutorTests
```

The optional benchmark uses a synthetic 1920 × 1080 negative with emulsion MTF,
local couplers, Digital Reference output, and grain disabled. It alternates the
original and fused graphs in AB/BA order, using four warm-up pairs followed by
32 measured pairs, one command buffer in flight. It checks output bits and
reports GPU median and p95; preparation, input decoding, and final delivery are
outside the measured interval. Run it without parallel GPU workloads:

```sh
FOTUFILM_SPATIAL_FUSION_BENCH=1 swift test -c release \
  --filter HandwrittenMetalSpatialExecutorTests/testCopyReleaseFusionPairedPerformance
```

Measured on Apple M4 Pro on 13 September 2026 with a release Swift package build:

| Spatial graph | Dispatches | GPU median | GPU p95 |
| --- | ---: | ---: | ---: |
| Separate copy and release | 4 | 0.871 ms | 0.878 ms |
| Fused copy and release | 3 | 0.743 ms | 0.764 ms |

The measured median fell by 14.6%, with identical output bits. This is a
measurement of the eligible spatial graph on this device, not of complete
camera, export, or other stock workloads.
