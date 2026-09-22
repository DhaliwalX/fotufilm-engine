import { encodeTileInto, copyEncodedTile } from './output-encoding.js'
export { encodeTileInto } from './output-encoding.js'
import {
  sourceContext,
  sourcePixels,
  decodeCanvasPixels,
  validateColorSpace,
} from './canvas-color.js'
import { loadMediumBytes } from './output-media.js'
import { yieldToBrowser } from './yield.js'
import { measureTone, toneKey } from './tone-base.js'
import { applyScreenLevels } from './screen-conversion.js'
import { CONFIG } from './engine-constants.js'
import {
  runtimeAssetUrl,
  createRuntimeLoader,
  supportsWebgpuRuntime,
} from './runtime-assets.js'
import {
  packedGrade,
  whiteBalanceGains,
  applyColorControls,
} from './color-controls.js'

import { CONTROLS } from './generated/controls.js'
// The browser half of the film engine.
//
// The WebAssembly module holds the same Halide kernels the phones run, but none of the physics
// that builds their inputs. Those arrive as a pack exported by `fotufilm --dump-wasm-pack`: the
// packed configuration and the three spectral cubes, already solved. This file loads a pack,
// hands the numbers to the kernel, and converts source colors to linear Rec.2020 and
// developed Display P3 to the selected delivery space.

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
export const assetUrl = (name) =>
  runtimeAssetUrl(
    name,
    import.meta.env.BASE_URL,
    globalThis.location.href,
    typeof __FOTUFILM_RUNTIME_REVISION__ === 'string'
      ? __FOTUFILM_RUNTIME_REVISION__
      : '',
  )

const runtime = createRuntimeLoader((kind) => assetUrl(ENGINES[kind]))
const toneMeasurements = new WeakMap()
const preparedSources = new WeakSet()
export async function measuredTone(
  source,
  controls,
  balance = whiteBalanceGains(controls.temperature, controls.tint),
) {
  const key = JSON.stringify([controls.ev || 0, ...balance])
  const cached = preparedSources.has(source)
    ? toneMeasurements.get(source)
    : null
  if (cached?.key === key) return cached.grid
  const grid = await measureTone(source, controls, decodeRGBA, balance)
  if (preparedSources.has(source)) toneMeasurements.set(source, { key, grid })
  return grid
}

export async function sceneHighlightStops(source, controls) {
  const grid = await measuredTone(
    source,
    controls,
    whiteBalanceGains(controls.temperature, controls.tint),
  )
  const values = Array.from(grid.regionStops)
    .filter(Number.isFinite)
    .sort((a, b) => a - b)
  if (!values.length) return null
  const p = 0.995 * (values.length - 1),
    i = Math.floor(p)
  return (
    values[i] +
    (p - i) * (values[Math.min(i + 1, values.length - 1)] - values[i])
  )
}

function loadModule(kind) {
  return runtime.load(kind)
}

/// Parses the little-endian pack written by the CLI. The layout is fixed by
/// `--dump-wasm-pack` in Sources/fotufilm/main.swift; the two must be changed together.
///
/// A pack is sealed for one frame size — every spatial slot is millimetres of emulsion times
/// that frame's pixels per millimetre — and since version 2 it also carries a ladder: for each
/// of a range of short edges, the slots that would differ, the feature mask, and the apron a
/// tile needs. `sizeEntryFor` picks the rung for a frame; a version 1 pack has one rung, its own.
export async function loadPack(url) {
  const response = await fetch(url)
  if (!response.ok) throw new Error(`no pack at ${url} (${response.status})`)
  return parsePack(await response.arrayBuffer())
}

