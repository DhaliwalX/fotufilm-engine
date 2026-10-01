import { CONFIG } from './engine-constants.js'

function percentile(sorted, q) {
  const p = q * (sorted.length - 1), low = Math.floor(p)
  return sorted[low] + (p-low) * (sorted[Math.min(low+1, sorted.length-1)]-sorted[low])
}

// The highlight a whole-frame measurement is levelled on, from the regional log-luminances
// ToneBaseMeasurement takes: Digital Reference's Auto Levels reads the 99.5th percentile; Lab Scan
// lowers it by half its excess over three stops above the median, at most two stops, as
// LabScanTiming.highlight does. Null for an empty measurement.
export function meteredHighlight(regionStops, labScan = false) {
  const sorted = Array.from(regionStops || []).filter(Number.isFinite).sort((a,b) => a-b)
  if (!sorted.length) return null
  const bright = percentile(sorted, .995)
  if (!labScan) return bright
  const excess = Math.max(0, bright - percentile(sorted, .5) - 3)
  return bright - Math.min(2, .5 * excess)
}

// Native exporter supplies the levels table. Meter once over the same regional log-luminances as
// ToneBaseMeasurement, before either CPU or GPU tiling. Lab Scan's table carries a contrast per
// record and is solved before the edit's exposure, so `exposureEV` is taken out of the reading.
export function applyScreenLevels(configuration, meter, regionStops, exposureEV = 0) {
  if (!meter) return
  const metered = meteredHighlight(regionStops, Boolean(meter.labScan))
  if (metered === null) return
  const bright = meter.labScan ? metered - exposureEV : metered
  const samples = meter.adjustments
  if (!Array.isArray(samples) || samples.length < 2) throw new Error('Invalid screen conversion profile.')
  const position = Math.max(0, Math.min(1, (bright-meter.min)/(meter.max-meter.min))) * (samples.length-1)
  const i = Math.min(Math.floor(position), samples.length-2), t = position-i
  const row = samples[i].map((value, k) => value*(1-t) + samples[i+1][k]*t)
  const scales = row.length === 4 ? row.slice(0, 3) : [row[0], row[0], row[0]]
  const shift = row[row.length-1]
  if (![...scales, shift].every(Number.isFinite)) throw new Error('Invalid screen conversion levels.')
  for (let c=0;c<3;c++) configuration[CONFIG.MASKING+c] *= scales[c]
  for (const slot of [CONFIG.PAPER_MIDPOINT, CONFIG.PAPER_MIDPOINT_RED, CONFIG.PAPER_MIDPOINT_BLUE]) configuration[slot] += shift
}
