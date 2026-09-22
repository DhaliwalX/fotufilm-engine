import { validateColorSpace } from './canvas-color.js'

function clamp01(v) {
  return Math.min(Math.max(v, 0), 1)
}

function linearToSrgb(value) {
  const c = clamp01(value)
  return c <= 0.0031308 ? c * 12.92 : 1.055 * Math.pow(c, 1 / 2.4) - 0.055
}

const P3_TO_SRGB = [
  1.2249401, -0.2249404, 0.0, -0.0420569, 1.0420571, 0.0, -0.0196376,
  -0.0786361, 1.0982735,
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
  const state = (Math.imul(v, 747796405) + 2891336453) >>> 0
  const word =
    Math.imul((state >>> ((state >>> 28) + 4)) ^ state, 277803737) >>> 0
  return (word >>> 22) ^ word
}

function triangularDither(index, channelSeed) {
  const h1 = pcgHash((index ^ channelSeed) >>> 0)
  const h2 = pcgHash(h1)
  return (h1 >>> 8) / 16777216 + (h2 >>> 8) / 16777216 - 1
}

/// The print's interior of one tile, encoded for a canvas into its place in the frame. The
/// shoulder and the clip belong to the print, so they happen in P3 where the CLI does them; only
/// then does the result change primaries. The dither is indexed by the pixel's place in the frame,
/// not in the tile, so how the frame was cut leaves no trace in it.
export function encodeTileInto(
  pixels,
  frameWidth,
  output,
  tile,
  seed,
  stride,
  offsets,
  colorSpace = 'srgb',
  destination = { x: 0, y: 0, width: frameWidth },
) {
  validateColorSpace(colorSpace)
  const sixteen = pixels instanceof Uint16Array
  const n =
    colorSpace === 'display-p3' ? [1, 0, 0, 0, 1, 0, 0, 0, 1] : P3_TO_SRGB
  const [o0, o1, o2] = offsets
  const channelSeeds = [0, 1, 2].map((channel) =>
    pcgHash((channel + Math.imul(seed, 0x9e3779b9)) >>> 0),
  )
  const { region } = tile
  for (let y = tile.y; y < tile.y + tile.height; ++y) {
    for (let x = tile.x; x < tile.x + tile.width; ++x) {
      const at = ((y - region.y) * region.width + (x - region.x)) * stride
      const r = clamp01(displayShoulder(output[at + o0]))
      const g = clamp01(displayShoulder(output[at + o1]))
      const b = clamp01(displayShoulder(output[at + o2]))
      const p = y * frameWidth + x
      const i =
        ((y - destination.y) * destination.width + x - destination.x) * 4
      if (sixteen) {
        for (let c = 0; c < 3; c++) {
          const value = linearToSrgb(
            n[c * 3] * r + n[c * 3 + 1] * g + n[c * 3 + 2] * b,
          )
          pixels[i + c] = Number.isFinite(value)
            ? Math.round(clamp01(value) * 65535)
            : 0
        }
        pixels[i + 3] = 65535
        continue
      }
      // Native UInt8 conversion truncates after the half-step and dither.
      // Uint8ClampedArray rounds instead, so floor first to avoid a second round.
      pixels[i] = Math.floor(
        linearToSrgb(n[0] * r + n[1] * g + n[2] * b) * 255 +
          0.5 +
          triangularDither(p, channelSeeds[0]),
      )
      pixels[i + 1] = Math.floor(
        linearToSrgb(n[3] * r + n[4] * g + n[5] * b) * 255 +
          0.5 +
          triangularDither(p, channelSeeds[1]),
      )
      pixels[i + 2] = Math.floor(
        linearToSrgb(n[6] * r + n[7] * g + n[8] * b) * 255 +
          0.5 +
          triangularDither(p, channelSeeds[2]),
      )
      pixels[i + 3] = 255
    }
  }
}

// Copy only the tile interior. GPU encoding includes its spatial apron, and
// viewport output can have a different origin and row width from the full image.
export function copyEncodedTile(destination, encoded, tile, frame) {
  for (let y = tile.y; y < tile.y + tile.height; y++) {
    const sourceStart =
      ((y - tile.region.y) * tile.region.width + tile.x - tile.region.x) * 4
    const targetStart = ((y - frame.y) * frame.width + tile.x - frame.x) * 4
    destination.set(
      encoded.subarray(sourceStart, sourceStart + tile.width * 4),
      targetStart,
    )
  }
}
