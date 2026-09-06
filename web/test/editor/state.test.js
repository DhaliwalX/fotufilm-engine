import test from 'node:test'
import assert from 'node:assert/strict'
import {
  defaultEdit,
  initialHistory,
  historyReducer,
  fullCrop,
  rotatedCrop,
  flippedCrop,
  cropForRatio,
  validCrop,
  parseEdit,
} from '../../src/editor-state.js'
import { homography, mapPoint, outputSize } from '../../src/geometry.js'
import { whiteBalanceGains, packedGrade } from '../../src/color-controls.js'
import { boxMean, measureTone, toneKey } from '../../src/tone-base.js'

test('a continuous edit is one undo and a new edit discards redo', () => {
  let history = initialHistory
  for (const ev of [0.2, 0.4, 0.6])
    history = historyReducer(history, {
      type: 'edit',
      patch: { params: { ...history.present.params, ev } },
      group: 'ev',
    })
  assert.equal(history.past.length, 1)
  history = historyReducer(history, { type: 'undo' })
  assert.equal(history.present.params.ev, 0)
  history = historyReducer(history, { type: 'redo' })
  assert.equal(history.present.params.ev, 0.6)
  history = historyReducer(history, { type: 'undo' })
  history = historyReducer(history, { type: 'edit', patch: { flip: true } })
  assert.equal(history.future.length, 0)
})
test('edits round-trip and invalid files cannot enter the renderer', () => {
  const edit = defaultEdit('gold200')
  const save = (edit) => JSON.stringify({ version: 1, edit })
  assert.deepEqual(parseEdit(save(edit), ['gold200']), edit)
  for (const invalid of [
    { ...edit, stock: 'missing' },
    {
      ...edit,
      crop: [
        [0, 0],
        [1, 1],
        [1, 0],
        [0, 1],
      ],
    },
    { ...edit, rotation: 12 },
    { ...edit, params: {} },
    { ...edit, params: { ...edit.params, ev: 100 } },
    { ...edit, ratio: 'potato' },
  ]) {
    assert.throws(() => parseEdit(save(invalid), ['gold200']))
  }
})
test('perspective crop maps all four corners and rejects concave selections', () => {
  const crop = [
    [0.1, 0.2],
    [0.8, 0.1],
    [0.9, 0.9],
    [0.2, 0.8],
  ]
  const matrix = homography(crop)
  fullCrop().forEach(([u, v], i) =>
    mapPoint(matrix, u, v).forEach((value, c) => assert.ok(Math.abs(value - crop[i][c]) < 1e-12)),
  )
  assert.equal(
    validCrop([
      [0, 0],
      [1, 0],
      [0.4, 0.1],
      [0, 1],
    ]),
    false,
  )
  assert.throws(() =>
    homography([
      [0, 0],
      [1, 1],
      [1, 0],
      [0, 1],
    ]),
  )
  let turned = crop
  for (let i = 0; i < 4; i++) turned = rotatedCrop(turned)
  turned.flat().forEach((v, i) => assert.ok(Math.abs(v - crop.flat()[i]) < 1e-12))
  const flipped = flippedCrop(flippedCrop(crop))
  flipped.flat().forEach((v, i) => assert.ok(Math.abs(v - crop.flat()[i]) < 1e-12))
  assert.deepEqual(outputSize(cropForRatio('1:1', 1600, 1000), 1600, 1000), {
    width: 1000,
    height: 1000,
  })
})
test('white balance and grade preserve neutral and have expected directions', () => {
  assert.deepEqual(whiteBalanceGains(), [1, 1, 1])
  const tungsten = whiteBalanceGains(2856, 0)
  assert.ok(tungsten[0] < 1 && tungsten[2] > 1)
  for (const k of [2000, 4000, 4500, 5000, 6504, 12000])
    for (const tint of [-100, 0, 100])
      assert.ok(whiteBalanceGains(k, tint).every((v) => Number.isFinite(v) && v > 0))
  assert.deepEqual(packedGrade({}), [0, 0, 0, 1, 1, 1, 1, 1, 1])
  const warm = packedGrade({ gradeHighlightsWarmth: 1 })
  assert.ok(warm[3] > 1 && warm[5] < 1)
})
test('regional masks preserve a uniform field and box means clip at the edge', async () => {
  assert.deepEqual(Array.from(boxMean([1, 2, 3, 4], 2, 2, 1)), [2.5, 2.5, 2.5, 2.5])
  const source = {
    width: 80,
    height: 40,
    read: (x, y, w, h) => new Float32Array(w * h * 4).fill(0.18),
  }
  const grid = await measureTone(source, { ev: 0 }, (bytes) => bytes, [1, 1, 1])
  assert.equal(grid.width, 64)
  assert.equal(grid.height, 32)
  assert.ok(Math.abs(toneKey(grid, 0, 32, 15, 80, 40)) < 1e-6)
})

test('browser color constants stay aligned with the native parity fixture', async () => {
  const { readFile } = await import('node:fs/promises')
  const fixture = JSON.parse(await readFile(new URL('./color-fixtures.json', import.meta.url)))
  for (const balance of fixture.balances)
    whiteBalanceGains(balance.temperature, balance.tint).forEach((v, i) =>
      assert.ok(Math.abs(v - balance.gains[i]) < 1e-12),
    )
  assert.deepEqual(packedGrade(fixture.grade.controls), fixture.grade.packed)
})

test('foreground renders run before pending thumbnails, without overlapping heaps', async () => {
  const { RenderSession } = await import('../../src/render-session.js')
  const session = new RenderSession(),
    order = []
  let release
  const gate = new Promise((resolve) => {
    release = resolve
  })
  const first = session.enqueue(async () => {
    order.push('start')
    await gate
    order.push('end')
  })
  const background = session.enqueue(() => order.push('thumbnail'), true)
  const preview = session.enqueue(() => order.push('preview'))
  release()
  await Promise.all([first, background, preview])
  assert.deepEqual(order, ['start', 'end', 'preview', 'thumbnail'])
  await session.dispose()
  assert.equal(await session.render({}), null)
})
