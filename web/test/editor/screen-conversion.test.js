import test from 'node:test'
import assert from 'node:assert/strict'
import { SHADOW_LIFT_SHARE, applyScreenLevels, autoColourShift, channelMedians, filmBoost, labScanDodge, labScanHighlight, retimeHighlight, toneCompression, toneStops } from '../../src/screen-conversion.js'
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
  // A flat frame, median 5.5 and highlight 5.995, is timed with white held 2.5 stops over its
  // median, at 8.
  applyScreenLevels(config, meter, [5, 6])
  assert.ok(Math.abs(config[CONFIG.MASKING] - 2.6) < 1e-5)
  assert.ok(Math.abs(config[CONFIG.MASKING+1] / config[CONFIG.MASKING] - 2) < 1e-6)
  for (const slot of [CONFIG.PAPER_MIDPOINT, CONFIG.PAPER_MIDPOINT_RED, CONFIG.PAPER_MIDPOINT_BLUE])
    assert.ok(Math.abs(config[slot] - .8) < 1e-5)
  const fixed = config.slice()
  applyScreenLevels(config, null, [100])
  assert.deepEqual(config, fixed)
})

test('lab scan levels each record from the backlight-adjusted highlight before exposure', () => {
  // median 0, highlight 9.9: lowered by the two-stop cap to 7.9, then the edit's +1.9 EV taken out
  assert.ok(Math.abs(labScanHighlight([-20, 0, 10]) - 7.9) < 1e-9)
  const meter = {min: 0, max: 10, labScan: true, adjustments: [[1, 1, 1, 0], [2, 1.5, 3, 1]]}
  const config = new Float32Array(9000)
  config.set([1, 1, 1], CONFIG.MASKING)
  assert.equal(applyScreenLevels(config, meter, [-20, 0, 10], 1.9), 0)
  assert.ok(Math.abs(config[CONFIG.HIGHLIGHTS] + .15) < 1e-6)
  assert.ok(Math.abs(config[CONFIG.SHADOWS] - .2) < 1e-6)
  const t = 0.6
  assert.ok(Math.abs(config[CONFIG.MASKING] - (1 + t)) < 1e-6)
  assert.ok(Math.abs(config[CONFIG.MASKING + 1] - (1 + .5 * t)) < 1e-6)
  assert.ok(Math.abs(config[CONFIG.MASKING + 2] - (1 + 2 * t)) < 1e-6)
  assert.ok(Math.abs(config[CONFIG.PAPER_MIDPOINT_RED] - t) < 1e-6)
})

test('lab scan dodges only a frame reaching past the print, keyed on its median', () => {
  assert.deepEqual(labScanDodge([-1, 0, 1]), {hold: 0, lift: 0, key: 0})
  const {hold, lift, key} = labScanDodge([-2, 1, 5])
  assert.ok(Math.abs(key - 1) < 1e-9)
  assert.ok(Math.abs(hold - .15 * (3.96 - 3) / 3) < 1e-9)
  assert.equal(lift, 0)
  assert.equal(labScanDodge([-2, 1, 5], 0).hold, 0)
  assert.ok(Math.abs(labScanDodge([-2, 1, 5], 2).hold - 2 * hold) < 1e-9)
})

test('auto levels holds white between two and a half and three and a half stops over the median', () => {
  assert.equal(retimeHighlight([0, 10]), 8.5)
  assert.equal(retimeHighlight([5, 5.5]), 7.75)
  assert.ok(Math.abs(retimeHighlight([0, 0, 0, 3]) - 2.955) < 1e-9)
  assert.equal(retimeHighlight([]), null)
  // A frame exposed for its lights is lifted two and a half stops at most.
  assert.equal(retimeHighlight([-8, -7]), 0.5)
  assert.equal(retimeHighlight([-8, -7], 1), 1.5)
})

test('auto levels meters the frame before the edit exposure', () => {
  const meter = {min:0, max:10, adjustments:[[1,0], [2,.5], [3,1]]}
  const levels = (regionStops, ev) => {
    const config = new Float32Array(9000)
    config.set([1, 1, 1], CONFIG.MASKING)
    applyScreenLevels(config, meter, regionStops, ev)
    return [config[CONFIG.MASKING], config[CONFIG.PAPER_MIDPOINT]]
  }
  // A +1 EV edit brightens every region by a stop; the re-time must not take it back out.
  assert.deepEqual(levels([6, 7], 1), levels([5, 6], 0))
})

