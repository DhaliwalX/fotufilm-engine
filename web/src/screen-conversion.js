import { CONFIG } from './engine-constants.js'

// Native exporter supplies the receiver affine. Meter once over the same regional
// log-luminances as ToneBaseMeasurement, before either CPU or GPU tiling.
export function applyScreenLevels(configuration, meter, regionStops) {
  if (!meter || !regionStops?.length) return
  const sorted = Array.from(regionStops).filter(Number.isFinite).sort((a,b) => a-b)
  if (!sorted.length) return
  const p = .995 * (sorted.length - 1), low = Math.floor(p)
  const bright = sorted[low] + (p-low) * (sorted[Math.min(low+1, sorted.length-1)]-sorted[low])
  const samples = meter.adjustments
  if (!Array.isArray(samples) || samples.length < 2) throw new Error('Invalid screen conversion profile.')
  const position = Math.max(0, Math.min(1, (bright-meter.min)/(meter.max-meter.min))) * (samples.length-1)
  const i = Math.min(Math.floor(position), samples.length-2), t = position-i
  const scale = samples[i][0]*(1-t)+samples[i+1][0]*t
  const shift = samples[i][1]*(1-t)+samples[i+1][1]*t
  if (!Number.isFinite(scale) || !Number.isFinite(shift)) throw new Error('Invalid screen conversion levels.')
  for (let c=0;c<3;c++) configuration[CONFIG.MASKING+c] *= scale
  for (const slot of [CONFIG.PAPER_MIDPOINT, CONFIG.PAPER_MIDPOINT_RED, CONFIG.PAPER_MIDPOINT_BLUE]) configuration[slot] += shift
}
