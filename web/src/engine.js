// The browser half of the film engine.
//
// The WebAssembly module holds the same Halide kernels the phones run, but none of the physics
// that builds their inputs. Those arrive as a pack exported by `fotufilm --dump-wasm-pack`: the
// packed configuration and the three spectral cubes, already solved. This file loads a pack,
// hands the numbers to the kernel, and converts at the two ends the kernel does not — sRGB in,
// sRGB out, because the kernels work scene-referred throughout.

const PACK_MAGIC = 'FSWP'
const STAGES_MAGIC = 'FSSQ'
const LUT_COUNT = 33 * 33 * 33 * 4

// The two paths into the same Halide schedule. `webgpu` is the fused kernel the phones run,
// dispatched through WGSL compute shaders; `simd` is the same physics compiled for the CPU. Both
// are Emscripten builds living in `public/`, fetched at runtime rather than bundled.
const ENGINES = {
  webgpu: 'fotufilm-webgpu.mjs',
  simd: 'fotufilm.mjs',
}

/// Where the site is served from — '/' in development, a sub-path on the published demo. Every
/// runtime fetch is addressed from here, since none of them go through the bundler.
export const assetUrl = (name) => new URL(import.meta.env.BASE_URL + name, window.location.href).href

const modulePromises = new Map()

function loadModule(kind) {
  if (!modulePromises.has(kind)) {
    // The URL is assembled at runtime so the bundler treats it as an opaque fetch rather than a
    // module to resolve: files in public/ are copied verbatim and are not part of the graph.
    const url = assetUrl(ENGINES[kind])
    modulePromises.set(kind, import(/* @vite-ignore */ url).then((m) => m.default()))
  }
  return modulePromises.get(kind)
}

/// Parses the little-endian pack written by the CLI. The layout is fixed by
/// `--dump-wasm-pack` in Sources/fotufilm/main.swift; the two must be changed together.
export async function loadPack(url) {
  const response = await fetch(url)
  if (!response.ok) throw new Error(`no pack at ${url} (${response.status})`)
  const bytes = await response.arrayBuffer()
  const view = new DataView(bytes)

  const magic = String.fromCharCode(...new Uint8Array(bytes, 0, 4))
  if (magic !== PACK_MAGIC) throw new Error(`not a film pack: ${magic}`)
  const version = view.getUint32(4, true)
  if (version !== 1) throw new Error(`unsupported pack version ${version}`)

  const width = view.getInt32(8, true)
  const height = view.getInt32(12, true)
  const featureMask = view.getInt32(16, true)
  const seed = view.getUint32(20, true)
  const configCount = view.getInt32(24, true)
  const lutDimension = view.getInt32(28, true)
  const lutCount = view.getInt32(32, true)
  const hasPaper = view.getInt32(36, true) !== 0

  if (lutCount !== LUT_COUNT) throw new Error(`pack LUT is ${lutCount}, expected ${LUT_COUNT}`)

  let offset = 40
  const take = (count) => {
    const values = new Float32Array(bytes.slice(offset, offset + count * 4))
    offset += count * 4
    return values
  }

  return {
    width,
    height,
    featureMask,
    seed,
    lutDimension,
    hasPaper,
    configuration: take(configCount),
    exposure: take(lutCount),
    film: take(lutCount),
    paper: take(lutCount),
  }
}

