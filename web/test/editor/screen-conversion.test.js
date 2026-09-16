import test from 'node:test'
import assert from 'node:assert/strict'
import { applyScreenLevels } from '../../src/screen-conversion.js'
import { CONFIG } from '../../src/engine-constants.js'
import { defaultEdit, parseEdit } from '../../src/editor-state.js'

test('screen conversion survives save, load and legacy edits', () => {
  for (const digitalReference of ['reference-exposure', 'graded-print', 'auto-levels']) {
    const edit = { ...defaultEdit('gold200'), digitalReference }
    assert.equal(parseEdit(JSON.stringify({version:1, edit}), ['gold200']).digitalReference, digitalReference)
  }
  const edit = defaultEdit('gold200')
  delete edit.digitalReference
  assert.equal(parseEdit(JSON.stringify({version:1, edit}), ['gold200']).digitalReference, 'auto-levels')
})

test('automatic levels meter bright regions and preserve channel ratios', () => {
  const config = new Float32Array(9000)
  config.set([1, 2, 3], CONFIG.MASKING)
  const meter = {min:0, max:10, adjustments:[[1,0], [2,.5], [3,1]]}
  applyScreenLevels(config, meter, [0, 10])
  assert.ok(Math.abs(config[CONFIG.MASKING] - 2.99) < 1e-6)
  assert.ok(Math.abs(config[CONFIG.MASKING+1] / config[CONFIG.MASKING] - 2) < 1e-6)
  for (const slot of [CONFIG.PAPER_MIDPOINT, CONFIG.PAPER_MIDPOINT_RED, CONFIG.PAPER_MIDPOINT_BLUE])
    assert.ok(Math.abs(config[slot] - .995) < 1e-6)
  const fixed = config.slice()
  applyScreenLevels(config, null, [100])
  assert.deepEqual(config, fixed)
})