test('auto levels balances a colour negative half the way to a neutral lit median', () => {
  // Two lit regions with a warm cast and two black ones the meter floors: the cast is read from
  // the lit ones.
  const luma = [-20, -20, 0, 1]
  const colour = [[-20, -20, 1, 2], [-20, -20, 0, 1], [-20, -20, -1, 0]]
  assert.deepEqual(channelMedians(luma, colour), [1.5, 0.5, -0.5])
  assert.equal(channelMedians(null, null), null)
  // A record read falling one unit per stop: red one stop warm prints half a unit denser.
  const meter = { min: -12, max: 12, adjustments: [[1, 0], [1, 0]], reads: [12, -12] }
  const near = (actual, expected) =>
    actual.forEach((v, i) => assert.ok(Math.abs(v - expected[i]) < 1e-9, `${actual} ≠ ${expected}`))
  near(autoColourShift(meter, [1.5, 0.5, -0.5]), [0.5, -0.5])
  near(autoColourShift(meter, [9, 0, -9]), [1, -1])
  assert.deepEqual(autoColourShift({ ...meter, reads: undefined }, [1.5, 0.5, -0.5]), [0, 0])
  const config = new Float32Array(9000)
  config.set([1, 1, 1], CONFIG.MASKING)
  applyScreenLevels(config, meter, luma, 0, colour)
  assert.equal(config[CONFIG.PAPER_MIDPOINT], 0)
  near([config[CONFIG.PAPER_MIDPOINT_RED], config[CONFIG.PAPER_MIDPOINT_BLUE]], [0.5, -0.5])
})

test('auto levels brings both ends of a wide negative onto the print alike', () => {
  // Pulled in by its own overflow, each end lands on the print: 3 * amount * smoothstep.
  const landed = (amount, reach) => {
    const t = Math.min(reach / 6, 1)
    return reach - 3 * amount * t * t * (3 - 2 * t)
  }
  const wide = toneCompression([0, -5.3, 5], 3)
  assert.ok(Math.abs(landed(wide.hold, 5) - 3) < 1e-6)
  assert.ok(Math.abs(landed(wide.lift / SHADOW_LIFT_SHARE, 5.3) - 3.3) < 1e-6)
  assert.deepEqual(toneCompression([0, -3.3, 3], 3), { hold: 0, lift: 0 })
  assert.equal(toneCompression([0, -12, 12], 3).hold, 1, 'a sun clips past the reach')
  assert.equal(filmBoost(1), 2)
  assert.equal(filmBoost(4), -1)
  const regions = [-6, -6, -5, -4, -3, -2, -2, -1, 0, 1, 2]
  assert.deepEqual(toneStops(regions).slice(0, 1), [-2])
  const config = new Float32Array(9000)
  config.set([1, 1, 1], CONFIG.MASKING)
  config[CONFIG.EXPOSURE_GAIN] = 1
  config[CONFIG.SHADOWS] = 0.9
  const meter = { min: -12, max: 12, adjustments: [[1, 0], [1, 0]], placesFilm: true }
  // Median -2 and highlight 1.95: white three and a half stops over the median, at 1.5, a film
  // boost of 1.5, a hold for the highlight past it and a lift for the end more than 6.3 stops
  // under it; the key is the boosted print grey.
  const key = applyScreenLevels(config, meter, regions)
  assert.ok(Math.abs(config[CONFIG.EXPOSURE_GAIN] - 2 ** 1.5) < 1e-5)
  assert.ok(config[CONFIG.HIGHLIGHTS] < -0.1)
  assert.ok(Math.abs(config[CONFIG.SHADOWS] - 1) < 1e-6, 'the lift stops where the control does')
  assert.ok(Math.abs(key - 0) < 1e-5)
  const untouched = new Float32Array(9000)
  untouched[CONFIG.EXPOSURE_GAIN] = 1
  assert.equal(applyScreenLevels(untouched, { ...meter, placesFilm: undefined }, regions), null)
  assert.equal(untouched[CONFIG.EXPOSURE_GAIN], 1)
})
