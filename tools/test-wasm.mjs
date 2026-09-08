// Exercise the browser-targeted module in Node using local files for its fetches.
// No server or browser installation is needed for this render check.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const assets = new URL('../web/public/', import.meta.url);
globalThis.window = {};
globalThis.fetch = async (url) => new Response(await readFile(new URL(url)), {
  headers: { 'Content-Type': 'application/wasm' },
});
const { default: create } = await import(new URL('fotufilm.mjs', assets));
const engine = await create();
const stocks = JSON.parse(await readFile(new URL('packs/index.json', assets)));
assert.ok(stocks.length > 0, 'No exported stock packs');

for (const { id } of stocks) {
  const bytes = await readFile(new URL(`packs/${id}.pack`, assets));
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  assert.equal(bytes.toString('ascii', 0, 4), 'FSWP');
  assert.equal(view.getUint32(4, true), 1);
  const configCount = view.getInt32(24, true);
  const lutCount = view.getInt32(32, true);
  assert.equal(configCount, engine._fotufilm_wasm_configuration_count());
  assert.equal(lutCount, engine._fotufilm_wasm_lut_count());
  assert.equal(bytes.length, 40 + 4 * (configCount + 3 * lutCount));

  const pointers = [];
  const allocate = (values) => {
    const pointer = engine._malloc(values.length * 4);
    assert.ok(pointer, 'WASM allocation failed');
    pointers.push(pointer);
    engine.HEAPF32.set(values, pointer / 4);
    return pointer;
  };
  let offset = 40;
  const take = (count) => {
    const start = bytes.byteOffset + offset;
    offset += count * 4;
    return allocate(new Float32Array(bytes.buffer.slice(start, start + count * 4)));
  };

  try {
    const width = 32, height = 24, count = width * height * 3;
    const input = Float32Array.from({ length: count }, (_, i) =>
      0.02 + 0.85 * (i % width) / (width - 1));
    const inputPtr = allocate(input);
    const outputPtr = allocate(new Float32Array(count));
    const densityPtr = allocate(new Float32Array(count));
    const configuration = take(configCount);
    const exposure = take(lutCount), film = take(lutCount), paper = take(lutCount);
    const render = () => {
      const status = engine._fotufilm_wasm_cpu_render(
        inputPtr, outputPtr, width, height, configuration, exposure, film, paper,
        densityPtr, view.getInt32(16, true), view.getUint32(20, true));
      assert.equal(status, 0, `${id}: render failed`);
      return engine.HEAPF32.slice(outputPtr / 4, outputPtr / 4 + count);
    };
    const output = render();
    assert.ok(output.every(Number.isFinite), `${id}: nonfinite output`);
    assert.ok(Math.max(...output) - Math.min(...output) > 0.001, `${id}: flat output`);
    assert.deepEqual(render(), output, `${id}: seeded render changed between calls`);
    console.log(`${id}: WASM render passed`);
  } finally {
    pointers.forEach((pointer) => engine._free(pointer));
  }
}

// Exercise the shipped parser and browser orchestrator, including component convolution and
// record-exposure continuation. The selected model must change an edge and remain deterministic.
const { loadPack, SimdDeveloper } = await import('../web/src/engine.js');
const references = process.env.FOTUFILM_WASM_REFERENCE_OUTPUT
  ? JSON.parse(await readFile(process.env.FOTUFILM_WASM_REFERENCE_OUTPUT)) : null;
for (const { id } of stocks) {
  const legacyPack = await loadPack(new URL(`packs/${id}.pack`, assets));
  const layeredPack = await loadPack(new URL(`packs/${id}.layered.pack`, assets));
  assert.ok(layeredPack.transport?.components.length > 0, `${id}: no transport components`);
  const count = layeredPack.width * layeredPack.height;
  const source = new Uint8ClampedArray(count * 4);
  for (let p = 0; p < count; ++p) {
    const bright = p % layeredPack.width > layeredPack.width / 2;
    source.set([bright ? 255 : 20, bright ? 255 : 15, bright ? 255 : 10, 255], p * 4);
  }
  const legacy = new SimdDeveloper(engine, legacyPack);
  const layered = new SimdDeveloper(engine, layeredPack);
  try {
    const a = await legacy.develop(source, { grain: 0 });
    const b = await layered.develop(source, { grain: 0 });
    assert.notDeepEqual(b.pixels, a.pixels, `${id}: selector did not change the image`);
    if (references) {
      const actual = engine.HEAPF32.slice(layered.outputPtr / 4, layered.outputPtr / 4 + count * 3);
      const expected = references[id];
      assert.equal(actual.length, expected.length);
      let error = 0;
      for (let i = 0; i < actual.length; ++i) error = Math.max(error, Math.abs(actual[i] - expected[i]));
      assert.ok(error < 0.0001, `${id}: CPU/WASM maximum error ${error}`);
      console.log(`${id}: CPU/WASM max error ${error}`);
    }
    assert.deepEqual((await layered.develop(source, { grain: 0 })).pixels, b.pixels,
      `${id}: layered render was not deterministic`);
    const exposed = await layered.develop(source, { grain: 0, ev: 1 });
    assert.notDeepEqual(exposed.pixels, b.pixels, `${id}: layered exposure control did nothing`);
    console.log(`${id}: Legacy/Layered browser selection, determinism and exposure passed`);
  } finally { legacy.dispose(); layered.dispose(); }
}
