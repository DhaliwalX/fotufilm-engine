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
 * The sizes for an upright picture of `width` x `height`; each names the pixels it delivers of
 * `output` (the cropped picture, the whole one by default).
 */
export function exportSizeOptions(width, height, video = false, output = { width, height }) {
  const long = Math.max(width, height);
  const scaled = (edge) => {
    const scale = Math.min(1, edge / long);
    return `${Math.max(1, Math.round(output.width * scale))} × ${Math.max(1, Math.round(output.height * scale))}`;
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

/** The long edge an export size asks for, Infinity for the full picture. */
export function exportMaxEdge(size, width, height) {
  const value = Number(size);
  if (size === "full" || !Number.isFinite(value) || value <= 0) return Infinity;
  return value < 1 ? Math.round(Math.max(width, height) * value) : value;
}
