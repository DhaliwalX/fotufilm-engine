import test from 'node:test'
import assert from 'node:assert/strict'
import { gzipSync } from 'node:zlib'
import { createHash } from 'node:crypto'
import { applyMediumDelta } from '../../src/output-media.js'
import { defaultEdit, parseEdit } from '../../src/editor-state.js'

function patch(base, target) {
  const header = Buffer.alloc(80)
  header.write('FMED')
  header.writeUInt32LE(1, 4)
  header.writeUInt32LE(base.length, 8)
  header.writeUInt32LE(target.length, 12)
  createHash('sha256').update(base).digest().copy(header, 16)
  createHash('sha256').update(target).digest().copy(header, 48)
  const difference = target.map((value, i) => value ^ (base[i] || 0))
  return gzipSync(Buffer.concat([header, difference]))
}
const arrayBuffer = (bytes) => Uint8Array.from(bytes).buffer

test('medium deltas restore exact native bytes across pack size changes and reject mixed assets', async () => {
  const base = Buffer.from([0, 255, 127, 30, 20, 40])
  for (const target of [Buffer.from([4, 255]), Buffer.from([0, 255, 128, 30, 20, 50, 60, 70])]) {
    const compressed = patch(base, target)
    assert.deepEqual(Buffer.from(await applyMediumDelta(arrayBuffer(base), compressed)), target)
    await assert.rejects(
      applyMediumDelta(arrayBuffer(Buffer.alloc(base.length)), compressed),
      /do not match/,
    )
    const corrupt = Buffer.from(compressed)
    corrupt[corrupt.length - 1] ^= 1
    await assert.rejects(applyMediumDelta(arrayBuffer(base), corrupt))
  }
})

test('saved edits preserve output media, read legacy defaults and reject unsafe identifiers', () => {
  const edit = { ...defaultEdit('gold200'), medium: 'lab-scan' }
  const parse = (value) => parseEdit(JSON.stringify({ version: 1, edit: value }), ['gold200'])
  assert.equal(parse(edit).medium, 'lab-scan')
  const legacy = { ...edit }
  delete legacy.medium
  assert.equal(parse(legacy).medium, null)
  assert.throws(() => parse({ ...edit, medium: '../secret' }), /Invalid output medium/)
})