/// Parses the stage sidecar written by `--dump-wasm-stages`, and returns one pack per pipeline
/// stage — the same shape `loadPack` returns, so a developer cannot tell the difference.
///
/// A stage is stored as what it does *not* share with the finished film: the configuration slots
/// it moves, and an index into a pool of colour cubes for the tables it re-solved. Everything else
/// is handed straight back from `base`, arrays included, so ten stages cost one extra configuration
/// each rather than ten copies of five megabytes.
export async function loadStages(url, base) {
  const response = await fetch(url)
  if (!response.ok) throw new Error(`no stages at ${url} (${response.status})`)
  const bytes = await response.arrayBuffer()
  const view = new DataView(bytes)

  const magic = String.fromCharCode(...new Uint8Array(bytes, 0, 4))
  if (magic !== STAGES_MAGIC) throw new Error(`not a stage sidecar: ${magic}`)
  const version = view.getUint32(4, true)
  if (version !== 1) throw new Error(`unsupported sidecar version ${version}`)

  const width = view.getInt32(8, true)
  const height = view.getInt32(12, true)
  const configCount = view.getInt32(16, true)
  const lutCount = view.getInt32(20, true)
  const stageCount = view.getInt32(24, true)
  const cubeCount = view.getInt32(28, true)

  // A sidecar and a pack from different exports would agree slot for slot on nothing.
  if (width !== base.width || height !== base.height) {
    throw new Error(`sidecar is ${width}×${height}, pack is ${base.width}×${base.height}`)
  }
  if (configCount !== base.configuration.length) {
    throw new Error(`sidecar carries ${configCount} slots, pack carries ${base.configuration.length}`)
  }
  if (lutCount !== LUT_COUNT) throw new Error(`sidecar LUT is ${lutCount}, expected ${LUT_COUNT}`)

  let offset = 32
  // Length-prefixed UTF-8, tail-padded to keep what follows four-byte aligned.
  const takeString = () => {
    const length = view.getInt32(offset, true)
    offset += 4
    const text = new TextDecoder().decode(new Uint8Array(bytes, offset, length))
    offset += length + ((4 - (length % 4)) % 4)
    return text
  }

  const stages = []
  for (let i = 0; i < stageCount; ++i) {
    const id = takeString()
    const label = takeString()
    const featureMask = view.getInt32(offset, true)
    const seed = view.getUint32(offset + 4, true)
    const cubes = [view.getInt32(offset + 8, true), view.getInt32(offset + 12, true),
                   view.getInt32(offset + 16, true)]
    const changedCount = view.getInt32(offset + 20, true)
    offset += 24

    const configuration = base.configuration.slice()
    for (let c = 0; c < changedCount; ++c) {
      configuration[view.getInt32(offset, true)] = view.getFloat32(offset + 4, true)
      offset += 8
    }
    stages.push({ id, label, featureMask, seed, cubes, configuration })
  }

  // The pool sits after the records, since those are variable length and these are not.
  const cubes = []
  for (let i = 0; i < cubeCount; ++i) {
    cubes.push(new Float32Array(bytes.slice(offset, offset + lutCount * 4)))
    offset += lutCount * 4
  }

  return stages.map(({ cubes: indices, ...stage }) => ({
    ...base,
    ...stage,
    featureMask: dispatchMask(base.featureMask, stage.featureMask),
    exposure: indices[0] < 0 ? base.exposure : cubes[indices[0]],
    film: indices[1] < 0 ? base.film : cubes[indices[1]],
    paper: indices[2] < 0 ? base.paper : cubes[indices[2]],
  }))
}

// The two bits the browser engine reads for itself. Everything else in the mask describes which
// stages a kernel was compiled with, which is a build-time question here — see below.
const FRAME_REVERSAL = 1 << 6
const FRAME_MONOCHROME = 1 << 7

/// Combines a finished-film kernel mask with the stage's film-type bits. Browser CPU kernels exist
/// only for finished-stock masks, so individual stages are disabled through configuration rather
/// than by selecting sparse stage masks. The GPU kernel ignores compiled-stage bits.
function dispatchMask(baseMask, stageMask) {
  const own = FRAME_REVERSAL | FRAME_MONOCHROME
  return (baseMask & ~own) | (stageMask & own)
}

// Transfer functions, matching ColorScience.swift so a frame developed here lands where the
// native CLI puts it.
function srgbToLinear(v) {
  return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)
}

function clamp01(v) {
  return Math.min(Math.max(v, 0), 1)
}

