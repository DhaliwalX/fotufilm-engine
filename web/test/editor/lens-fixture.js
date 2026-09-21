// Original synthetic calibration and metadata, never a measured/vendor lens corpus.
export const measuredProfile = {
  id: "fotufilm-synthetic-lens",
  maker: "Fotufilm",
  model: "Synthetic 35mm f/2",
  cropFactor: 1,
  source: "Project-authored test coefficients",
  calibrations: [
    {
      focalLength: 35,
      aperture: 2,
      distortion: { poly3: { k1: 0.08 } },
      vignetting: { radial: { k1: -0.2, k2: 0, k3: 0 } },
      lateralChroma: { linear: { red: 1.003, blue: 0.997 } },
    },
  ],
};
export const lensShot = {
  lensModel: "Synthetic 35mm f/2",
  lensMaker: "Fotufilm",
  cameraModel: "Synthetic DNG",
  focalLength: 35,
  aperture: 2,
};
export const captureTags = [
  [42036, 2, lensShot.lensModel],
  [42035, 2, lensShot.lensMaker],
  [37386, 5, [35]],
  [33437, 5, [2]],
];
export function lensOpcodes({ tangential = 0, center = 0.5 } = {}) {
  const warp = new Uint8Array(4 + 3 * 6 * 8 + 16),
    view = new DataView(warp.buffer);
  view.setUint32(0, 3);
  for (let c = 0; c < 3; c++)
    [1, 0.06 + c * 0.004, 0, 0, tangential, 0].forEach((value, i) =>
      view.setFloat64(4 + (c * 6 + i) * 8, value),
    );
  view.setFloat64(warp.length - 16, center);
  view.setFloat64(warp.length - 8, 0.5);
  const vignette = new Uint8Array(7 * 8),
    v = new DataView(vignette.buffer);
  [0.3, 0.1, 0, 0, 0, 0.5, 0.5].forEach((value, i) =>
    v.setFloat64(i * 8, value),
  );
  const bytes = new Uint8Array(4 + 32 + warp.length + vignette.length),
    all = new DataView(bytes.buffer);
  all.setUint32(0, 2);
  let offset = 4;
  for (const [id, payload] of [
    [1, warp],
    [3, vignette],
  ]) {
    all.setUint32(offset, id);
    all.setUint32(offset + 4, 0x01030000);
    all.setUint32(offset + 8, 1);
    all.setUint32(offset + 12, payload.length);
    bytes.set(payload, offset + 16);
    offset += 16 + payload.length;
  }
  return [...bytes];
}
