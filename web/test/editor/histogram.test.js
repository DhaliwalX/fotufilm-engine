import { previewToOKLab } from "../../src/histogram-color.js";
import {
  histogramCountAxis,
  histogramCountHeight,
} from "../../src/histogram-views.js";
import test from "node:test";
import assert from "node:assert/strict";
import { histogramStatistics } from "../../src/histogram-model.js";
import { smoothHistogram } from "../../src/histogram-curves.js";
import { constrainPanel } from "../../src/use-floating-panel.js";

test("RGB counts exclude transparent pixels and leave source pixels unchanged", () => {
  const data = new Uint8ClampedArray([
    0, 0, 0, 255, 255, 80, 60, 255, 64, 64, 64, 255, 128, 128, 128, 0,
  ]);
  const original = data.slice();
  const result = histogramStatistics({ data });
  assert.equal(result.count, 3);
  assert.equal(result.bins[0][255], 1);
  assert.equal(result.bins[1][80], 1);
  assert.equal(result.bins[2][60], 1);
  for (const channel of result.bins) {
    assert.equal(channel[128], 0);
    assert.equal(
      channel.reduce((a, b) => a + b),
      3,
    );
  }
  assert.deepEqual(data, original);
});
test("an empty preview has zero counts in every RGB bin", () => {
  const result = histogramStatistics({ data: new Uint8ClampedArray(4) });
  assert.equal(result.count, 0);
  assert.equal(result.bins.length, 3);
  for (const channel of result.bins) assert.ok(channel.every((n) => n === 0));
});
test("floating panels remain reachable after a viewport shrinks below their minimum size", () => {
  const r = constrainPanel(
    { x: 800, y: 600, width: 900, height: 700 },
    { width: 240, height: 260 },
  );
  assert.ok(r.x >= 0 && r.y >= 0);
  assert.ok(r.width + r.x <= 240 && r.height + r.y <= 260);
  const small = constrainPanel(r, { width: 10, height: 10 });
  assert.ok(small.x + small.width <= 10);
});

test("luma follows preview primaries and chroma keeps all neutral tones centred", () => {
  const data = new Uint8ClampedArray([
    255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255,
  ]);
  const srgb = histogramStatistics({ data, colorSpace: "srgb" });
  const p3 = histogramStatistics({ data, colorSpace: "display-p3" });
  for (const bin of [54, 182, 18]) assert.equal(srgb.luma[bin], 1);
  for (const bin of [58, 176, 20]) assert.equal(p3.luma[bin], 1);
  assert.equal(srgb.chroma[0][255], 1); // Blue endpoint.
  assert.equal(srgb.chroma[1][255], 1); // Red endpoint.
  for (const result of [srgb, p3]) {
    for (const bins of [result.luma, ...result.chroma])
      assert.equal(
        bins.reduce((a, b) => a + b),
        3,
      );
  }
  const neutral = new Uint8ClampedArray(
    Array.from({ length: 256 }, (_, i) => [i, i, i, 255]).flat(),
  );
  for (const colorSpace of ["srgb", "display-p3"]) {
    const result = histogramStatistics({ data: neutral, colorSpace });
    assert.ok(result.luma.every((count) => count === 1));
    for (const bins of result.chroma) assert.equal(bins[128], 256);
  }
});
test("curve smoothing conserves counts, retains endpoint peaks and never changes raw data", () => {
  for (const position of [0, 1, 128, 254, 255]) {
    const raw = new Uint32Array(256);
    raw[position] = 256;
    const original = raw.slice();
    const smoothed = smoothHistogram(raw);
    assert.equal(
      smoothed.reduce((a, b) => a + b),
      256,
    );
    assert.ok(smoothed.every((value) => Number.isFinite(value) && value >= 0));
    assert.ok(Math.max(...smoothed) < 256);
    assert.deepEqual(raw, original);
    if (position === 0 || position === 255)
      assert.equal(smoothed[position], Math.max(...smoothed));
  }
  assert.ok(
    smoothHistogram(new Uint32Array(256).fill(12)).every((n) => n === 12),
  );
});

test("OKLab reference colours use linear light and preserve neutral axes in both preview spaces", () => {
  const close = (actual, expected, tolerance = 0.000002) =>
    actual.forEach((v, c) =>
      assert.ok(
        Math.abs(v - expected[c]) < tolerance,
        `${v} != ${expected[c]}`,
      ),
    );
  // Reference primary conversions using Ottosson's published linear-sRGB matrix.
  close(previewToOKLab(255, 0, 0), [0.62795536, 0.22486306, 0.1258463]);
  close(previewToOKLab(0, 255, 0), [0.86643961, -0.23388757, 0.17949848]);
  close(previewToOKLab(0, 0, 255), [0.45201372, -0.03245698, -0.31152815]);
  close(previewToOKLab(128, 128, 128), [0.5998708, 0, 0]);
  assert.notDeepEqual(
    previewToOKLab(255, 0, 0, "srgb"),
    previewToOKLab(255, 0, 0, "display-p3"),
  );
  for (const colorSpace of ["srgb", "display-p3"]) {
    close(previewToOKLab(255, 255, 255, colorSpace), [1, 0, 0]);
    close(previewToOKLab(0, 0, 0, colorSpace), [0, 0, 0]);
    const data = new Uint8ClampedArray(
      Array.from({ length: 256 }, (_, i) => [i, i, i, 255]).flat(),
    );
    const result = histogramStatistics({ data, colorSpace });
    assert.equal(result.oklab[0][0], 1);
    assert.equal(result.oklab[0][255], 1);
    for (const channel of result.oklab)
      assert.equal(
        channel.reduce((a, b) => a + b),
        256,
      );
    assert.equal(result.oklab[1][128], 256);
    assert.equal(result.oklab[2][128], 256);
  }
});
test("count axes have readable steps, include all peaks and remain finite for empty data", () => {
  assert.deepEqual(histogramCountAxis(809, "log"), {
    max: 1000,
    ticks: [0, 1, 10, 100, 1000],
  });
  assert.deepEqual(histogramCountAxis(809, "linear"), {
    max: 1000,
    ticks: [0, 500, 1000],
  });
  for (const peak of [0, 1, 2, 9, 11, 809, 1000, 1001, 65536])
    for (const scale of ["log", "linear"]) {
      const { max, ticks } = histogramCountAxis(peak, scale);
      assert.ok(max >= peak);
      assert.equal(ticks[0], 0);
      assert.equal(ticks.at(-1), max);
      assert.equal(histogramCountHeight(0, max, scale), 0);
      assert.equal(histogramCountHeight(max, max, scale), 1);
      assert.ok(
        ticks.every((n, i) => Number.isInteger(n) && (!i || n > ticks[i - 1])),
      );
    }
});