export function parsePack(bytes) {
  const view = new DataView(bytes)

  const magic = String.fromCharCode(...new Uint8Array(bytes, 0, 4))
  if (magic !== PACK_MAGIC) throw new Error(`not a film pack: ${magic}`)
  const version = view.getUint32(4, true)
  if (version !== 1 && version !== 2 && version !== 3)
    throw new Error(`unsupported pack version ${version}`)

  const width = view.getInt32(8, true)
  const height = view.getInt32(12, true)
  const featureMask = view.getInt32(16, true)
  const seed = view.getUint32(20, true)
  const configCount = view.getInt32(24, true)
  const lutDimension = view.getInt32(28, true)
  const lutCount = view.getInt32(32, true)
  const hasPaper = view.getInt32(36, true) !== 0

  if (lutCount !== LUT_COUNT)
    throw new Error(`pack LUT is ${lutCount}, expected ${LUT_COUNT}`)

  let offset = 40
  const take = (count) => {
    const values = new Float32Array(bytes.slice(offset, offset + count * 4))
    offset += count * 4
    return values
  }

  const configuration = take(configCount)
  const exposure = take(lutCount)
  const film = take(lutCount)
  const paper = take(lutCount)

  const ladder = []
  if (version >= 2) {
    const rungs = view.getInt32(offset, true)
    offset += 4
    for (let r = 0; r < rungs; ++r) {
      const shortEdge = view.getInt32(offset, true)
      const rungMask = view.getInt32(offset + 4, true)
      const rungSeed = view.getUint32(offset + 8, true)
      const spatialSupport = view.getInt32(offset + 12, true)
      const changed = view.getInt32(offset + 16, true)
      offset += 20
      const slots = new Int32Array(changed)
      const values = new Float32Array(changed)
      for (let c = 0; c < changed; ++c) {
        slots[c] = view.getInt32(offset, true)
        values[c] = view.getFloat32(offset + 4, true)
        offset += 8
      }
      ladder.push({
        shortEdge,
        featureMask: rungMask,
        seed: rungSeed,
        spatialSupport,
        slots,
        values,
      })
    }
  }
  let transport
  if (version === 3) {
    const integer = () => {
      const n = view.getInt32(offset, true)
      offset += 4
      return n
    }
    const headMask = integer(),
      headConfiguration = take(configCount),
      tailConfiguration = take(configCount)
    const count = integer()
    if (count < 1 || count > 11)
      throw new Error('invalid transport component count')
    const readBands = () => {
      const bands = [],
        n = integer()
      if (n < 1 || n > 64) throw new Error('invalid transport band count')
      for (let b = 0; b < n; ++b) {
        const weight = take(1)[0],
          radius = integer(),
          stride = integer()
        if (
          !Number.isFinite(weight) ||
          weight < 0 ||
          radius < 1 ||
          radius > 128 ||
          stride < 1 ||
          stride > 4096 ||
          stride & (stride - 1)
        )
          throw new Error('invalid transport stencil')
        bands.push({
          weight,
          radius,
          stride,
          weights: take((radius * 2 + 1) ** 2),
        })
      }
      return bands
    }
    const delta = (base) => {
      const result = base.slice(),
        count = integer()
      if (count < 0 || count > configCount)
        throw new Error('invalid transport configuration')
      for (let i = 0; i < count; ++i) {
        const slot = integer()
        if (slot < 0 || slot >= configCount)
          throw new Error('invalid transport slot')
        result[slot] = take(1)[0]
      }
      return result
    }
    const components = Array.from({ length: count }, () => ({
      exposure: take(lutCount),
      bands: readBands(),
    }))
    const sizes = [],
      sizeCount = integer()
    if (sizeCount !== ladder.length)
      throw new Error('transport size ladder mismatch')
    for (let i = 0; i < sizeCount; ++i) {
      const shortEdge = integer(),
        headConfigurationAtSize = delta(headConfiguration),
        tailConfigurationAtSize = delta(tailConfiguration)
      sizes.push({
        shortEdge,
        headConfiguration: headConfigurationAtSize,
        tailConfiguration: tailConfigurationAtSize,
        components: components.map((component) => ({
          exposure: component.exposure,
          bands: readBands(),
        })),
      })
    }
    transport = {
      headMask,
      headConfiguration,
      tailConfiguration,
      components,
      sizes,
    }
  }
  if (offset !== bytes.byteLength)
    throw new Error(`pack has ${bytes.byteLength - offset} trailing bytes`)

  return {
    bytes,
    width,
    height,
    featureMask,
    seed,
    lutDimension,
    hasPaper,
    configuration,
    // The slots as the CLI sealed them. A stage replaces `configuration` with its own; the ladder
    // lays its size over whichever slots the stage left alone, and this is how it tells.
    baseConfiguration: configuration,
    transport,
    ladder,
    exposure,
    film,
    paper,
  }
}

