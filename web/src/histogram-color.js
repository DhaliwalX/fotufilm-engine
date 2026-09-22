// D65 matrices and OKLab conversion follow the W3C CSS Color 4 sample code:
// https://www.w3.org/TR/css-color-4/#color-conversion-code
const xyzToLms = [
  [0.819022437996703, 0.3619062600528904, -0.1288737815209879],
  [0.0329836539323885, 0.9292868615863434, 0.0361446663506424],
  [0.0481771893596242, 0.2642395317527308, 0.6335478284694309],
];
const rgbToXyz = {
  srgb: [
    [506752 / 1228815, 87881 / 245763, 12673 / 70218],
    [87098 / 409605, 175762 / 245763, 12673 / 175545],
    [7918 / 409605, 87881 / 737289, 1001167 / 1053270],
  ],
  "display-p3": [
    [608311 / 1250200, 189793 / 714400, 198249 / 1000160],
    [35783 / 156275, 247089 / 357200, 198249 / 2500400],
    [0, 32229 / 714400, 5220557 / 5000800],
  ],
};
const rgbToLms = Object.fromEntries(
  Object.entries(rgbToXyz).map(([space, matrix]) => [
    space,
    xyzToLms.map((row) =>
      [0, 1, 2].map((c) =>
        row.reduce((sum, v, i) => sum + v * matrix[i][c], 0),
      ),
    ),
  ]),
);
// Both display spaces use the sRGB transfer function. Decode before OKLab.
const linear = Float64Array.from({ length: 256 }, (_, i) => {
  const v = i / 255;
  return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
});
export function previewToOKLab(r, g, b, space = "srgb") {
  const matrix = rgbToLms[space];
  if (!matrix) throw new Error("Unsupported histogram color space.");
  const R = linear[r],
    G = linear[g],
    B = linear[b];
  const [l, m, s] = matrix.map((row) =>
    Math.cbrt(row[0] * R + row[1] * G + row[2] * B),
  );
  return [
    0.210454268309314 * l + 0.7936177747023054 * m - 0.0040720430116193 * s,
    1.9779985324311684 * l - 2.42859224204858 * m + 0.450593709617411 * s,
    0.0259040424655478 * l + 0.7827717124575296 * m - 0.8086757549230774 * s,
  ];
}