function linearToSrgb(v) {
  const c = clamp01(v)
  return c <= 0.0031308 ? c * 12.92 : 1.055 * Math.pow(c, 1 / 2.4) - 0.055
}

// The engine's scene side works in linear Rec.2020 — the CLI loads into
// extendedLinearITUR_2020 — while its print comes out in Display P3, the delivery basis the
// CLI writes tagged displayP3. A canvas hands over and takes back sRGB, so ingest is
// sRGB→2020 and the encode is P3→sRGB. All three spaces are D65, so each change of primaries
// is a plain 3×3 with no chromatic adaptation. Digits match ColorScience.linearSRGBToRec2020.
const SRGB_TO_2020 = [
  0.6274039, 0.3292830, 0.0433131,
  0.0690973, 0.9195404, 0.0113623,
  0.0163914, 0.0880133, 0.8955953,
]
const P3_TO_SRGB = [
  1.2249401, -0.2249404, 0.0000000,
  -0.0420569, 1.0420571, 0.0000000,
  -0.0196376, -0.0786361, 1.0982735,
]

/// The soft clip the CLI applies before encoding, so print highlights roll off instead of
/// clipping flat at display white.
function displayShoulder(x) {
  const knee = 0.9
  if (x <= knee) return x
  const over = x - knee
  const room = 1 - knee
  return knee + (room * over) / (over + room)
}

// The quantiser's own dither, ported from Math.swift: one triangular sample spanning ±1 step, so
// a print's gradients do not band on the way to eight bits. The CLI dithers for the same reason,
// and a print downloaded from here should not be the coarser of the two.
function pcgHash(v) {
  const state = Math.imul(v, 747796405) + 2891336453 >>> 0
  const word = Math.imul((state >>> ((state >>> 28) + 4)) ^ state, 277803737) >>> 0
  return (word >>> 22) ^ word
}

function triangularDither(index, channel, seed) {
  const h1 = pcgHash((index ^ pcgHash(channel + Math.imul(seed, 0x9e3779b9) >>> 0)) >>> 0)
  const h2 = pcgHash(h1)
  return (h1 >>> 8) / 16777216 + (h2 >>> 8) / 16777216 - 1
}

const srgbToLinearTable = new Float32Array(256)
for (let i = 0; i < 256; ++i) srgbToLinearTable[i] = srgbToLinear(i / 255)

/// Scene-referred linear Rec.2020 out of a canvas's sRGB bytes, written into `destination` at
/// `stride` floats per pixel starting at `offsets`. The two paths want the same numbers in
/// different orders — planar for the CPU kernels, interleaved RGBA for the GPU ones.
function decodeInto(destination, source, plane, stride, offsets) {
  const m = SRGB_TO_2020
  const [o0, o1, o2] = offsets
  for (let p = 0, i = 0; p < plane; ++p, i += 4) {
    const r = srgbToLinearTable[source[i]]
    const g = srgbToLinearTable[source[i + 1]]
    const b = srgbToLinearTable[source[i + 2]]
    const at = p * stride
    destination[at + o0] = m[0] * r + m[1] * g + m[2] * b
    destination[at + o1] = m[3] * r + m[4] * g + m[5] * b
    destination[at + o2] = m[6] * r + m[7] * g + m[8] * b
  }
}

/// The print, encoded for a canvas. The shoulder and the clip belong to the print, so they
/// happen in P3 where the CLI does them; only then does the result change primaries.
function encodeFrom(output, plane, seed, stride, offsets) {
  const n = P3_TO_SRGB
  const [o0, o1, o2] = offsets
  const result = new Uint8ClampedArray(plane * 4)
  for (let p = 0, i = 0; p < plane; ++p, i += 4) {
    const at = p * stride
    const r = clamp01(displayShoulder(output[at + o0]))
    const g = clamp01(displayShoulder(output[at + o1]))
    const b = clamp01(displayShoulder(output[at + o2]))
    result[i] = linearToSrgb(n[0] * r + n[1] * g + n[2] * b) * 255 + 0.5 +
      triangularDither(p, 0, seed)
    result[i + 1] = linearToSrgb(n[3] * r + n[4] * g + n[5] * b) * 255 + 0.5 +
      triangularDither(p, 1, seed)
    result[i + 2] = linearToSrgb(n[6] * r + n[7] * g + n[8] * b) * 255 + 0.5 +
      triangularDither(p, 2, seed)
    result[i + 3] = 255
  }
  return result
}

