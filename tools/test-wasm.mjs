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
  assert.equal(view.getUint32(4, true), 2);
  const configCount = view.getInt32(24, true);
  const lutCount = view.getInt32(32, true);
  assert.equal(configCount, engine._fotufilm_wasm_configuration_count());
  assert.equal(lutCount, engine._fotufilm_wasm_lut_count());
  // The size ladder follows the cubes: a count, then per rung five ints and the changed slots.
  let end = 40 + 4 * (configCount + 3 * lutCount);
  const rungs = view.getInt32(end, true);
  end += 4;
  assert.ok(rungs > 0, `${id}: no size ladder`);
  for (let r = 0; r < rungs; ++r) {
    assert.ok(view.getInt32(end, true) > 0, `${id}: rung ${r} has no short edge`);
    assert.ok(view.getInt32(end + 12, true) >= 0, `${id}: rung ${r} has a negative apron`);
    end += 20 + 8 * view.getInt32(end + 16, true);
  }
  assert.equal(bytes.length, end, `${id}: pack length does not match its ladder`);

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
        inputPtr, outputPtr, width, height, 0, 0, configuration, exposure, film, paper,
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
