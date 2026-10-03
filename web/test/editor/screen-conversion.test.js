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

// A Lab Scan meter whose profile scans white two stops over mid-grey, with its toe four under,
// and whose records read a stop as `slopes` of log light: straight, so a record's levels come out
// in closed form.
const slopes = [.25, .3, .35]
const labScanMeter = {labScan: true, white: 2, toe: -4, keyShare: .5, maxStretch: 1.5,
  anchorBelow: 2, anchorSpan: 1.5, min: -16, max: 16,
  reads: Array.from({length: 33}, (_, i) => slopes.map(slope => -slope * (i - 16)))}
function labScanConfiguration() {
  const config = new Float32Array(CONFIG.FOTUFILM_FRAME_CONFIGURATION_COUNT)
  config.set([.9, 1, 1.1], CONFIG.MASKING)
  config.set([.2, .6, -2, .3, 1, .4], CONFIG.CURVES)
  return config
}
const close = (a, b) => Math.abs(a - b) < 1e-5
const midpoints = [CONFIG.PAPER_MIDPOINT_RED, CONFIG.PAPER_MIDPOINT, CONFIG.PAPER_MIDPOINT_BLUE]

// Each record scans a grey at x where the fixed profile scans it at toe + contrast (x - toe) + ev
// + stops: on straight reads, the record's contrast is the setup's, and its shift carries the rest.
function assertLabScanLevels(config, fixed, contrast, stops, exposureEV) {
  slopes.forEach((slope, c) => {
    assert.ok(close(config[CONFIG.MASKING + c], fixed[CONFIG.MASKING + c] * contrast), `scale ${c}`)
    const shift = -slope * ((labScanMeter.toe + exposureEV) * (1 - contrast) + stops)
    assert.ok(close(config[midpoints[c]], shift), `shift ${c}`)
    config[CONFIG.MASKING + c] = fixed[CONFIG.MASKING + c]
    config[midpoints[c]] = 0
  })
  // The film keeps the exposure it had.
  assert.deepEqual(config, fixed)
}

test('lab scan steepens each scan record about the toe and darkens it toward the key', () => {
  // median 0, highlight 9.9: lowered by the two-stop cap to 7.9
  assert.ok(Math.abs(labScanHighlight([-20, 0, 10]) - 7.9) < 1e-9)
  const config = labScanConfiguration(), fixed = config.slice()
  // median 0 and highlight 0.99: steepened until the highlight would scan at white, then
  // darkened toward the key, half the median's distance from mid-grey, which lands it on 0.
  assert.equal(applyScreenLevels(config, labScanMeter, [-1, 0, 1]), null)
  const contrast = 6 / 4.99
  assertLabScanLevels(config, fixed, contrast, 4 - contrast * 4, 0)
})

test('lab scan darkens a frame already past white on the scan alone, before the edit exposure', () => {
  for (const [exposureEV, stops] of [[0, -2.99], [1, -1.99]]) {
    const config = labScanConfiguration(), fixed = config.slice()
    // median 4, highlight 4.99: past white at the stock's contrast, so the records keep their
    // contrast and the scan darkens until the highlight scans at white.
    applyScreenLevels(config, labScanMeter, [3, 4, 5], exposureEV)
    assertLabScanLevels(config, fixed, 1, stops, exposureEV)
  }
})

test('lab scan lands each record on the fixed profile at the greys bracketing the frame', () => {
  // Curved reads: each record flattens toward its base under -3 stops.
  const curved = {...labScanMeter, reads: Array.from({length: 33}, (_, i) =>
    slopes.map(slope => -slope * Math.max(i - 16, -3 + (i - 13) / 4)))}
  const read = (stops, c) => {
    const x = Math.min(Math.max(stops, -16), 16) + 16, i = Math.min(Math.floor(x), 31), t = x - i
    return curved.reads[i][c] * (1 - t) + curved.reads[i + 1][c] * t
  }
  const config = labScanConfiguration(), fixed = config.slice()
  // median 0 and highlight 0.99, as above: the greys at -2 and 1.5 stops land where the profile
  // scans the greys the setup places them on.
  applyScreenLevels(config, curved, [-1, 0, 1])
  const contrast = 6 / 4.99, stops = 4 - contrast * 4
  const placed = x => -4 + contrast * (x + 4) + stops
  slopes.forEach((_, c) => {
    const scale = config[CONFIG.MASKING + c] / fixed[CONFIG.MASKING + c]
    for (const x of [-2, 1.5])
      assert.ok(close(scale * read(x, c) + config[midpoints[c]], read(placed(x), c)), `record ${c} at ${x}`)
  })
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
