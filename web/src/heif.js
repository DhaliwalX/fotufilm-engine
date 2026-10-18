// The HEIF container (ISO/IEC 23008-12) around HEIC photos: the primary image's HEVC tiles,
// its colour, the transforms that display it, and the Exif item. Pixels are decoded elsewhere.

const HEIF_BRANDS = new Set(['heic', 'heix', 'heim', 'heis', 'hevc', 'hevx'])

const fourCC = (bytes, at) =>
  String.fromCharCode(bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3])

// HEVC-coded HEIF: an HEVC major brand, or MIAF's generic one with an HEVC brand beside it.
// AVIF shares the container and stays with the browser's own decoder.
export function isHEIF(header) {
  if (header.length < 12 || fourCC(header, 4) !== 'ftyp') return false
  const size = Math.min(header.length, new DataView(header.buffer, header.byteOffset).getUint32(0))
  const brands = [fourCC(header, 8)]
  for (let at = 16; at + 4 <= size; at += 4) brands.push(fourCC(header, at))
  return HEIF_BRANDS.has(brands[0]) ||
    (['mif1', 'msf1'].includes(brands[0]) && brands.some((brand) => HEIF_BRANDS.has(brand)))
}

class Reader {
  constructor(bytes, at = 0, end = bytes.length) {
    this.bytes = bytes
    this.view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
    this.at = at
    this.end = end
  }
  need(count) {
    if (this.at + count > this.end) throw new Error('This HEIC file is damaged.')
  }
  u8() { this.need(1); return this.bytes[this.at++] }
  u16() { this.need(2); const v = this.view.getUint16(this.at); this.at += 2; return v }
  u32() { this.need(4); const v = this.view.getUint32(this.at); this.at += 4; return v }
  i32() { this.need(4); const v = this.view.getInt32(this.at); this.at += 4; return v }
  uint(size) {
    if (size === 0) return 0
    if (size === 4) return this.u32()
    if (size === 2) return this.u16()
    if (size === 8) {
      const high = this.u32(), low = this.u32()
      const value = high * 2 ** 32 + low
      if (!Number.isSafeInteger(value)) throw new Error('This HEIC file is too large.')
      return value
    }
    throw new Error('This HEIC file is damaged.')
  }
  fourCC() { this.need(4); const v = fourCC(this.bytes, this.at); this.at += 4; return v }
  full() { const word = this.u32(); return { version: word >>> 24, flags: word & 0xffffff } }
  *boxes() {
    while (this.at + 8 <= this.end) {
      const start = this.at
      let size = this.u32()
      const type = this.fourCC()
      if (size === 1) size = this.uint(8)
      else if (size === 0) size = this.end - start
      const body = this.at
      if (size < body - start || start + size > this.end) throw new Error('This HEIC file is damaged.')
      this.at = start + size
      yield { type, start, body, end: start + size }
    }
  }
  sub(box) { return new Reader(this.bytes, box.body, box.end) }
}

// The top-level `meta` box of a file whose start is `bytes` (at least through that box).
export function findMetaBox(bytes) {
  for (const box of new Reader(bytes).boxes()) if (box.type === 'meta') return box
  return null
}

