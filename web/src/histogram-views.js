// Plot metadata is separate from the controls catalogue and rendering code.
export const histogramViews = {
  rgb: {
    channels: [0, 1, 2],
    description: "Red, green and blue tonal distribution",
    legend: [["RGB", "luma"]],
    ticks: ["0", "64", "128", "192", "255"],
  },
  luma: {
    channels: [3],
    description: "Luma brightness distribution",
    legend: [["Luma Y′", "luma"]],
    ticks: ["0", "64", "128", "192", "255"],
  },
  chroma: {
    channels: [4, 5],
    description: "Chroma Cb and Cr color-difference distribution",
    legend: [
      ["Cb", "blue"],
      ["Cr", "red"],
    ],
    ticks: ["−0.5", "−0.25", "0", "+0.25", "+0.5"],
    centered: true,
  },
  "oklab-l": {
    channels: [6],
    description: "OKLab perceptual lightness distribution",
    legend: [["Lightness L", "luma"]],
    ticks: ["0", "0.25", "0.5", "0.75", "1"],
  },
  "oklab-ab": {
    channels: [7, 8],
    description: "OKLab a and b color-balance distribution",
    legend: [
      ["a · green–red", "a"],
      ["b · blue–yellow", "b"],
    ],
    ticks: ["−0.4", "−0.2", "0", "+0.2", "+0.4"],
    centered: true,
  },
};
export const histogramPalette = [
  "red",
  "green",
  "blue",
  "luma",
  "blue",
  "red",
  "luma",
  "a",
  "b",
];

// Round count limits upward so axes read 10 / 100 / 1k, not arbitrary sample peaks.
export function histogramCountAxis(peak, scale) {
  peak = Math.max(1, peak);
  if (scale === "log") {
    const max = 10 ** Math.ceil(Math.log10(peak));
    const ticks = [0];
    for (let n = 1; n <= max; n *= 10) ticks.push(n);
    return { max, ticks };
  }
  const magnitude = 10 ** Math.floor(Math.log10(peak / 4));
  const step = Math.max(
    1,
    [1, 2, 5, 10].find((n) => n * magnitude >= peak / 4) * magnitude,
  );
  const max = Math.ceil(peak / step) * step;
  return {
    max,
    ticks: Array.from(
      { length: Math.round(max / step) + 1 },
      (_, i) => i * step,
    ),
  };
}
export const histogramCountHeight = (count, max, scale) =>
  scale === "log" ? Math.log1p(count) / Math.log1p(max) : count / max;
