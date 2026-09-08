// Develops frames of sizes the pack was not sealed for, whole and in tiles, through the CPU module
// in Node — the same code path the browser takes in web/src/engine.js, so what is checked here is
// the browser's tiling and the pack's size ladder, not just the kernel.
//
// Two things must hold. A frame cut into tiles, each carrying the pack's apron for that size, must
// come out byte for byte as the same frame developed in one piece — that is the contract the
// kernel's origin parameters make, and the only way a hundred-megapixel frame can be developed at
// all. And a frame far from the pack's own size must pick a different rung of the ladder, with the
// feature mask that size asks for, and a kernel must exist for it.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { loadPack, SimdDeveloper, pixelSource, planTiles, sizeEntryFor } from '../web/src/engine.js';

const assets = new URL('../web/public/', import.meta.url);
globalThis.window = {};
globalThis.fetch = async (url) => new Response(await readFile(new URL(url)), {
  headers: { 'Content-Type': 'application/wasm' },
});
const { default: create } = await import(new URL('fotufilm.mjs', assets));
const module = await create();
const stocks = JSON.parse(await readFile(new URL('packs/index.json', assets)));

/// A scene with something for every stage to read across a tile edge: a gradient, a hard-edged
/// highlight, and a dark field for halation to spill into.
function scene(width, height) {
  const data = new Uint8ClampedArray(width * height * 4);
  for (let y = 0; y < height; ++y) {
    for (let x = 0; x < width; ++x) {
      const i = (y * width + x) * 4;
      const inBox = x > width * 0.4 && x < width * 0.6 && y > height * 0.3 && y < height * 0.7;
      data[i] = inBox ? 250 : 20 + (200 * x) / width;
      data[i + 1] = inBox ? 245 : 30 + (150 * y) / height;
      data[i + 2] = inBox ? 230 : 40;
      data[i + 3] = 255;
    }
  }
  return pixelSource({ data, width, height });
}

// The plan itself, before any kernel runs.
{
  const one = planTiles(1600, 900, 40, 2_000_000);
  assert.equal(one.length, 1, 'a frame within budget is one tile');
  assert.deepEqual(one[0].region, { x: 0, y: 0, width: 1600, height: 900 });
  const many = planTiles(1000, 700, 30, 300 * 300);
  const covered = new Uint8Array(1000 * 700);
  for (const tile of many) {
    assert.ok(tile.region.x <= tile.x && tile.region.y <= tile.y, 'region contains the tile');
    assert.ok(tile.region.x + tile.region.width >= tile.x + tile.width);
    assert.ok(tile.region.y + tile.region.height >= tile.y + tile.height);
    assert.ok(tile.region.width * tile.region.height <= 300 * 300, 'region within budget');
    for (let y = tile.y; y < tile.y + tile.height; ++y) {
      for (let x = tile.x; x < tile.x + tile.width; ++x) covered[y * 1000 + x] += 1;
    }
  }
  assert.ok(covered.every((c) => c === 1), 'tiles cover the frame exactly once');
  console.log(`tiling plan: ${many.length} tiles for 1000×700 at a 300² budget`);
}

for (const { id } of stocks) {
  const pack = await loadPack(new URL(`packs/${id}.pack`, assets));
  assert.ok(pack.ladder.length > 10, `${id}: the pack carries a size ladder`);
  const developer = new SimdDeveloper(module, pack);
  try {
    // Whole against tiled, at a size with rungs on either side of it.
    const width = 176, height = 128;
    const rung = sizeEntryFor(pack, width, height);
    assert.ok(rung.spatialSupport >= 0, `${id}: rung carries an apron`);
    const source = scene(width, height);
    developer.tileBudget = Infinity;
    const whole = await developer.develop(source, { ev: 0.3, grain: 1 });
    assert.equal(developer.tiles.length, 1);
    assert.equal(developer.configuration[developer.frameSizeSlot], width);
    assert.equal(developer.configuration[developer.frameSizeSlot + 1], height);
    developer.tileBudget = 1;  // the smallest tiles the planner will cut
    developer.width = 0;       // force a new plan at the same size
    const tiled = await developer.develop(source, { ev: 0.3, grain: 1 });
    assert.ok(developer.tiles.length > 1, `${id}: the frame was cut (${developer.tiles.length} tiles)`);
    assert.ok(whole.pixels.some((v, i) => i % 4 !== 3 && v > 8), `${id}: flat output`);
    let differing = 0;
    for (let i = 0; i < whole.pixels.length; ++i) if (whole.pixels[i] !== tiled.pixels[i]) differing++;
    assert.equal(differing, 0,
      `${id}: ${differing} of ${whole.pixels.length} bytes differ between whole and tiled develops`);

    // A frame the size of a camera's, far from the pack's 900 px short edge: another rung, and a
    // kernel built for whatever mask it asks for.
    developer.tileBudget = 2_000_000;
    developer.width = 0;
    const large = { width: 2400, height: 1600 };
    const largeRung = sizeEntryFor(pack, large.width, large.height);
    assert.notEqual(largeRung.shortEdge, rung.shortEdge, `${id}: a different rung for 1600 px`);
    developer.setFrame(large.width, large.height);
    assert.ok(developer.tiles.length >= 2, `${id}: 2400×1600 is cut into tiles`);
    const corner = developer.tiles[developer.tiles.length - 1];
    // One tile only — the whole frame on the CPU would take a while per stock — with a source
    // that reads flat grey wherever it is asked.
    const grey = { width: large.width, height: large.height,
                   read: (x, y, w, h) => new Uint8ClampedArray(w * h * 4).fill(120) };
    developer.tiles = [corner];
    const { pixels } = await developer.develop(grey, {});
    const at = ((corner.y + 1) * large.width + corner.x + 1) * 4;
    assert.ok(pixels[at] > 0 || pixels[at + 1] > 0 || pixels[at + 2] > 0, `${id}: the tile developed`);
    console.log(`${id}: tiled develop matches whole (${tiled.pixels.length / 4} px, apron ${rung.spatialSupport}); `
      + `rung ${largeRung.shortEdge} px mask ${largeRung.featureMask} apron ${largeRung.spatialSupport} ok`);
  } finally {
    developer.dispose();
  }
}
