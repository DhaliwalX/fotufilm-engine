import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  isHEIF,
  findMetaBox,
  parseHEIFMeta,
  heifImage,
  heifExifRange,
  heifOrientation,
  heifCrop,
} from '../../src/heif.js'
import { heifColorSpace, iccToRec2020, applyICC } from '../../src/heif-color.js'
import { iccProfile } from '../../src/color-profiles.js'
import { orientedPixel } from '../../src/hdr-color.js'

const ascii = (s) => [...s].map((c) => c.charCodeAt(0))
const u16 = (v) => [v >> 8, v & 255]
const u32 = (v) => [v >>> 24, (v >> 16) & 255, (v >> 8) & 255, v & 255]
const box = (type, ...parts) => {
  const body = parts.flat()
  return [...u32(body.length + 8), ...ascii(type), ...body]
}
const full = (type, version, flags, ...parts) =>
  box(type, [version, (flags >> 16) & 255, (flags >> 8) & 255, flags & 255], ...parts)

// A grid of two 4×2 HEVC tiles kept in `mdat`, the grid's descriptor in `idat`, and an Exif item.
function gridFile({ transforms = [], colr = null } = {}) {
  const tileA = [1, 2, 3], tileB = [4, 5], exif = [...u32(6), ...ascii('Exif\0\0'), ...ascii('II*\0')]
  const grid = [0, 0, 0, 1, ...u16(8), ...u16(2)]
  const hvcC = box('hvcC', Array(23).fill(0).map((_, i) => (i === 0 ? 1 : 0)))
  const properties = [
    hvcC,
    full('ispe', 0, 0, u32(4), u32(2)),
    full('ispe', 0, 0, u32(8), u32(2)),
    ...(colr ? [colr] : []),
    ...transforms,
  ]
  const own = properties.slice(2).map((_, i) => 0x80 | (i + 3))
  const ipma = full('ipma', 0, 0, u32(3),
    u16(1), [2, 0x81, 0x82], u16(2), [2, 0x81, 0x82], u16(3), [own.length, ...own])
  const ftyp = box('ftyp', ascii('heic'), u32(0), ascii('mif1heic'))
  const metaWith = (mdatStart) => full('meta', 0, 0,
    full('hdlr', 0, 0, u32(0), ascii('pict'), u32(0), u32(0), u32(0), [0]),
    full('pitm', 0, 0, u16(3)),
    full('iinf', 0, 0, u16(4),
      full('infe', 2, 1, u16(1), u16(0), ascii('hvc1'), [0]),
      full('infe', 2, 1, u16(2), u16(0), ascii('hvc1'), [0]),
      full('infe', 2, 0, u16(3), u16(0), ascii('grid'), [0]),
      full('infe', 2, 1, u16(4), u16(0), ascii('Exif'), [0])),
    full('iref', 0, 0, box('dimg', u16(3), u16(2), u16(1), u16(2)), box('cdsc', u16(4), u16(1), u16(3))),
    box('iprp', box('ipco', ...properties), ipma),
    box('idat', grid),
    full('iloc', 1, 0, [0x44, 0x00], u16(4),
      u16(1), u16(0), u16(0), u16(1), u32(mdatStart), u32(tileA.length),
      u16(2), u16(0), u16(0), u16(1), u32(mdatStart + 3), u32(tileB.length),
      u16(3), u16(1), u16(0), u16(1), u32(0), u32(grid.length),
      u16(4), u16(0), u16(0), u16(1), u32(mdatStart + 5), u32(exif.length)))
  const metaLength = metaWith(0).length
  const mdatStart = ftyp.length + metaLength + 8
  return new Uint8Array([...ftyp, ...metaWith(mdatStart), ...box('mdat', tileA, tileB, exif)])
}

test('HEIF brands: HEVC brands are HEIC, AVIF is left to the browser', () => {
  const ftyp = (major, ...compatible) =>
    new Uint8Array(box('ftyp', ascii(major), u32(0), ...compatible.map(ascii)))
  assert.ok(isHEIF(ftyp('heic', 'mif1', 'heic')))
  assert.ok(isHEIF(ftyp('mif1', 'mif1', 'heix')))
  assert.ok(!isHEIF(ftyp('avif', 'mif1', 'avif')))
  assert.ok(!isHEIF(ftyp('mif1', 'mif1', 'avif')))
  assert.ok(!isHEIF(new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0, 16, ...ascii('JFIF\0\0\0\0')])))
})