/// Parses the stage sidecar written by `--dump-wasm-stages`, and returns one pack per pipeline
/// stage — the same shape `loadPack` returns, so a developer cannot tell the difference.
///
/// A stage is stored as what it does *not* share with the finished film: the configuration slots
/// it moves, and an index into a pool of colour cubes for the tables it re-solved. Everything else
/// is handed straight back from `base`, arrays included, so ten stages cost one extra configuration
/// each rather than ten copies of five megabytes.
export async function loadStages(url, base, mediumUrl = null) {
  const response = await fetch(url)
  if (!response.ok) throw new Error(`no stages at ${url} (${response.status})`)
  let bytes = await response.arrayBuffer()
  if (mediumUrl) bytes = await loadMediumBytes(bytes, mediumUrl)
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
    throw new Error(
      `sidecar is ${width}×${height}, pack is ${base.width}×${base.height}`,
    )
  }
  if (configCount !== base.configuration.length) {
    throw new Error(
      `sidecar carries ${configCount} slots, pack carries ${base.configuration.length}`,
    )
  }
  if (lutCount !== LUT_COUNT)
    throw new Error(`sidecar LUT is ${lutCount}, expected ${LUT_COUNT}`)

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
    const cubes = [
      view.getInt32(offset + 8, true),
      view.getInt32(offset + 12, true),
      view.getInt32(offset + 16, true),
    ]
    const changedCount = view.getInt32(offset + 20, true)
    offset += 24

    const configuration = base.configuration.slice()
    for (let c = 0; c < changedCount; ++c) {
      configuration[view.getInt32(offset, true)] = view.getFloat32(
        offset + 4,
        true,
      )
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
    ownFeatureMask: stage.featureMask,
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

// The engine's scene side works in linear Rec.2020 — the CLI loads into
// extendedLinearITUR_2020 — while its print comes out in Display P3, the delivery basis the
// CLI writes tagged displayP3. Sources carry linear Rec.2020 or legacy sRGB bytes;
// delivery keeps Display P3 or converts to sRGB. All three spaces are D65, so each change
// of primaries is a plain 3×3 with no chromatic adaptation.
const SRGB_TO_2020 = [
  0.6274039, 0.329283, 0.0433131, 0.0690973, 0.9195404, 0.0113623, 0.0163914,
  0.0880133, 0.8955953,
]
const srgbToLinearTable = new Float32Array(256)
for (let i = 0; i < 256; ++i) srgbToLinearTable[i] = srgbToLinear(i / 255)

/// Scene-referred linear Rec.2020 out of a canvas's sRGB bytes, written into `destination` at
/// `stride` floats per pixel starting at `offsets`. The two paths want the same numbers in
/// different orders — planar for the CPU kernels, interleaved RGBA for the GPU ones.
function decodeInto(destination, source, plane, stride, offsets) {
  const [o0, o1, o2] = offsets
  if (source instanceof Float32Array) {
    // RAW and EXR geometry already supply scene-linear Rec.2020; preserve that light directly.
    if (stride === 4 && o0 === 0 && o1 === 1 && o2 === 2) {
      destination.set(source.subarray(0, plane * 4))
      return
    }
    for (let p = 0; p < plane; p++) {
      destination[p * stride + o0] = source[p * 4]
      destination[p * stride + o1] = source[p * 4 + 1]
      destination[p * stride + o2] = source[p * 4 + 2]
    }
    return
  }
  const m = SRGB_TO_2020
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

/// A pack exported against a different build of the engine has a configuration of the wrong
/// length, and every slot after the first mismatch means something else. Caught here rather
/// than left to develop a frame that is merely wrong.
function checkConfigurationCount(module, pack) {
  const expected = module.ccall(
    'fotufilm_wasm_configuration_count',
    'number',
    [],
    [],
  )
  if (expected !== CONFIG.FOTUFILM_FRAME_CONFIGURATION_COUNT) {
    throw new Error(
      'The browser engine is out of date. Rebuild the runtime and film files together.',
    )
  }
  if (pack.configuration.length !== expected) {
    throw new Error(
      `pack carries ${pack.configuration.length} configuration slots, engine wants ${expected}`,
    )
  }
}

/// The pack's own grain amplitudes, kept aside so the grain slider can rescale them without the
/// browser having to know how they were calibrated. The slot is fixed by FotufilmHalide.h, where
/// later additions are appended so that adding one renumbers nothing. Read from the configuration
/// for the frame's size rather than the pack's: the amplitude is set per pixel of emulsion.
const GRAIN_OFFSET = 30

function writeBaseGrain(module, configuration, ptr) {
  module.HEAPF32.set(
    configuration.slice(GRAIN_OFFSET, GRAIN_OFFSET + 3),
    ptr / 4,
  )
}

/// The rung of the pack's size ladder nearest to a frame: the one whose short edge is closest to
/// the frame's, in ratio. Rungs sit 3% apart, so every spatial parameter lands within 1.5% of
/// where a pack sealed for exactly this frame would put it. A pack with no ladder has one rung,
/// its own size, with no apron to speak of — a frame then develops in one piece.
export function sizeEntryFor(pack, width, height) {
  const shortEdge = Math.max(1, Math.min(width, height))
  if (!pack.ladder?.length) {
    return {
      shortEdge: Math.min(pack.width, pack.height),
      featureMask: pack.featureMask,
      seed: pack.seed,
      spatialSupport: null,
      slots: new Int32Array(0),
      values: new Float32Array(0),
    }
  }
  let best = pack.ladder[0]
  let distance = Infinity
  for (const rung of pack.ladder) {
    const d = Math.abs(Math.log(rung.shortEdge / shortEdge))
    if (d < distance) {
      best = rung
      distance = d
    }
  }
  return best
}

/// The configuration a frame of this size develops with: the pack's slots with the rung's laid
/// over them, and the frame's own size where the kernel reads it. A stage pack has moved slots of
/// its own — a radius zeroed to switch halation off — and the rung leaves those alone, or the
/// stage would come back with the size.
export function configurationFor(pack, rung, width, height, frameSizeSlot) {
  const configuration = pack.configuration.slice()
  const base = pack.baseConfiguration ?? pack.configuration
  for (let i = 0; i < rung.slots.length; ++i) {
    const slot = rung.slots[i]
    if (pack.configuration[slot] === base[slot])
      configuration[slot] = rung.values[i]
  }
  configuration[frameSizeSlot] = width
  configuration[frameSizeSlot + 1] = height
  return configuration
}

/// Pixels a kernel run may cover, apron included. The GPU kernel keeps dozens of intermediates
/// of the region's size alive at once, and a browser's adapter is not asked for more than a few
/// gigabytes; the CPU kernel holds the thread for the length of the run.
const TILE_BUDGET = { webgpu: 6_000_000, simd: 2_000_000 }
const MIN_TILE_SIDE = 64

/// Cuts a frame into the tiles it develops as. Each tile is an interior rectangle of finished
/// pixels and the region around it — the interior grown by `apron` on every side, clipped to the
/// frame — that the kernel is actually run over; the apron is what the interior's pixels read
/// from their neighbours, so the interior comes out exactly as it would in one piece. A frame that
/// fits the budget whole is one tile with no apron to cut away.
export function planTiles(width, height, apron, budget) {
  const a = Math.max(0, apron | 0)
  const tiles = []
  if (width * height <= budget) {
    tiles.push({
      x: 0,
      y: 0,
      width,
      height,
      region: { x: 0, y: 0, width, height },
    })
    return tiles
  }
  const side = Math.max(MIN_TILE_SIDE, Math.floor(Math.sqrt(budget)) - 2 * a)
  for (let y = 0; y < height; y += side) {
    for (let x = 0; x < width; x += side) {
      const w = Math.min(side, width - x)
      const h = Math.min(side, height - y)
      const rx = Math.max(0, x - a)
      const ry = Math.max(0, y - a)
      const region = {
        x: rx,
        y: ry,
        width: Math.min(width, x + w + a) - rx,
        height: Math.min(height, y + h + a) - ry,
      }
      tiles.push({ x, y, width: w, height: h, region })
    }
  }
  return tiles
}

// The delivered rectangle has local storage, while physics and dither retain
// full-frame coordinates. Neighboring pixels are read only for spatial support.
export function frameRegion(width, height, region = null) {
  const r = region || { x: 0, y: 0, width, height }
  if (
    ![r.x, r.y, r.width, r.height].every(Number.isSafeInteger) ||
    r.x < 0 ||
    r.y < 0 ||
    r.width < 1 ||
    r.height < 1 ||
    r.x + r.width > width ||
    r.y + r.height > height
  )
    throw new Error('Invalid visible image region.')
  return r
}

export function planRegionTiles(width, height, apron, budget, region) {
  const r = frameRegion(width, height, region)
  const a = Math.max(0, Math.ceil(apron))
  const withSupport = (tile) => {
    const left = Math.max(0, tile.x - a),
      top = Math.max(0, tile.y - a)
    return {
      ...tile,
      region: {
        x: left,
        y: top,
        width: Math.min(width, tile.x + tile.width + a) - left,
        height: Math.min(height, tile.y + tile.height + a) - top,
      },
    }
  }
  const whole = withSupport(r)
  if (whole.region.width * whole.region.height <= budget) return [whole]
  // Unlike a whole-frame tile, a visible rectangle can need an apron on all
  // four sides. Include that support when deciding whether it fits the budget.
  const side = Math.max(MIN_TILE_SIDE, Math.floor(Math.sqrt(budget)) - 2 * a)
  const tiles = []
  for (let y = r.y; y < r.y + r.height; y += side)
    for (let x = r.x; x < r.x + r.width; x += side)
      tiles.push(
        withSupport({
          x,
          y,
          width: Math.min(side, r.x + r.width - x),
          height: Math.min(side, r.y + r.height - y),
        }),
      )
  return tiles
}

/// Rectangle input: Uint8 RGBA is encoded sRGB; Float32 RGBA is linear Rec.2020.
/// Reading by rectangle is what lets a hundred-megapixel frame develop without its float form
/// ever existing whole: only a tile's worth is decoded at once.
export function pixelSource({ data, width, height }) {
  return {
    width,
    height,
    read(x, y, w, h) {
      if (x === 0 && y === 0 && w === width && h === height) return data
      const out = new data.constructor(w * h * 4)
      for (let row = 0; row < h; ++row) {
        const from = ((y + row) * width + x) * 4
        out.set(data.subarray(from, from + w * 4), row * w * 4)
      }
      return out
    },
  }
}

/// The same, over a decoded image — an <img>, an ImageBitmap, a canvas — drawn a rectangle at a
/// time into a scratch canvas no larger than the biggest tile.
export function imageSource(image) {
  const width = image.naturalWidth || image.width
  const height = image.naturalHeight || image.height
  let canvas = null
  let context = null
  return {
    width,
    height,
    read(x, y, w, h) {
      if (!canvas || canvas.width < w || canvas.height < h) {
        canvas =
          typeof OffscreenCanvas !== 'undefined'
            ? new OffscreenCanvas(w, h)
            : Object.assign(document.createElement('canvas'), {
                width: w,
                height: h,
              })
        context = sourceContext(canvas)
      }
      context.clearRect(0, 0, w, h)
      context.drawImage(image, x, y, w, h, 0, 0, w, h)
      const data = sourcePixels(context, 0, 0, w, h)
      return decodeCanvasPixels(data.data, data.colorSpace)
    },
  }
}

/// What the two paths share: a pack, a frame size, and the way a frame is cut into tiles and
/// developed one at a time. A subclass owns the wasm-side buffers in its kernel's own layout and
/// runs the kernel over one region.
class Developer {
  constructor(module, pack, backend) {
    this.backend = backend
    this.module = module
    this.pack = pack
    checkConfigurationCount(module, pack)
    this.frameSizeSlot = module.ccall(
      'fotufilm_wasm_frame_size_slot',
      'number',
      [],
      [],
    )
    this.width = 0
    this.height = 0
    // Region pixels the frame buffers hold; they grow to the largest tile and stay.
    this.capacity = 0
    this.tileBudget = TILE_BUDGET[backend]
    this.grainPtr = module._malloc(3 * 4)
    this.uploaded = {}
  }

  /// The frame every develop from here on is the size of. Picks the rung of the size ladder,
  /// lays out the configuration, cuts the tiles, and grows the buffers to the largest of them.
  setFrame(width, height, region = null) {
    frameRegion(width, height, region)
    if (
      width === this.width &&
      height === this.height &&
      JSON.stringify(region) === JSON.stringify(this.region || null)
    )
      return
    if (!(width > 0 && height > 0))
      throw new Error(`cannot develop a ${width}×${height} frame`)
    this.width = width
    this.height = height
    this.region = region
    this.plan()
  }

  /// Develops through a different set of tables from here on — a pipeline stage of the same stock,
  /// which shares the slot layout and usually two of the three cubes.
  ///
  /// A cube is compared by identity, not by contents: the loader hands back the base pack's own
  /// array for a table the stage did not re-solve, so an unchanged cube is the same object and
  /// skips a half-megabyte copy into the heap.
  usePack(pack) {
    this.pack = pack
    this.uploadTables(pack)
    this.uploaded = {
      film: pack.film,
      paper: pack.paper,
      exposure: pack.exposure,
    }
    if (this.width) this.plan()
  }

  plan() {
    const rung = sizeEntryFor(this.pack, this.width, this.height)
    this.rung = rung
    this.configuration = configurationFor(
      this.pack,
      rung,
      this.width,
      this.height,
      this.frameSizeSlot,
    )
    // Browser CPU kernels exist only for finished-stock masks, so a stage keeps the rung's stage
    // bits and contributes only its film-type bits; see dispatchMask.
    this.featureMask =
      this.pack.ownFeatureMask == null
        ? rung.featureMask
        : dispatchMask(rung.featureMask, this.pack.ownFeatureMask)
    this.seed = this.pack.seed >>> 0
    this.apron = rung.spatialSupport ?? 0
    this.tiles =
      this.pack.transport || rung.spatialSupport == null
        ? planTiles(this.width, this.height, 0, Infinity)
        : planTiles(this.width, this.height, this.apron, this.tileBudget)
    if (this.region) {
      let apron = this.apron
      if (this.pack.transport) {
        const root = this.pack.transport
        const plan =
          root.sizes.find((size) => size.shortEdge === this.rung.shortEdge) ??
          root
        apron += Math.max(
          0,
          ...plan.components.flatMap((c) =>
            c.bands.map((b) => b.radius * b.stride),
          ),
        )
      }
      this.tiles = planRegionTiles(
        this.width,
        this.height,
        apron,
        this.tileBudget,
        this.region,
      )
    }
    let needed = 0
    for (const tile of this.tiles)
      needed = Math.max(needed, tile.region.width * tile.region.height)
    if (needed > this.capacity) {
      this.freeFrame()
      this.allocateFrame(needed)
      this.capacity = needed
    }
    writeBaseGrain(this.module, this.configuration, this.grainPtr)
  }

  applyControls(controls) {
    const { module } = this
    // The editor stores exposure as `ev`; the shared control catalogue calls it `exposure`.
    const values = { ...controls, exposure: controls.ev ?? controls.exposure }
    module.HEAPF32.set(this.configuration, this.configPtr / 4)
    for (const control of CONTROLS) {
      const value = values[control.key] ?? control.def
      if (control.kind === 'grain') {
        module.ccall(
          'fotufilm_wasm_set_grain',
          null,
          ['number', 'number', 'number'],
          [this.configPtr, this.grainPtr, value],
        )
        continue
      }
      const slot = module.ccall(
        'fotufilm_wasm_control_slot',
        'number',
        ['number'],
        [control.index],
      )
      const stored = control.kind === 'exp2' ? Math.pow(2, value) : value
      module.ccall(
        'fotufilm_wasm_set_slot',
        null,
        ['number', 'number', 'number'],
        [this.configPtr, slot, stored],
      )
    }
    const configuration = module.HEAPF32.subarray(
      this.configPtr / 4,
      this.configPtr / 4 + this.configuration.length,
    )
    applyColorControls(configuration, controls)
    configuration[CONFIG.CAMERA_PREFLASH] =
      this.featureMask === 1 << 29 ? 0 : (controls.cameraPreflash ?? 0)
    // Keep coarse and resolved grain at the same strength as the clump field.
    for (const offset of [CONFIG.MOTTLE, CONFIG.GRAIN_DISC]) {
      for (let c = 0; c < 3; c++)
        configuration[offset + c] *= controls.grain ?? 1
    }
    this.seed = ((controls.seed ?? 0) + this.pack.seed) >>> 0
  }

  /// Develops one frame. `source` is a `pixelSource` or `imageSource` at the frame's size; the
  /// Result is RGBA8 or RGBA16 in the delivery color space. `elapsed` sums backend
  /// calls: GPU film, display encoding and readback, or CPU film processing.
  async develop(
    source,
    controls,
    onProgress = () => {},
    stale = () => false,
    { bitDepth = 8, colorSpace = 'srgb', region = null, toneGrid = null } = {},
  ) {
    validateColorSpace(colorSpace)
    if (
      source.width !== this.width ||
      source.height !== this.height ||
      JSON.stringify(region) !== JSON.stringify(this.region || null)
    ) {
      this.setFrame(source.width, source.height, region)
    }
    const destination = frameRegion(this.width, this.height, region)
    this.controls = controls
    this.applyControls(controls)
    if (
      this.pack?.screenMeter ||
      (controls.localTone && (controls.highlights || controls.shadows))
    ) {
      onProgress('Measuring local highlights and shadows')
      const grid =
        toneGrid ||
        (await measuredTone(
          source,
          controls,
          whiteBalanceGains(controls.temperature, controls.tint),
        ))
      const offset = this.configPtr / 4
      applyScreenLevels(
        this.module.HEAPF32.subarray(
          offset,
          offset + this.configuration.length,
        ),
        this.pack?.screenMeter,
        grid.regionStops,
      )
      this.module.HEAPF32[offset + CONFIG.TONE_GRID_WIDTH] = grid.width
      this.module.HEAPF32[offset + CONFIG.TONE_GRID_HEIGHT] = grid.height
      this.module.HEAPF32.set(grid.a, offset + CONFIG.TONE_GRID_A)
      this.module.HEAPF32.set(grid.b, offset + CONFIG.TONE_GRID_B)
    }
    const pixels = new (bitDepth === 16 ? Uint16Array : Uint8ClampedArray)(
      destination.width * destination.height * 4,
    )
    let elapsed = 0
    for (let t = 0; t < this.tiles.length; ++t) {
      if (stale()) return null
      const tile = this.tiles[t]
      const { region } = tile
      const operation =
        this.featureMask === 1 << 29
          ? 'Applying light and color'
          : 'Rendering film and output medium'
      onProgress(`${operation} · tile ${t + 1} of ${this.tiles.length}`)
      // Let a long CPU tile show its current operation before it occupies the main thread.
      if (this.tiles.length > 1) await yieldToBrowser()
      this.decodeRegion(
        await source.read(region.x, region.y, region.width, region.height),
        region,
      )
      if (stale()) return null
      const started = performance.now()
      const status = await this.run(region, { bitDepth, colorSpace })
      elapsed += performance.now() - started
      if (status === -2)
        throw new Error('no kernel was built for this stock at this size')
      if (status !== 0) throw new Error(`engine returned ${status}`)
      // Read the heap after the call, not before: the module can grow its memory mid-render,
      // which detaches any view taken earlier.
      if (this.encodedRegion) {
        copyEncodedTile(
          pixels,
          this.encodedRegion(region, bitDepth),
          tile,
          destination,
        )
      } else {
        encodeTileInto(
          pixels,
          this.width,
          this.regionOutput(region),
          tile,
          this.seed,
          this.outputStride,
          this.outputOffsets(region),
          colorSpace,
          destination,
        )
      }
      if (t + 1 < this.tiles.length) await yieldToBrowser()
    }
    return { pixels, elapsed }
  }

  get isAborted() {
    return runtime.wasAborted(this.module)
  }

  dispose() {
    if (this.isAborted) return
    this.freeFrame()
    this.module._free(this.grainPtr)
    this.disposeTables()
  }
}

/// Develops through the fused GPU kernel — the same schedule the phones run — over WGSL compute
/// shaders. Holds the wasm-side buffers for one frame size and pack, so dragging a slider does
/// not re-upload five megabytes of spectral cube on every frame.
export class WebgpuDeveloper extends Developer {
  constructor(module, pack) {
    super(module, pack, 'webgpu')
    // The film and paper cubes ride behind the configuration in one buffer. A WebGPU compute
    // stage is promised only eight storage buffers and the combine kernel binds nine as it is;
    // with the cubes on their own it bound eleven, which no adapter here would create.
    this.configPtr = module._malloc(
      (pack.configuration.length + 2 * LUT_COUNT) * 4,
    )
    this.exposurePtr = module._malloc(LUT_COUNT * 4)
    this.inputPtr = 0
    this.outputPtr = 0
    // Interleaved RGBA float at both ends: this kernel's own layout.
    this.outputStride = 4
    this.usePack(pack)

    // Asynchronous: the kernel suspends through JSPI while the device works.
    this.renderCall = module.cwrap(
      'fotufilm_wasm_render',
      'number',
      [
        'number',
        'number',
        'number',
        'number',
        'number',
        'number',
        'number',
        'number',
        'number',
        'number',
      ],
      { async: true },
    )
    this.renderDisplayCall = module.cwrap(
      'fotufilm_wasm_render_display',
      'number',
      Array(14).fill('number'),
      { async: true },
    )
  }

  uploadTables(pack) {
    const { module } = this
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
  }

  allocateFrame(pixels) {
    this.inputPtr = this.module._malloc(pixels * 4 * 4)
    this.outputPtr = this.module._malloc(pixels * 4 * 4)
    this.displayPtr = this.module._malloc(pixels * 4 * 2)
  }

  freeFrame() {
    if (this.inputPtr) this.module._free(this.inputPtr)
    if (this.outputPtr) this.module._free(this.outputPtr)
    if (this.displayPtr) this.module._free(this.displayPtr)
    this.inputPtr = 0
    this.outputPtr = 0
    this.displayPtr = 0
  }

  disposeTables() {
    this.module._free(this.configPtr)
    this.module._free(this.exposurePtr)
  }

  decodeRegion(bytes, region) {
    const n = region.width * region.height
    decodeInto(
      this.module.HEAPF32.subarray(
        this.inputPtr / 4,
        this.inputPtr / 4 + n * 4,
      ),
      bytes,
      n,
      4,
      [0, 1, 2],
    )
  }

  run(region, delivery) {
    const args = [
      this.inputPtr,
      this.outputPtr,
      region.width,
      region.height,
      region.x,
      region.y,
      this.configPtr,
      this.exposurePtr,
      this.featureMask,
      this.seed,
    ]
    if (!delivery) return this.renderCall(...args)
    return this.renderDisplayCall(
      ...args,
      this.displayPtr,
      delivery.bitDepth,
      delivery.colorSpace === 'display-p3' ? 1 : 0,
      this.width,
    )
  }

  encodedRegion(region, bitDepth) {
    const ArrayType = bitDepth === 16 ? Uint16Array : Uint8Array
    return new ArrayType(
      this.module.HEAPF32.buffer,
      this.displayPtr,
      region.width * region.height * 4,
    )
  }

  regionOutput(region) {
    const n = region.width * region.height
    return this.module.HEAPF32.subarray(
      this.outputPtr / 4,
      this.outputPtr / 4 + n * 4,
    )
  }

  outputOffsets() {
    return [0, 1, 2]
  }

  // Exercise real dispatches: loading WASM alone does not compile GPU pipelines.
  async probe({ width = 16, height = 16, bitDepth = 8 } = {}) {
    const grey = new Uint8ClampedArray(width * height * 4).fill(118)
    for (let i = 3; i < grey.length; i += 4) grey[i] = 255
    await this.develop(
      pixelSource({ data: grey, width, height }),
      { grain: 1 },
      undefined,
      undefined,
      { bitDepth },
    )
  }
}

/// Develops on the CPU, through the same physics compiled to SIMD WebAssembly. This is what a
/// browser without a WebGPU adapter gets, and what the GPU path falls back to.
export class SimdDeveloper extends Developer {
  constructor(module, pack) {
    super(module, pack, 'simd')
    this.configPtr = module._malloc(pack.configuration.length * 4)
    this.exposurePtr = module._malloc(LUT_COUNT * 4)
    this.filmPtr = module._malloc(LUT_COUNT * 4)
    this.paperPtr = module._malloc(LUT_COUNT * 4)
    // These kernels work planar — three width*height planes — and carry a density field between
    // the develop and print stages.
    this.inputPtr = 0
    this.outputPtr = 0
    this.densityPtr = 0
    this.outputStride = 1
    this.usePack(pack)

    this.renderCall = module.cwrap('fotufilm_wasm_cpu_render', 'number', [
      'number',
      'number',
      'number',
      'number',
      'number',
      'number',
      'number',
      'number',
      'number',
      'number',
      'number',
      'number',
      'number',
    ])
  }

  uploadTables(pack) {
    const { module } = this
    for (const [name, ptr] of [
      ['exposure', this.exposurePtr],
      ['film', this.filmPtr],
      ['paper', this.paperPtr],
    ]) {
      if (this.uploaded[name] !== pack[name])
        module.HEAPF32.set(pack[name], ptr / 4)
    }
  }

  allocateFrame(pixels) {
    this.transportPtrs = this.pack.transport
      ? [
          this.module._malloc(pixels * 3 * 4),
          this.module._malloc(pixels * 3 * 4),
          this.module._malloc(257 * 257 * 4),
        ]
      : []
    this.inputPtr = this.module._malloc(pixels * 3 * 4)
    this.outputPtr = this.module._malloc(pixels * 3 * 4)
    this.densityPtr = this.module._malloc(pixels * 3 * 4)
  }

  freeFrame() {
    for (const ptr of [
      this.inputPtr,
      this.outputPtr,
      this.densityPtr,
      ...(this.transportPtrs ?? []),
    ]) {
      if (ptr) this.module._free(ptr)
    }
    this.transportPtrs = []
    this.inputPtr = 0
    this.outputPtr = 0
    this.densityPtr = 0
  }

  disposeTables() {
    for (const ptr of [
      this.configPtr,
      this.exposurePtr,
      this.filmPtr,
      this.paperPtr,
    ]) {
      this.module._free(ptr)
    }
  }

  decodeRegion(bytes, region) {
    const n = region.width * region.height
    decodeInto(
      this.module.HEAPF32.subarray(
        this.inputPtr / 4,
        this.inputPtr / 4 + n * 3,
      ),
      bytes,
      n,
      1,
      [0, n, 2 * n],
    )
  }

  /// Synchronous: the kernel runs on this thread and holds it for the length of the tile.
  run(region) {
    if (this.pack.transport) return this.runTransport(region)
    return this.renderCall(
      this.inputPtr,
      this.outputPtr,
      region.width,
      region.height,
      region.x,
      region.y,
      this.configPtr,
      this.exposurePtr,
      this.filmPtr,
      this.paperPtr,
      this.densityPtr,
      this.featureMask,
      this.seed,
    )
  }

  runTransport(region) {
    const { module, pack } = this
    const root = pack.transport
    const plan =
      root.sizes.find((size) => size.shortEdge === this.rung.shortEdge) ?? root
    const [sumPtr, filteredPtr, kernelPtr] = this.transportPtrs
    const count = region.width * region.height * 3
    module.HEAPF32.fill(0, sumPtr / 4, sumPtr / 4 + count)
    const render = (input, mask) =>
      this.renderCall(
        input,
        this.outputPtr,
        region.width,
        region.height,
        region.x,
        region.y,
        this.configPtr,
        this.exposurePtr,
        this.filmPtr,
        this.paperPtr,
        this.densityPtr,
        mask,
        this.seed,
      )
    const original = this.configuration
    const configure = (values) => {
      this.configuration = values.slice()
      this.configuration[this.frameSizeSlot] = this.width
      this.configuration[this.frameSizeSlot + 1] = this.height
      this.applyControls(this.controls)
    }
    try {
      for (const component of plan.components) {
        configure(plan.headConfiguration)
        module.HEAPF32.set(component.exposure, this.exposurePtr / 4)
        const status = render(this.inputPtr, root.headMask)
        if (status !== 0) return status
        for (const band of component.bands) {
          module.HEAPF32.set(band.weights, kernelPtr / 4)
          const status = module.ccall(
            'fotufilm_wasm_transport',
            'number',
            Array(7).fill('number'),
            [
              this.outputPtr,
              filteredPtr,
              region.width,
              region.height,
              kernelPtr,
              band.radius,
              band.stride,
            ],
          )
          if (status !== 0) return status
          const heap = module.HEAPF32
          for (let i = 0; i < count; ++i)
            heap[sumPtr / 4 + i] += band.weight * heap[filteredPtr / 4 + i]
        }
      }
      configure(plan.tailConfiguration)
      module.HEAPF32.set(pack.exposure, this.exposurePtr / 4)
      return render(sumPtr, this.featureMask)
    } finally {
      this.configuration = original
    }
  }

  regionOutput(region) {
    const n = region.width * region.height
    return this.module.HEAPF32.subarray(
      this.outputPtr / 4,
      this.outputPtr / 4 + n * 3,
    )
  }

  outputOffsets(region) {
    const n = region.width * region.height
    return [0, n, 2 * n]
  }
}

/// Builds the fastest developer this browser will actually run: WebGPU when the adapter can
/// create the kernel's pipelines, and the SIMD path otherwise.
export async function createDeveloper(
  pack,
  onProgress = () => {},
  { preferGpu = true } = {},
) {
  if (typeof WebAssembly !== 'object')
    throw new Error(
      'This browser cannot process film profiles. Use a browser with WebAssembly support.',
    )
  if (
    preferGpu &&
    supportsWebgpuRuntime(navigator.gpu, WebAssembly) &&
    !pack.transport &&
    !(pack.featureMask & (1 << 28))
  ) {
    let developer
    try {
      onProgress('Loading WebGPU engine')
      developer = new WebgpuDeveloper(await loadModule('webgpu'), pack)
      onProgress('Compiling WebGPU shaders')
      await developer.probe()
      return developer
    } catch (error) {
      // An aborted Emscripten module cannot be called again, so the promise goes with it and the
      // next pack loads a fresh one.
      if (developer && !runtime.wasAborted(developer.module))
        developer.dispose()
      runtime.forget('webgpu')
      console.warn(
        'WebGPU engine unavailable, developing on the CPU instead:',
        error,
      )
    }
  }
  onProgress('Loading CPU engine')
  return new SimdDeveloper(await loadModule('simd'), pack)
}

export function decodeRGBA(bytes) {
  if (bytes instanceof Float32Array) return bytes.slice()
  const linear = new Float32Array(bytes.length)
  decodeInto(linear, bytes, bytes.length / 4, 4, [0, 1, 2])
  for (let i = 3; i < bytes.length; i += 4) linear[i] = bytes[i] / 255
  return linear
}

// PlainDevelop.swift, for Normal. A pipeline's bypass diagnostic is still a film model.
export async function developNormalReference(
  source,
  controls,
  onProgress = () => {},
  stale = () => false,
  { bitDepth = 8, colorSpace = 'srgb', region = null, toneGrid = null } = {},
) {
  const { width, height } = source,
    started = performance.now()
  const destination = frameRegion(width, height, region)
  const balance = whiteBalanceGains(controls.temperature, controls.tint),
    grade = packedGrade(controls)
  const exposure = 2 ** (controls.ev || 0),
    weights = [0.2627002, 0.6779981, 0.0593017]
  const matrix = [
    1.343578253, -0.282179671, -0.061398582, -0.065297453, 1.075787916,
    -0.010490463, 0.002821787, -0.019598495, 1.016776707,
  ]
  const grid =
    controls.localTone && (controls.highlights || controls.shadows)
      ? toneGrid || (await measuredTone(source, controls, balance))
      : null
  const pixels = new (bitDepth === 16 ? Uint16Array : Uint8ClampedArray)(
    destination.width * destination.height * 4,
  )
  const encode = (v) =>
    v <= 0.0031308
      ? v * 12.92
      : v >= 1
        ? 1 + (v - 1) * (1.055 / 2.4)
        : 1.055 * v ** (1 / 2.4) - 0.055
  const decode = (v) =>
    v <= 0.04045
      ? v / 12.92
      : v >= 1
        ? 1 + (v - 1) / (1.055 / 2.4)
        : ((v + 0.055) / 1.055) ** 2.4
  for (
    let top = destination.y;
    top < destination.y + destination.height;
    top += 32
  ) {
    if (stale()) return null
    onProgress(
      `Applying light and color · rows ${top + 1}–${Math.min(top + 32, height)} of ${height}`,
    )
    const rows = Math.min(32, destination.y + destination.height - top),
      linear = decodeRGBA(
        await source.read(destination.x, top, destination.width, rows),
      )
    for (let y = 0; y < rows; y++)
      for (let x = 0; x < destination.width; x++) {
        const i = (y * destination.width + x) * 4
        const rgb = [0, 1, 2].map((c) => linear[i + c] * balance[c])
        const luma = rgb.reduce((sum, v, c) => sum + v * weights[c], 0)
        const stops = toneKey(
          grid,
          Math.log2(Math.max((luma * exposure) / 0.18, 1e-6)),
          x + destination.x,
          top + y,
          width,
          height,
        )
        const high = clamp01(stops / 6),
          low = clamp01(-stops / 6)
        const gain =
          2 **
          (3 *
            ((controls.highlights || 0) * high * high * (3 - 2 * high) +
              (controls.shadows || 0) * low * low * (3 - 2 * low)))
        const peak = Math.max(...rgb),
          colourfulness = (peak - Math.min(...rgb)) / Math.max(peak, 1e-6)
        const chroma =
          (controls.saturation ?? 1) *
          (1 + (controls.vibrance || 0) * (1 - colourfulness))
        const lit = rgb.map(
          (v) => (luma + chroma * (v - luma)) * gain * exposure,
        )
        for (let c = 0; c < 3; c++) {
          let value =
            matrix[c * 3] * lit[0] +
            matrix[c * 3 + 1] * lit[1] +
            matrix[c * 3 + 2] * lit[2]
          if (controls.gradeSpace) value = encode(value)
          value = value * (grade[c + 3] - grade[c]) + grade[c]
          if (grade[c + 6] !== 1) value = Math.max(value, 0) ** grade[c + 6]
          linear[i + c] = controls.gradeSpace ? decode(value) : value
        }
      }
    const tile = {
      x: destination.x,
      y: top,
      width: destination.width,
      height: rows,
      region: {
        x: destination.x,
        y: top,
        width: destination.width,
        height: rows,
      },
    }
    encodeTileInto(
      pixels,
      width,
      linear,
      tile,
      0,
      4,
      [0, 1, 2],
      colorSpace,
      destination,
    )
    await yieldToBrowser()
  }
  return { pixels, elapsed: performance.now() - started }
}

export async function createCpuDeveloper(pack) {
  return new SimdDeveloper(await loadModule('simd'), pack)
}

export function normalPack() {
  const configuration = new Float32Array(
    CONFIG.FOTUFILM_FRAME_CONFIGURATION_COUNT,
  )
  configuration[CONFIG.TONE_GRID_WIDTH] = configuration[
    CONFIG.TONE_GRID_HEIGHT
  ] = 1
  configuration[CONFIG.TONE_GRID_A] = 1
  const cube = new Float32Array(LUT_COUNT)
  return {
    configuration,
    exposure: cube,
    film: cube,
    paper: cube,
    seed: 0,
    width: 1600,
    height: 1600,
    featureMask: 1 << 29,
    ladder: [
      {
        shortEdge: 1600,
        featureMask: 1 << 29,
        seed: 0,
        spatialSupport: 0,
        slots: new Int32Array(0),
        values: new Float32Array(0),
      },
    ],
  }
}
export async function createNormalDeveloper(options) {
  return createDeveloper(normalPack(), undefined, options).catch((error) => {
    console.warn('Using the light and color reference:', error)
    return null
  })
}
// Import previews get their own buffers; live sessions keep a persistent developer.
export async function developNormal(
  source,
  controls,
  onProgress = () => {},
  stale = () => false,
  output = {},
) {
  if (typeof window === 'undefined')
    return developNormalReference(source, controls, onProgress, stale, output)
  onProgress('Preparing light and color engine')
  const developer = await createNormalDeveloper()
  if (!developer)
    return developNormalReference(source, controls, onProgress, stale, output)
  try {
    return await developer.develop(source, controls, onProgress, stale, output)
  } finally {
    developer.dispose()
  }
}

export function linearSource(source) {
  if (source.width * source.height > 4_000_000) return source
  const prepared = pixelSource({
    width: source.width,
    height: source.height,
    data: decodeRGBA(source.read(0, 0, source.width, source.height)),
  })
  preparedSources.add(prepared)
  return prepared
}

// Geometry and color conversion must yield while preparing a detailed preview.
export async function prepareLinearSource(source, stale = () => false) {
  if (source.width * source.height > 4_000_000) return source
  const data = new Float32Array(source.width * source.height * 4)
  const rows = Math.max(1, Math.floor(32768 / source.width))
  for (let y = 0; y < source.height; y += rows) {
    if (stale()) return null
    data.set(
      decodeRGBA(
        source.read(0, y, source.width, Math.min(rows, source.height - y)),
      ),
      y * source.width * 4,
    )
    await yieldToBrowser()
  }
  const prepared = pixelSource({
    width: source.width,
    height: source.height,
    data,
  })
  preparedSources.add(prepared)
  return prepared
}