/// A pack exported against a different build of the engine has a configuration of the wrong
/// length, and every slot after the first mismatch means something else. Caught here rather
/// than left to develop a frame that is merely wrong.
function checkConfigurationCount(module, pack) {
  const expected = module.ccall('fotufilm_wasm_configuration_count', 'number', [], [])
  if (pack.configuration.length !== expected) {
    throw new Error(
      `pack carries ${pack.configuration.length} configuration slots, engine wants ${expected}`)
  }
}

/// Rewrites the configuration slots that are a pure function of a control. Anything that
/// re-enters the film model — halation, coupler range — is not adjustable here and needs a
/// pack exported at that setting.
function applyControlsTo(module, pack, configPtr, grainPtr, controls) {
  const { ev = 0, grain = 1, highlights = 0, shadows = 0,
          saturation = 1, vibrance = 0 } = controls
  module.HEAPF32.set(pack.configuration, configPtr / 4)
  module.ccall('fotufilm_wasm_set_exposure', null, ['number', 'number'],
               [configPtr, Math.pow(2, ev)])
  module.ccall('fotufilm_wasm_set_scene', null,
               ['number', 'number', 'number', 'number', 'number'],
               [configPtr, highlights, shadows, saturation, vibrance])
  module.ccall('fotufilm_wasm_set_grain', null, ['number', 'number', 'number'],
               [configPtr, grainPtr, grain])
}

/// The pack's own grain amplitudes, kept aside so the grain slider can rescale them without the
/// browser having to know how they were calibrated. The slot is fixed by FotufilmHalide.h, where
/// later additions are appended so that adding one renumbers nothing.
const GRAIN_OFFSET = 30

function writeBaseGrain(module, pack, ptr) {
  module.HEAPF32.set(pack.configuration.slice(GRAIN_OFFSET, GRAIN_OFFSET + 3), ptr / 4)
}

/// Develops through the fused GPU kernel — the same schedule the phones run — over WGSL compute
/// shaders. Holds the wasm-side buffers for one frame size and pack, so dragging a slider does
/// not re-upload five megabytes of spectral cube on every frame.
class WebgpuDeveloper {
  constructor(module, pack) {
    this.backend = 'webgpu'
    this.module = module
    this.pack = pack
    this.width = pack.width
    this.height = pack.height
    checkConfigurationCount(module, pack)

    const plane = this.width * this.height
    this.plane = plane
    // Interleaved RGBA float at both ends: this kernel's own layout.
    this.inputPtr = module._malloc(plane * 4 * 4)
    this.outputPtr = module._malloc(plane * 4 * 4)

    // The film and paper cubes ride behind the configuration in one buffer. A WebGPU compute
    // stage is promised only eight storage buffers and the combine kernel binds nine as it is;
    // with the cubes on their own it bound eleven, which no adapter here would create.
    this.configPtr = module._malloc((pack.configuration.length + 2 * LUT_COUNT) * 4)
    this.exposurePtr = module._malloc(LUT_COUNT * 4)
    this.grainPtr = module._malloc(3 * 4)
    this.uploaded = {}
    this.usePack(pack)

    // Asynchronous: the kernel suspends through JSPI while the device works.
    this.renderCall = module.cwrap('fotufilm_wasm_render', 'number',
                                   ['number', 'number', 'number', 'number',
                                    'number', 'number', 'number', 'number'],
                                   { async: true })
  }