test('HEIF grid: tiles in raster order, the descriptor from idat, colour and transforms', () => {
  const file = gridFile({
    colr: box('colr', ascii('nclx'), u16(12), u16(13), u16(6), [0x80]),
    transforms: [box('irot', [3]), box('imir', [1])],
  })
  const image = heifImage(file)
  assert.deepEqual(image.grid, { rows: 1, columns: 2, width: 8, height: 2 })
  assert.deepEqual(image.tiles.map((t) => [...t.data]), [[1, 2, 3], [4, 5]])
  assert.equal(image.tiles[0].config.length, 23)
  assert.deepEqual(image.nclx, { primaries: 12, transfer: 13, matrix: 6, fullRange: true })
  assert.equal(image.icc, null)
  assert.deepEqual(image.transforms.map((t) => t.type), ['irot', 'imir'])
  const meta = parseHEIFMeta(file, findMetaBox(file))
  const exif = heifExifRange(meta, file.length)
  assert.deepEqual([...file.subarray(exif.offset + 10, exif.offset + 14)], ascii('II*\0'))
  assert.throws(() => heifImage(file.subarray(0, 40)), /damaged|no picture/)
})

test('HEIF transforms compose into the EXIF orientation that displays them', () => {
  const rot = (turns) => ({ type: 'irot', turns }), mir = (axis) => ({ type: 'imir', axis })
  // ImageIO writes EXIF 2 as imir 1, 4 as imir 0, 5 as irot 1 then imir 0, 6 as irot 3.
  assert.equal(heifOrientation([]), 1)
  assert.equal(heifOrientation([mir(1)]), 2)
  assert.equal(heifOrientation([rot(2)]), 3)
  assert.equal(heifOrientation([mir(0)]), 4)
  assert.equal(heifOrientation([rot(1), mir(0)]), 5)
  assert.equal(heifOrientation([rot(3)]), 6)
  assert.equal(heifOrientation([rot(3), mir(0)]), 7)
  assert.equal(heifOrientation([rot(1)]), 8)
  // The composition agrees with orientedPixel moving a corner pixel.
  for (const [transforms, corner] of [[[rot(1)], [0, 3]], [[rot(3)], [2, 0]], [[mir(1)], [3, 0]]]) {
    assert.deepEqual(orientedPixel(0, 0, 4, 3, heifOrientation(transforms)), corner)
  }
})

test('HEIF clean aperture crops the centre before rotating', () => {
  const clap = { type: 'clap', width: 4, height: 2, x: 0, y: 0 }
  assert.deepEqual(heifCrop([clap, { type: 'irot', turns: 1 }], 8, 6), { x: 2, y: 2, width: 4, height: 2 })
  assert.deepEqual(heifCrop([], 8, 6), { x: 0, y: 0, width: 8, height: 6 })
  assert.throws(() => heifCrop([{ type: 'irot', turns: 1 }, clap], 8, 6), /crops after rotating/)
})

test('HEIF colour: nclx names, and Apple’s defaults without one', () => {
  assert.deepEqual(heifColorSpace({ primaries: 9, transfer: 16, matrix: 9, fullRange: false }),
    { primaries: 'bt2020', transfer: 'pq', matrix: 'bt2020-ncl', fullRange: false })
  assert.deepEqual(heifColorSpace(null),
    { primaries: 'bt709', transfer: 'iec61966-2-1', matrix: 'smpte170m', fullRange: true })
  assert.deepEqual(heifColorSpace(null, { icc: true }),
    { primaries: 'bt2020', transfer: 'linear', matrix: 'smpte170m', fullRange: true })
  assert.throws(() => heifColorSpace({ primaries: 22, transfer: 13, matrix: 6, fullRange: true }),
    /colour primaries \(22\)/)
})

test('ICC profiles: sRGB and Display P3 land on the movie converter’s Rec. 2020 matrices', () => {
  const srgbTo2020 = [0.627403896, 0.329283038, 0.043313066, 0.069097289, 0.919540395,
    0.011362316, 0.016391439, 0.088013308, 0.895595253]
  const p3To2020 = [0.753833035, 0.198597369, 0.047569596, 0.045743849, 0.94177722,
    0.012478931, -0.00121034, 0.017601717, 0.983608623]
  for (const [name, expected] of [['srgb', srgbTo2020], ['display-p3', p3To2020]]) {
    const { matrix, curves } = iccToRec2020(iccProfile(name))
    matrix.forEach((v, i) => assert.ok(Math.abs(v - expected[i]) < 2e-3, `${name}[${i}] ${v}`))
    // sRGB's curve: 0.5 encodes 0.214 linear, 0.04045 sits at the linear knee.
    for (const curve of curves) {
      assert.ok(Math.abs(curve(0.5) - 0.21404) < 1e-4)
      assert.ok(Math.abs(curve(0.04045) - 0.04045 / 12.92) < 1e-5)
    }
  }
  const pixels = new Float32Array([1, 1, 1, 1, 0.5, 0.5, 0.5, 1])
  applyICC(pixels, iccToRec2020(iccProfile('display-p3')))
  for (const [i, v] of [[0, 1], [4, 0.21404]]) assert.ok(Math.abs(pixels[i] - v) < 2e-3)
  assert.throws(() => iccToRec2020(new Uint8Array(64)), /damaged/)
})
