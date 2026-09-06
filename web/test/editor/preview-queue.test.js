import test from 'node:test'
import assert from 'node:assert/strict'
import { PreviewQueue } from '../../src/preview-queue.js'
test('continuous input displays the running frame and skips superseded edits', async () => {
  const queue = new PreviewQueue(),
    rendered = []
  let release
  const gate = new Promise((resolve) => {
    release = resolve
  })
  const first = queue.submit(async () => {
    await gate
    rendered.push(0)
    return 0
  })
  const pending = Array.from({ length: 100 }, (_, i) =>
    queue.submit(() => {
      rendered.push(i + 1)
      return i + 1
    }),
  )
  release()
  assert.equal(await first, 0)
  const values = await Promise.all(pending)
  assert.deepEqual(rendered, [0, 100])
  assert.equal(values.at(-1), 100)
  assert.ok(values.slice(0, -1).every((value) => value === null))
  queue.close()
  assert.equal(await queue.submit(() => assert.fail()), null)
})