// Every item of a `meta` box: its type, the bytes' location, its properties in their order,
// and its references. Extents are file offsets (construction method 0) or ranges of `idat` (1).
export function parseHEIFMeta(bytes, box) {
  const meta = new Reader(bytes, box.body, box.end)
  meta.full()
  const items = new Map()
  const item = (id) => {
    if (!items.has(id))
      items.set(id, { id, type: null, hidden: false, extents: [], method: 0, properties: [], references: {} })
    return items.get(id)
  }
  let primary = null, idat = null, properties = [], associations = []
  for (const child of meta.boxes()) {
    const r = meta.sub(child)
    if (child.type === 'pitm') primary = r.full().version === 0 ? r.u16() : r.u32()
    else if (child.type === 'idat') idat = bytes.subarray(child.body, child.end)
    else if (child.type === 'iinf') {
      const { version } = r.full()
      version === 0 ? r.u16() : r.u32()
      for (const entry of r.boxes()) {
        if (entry.type !== 'infe') continue
        const e = r.sub(entry), { version: v, flags } = e.full()
        if (v < 2) continue
        const info = item(v === 2 ? e.u16() : e.u32())
        e.u16()
        info.type = e.fourCC()
        info.hidden = (flags & 1) === 1
      }
    } else if (child.type === 'iloc') {
      const { version } = r.full()
      const sizes = r.u16()
      const offsetSize = sizes >> 12, lengthSize = (sizes >> 8) & 15, baseSize = (sizes >> 4) & 15
      const indexSize = version === 1 || version === 2 ? sizes & 15 : 0
      const count = version < 2 ? r.u16() : r.u32()
      for (let i = 0; i < count; i++) {
        const info = item(version < 2 ? r.u16() : r.u32())
        if (version === 1 || version === 2) info.method = r.u16() & 15
        r.u16()
        const base = r.uint(baseSize)
        const extents = r.u16()
        for (let x = 0; x < extents; x++) {
          if (indexSize) r.uint(indexSize)
          const offset = base + r.uint(offsetSize), length = r.uint(lengthSize)
          info.extents.push({ offset, length })
        }
      }
    } else if (child.type === 'iref') {
      const { version } = r.full()
      for (const reference of r.boxes()) {
        const e = r.sub(reference)
        const from = version === 0 ? e.u16() : e.u32()
        const count = e.u16(), to = []
        for (let i = 0; i < count; i++) to.push(version === 0 ? e.u16() : e.u32())
        ;(item(from).references[reference.type] ??= []).push(...to)
      }
    } else if (child.type === 'iprp') {
      for (const part of r.boxes()) {
        const p = r.sub(part)
        if (part.type === 'ipco') properties = [...p.boxes()].map((b) => property(bytes, b))
        else if (part.type === 'ipma') {
          const { version, flags } = p.full()
          const count = p.u32()
          for (let i = 0; i < count; i++) {
            const id = version < 1 ? p.u16() : p.u32()
            const n = p.u8(), indices = []
            for (let a = 0; a < n; a++) indices.push(flags & 1 ? p.u16() & 0x7fff : p.u8() & 0x7f)
            associations.push([id, indices])
          }
        }
      }
    }
  }
  for (const [id, indices] of associations)
    for (const index of indices)
      if (index > 0 && properties[index - 1]) item(id).properties.push(properties[index - 1])
  return { primary, items, idat }
}

function property(bytes, box) {
  const r = new Reader(bytes, box.body, box.end)
  switch (box.type) {
    case 'hvcC':
      return { type: 'hvcC', record: bytes.subarray(box.body, box.end) }
    case 'ispe':
      r.full()
      return { type: 'ispe', width: r.u32(), height: r.u32() }
    case 'colr': {
      const kind = r.fourCC()
      if (kind === 'nclx')
        return { type: 'colr', nclx: { primaries: r.u16(), transfer: r.u16(), matrix: r.u16(), fullRange: (r.u8() & 0x80) !== 0 } }
      if (kind === 'prof' || kind === 'rICC') return { type: 'colr', icc: bytes.subarray(r.at, box.end) }
      return { type: 'colr' }
    }
    // Anticlockwise quarter turns.
    case 'irot':
      return { type: 'irot', turns: r.u8() & 3 }
    // Axis 0 flips top to bottom and 1 left to right, as ImageIO and libheif read it.
    case 'imir':
      return { type: 'imir', axis: r.u8() & 1 }
    case 'clap': {
      const fraction = () => { const n = r.i32(), d = r.i32(); return d ? n / d : 0 }
      return { type: 'clap', width: fraction(), height: fraction(), x: fraction(), y: fraction() }
    }
    default:
      return { type: box.type }
  }
}

// An item's bytes from the whole file.
export function itemBytes(file, meta, item) {
  const source = item.method === 1 ? meta.idat : item.method === 0 ? file : null
  if (!source) throw new Error('This HEIC file keeps its picture in an unsupported place.')
  const length = item.extents.reduce((sum, e) => sum + e.length, 0)
  const out = new Uint8Array(length)
  let at = 0
  for (const { offset, length: size } of item.extents) {
    if (offset + size > source.length) throw new Error('This HEIC file is damaged.')
    out.set(source.subarray(offset, offset + size), at)
    at += size
  }
  return out
}

const first = (item, type) => item?.properties.find((p) => p.type === type)

