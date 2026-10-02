import { CONFIG } from './engine-constants.js'

// Where Auto Levels holds white, in stops over the scene's median, and the most it brightens a
// frame over the exposure it was taken at: DigitalReferenceReceiver.retimeWhiteSpan and
// retimeLiftLimit. A lamp clips, a fog is not stretched to white, a night stays dark.
export const RETIME_WHITE_SPAN = [2.5, 3.5]
export const RETIME_LIFT_LIMIT = 2.5
// The print's room in stops of scene light: white over the stop it prints mid-grey, and black with
// detail under white: DigitalReferenceReceiver.printWhiteOverGrey and printRange.
export const PRINT_WHITE_OVER_GREY = 3
export const PRINT_RANGE = 6.3
// How much of its overflow the shadow end is lifted by: DigitalReferenceReceiver.shadowLiftShare.
export const SHADOW_LIFT_SHARE = 0.75
// How much of a colour negative's cast Auto Levels takes out, and the largest cast it reads, in
// stops: DigitalReferenceReceiver.autoColourShare and autoColourReach.
export const AUTO_COLOUR_SHARE = 0.5
export const AUTO_COLOUR_REACH = 2

function percentiles(regionStops) {
  const sorted = Array.from(regionStops || []).filter(Number.isFinite).sort((a,b) => a-b)
  if (!sorted.length) return null
  return q => {
    const p = q * (sorted.length - 1), low = Math.floor(p)
    return sorted[low] + (p-low) * (sorted[Math.min(low+1, sorted.length-1)]-sorted[low])
  }
}

// The highlight Auto Levels re-times a frame on, as DigitalReferenceReceiver.retimeHighlight
// reads it from the same regional log-luminances, metered after the edit's exposure: the 99.5th
// percentile, held inside RETIME_WHITE_SPAN over the median and lifting the frame no more than
// RETIME_LIFT_LIMIT. Null for an empty measurement.
export function retimeHighlight(regionStops, exposureEV = 0) {
  const percentile = percentiles(regionStops)
  if (!percentile) return null
  const median = percentile(.5)
  const white = Math.min(Math.max(percentile(.995), median + RETIME_WHITE_SPAN[0]),
                         median + RETIME_WHITE_SPAN[1])
  return Math.max(white, exposureEV + PRINT_WHITE_OVER_GREY - RETIME_LIFT_LIMIT)
}

// The tone reading Auto Levels takes, as ToneBaseMeasurement hands it on: the frame's median and
// its two ends, the 0.5th and 99.5th percentiles. Null for an empty measurement.
export function toneStops(regionStops) {
  const percentile = percentiles(regionStops)
  return percentile ? [percentile(.5), percentile(.005), percentile(.995)] : null
}

// The highlight hold and shadow lift Auto Levels gives a negative whose ends reach past the print
// from `white`, as DigitalReferenceReceiver.toneCompression does: each end pulled in by the stops
// it reaches past, by the same rule, the shadows by SHADOW_LIFT_SHARE of them.
export function toneCompression([, dark, bright], white) {
  const amount = (overflow, room) => {
    if (!(overflow > 0)) return 0
    const t = Math.min((room + overflow) / 6, 1)
    return Math.min(overflow / (3 * t * t * (3 - 2 * t)), 1)
  }
  return {
    hold: amount(bright - white, PRINT_WHITE_OVER_GREY),
    lift: SHADOW_LIFT_SHARE * amount(white - PRINT_RANGE - dark, PRINT_RANGE - PRINT_WHITE_OVER_GREY),
  }
}

// The extra film exposure Auto Levels gives an under-exposed negative, as
// DigitalReferenceReceiver.filmBoost does: what puts its print grey on the film's grey, more for a
// dark frame and less for a bright one.
export function filmBoost(white, exposureEV = 0) {
  return exposureEV - (white - PRINT_WHITE_OVER_GREY)
}