  /// Develops through a different set of tables from here on — a pipeline stage of the same stock,
  /// which shares the frame size and the slot layout and usually two of the three cubes.
  ///
  /// A cube is compared by identity, not by contents: the loader hands back the base pack's own
  /// array for a table the stage did not re-solve, so an unchanged cube is the same object and
  /// skips a half-megabyte copy into the heap.
  usePack(pack) {
    const { module } = this
    this.pack = pack
    const count = pack.configuration.length
    if (this.uploaded.film !== pack.film) {
      module.HEAPF32.set(pack.film, this.configPtr / 4 + count)
    }
    if (this.uploaded.paper !== pack.paper) {
      module.HEAPF32.set(pack.paper, this.configPtr / 4 + count + LUT_COUNT)
    }
    if (this.uploaded.exposure !== pack.exposure) {
      module.HEAPF32.set(pack.exposure, this.exposurePtr / 4)
    }
    // Re-read for this pack rather than kept from the first: a stage with grain switched off
    // stores zero amplitudes, and rescaling the finished film's would put the grain back.
    writeBaseGrain(module, pack, this.grainPtr)
    this.uploaded = { film: pack.film, paper: pack.paper, exposure: pack.exposure }
  }

  /// Develops a small frame to find out whether this adapter can actually run the kernel.
  ///
  /// Feature detection cannot answer that. `navigator.gpu` only says the API exists; whether the
  /// combine kernel fits inside the adapter's per-stage storage-buffer budget is not known until
  /// a compute pipeline is created, and the runtime aborts the module when it is not. So the
  /// caller confirms the path by walking a few metres of it, and discards the module if it ends.
  async probe() {
    const side = 16
    const inputPtr = this.module._malloc(side * side * 4 * 4)
    const outputPtr = this.module._malloc(side * side * 4 * 4)
    this.module.HEAPF32.fill(0.18, inputPtr / 4, inputPtr / 4 + side * side * 4)
    this.module.HEAPF32.set(this.pack.configuration, this.configPtr / 4)
    const status = await this.renderCall(
      inputPtr, outputPtr, side, side, this.configPtr, this.exposurePtr,
      this.pack.featureMask, this.pack.seed)
    // Only reached when the module is still alive, so freeing is safe; an abort took the whole
    // module with it and the caller throws this instance away.
    this.module._free(inputPtr)
    this.module._free(outputPtr)
    if (status !== 0) throw new Error(`engine returned ${status}`)
  }

  dispose() {
    for (const ptr of [this.inputPtr, this.outputPtr, this.configPtr,
                       this.exposurePtr, this.grainPtr]) {
      this.module._free(ptr)
    }
  }

  /// Develops one frame. `source` is sRGB RGBA8 at the pack's size; the result is the same.
  async develop(source, controls) {
    const { module, plane } = this
    decodeInto(module.HEAPF32.subarray(this.inputPtr / 4, this.inputPtr / 4 + plane * 4),
               source, plane, 4, [0, 1, 2])
    applyControlsTo(module, this.pack, this.configPtr, this.grainPtr, controls)

    const started = performance.now()
    const status = await this.renderCall(
      this.inputPtr, this.outputPtr, this.width, this.height, this.configPtr,
      this.exposurePtr, this.pack.featureMask, this.pack.seed)
    const elapsed = performance.now() - started
    if (status !== 0) throw new Error(`engine returned ${status}`)

    // Read the heap after the call, not before: the module can grow its memory mid-render, which
    // detaches any view taken earlier.
    const output = module.HEAPF32.subarray(this.outputPtr / 4, this.outputPtr / 4 + plane * 4)
    return { pixels: encodeFrom(output, plane, this.pack.seed >>> 0, 4, [0, 1, 2]), elapsed }
  }
}

