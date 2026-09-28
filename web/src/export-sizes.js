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
 * `output` (the cropped picture, the whole one by default). With `ofCrop` the sizes are of the
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
  const scaled = (edge) => {
    const pixels = exportPixels(edge, width, height, output, ofCrop);
    return `${pixels.width} × ${pixels.height}`;
  };
  if (!(long > 0)) return [{ id: "full", label: video ? "Source" : "Full resolution" }];
  const options = [
    { id: "full", label: video ? "Source" : "Full resolution", detail: scaled(long) },
  ];
  if (video) {
    for (const [label, edge] of VIDEO_EDGES)
      if (edge < long - 1)
        options.push({ id: String(edge), label, detail: scaled(edge) });
    return options;
  }
  for (const [label, fraction] of FRACTIONS) {
    const edge = Math.round(long * fraction);
    if (edge >= 640 && edge < long - 1)
      options.push({ id: String(fraction), label, detail: scaled(edge) });
  }
  for (const edge of STILL_EDGES)
    if (edge < long - 1)
      options.push({
        id: String(edge),
        label: `${edge} px long edge`,
        detail: scaled(edge),
      });
  return options;
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