// The frame's colour as ToneBaseMeasurement.channelMedians reads it: green's median over the lit
// regions, red and blue off it by the median of each lit region's own ratio to green. A region is
// lit above the frame's lower quartile and clear of the meter's floor, -12 stops.
export function channelMedians(regionStops, channelStops) {
  if (!regionStops || !channelStops || channelStops.length !== 3) return null
  const quartile = percentiles(regionStops)?.(.25)
  if (!Number.isFinite(quartile)) return null
  const floor = Math.max(quartile, -12)
  const lit = Array.from(regionStops).flatMap((luma, i) =>
    luma >= floor ? [channelStops.map(stops => stops[i])] : [])
  const median = values => percentiles(values)?.(.5)
  const green = median(lit.map(c => c[1]))
  const red = median(lit.map(c => c[0] - c[1])), blue = median(lit.map(c => c[2] - c[1]))
  return [green + red, green, green + blue].every(Number.isFinite)
    ? [green + red, green, green + blue] : null
}

// A meter table's value at `stops`, interpolated and held at its ends.
function tabulated(meter, samples, stops) {
  const position = Math.max(0, Math.min(1, (stops-meter.min)/(meter.max-meter.min))) * (samples.length-1)
  const i = Math.min(Math.floor(position), samples.length-2), t = position-i
  const at = (a, b) => a*(1-t) + b*t
  return Array.isArray(samples[i]) ? samples[i].map((v, k) => at(v, samples[i+1][k])) : at(samples[i], samples[i+1])
}

// Auto Levels' red and blue shifts, as DigitalReferenceReceiver.autoColourShift reads them from
// the stock's record reads the meter carries. Zero where the stock keeps its colour.
export function autoColourShift(meter, medians, exposureEV = 0) {
  if (!Array.isArray(meter?.reads) || meter.reads.length < 2 || !medians) return [0, 0]
  const read = stops => tabulated(meter, meter.reads, stops)
  const green = medians[1] - exposureEV
  const shift = median => {
    const cast = Math.min(Math.max(median - exposureEV - green, -AUTO_COLOUR_REACH), AUTO_COLOUR_REACH)
    return AUTO_COLOUR_SHARE * (read(green) - read(green + cast))
  }
  return [shift(medians[0]), shift(medians[2])]
}

// Lab Scan's dodging, as LabScanTiming.dodge reads it: a frame whose ends reach further from its
// median than a print holds has its bright regions held and its dark regions lifted, in the tone
// controls' units, keyed regionally on the median. Null for an empty measurement.
const DODGE_HIGHLIGHT_SPAN = 2.5, DODGE_SHADOW_SPAN = 3.5, DODGE_RAMP = 3
const DODGE_MAX_HOLD = .25, DODGE_MAX_LIFT = .2
export function labScanDodge(regionStops) {
  const percentile = percentiles(regionStops)
  if (!percentile) return null
  const median = percentile(.5)
  const ramp = (reach, span) => Math.min(Math.max((reach - span) / DODGE_RAMP, 0), 1)
  return {
    hold: DODGE_MAX_HOLD * ramp(percentile(.995) - median, DODGE_HIGHLIGHT_SPAN),
    lift: DODGE_MAX_LIFT * ramp(median - percentile(.005), DODGE_SHADOW_SPAN),
    key: median,
  }
}

// The highlight Lab Scan sets its white point on, as LabScanTiming.meteredHighlight reads it from
// the same regional log-luminances: the 99.5th percentile, lowered by half its excess over three
// stops above the median, at most two stops, then by what the dodge's hold takes from it. Null for
// an empty measurement.
export function labScanHighlight(regionStops) {
  const percentile = percentiles(regionStops)
  if (!percentile) return null
  const bright = percentile(.995)
  const excess = Math.max(0, bright - percentile(.5) - 3)
  const highlight = bright - Math.min(2, .5 * excess)
  const { hold, key } = labScanDodge(regionStops)
  const reach = Math.min(Math.max((highlight - key) / 6, 0), 1)
  return highlight - 3 * hold * reach * reach * (3 - 2 * reach)
}

