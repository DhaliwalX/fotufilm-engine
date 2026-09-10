import test from 'node:test'
import assert from 'node:assert/strict'
import { PreviewQueue, previewLabel } from '../../src/preview-queue.js'
import { defaultEdit } from '../../src/editor-state.js'
test('continuous input displays the running frame and skips superseded edits', async () => {
  const statuses = []
  const queue = new PreviewQueue((status) => statuses.push(status)),
    rendered = []
  let release, report
  const gate = new Promise((resolve) => {
    release = resolve
  })
  const first = queue.submit(async (onProgress) => {
    report = onProgress
    report('Rendering tile 1 of 2')
    await gate
    rendered.push(0)
    return 0
  })
  const pending = Array.from({ length: 100 }, (_, i) =>
    queue.submit(() => {
      rendered.push(i + 1)
      return i + 1
    }, `Exposure ${i + 1}`),
  )
  assert.equal(statuses.at(-1), 'Rendering tile 1 of 2 · Next: Exposure 100')
  report('Encoding preview image')
  assert.equal(statuses.at(-1), 'Encoding preview image · Next: Exposure 100')
  release()
  assert.equal(await first, 0)
  const values = await Promise.all(pending)
  assert.deepEqual(rendered, [0, 100])
  assert.equal(values.at(-1), 100)
  assert.ok(values.slice(0, -1).every((value) => value === null))
  assert.equal(statuses.at(-1), null)
  queue.close()
  const count = statuses.length
  report('Late progress')
  assert.equal(statuses.length, count)
  assert.equal(await queue.submit(() => assert.fail()), null)
})

test('pending preview labels distinguish exposure edits, full detail and another photo', () => {
  const initial = { fileId: 'a', filename: 'first.dng', edit: defaultEdit(), edge: 512 }
  const brighter = { ...initial, edit: { ...initial.edit, params: { ...initial.edit.params, ev: 1.25 } } }
  assert.equal(previewLabel(brighter, initial), 'Exposure +1.25 EV · 512px preview')
  assert.equal(previewLabel({ ...brighter, edge: 1600 }, brighter), 'Full detail · 1600px preview')
  assert.equal(previewLabel({ ...initial, fileId: 'b', filename: 'second.dng' }, brighter), 'second.dng · 512px preview')
})
