# Render baseline

Fingerprints of a fixed render matrix, one set per backend, so a change that should not alter
renders can show that it does not. Run it before and after such a change:

```
tools/render-baseline.sh check                 # cpu and metal
tools/render-baseline.sh check aot wasm        # the shipped AOT kernels and the browser engine
tools/render-baseline.sh update cpu metal      # record a change meant to alter renders
```

It is not part of the ordinary test suite: `RenderBaselineTests` skips unless
`tools/render-baseline.sh` runs it. `update` prints every case that moved and by how much; read
that list before committing the new references.

## The matrix

| Backend | What renders | Inputs | Media |
|---|---|---|---|
| `cpu` | The editor's develop (`HostService.prepare`, `framedScene`, `HostEngine.develop`) on the Halide CPU developer | scene, jpeg, heic-hdr, negative | all six |
| `metal` | The same on the Metal developer | scene, jpeg, heic-hdr, negative | all six |
| `aot` | Every shipped Metal AOT variant, through `tools/verify-aot-parity.sh` on its fixture pack | the parity fixture | the fixture's |
| `wasm` | The browser engine through the page's orchestration (`SimdDeveloper`) | scene, jpeg | all six |

The film is Gold 200. The six media are one per print route: Ektacolor Edge paper, Lab Scan,
Telecine, Cineon Log, Digital Reference and the negative itself. Frames develop at 640 x 360 on
the CPU and Metal and at the chart's 960 x 540 in the browser engine. Grain is on, from the
engine's fixed seed.

The inputs are one synthetic chart, entered four ways (`RenderBaselineTests.chart`): a neutral
ramp twelve stops long, twelve colour patches, a saturated hue sweep, specular highlights up to
64x diffuse white on a dark field, and a zone plate.

- `scene`: the chart as scene light, as a camera RAW decodes. The RAW decoder itself is not
  covered.
- `jpeg`: `inputs/chart.jpg`, the chart clipped at display white in sRGB.
- `heic-hdr`: `inputs/chart-hdr.heic`, the chart in Display P3 with a gain map to 8x.
- `negative`: the chart exposed onto a strip of colour negative, with clear rebate and a dense
  holder, read against its film base.

The two files are committed, not encoded at run time, because encoders change between releases.
`RenderBaselineTests.testWriteInputFiles` wrote them.

## Fingerprints and tolerances

`tools/render-baseline.py` reduces each render to the means and standard deviations of about a
thousand contiguous chunks of its floats, plus a run of 256 raw values from the middle. Means
catch a shift in tone or colour anywhere; deviations catch a change in texture, such as grain or
sharpness, that leaves the mean alone; the raw run catches a grain pattern that moved.

A case passes when every value is within the backend's tolerance, an absolute difference in the
backend's own output: linear Display P3 for `cpu` and `metal`, the kernel's own output for `aot`,
16-bit display codes scaled to 0..1 for `wasm`.

| Backend | Tolerance | Drift between two runs on one Mac (M4 Pro, Halide 22) |
|---|---|---|
| `cpu` | 2e-5 | 1.2e-6 |
| `metal` | 1e-4 | 0 |
| `aot` | 1e-4 | 0 |
| `wasm` | 2e-5 | 0 |

The tolerances leave room for another chip, driver or OS. They have not yet been measured on a
second machine; if one disagrees by more, widen that backend's tolerance with
`update --tolerance` and record the machine here.

What the check catches, measured on `cpu` by changing the engine and running `check`:

- Scene exposure raised by 0.0015 EV (0.1%): 22 of 24 cases fail, by 1.3e-4 to 1.2e-3. The
  scanned negative on Lab Scan and Cineon Log does not take the edit's exposure, so it passes.
- The grain seed moved by one: every photograph's 18 cases fail on the raw run, by 0.015 to
  0.038. Scanned negatives have no simulated grain, so their 6 cases pass.

## Toolchain

The CPU and Metal kernels are compiled at run time by the Halide the build links, and a different
Halide makes different floats. `tools/render-baseline.sh` pins the toolchain the AOT kernels use
(`tools/resolve-halide-toolchain.sh`); run `check` with the Halide that recorded the references.