// Lab Scan's levels: its table carries a contrast per record and is solved before the edit's
// exposure, so `exposureEV` is taken out of the reading. Its dodge rides the tone controls; returns
// the median it keys them on while it dodges, or null.
function applyLabScanLevels(configuration, meter, regionStops, exposureEV) {
  const metered = labScanHighlight(regionStops)
  if (metered === null) return null
  const { hold, lift, key } = labScanDodge(regionStops)
  const samples = meter.adjustments
  if (!Array.isArray(samples) || samples.length < 2) throw new Error('Invalid screen conversion profile.')
  const row = tabulated(meter, samples, metered - exposureEV)
  const scales = row.length === 4 ? row.slice(0, 3) : [row[0], row[0], row[0]]
  const shift = row[row.length-1]
  if (![...scales, shift].every(Number.isFinite)) throw new Error('Invalid screen conversion levels.')
  for (let c=0;c<3;c++) configuration[CONFIG.MASKING+c] *= scales[c]
  for (const slot of [CONFIG.PAPER_MIDPOINT, CONFIG.PAPER_MIDPOINT_RED, CONFIG.PAPER_MIDPOINT_BLUE]) configuration[slot] += shift
  const shadows = configuration[CONFIG.SHADOWS], highlights = configuration[CONFIG.HIGHLIGHTS]
  configuration[CONFIG.SHADOWS] = shadows + Math.min(lift, Math.max(1 - shadows, 0))
  configuration[CONFIG.HIGHLIGHTS] = highlights - Math.min(hold, Math.max(highlights + 1, 0))
  return hold || lift ? key : null
}

// Native exporter supplies the receiver affine. Meter once over the same regional
// log-luminances as ToneBaseMeasurement, before either CPU or GPU tiling. The regions are
// metered after the edit's exposure; the re-time takes the frame before it, so that exposure
// still shows, as DigitalReferenceReceiver.levels does. Returns the scene stop a negative's print
// takes for mid-grey, which keys the tone controls, or null where nothing keys them.
export function applyScreenLevels(configuration, meter, regionStops, exposureEV = 0,
                                  channelStops = null) {
  if (!meter) return null
  if (meter.labScan) return applyLabScanLevels(configuration, meter, regionStops, exposureEV)
  const metered = retimeHighlight(regionStops, exposureEV)
  if (metered === null) return null
  const samples = meter.adjustments
  if (!Array.isArray(samples) || samples.length < 2) throw new Error('Invalid screen conversion profile.')
  const boost = meter.placesFilm ? filmBoost(metered, exposureEV) : 0
  const { hold, lift } = meter.placesFilm
    ? toneCompression(toneStops(regionStops), metered) : { hold: 0, lift: 0 }
  const [scale, shift] = tabulated(meter, samples, metered + boost - exposureEV)
  const medians = channelMedians(regionStops, channelStops)?.map(stops => stops + boost) ?? null
  const [red, blue] = autoColourShift(meter, medians, exposureEV)
  if (![scale, shift, red, blue].every(Number.isFinite)) throw new Error('Invalid screen conversion levels.')
  const shadows = configuration[CONFIG.SHADOWS], highlights = configuration[CONFIG.HIGHLIGHTS]
  configuration[CONFIG.EXPOSURE_GAIN] *= 2 ** boost
  configuration[CONFIG.SHADOWS] = shadows + Math.min(lift, Math.max(1 - shadows, 0))
  configuration[CONFIG.HIGHLIGHTS] = highlights - Math.min(hold, Math.max(highlights + 1, 0))
  for (let c=0;c<3;c++) configuration[CONFIG.MASKING+c] *= scale
  configuration[CONFIG.PAPER_MIDPOINT] += shift
  configuration[CONFIG.PAPER_MIDPOINT_RED] += shift + red
  configuration[CONFIG.PAPER_MIDPOINT_BLUE] += shift + blue
  return meter.placesFilm ? metered - PRINT_WHITE_OVER_GREY + boost : null
}