/// Develops on the CPU, through the same physics compiled to SIMD WebAssembly. This is what a
/// browser without a WebGPU adapter gets, and what the GPU path falls back to.
class SimdDeveloper {
  constructor(module, pack) {
    this.backend = 'simd'
    this.module = module
    this.pack = pack
    this.width = pack.width
    this.height = pack.height
    checkConfigurationCount(module, pack)

    // These kernels work planar — three width*height planes — and carry a density field between
    // the develop and print stages.
    const plane = this.width * this.height
    this.plane = plane
    this.inputPtr = module._malloc(plane * 3 * 4)
    this.outputPtr = module._malloc(plane * 3 * 4)
    this.densityPtr = module._malloc(plane * 3 * 4)
    this.configPtr = module._malloc(pack.configuration.length * 4)
    this.exposurePtr = module._malloc(LUT_COUNT * 4)
    this.filmPtr = module._malloc(LUT_COUNT * 4)
    this.paperPtr = module._malloc(LUT_COUNT * 4)
    this.grainPtr = module._malloc(3 * 4)
    this.uploaded = {}
    this.usePack(pack)

    this.renderCall = module.cwrap('fotufilm_wasm_cpu_render', 'number', [
      'number', 'number', 'number', 'number', 'number', 'number', 'number', 'number',
      'number', 'number', 'number',
    ])
  }

  /// As on the GPU path: swap in a stage's tables, copying only the cubes it actually re-solved.
  usePack(pack) {
    const { module } = this
    this.pack = pack
    for (const [name, ptr] of [['exposure', this.exposurePtr], ['film', this.filmPtr],
                               ['paper', this.paperPtr]]) {
      if (this.uploaded[name] !== pack[name]) module.HEAPF32.set(pack[name], ptr / 4)
    }
    writeBaseGrain(module, pack, this.grainPtr)
    this.uploaded = { film: pack.film, paper: pack.paper, exposure: pack.exposure }
  }

  dispose() {
    for (const ptr of [this.inputPtr, this.outputPtr, this.densityPtr, this.configPtr,
                       this.exposurePtr, this.filmPtr, this.paperPtr, this.grainPtr]) {
      this.module._free(ptr)
    }
  }

  /// Develops one frame. Asynchronous only to match the GPU path — the kernel itself runs on
  /// this thread and holds it for the length of the develop.
  async develop(source, controls) {
    const { module, plane } = this
    decodeInto(module.HEAPF32.subarray(this.inputPtr / 4, this.inputPtr / 4 + plane * 3),
               source, plane, 1, [0, plane, 2 * plane])
    applyControlsTo(module, this.pack, this.configPtr, this.grainPtr, controls)

    const started = performance.now()
    const status = this.renderCall(
      this.inputPtr, this.outputPtr, this.width, this.height, this.configPtr,
      this.exposurePtr, this.filmPtr, this.paperPtr, this.densityPtr,
      this.pack.featureMask, this.pack.seed,
    )
    const elapsed = performance.now() - started
    if (status === -2) throw new Error('no kernel was built for this stock')
    if (status !== 0) throw new Error(`engine returned ${status}`)

    const output = module.HEAPF32.subarray(this.outputPtr / 4, this.outputPtr / 4 + plane * 3)
    return {
      pixels: encodeFrom(output, plane, this.pack.seed >>> 0, 1, [0, plane, 2 * plane]),
      elapsed,
    }
  }
}

/// Builds the fastest developer this browser will actually run: WebGPU when the adapter can
/// create the kernel's pipelines, and the SIMD path otherwise.
export async function createDeveloper(pack) {
  if (navigator.gpu) {
    try {
      const developer = new WebgpuDeveloper(await loadModule('webgpu'), pack)
      await developer.probe()
      return developer
    } catch (error) {
      // An aborted Emscripten module cannot be called again, so the promise goes with it and the
      // next pack loads a fresh one.
      modulePromises.delete('webgpu')
      console.warn('WebGPU engine unavailable, developing on the CPU instead:', error)
    }
  }
  return new SimdDeveloper(await loadModule('simd'), pack)
}