// What decodes and displays the primary image (or, with `thumbnail`, the primary's thumbnail
// when the file has one): its HEVC tiles in raster order, the grid they fill, its colour and
// its display transforms in order.
export function heifImage(file, { thumbnail = false } = {}) {
  const box = findMetaBox(file)
  if (!box) throw new Error('This HEIC file has no picture.')
  const meta = parseHEIFMeta(file, box)
  let item = meta.items.get(meta.primary)
  if (!item) throw new Error('This HEIC file has no picture.')
  // A tone-mapped HDR rendition (ISO 21496-1) is built on its base image.
  if (item.type === 'tmap') item = meta.items.get(item.references.dimg?.[0])
  if (thumbnail) {
    const small = [...meta.items.values()].find(
      (i) => i.references.thmb?.includes(item.id) && ['hvc1', 'grid'].includes(i.type))
    if (small) item = small
  }
  let tiles, grid
  if (item?.type === 'grid') {
    const r = new Reader(itemBytes(file, meta, item))
    r.u8()
    const flags = r.u8(), rows = r.u8() + 1, columns = r.u8() + 1
    const width = flags & 1 ? r.u32() : r.u16(), height = flags & 1 ? r.u32() : r.u16()
    tiles = (item.references.dimg || []).map((id) => meta.items.get(id))
    if (tiles.length !== rows * columns || tiles.some((t) => t?.type !== 'hvc1'))
      throw new Error('This HEIC file’s picture is not HEVC-coded.')
    grid = { rows, columns, width, height }
  } else if (item?.type === 'hvc1') {
    tiles = [item]
    const size = first(item, 'ispe')
    if (!size) throw new Error('This HEIC file is damaged.')
    grid = { rows: 1, columns: 1, width: size.width, height: size.height }
  } else throw new Error('This HEIC file’s picture is not HEVC-coded.')
  const colours = [item, tiles[0]].flatMap((i) => i.properties.filter((p) => p.type === 'colr'))
  return {
    grid,
    tiles: tiles.map((tile) => {
      const config = first(tile, 'hvcC')
      if (!config) throw new Error('This HEIC file is damaged.')
      return { config: config.record, data: itemBytes(file, meta, tile) }
    }),
    nclx: colours.find((c) => c.nclx)?.nclx ?? null,
    icc: colours.find((c) => c.icc)?.icc ?? null,
    transforms: item.properties.filter((p) => ['clap', 'irot', 'imir'].includes(p.type)),
  }
}

// The Exif item describing the primary image: the TIFF header's file offset and the item's end.
export function heifExifRange(meta, fileSize) {
  const exif = [...meta.items.values()].find(
    (i) => i.type === 'Exif' && i.method === 0 && i.extents.length === 1 &&
      (!i.references.cdsc || i.references.cdsc.includes(meta.primary)))
  if (!exif) return null
  const { offset, length } = exif.extents[0]
  if (length < 4 || offset + length > fileSize) return null
  return { offset, length }
}

// The display transforms as one EXIF orientation of the decoded (cropped) raster, by composing
// each as a matrix on centred pixel coordinates (x right, y down).
export function heifOrientation(transforms) {
  let m = [1, 0, 0, 1]
  const apply = ([a, b, c, d]) => {
    m = [a * m[0] + b * m[2], a * m[1] + b * m[3], c * m[0] + d * m[2], c * m[1] + d * m[3]]
  }
  for (const t of transforms) {
    if (t.type === 'irot') for (let i = 0; i < t.turns; i++) apply([0, 1, -1, 0])
    else if (t.type === 'imir') apply(t.axis === 0 ? [1, 0, 0, -1] : [-1, 0, 0, 1])
  }
  const exif = { '1,0,0,1': 1, '-1,0,0,1': 2, '-1,0,0,-1': 3, '1,0,0,-1': 4,
    '0,1,1,0': 5, '0,-1,1,0': 6, '0,-1,-1,0': 7, '0,1,-1,0': 8 }
  return exif[m.join(',')]
}

// The clean aperture as a pixel rectangle of the decoded raster. Cropping is honoured where it
// comes before the rotation and mirroring, the order HEIF writers use.
export function heifCrop(transforms, width, height) {
  const index = transforms.findIndex((t) => t.type === 'clap')
  if (index < 0) return { x: 0, y: 0, width, height }
  if (transforms.slice(0, index).length)
    throw new Error('This HEIC file crops after rotating, which is not supported.')
  const c = transforms[index]
  const w = Math.round(c.width), h = Math.round(c.height)
  const x = Math.round(c.x + (width - 1) / 2 - (w - 1) / 2)
  const y = Math.round(c.y + (height - 1) / 2 - (h - 1) / 2)
  if (w <= 0 || h <= 0 || x < 0 || y < 0 || x + w > width || y + h > height)
    throw new Error('This HEIC file is damaged.')
  return { x, y, width: w, height: h }
}
