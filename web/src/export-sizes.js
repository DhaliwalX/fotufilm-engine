// Export sizes, as the Mac app offers them: the full picture, then Large, Medium and Small at
// 75, 50 and 25 per cent of it where that is still a useful picture, then the long edges the web
// editor has always offered. A movie offers the source and the usual video sizes. An id is
// "full", a fraction ("0.75") or a long edge in pixels ("3840").
const FRACTIONS = [
  ["Large", 0.75],
  ["Medium", 0.5],
  ["Small", 0.25],
];
const STILL_EDGES = [3840, 2048, 1600];
const VIDEO_EDGES = [
  ["4K", 3840],
  ["1440p", 2560],
  ["1080p", 1920],
  ["720p", 1280],
];

/**
 * The pixels of `output` (the cropped picture) an export whose long edge is `edge` delivers from
 * an upright picture of `width` x `height`. A backend with `longEdgeOfCrop` measures the edge on
 * the cropped picture and rounds outward, as the Mac app does; others measure the whole picture.
 */
export function exportPixels(edge, width, height, output = { width, height }, ofCrop = false) {
  if (!ofCrop) {
    const scale = Math.min(1, edge / Math.max(width, height));
    return {
      width: Math.max(1, Math.round(output.width * scale)),
      height: Math.max(1, Math.round(output.height * scale)),
    };
  }
  const long = Math.max(output.width, output.height);
  if (!(edge < long - 0.5)) return { width: output.width, height: output.height };
  const outward = (length) => Math.max(1, Math.ceil((length * edge) / long - 1e-6));
  return { width: outward(output.width), height: outward(output.height) };
}

/**
 * The sizes for an upright picture of `width` x `height`; each names the pixels it delivers of
 * `output` (the cropped picture, the whole one by default), as `detail` and as `pixels`. With `ofCrop` the sizes are of the
 * cropped picture, whose long edge the backend measures.
 */
export function exportSizeOptions(
  width,
  height,
  video = false,
  output = { width, height },
  ofCrop = false,
) {
  const long = ofCrop ? Math.max(output.width, output.height) : Math.max(width, height);
  const size = (id, label, edge) => {
    const pixels = exportPixels(edge, width, height, output, ofCrop);
    return { id, label, detail: `${pixels.width} × ${pixels.height}`, pixels };
  };
  if (!(long > 0)) return [{ id: "full", label: video ? "Source" : "Full resolution" }];
  const options = [size("full", video ? "Source" : "Full resolution", long)];
  if (video) {
    for (const [label, edge] of VIDEO_EDGES)
      if (edge < long - 1) options.push(size(String(edge), label, edge));
    return options;
  }
  for (const [label, fraction] of FRACTIONS) {
    const edge = Math.round(long * fraction);
    if (edge >= 640 && edge < long - 1) options.push(size(String(fraction), label, edge));
  }
  for (const edge of STILL_EDGES)
    if (edge < long - 1) options.push(size(String(edge), `${edge} px long edge`, edge));
  return options;
}

/**
 * The sizes Export All offers, the same ids as one photograph's (`exportSizeOptions`), each
 * applied to every photograph's own cropped picture; a size at or past a picture's own delivers
 * the whole picture.
 */
export function batchExportSizeOptions() {
  return [
    { id: "full", label: "Full resolution" },
    ...FRACTIONS.map(([label, fraction]) => ({
      id: String(fraction),
      label,
      detail: `${fraction * 100}%`,
    })),
    ...STILL_EDGES.map((edge) => ({ id: String(edge), label: `${edge} px long edge` })),
  ];
}

/**
 * The long edge an export size asks for, Infinity for the full picture: a fraction is of the
 * picture the backend measures, `width` x `height` (`exportBasis`).
 */
export function exportMaxEdge(size, width, height) {
  const value = Number(size);
  if (size === "full" || !Number.isFinite(value) || value <= 0) return Infinity;
  return value < 1 ? Math.round(Math.max(width, height) * value) : value;
}

/** The picture export sizes are measured on: the cropped one with `ofCrop`, else the whole. */
export function exportBasis(width, height, output, ofCrop = false) {
  return ofCrop ? [output.width, output.height] : [width, height];
}

/**
 * The Mac app's note when the full picture exceeds the backend's memory limit (`unavailable`
 * ids): which smaller size stands in, or that none can. Null when the full picture is available.
 */
export function resolutionLimitWarning(sizes, selected, unavailable = []) {
  if (!unavailable.includes("full")) return null;
  const size = sizes.find(({ id }) => id === selected && !unavailable.includes(id));
  if (!size)
    return "Resolution unavailable: This image exceeds this device’s safe memory limit at every export size.";
  return `Resolution reduced: Full resolution exceeds this device’s safe memory limit. ${size.label} (${size.detail}) is selected instead, so the export will contain fewer pixels.`;
}
