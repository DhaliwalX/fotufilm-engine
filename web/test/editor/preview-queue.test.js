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

test('a playing movie keeps one more frame at the backend, and only then waits', async () => {
  const queue = new PreviewQueue(),
    started = [],
    gates = []
  const frame = (n) => () => {
    started.push(n)
    return new Promise((resolve) => gates.push(() => resolve(n)))
  }
  const first = queue.submit(frame(1), 'Frame 1', { pipelined: true })
  const second = queue.submit(frame(2), 'Frame 2', { pipelined: true })
  const third = queue.submit(frame(3), 'Frame 3', { pipelined: true })
  assert.deepEqual(started, [1, 2])
  gates[0]()
  assert.equal(await first, 1)
  assert.deepEqual(started, [1, 2, 3])
  gates[1]()
  gates[2]()
  assert.deepEqual([await second, await third], [2, 3])
  // A preview that is not a playing frame waits for the backend to be idle.
  const moving = queue.submit(frame(4), 'Frame 4', { pipelined: true })
  const settled = queue.submit(frame(5), 'Settled')
  assert.deepEqual(started, [1, 2, 3, 4])
  gates[3]()
  assert.equal(await moving, 4)
  assert.deepEqual(started, [1, 2, 3, 4, 5])
  gates[4]()
  assert.equal(await settled, 5)
  queue.close()
})
