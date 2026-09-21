import test from 'node:test';
import assert from 'node:assert/strict';
import { visiblePhotoViewport, viewportPlacement } from '../../src/viewport.js';
import { planRegionTiles, frameRegion, developNormalReference, pixelSource } from '../../src/engine.js';

test('zoom and DPR change image scale while delivery stays bounded to visible device pixels', () => {
  const options = { room: [1000, 700], displayWidth: 900, displayHeight: 600,
    offset: [0, 0], pixelRatio: 2 };
  const fit = visiblePhotoViewport({ ...options, zoom: 1 });
  assert.deepEqual(fit.region, { x: 0, y: 0, width: 1800, height: 1200 });
  const zoom = visiblePhotoViewport({ ...options, zoom: 8 });
  assert.equal(zoom.width, 14400);
  assert.equal(zoom.height, 9600);
  assert.equal(zoom.region.width, 2000);
  assert.equal(zoom.region.height, 1400);
  const pan = visiblePhotoViewport({ ...options, zoom: 8, offset: [100, -50] });
  assert.equal(pan.region.x, zoom.region.x - 200);
  assert.equal(pan.region.y, zoom.region.y + 100);
});

test('framed photos map the native bottom-left placement into visible image coordinates', () => {
  const v = visiblePhotoViewport({ room: [1000, 700], displayWidth: 800, displayHeight: 600,
    zoom: 1, offset: [0, 0], pixelRatio: 1,
    framePlan: { placement: { size: { width: 800, height: 600 },
      image: { x: 80, y: 120, width: 640, height: 420 } } } });
  assert.deepEqual(v.region, { x: 0, y: 0, width: 640, height: 420 });
  assert.deepEqual(viewportPlacement(v), { left: '10%', top: '10%', width: '80%', height: '70%' });
});

test('visible tiles include neighboring support and never allocate offscreen output', () => {
  const region = { x: 4980, y: 3010, width: 1024, height: 768 };
  const tiles = planRegionTiles(12000, 8000, 32, 150000, region);
  assert.equal(tiles.reduce((n, t) => n + t.width * t.height, 0), 1024 * 768);
  for (const tile of tiles) {
    assert.equal(tile.region.x, tile.x - 32);
    assert.equal(tile.region.y, tile.y - 32);
    assert.equal(tile.region.width, tile.width + 64);
    assert.equal(tile.region.height, tile.height + 64);
  }
  assert.throws(() => frameRegion(10, 10, { x: -1, y: 0, width: 5, height: 5 }));
});

test('Normal fallback ROI is exactly a full-frame crop with global tone and dither coordinates', async () => {
  const width = 83, height = 61;
  const data = new Float32Array(width * height * 4);
  for (let p = 0; p < width * height; p++) data.set([p / 4000, (p % width) / width, 0.2, 1], p * 4);
  const source = pixelSource({ width, height, data });
  const controls = { highlights: -0.2, shadows: 0.3, localTone: true };
  const region = { x: 17, y: 9, width: 31, height: 43 };
  for (const bitDepth of [8, 16]) {
    const full = await developNormalReference(source, controls, undefined, undefined, { bitDepth });
    const roi = await developNormalReference(source, controls, undefined, undefined, { bitDepth, region });
    const crop = pixelSource({ width, height, data: full.pixels }).read(region.x, region.y, region.width, region.height);
    assert.deepEqual(roi.pixels, crop);
  }
});

test('visible detail leaves the emulsion frame overlay intact at the photo edge', () => {
  const v = visiblePhotoViewport({ room: [1200, 900], displayWidth: 1000, displayHeight: 800,
    zoom: 1, offset: [0, 0], pixelRatio: 2,
    framePlan: { configuration: { frame: 'emulsion' }, placement: { size: { width: 1000, height: 800 },
      image: { x: 100, y: 100, width: 800, height: 600 } } } });
  assert.deepEqual(v.region, { x: 54, y: 54, width: 1492, height: 1092 });
});
