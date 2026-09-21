import test from 'node:test'
import assert from 'node:assert/strict'
import {
  defaultEdit,
  parseEdit,
  historyReducer,
  initialHistory,
} from '../../src/editor-state.js'
import { sourceIlluminant } from '../../src/editor-catalogue.js'
import {
  newSelection,
  sampleScene,
  selectionWeight,
  compositeSelection,
} from '../../src/selective.js'
import { pixelSource, developNormalReference } from '../../src/engine.js'

test('source illuminant is explicit, survives saved edits, and legacy files use Stock Native', () => {
  const edit = defaultEdit('gold200')
  assert.equal(sourceIlluminant(edit), null)
  edit.sceneLight = 'tungsten3200'
  assert.equal(
    sourceIlluminant(
      parseEdit(JSON.stringify({ version: 1, edit }), ['gold200']),
    ),
    3200,
  )
  edit.sceneLight = 'custom'
  edit.params.sceneLightKelvin = 4900
  assert.equal(sourceIlluminant(edit), 4900)
  delete edit.sceneLight
  delete edit.params.sceneLightKelvin
  delete edit.params.cameraPreflash
  const restored = parseEdit(JSON.stringify({ version: 1, edit }), ['gold200'])
  assert.equal(sourceIlluminant(restored), null)
  assert.equal(restored.params.cameraPreflash, 0)
  edit.sceneLight = 'made-up'
  assert.throws(
    () => parseEdit(JSON.stringify({ version: 1, edit }), ['gold200']),
    /illuminant/,
  )
})

test('selection follows undeveloped color and luminance, retaining scene highlight headroom', () => {
  const source = pixelSource({
    width: 2,
    height: 1,
    data: new Float32Array([2, 2, 2, 1, 0.1, 0.1, 0.1, 1]),
  })
  const sample = sampleScene(source, [0, 0])
  assert.ok(sample[0] > 1)
  const selection = {
    ...newSelection(defaultEdit()),
    sample: [0.5, 0.02, 0.02],
    point: [0.2, 0.2],
  }
  assert.equal(selectionWeight(selection.sample, selection), 1)
  assert.equal(selectionWeight([0.02, 0.02, 0.5], selection), 0)
  const light = {
    ...selection,
    kind: 'light',
    sample: [0.1, 0.1, 0.1],
    range: 0.1,
  }
  assert.equal(selectionWeight([0.1, 0.1, 0.1], light), 1)
  assert.equal(selectionWeight([1, 1, 1], light), 0)
  assert.ok(selectionWeight([0.175, 0.175, 0.175], light) > 0)
})

test('selective development changes only selected pixels and mask preview never changes alpha', async () => {
  const source = pixelSource({
    width: 2,
    height: 1,
    data: new Float32Array([0.1, 0.1, 0.1, 1, 0.8, 0.8, 0.8, 0.5]),
  })
  const edit = defaultEdit()
  const selective = {
    ...newSelection(edit),
    kind: 'light',
    sample: [0.1, 0.1, 0.1],
    point: [0, 0],
    range: 0.1,
  }
  const base = await developNormalReference(source, edit.params)
  const local = await developNormalReference(source, { ...edit.params, ev: 1 })
  const output = compositeSelection(
    source,
    base.pixels,
    local.pixels,
    selective,
  )
  assert.deepEqual(output.slice(0, 4), local.pixels.slice(0, 4))
  assert.deepEqual(output.slice(4), base.pixels.slice(4))
  const mask = compositeSelection(source, base.pixels, null, selective, true)
  assert.deepEqual(Array.from(mask.slice(0, 3)), [255, 255, 255])
  assert.equal(mask[7], base.pixels[7])
})

test('selection shares history and saved edits, rejects malformed masks and drops extra local controls', () => {
  const edit = defaultEdit()
  edit.selective = {
    ...newSelection(edit),
    point: [0.25, 0.5],
    sample: [0.3, 0.1, 0.1],
  }
  edit.selective.params.ev = 1
  let history = historyReducer(initialHistory, { type: 'edit', patch: edit })
  assert.equal(history.present.selective.params.ev, 1)
  history = historyReducer(history, { type: 'undo' })
  assert.equal(history.present.selective, null)
  history = historyReducer(history, { type: 'redo' })
  assert.deepEqual(
    parseEdit(JSON.stringify({ version: 1, edit: history.present }), []),
    edit,
  )
  edit.selective.params.grain = 99
  assert.equal(
    parseEdit(JSON.stringify({ version: 1, edit }), []).selective.params.grain,
    undefined,
  )
  edit.selective.range = 0
  assert.throws(
    () => parseEdit(JSON.stringify({ version: 1, edit }), []),
    /selective/,
  )
})

test('sampling a decoded ordinary photo retains its alpha and color', () => {
  const source = pixelSource({
    width: 1,
    height: 1,
    data: new Uint8ClampedArray([112, 48, 48, 255]),
  })
  const sample = sampleScene(source, [0.5, 0.5])
  assert.ok(sample[0] > sample[1])
  assert.ok(sample[1] > 0)
})
