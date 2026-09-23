# Vulkan image-quality gate

This harness runs the production Halide graphs on an Android Vulkan device and a
StrictFloat CPU reference **on the same device**. It does not fall back to CPU when
Vulkan fails. Test images are deterministic synthetic charts; fixtures come only
from the public stock index. Results and binaries belong in ignored `build/`.

## Android

Requirements: authorized arm64 Android device with Vulkan, Android NDK, host C++
compiler, Python 3, and a Halide SDK with the Vulkan backend. The diagnostic strict
build also needs `tools/halide-vulkan-strict-float.patch` and
`tools/halide-vulkan-bool-uniforms.patch` applied to Halide. The latter gives scalar
predicates a legal UInt32 uniform ABI instead of emitting forbidden OpTypeBool storage. Also apply
`tools/halide-vulkan-allocation-padding.patch` to preserve configured buffer padding;
otherwise allocator splits can return regions smaller than the requested size and
discard intermediate data. It includes allocator regression tests. The
`tools/build-halide.sh --webgpu` toolchain recipe includes all three patches.

```sh
export HALIDE_ROOT=/path/to/halide-sdk
export ANDROID_NDK_ROOT=/path/to/android-ndk
# On macOS, SDKROOT may select a full Xcode macOS SDK.
swift build -c release --product fotufilm
python3 tools/vulkan-parity/prepare-fixtures.py
tools/vulkan-parity/build-android.sh
tools/vulkan-parity/run-android.py --serial DEVICE_SERIAL --stages
```

Fixtures are generated from this checkout’s public stock definitions with standard
grain and the current configuration ABI. They live under `build/vulkan-parity/fixtures`;
regenerate them after changing the engine. `--fixtures PATH` selects another generated
fixture directory. Do not reuse deployed browser packs from an older engine revision.

Pass `--adb /path/to/adb` if it is outside PATH. Use `--stocks example-negative-400`
for a narrow diagnostic. `--cases stock --sizes 257x193` sweeps only stock presets.
The build also emits `spatial`: push it beside a fixture and run `spatial fixture.pack`
on the device to compare the three halation grids without film curves or delivery encoding.
It applies the linear quality limits by default; append `--exact` for byte equality.
Run `test-uniforms` on the device to check all four combinations of two boolean
uniforms against exact integer results.
`FOTUFILM_VULKAN_TARGET=arm-64-android` tests production
hardware arithmetic; the default adds `strict_float`. StrictFloat/NoContraction
restricts arithmetic contraction but does **not** guarantee CPU-identical Vulkan
transcendentals, division or reduction order. A zero-tolerance test can fail on
one differing output byte. The harness never rounds error counts down or accepts
a hidden mismatch budget. Pass `--exact` to the Android runner (or as the final
argument to `parity`) to make byte equality a requirement.

By default, acceptance uses the existing browser image-quality limits:
maximum linear error 0.0001, linear RMSE 0.00001, at most one RGBA8 code value of
error in no more than 0.1% of channels, and at most four RGBA16 code values of
error. Any nonfinite output, failed dispatch or failed encoding rejects the case.
Byte differences remain in every report as diagnostics. These limits distinguish
small arithmetic differences from incorrect rendering; passing them alone is
not evidence that every application feature works.

Each case compares every RGB float bit, then runs the shared delivery graph on
CPU and Vulkan and compares every RGBA8 and RGBA16 byte. The 8-bit graph includes
seeded dither. The 16-bit graph measures encoding precision, not the TIFF container.
The report includes input/binary hashes, Android build, dimensions, statuses,
nonfinite counts, maximum float error and mismatching byte counts. Device build
identifiers and local logs are diagnostic artifacts, not release attachments.

The stock sweep covers colour negative, monochrome and reversal presets at odd
and non-tile-aligned dimensions. Example stocks add Normal, pointwise, enabled
spatial stages, annular schedule, print from density, offset origins and negative
conversion. `--stages` isolates eleven stage masks. These use the stock's existing
parameters: an enabled mask is not proof that every corresponding control has a
nonzero effect. The offset case checks CPU/GPU agreement at that origin, not
stitched-tile equivalence. No claim of complete application coverage follows from
this matrix alone. Android reports set `completed` only after every selected case
finishes; an interrupted run is not a completed sweep.

Physical and organic grain require fixtures prepared for their respective modes;
changing only the mode number leaves required parameters uninitialized. For example:

```sh
swift run -c release fotufilm --dump-wasm-pack build/vulkan-parity/organic.pack \
  --stock example-negative-400 --grain-model organic --pack-size 65x49
tools/vulkan-parity/run-android.py --serial DEVICE_SERIAL \
  --stocks example-negative-400 --fixture build/vulkan-parity/organic.pack \
  --cases stage-crystal stock --sizes 65x49
```

The CPU reference includes all eight print variants, including paper grain. Rebuild
its AOT archives after updating the adapter; older four-variant archives cannot
link the current adapter. Reports distinguish CPU and Vulkan nonfinite output so
an invalid reference cannot be treated as a Vulkan-only failure.

## Linux runtime smoke test

Cross-compile the same generators for `arm-64-linux` (CPU) and
`arm-64-linux-strict_float` (Vulkan) into `build/vulkan-parity/linux`. Then:

```sh
docker build -t fotufilm-vulkan-test -f tools/vulkan-parity/Dockerfile tools/vulkan-parity
docker run --rm -v "$PWD:/src" fotufilm-vulkan-test bash tools/vulkan-parity/run-linux.sh
```

The current container command targets an arm64 Linux Docker host. Its llvmpipe
Vulkan driver tests Linux runtime/ABI portability, not GPU performance or a desktop
window. Keep Android hardware and Linux software results separate.

## Release requirements still beyond this harness

Do not publish an AppImage as feature-complete or byte-exact from these results.
The selected quality gate must pass, remaining AOT families and auxiliary kernels must be
covered (including the newer Film grain tile model, which is not yet in these AOT
variants), and the Linux desktop host must independently pass import, edit,
viewport, histogram, negative, image export, video colour/playback/export and
resource/lifetime checks. The AppImage also needs extraction/startup checks on its
stated architecture and a license/resource audit. The existing shared-interface
native host uses AppKit/WebKit and cannot be repackaged as a Linux desktop binary.
