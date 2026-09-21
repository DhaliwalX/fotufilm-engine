import { test, expect } from '@playwright/test';
import { png16 } from './png-fixture.js';

test('deep PNG decodes Adam7, gamma, alpha and orientation without reducing sample precision', async ({ page }) => {
  const gamma = Buffer.alloc(4); gamma.writeUInt32BE(100000);
  const sample = (x, y) => [12000 + 257 * x + 19 * y, 32768];
  const fixtures = [false, true].map(interlaced => Array.from(png16({ width: 13, height: 9, gray: true, interlaced, sample, chunks: [['gAMA', gamma]] })));
  await page.goto('/');
  const results = await page.evaluate(async fixtures => {
    const { decodeImageWorker } = await import('/src/image-worker.js');
    const { assetUrl } = await import('/src/engine.js');
    const outputs = [];
    for (const bytes of fixtures) {
      const result = await decodeImageWorker(new File([new Uint8Array(bytes)], 'Deep.png'),
        () => new Worker('/src/png-worker.js', { type: 'module' }),
        { label: 'PNG', message: { decoderURL: assetUrl('png/decoder.mjs'), orientation: 6 } });
      outputs.push({ width: result.width, height: result.height, pixels: Array.from(result.pixels) });
    }
    return outputs;
  }, fixtures);
  expect(results[0]).toEqual(results[1]);
  const { width, height, pixels } = results[0];
  expect([width, height]).toEqual([9, 13]);
  for (let y = 0; y < 9; y++) for (let x = 0; x < 13; x++) {
    const i = (x * width + 8 - y) * 4;
    const expected = sample(x, y)[0] / 65535 * (32768 / 65535);
    for (let c = 0; c < 3; c++) expect(Math.abs(pixels[i + c] - expected)).toBeLessThan(0.00005);
    expect(pixels[i + 3]).toBe(1);
  }
});

test('deep PNG rejects corrupt data and unsupported HDR instead of silently reinterpreting it', async ({ page }) => {
  const args = { width: 2, height: 2, sample: () => [10000, 20000, 30000, 65535] };
  const corrupt = png16(args); corrupt[corrupt.length - 1] ^= 1;
  const hdr = png16({ ...args, chunks: [['cICP', Buffer.from([9, 16, 0, 1])]] });
  await page.goto('/');
  const messages = await page.evaluate(async fixtures => {
    const { decodeImageWorker } = await import('/src/image-worker.js');
    const { assetUrl } = await import('/src/engine.js');
    return Promise.all(fixtures.map(async bytes => {
      try {
        await decodeImageWorker(new File([new Uint8Array(bytes)], 'Bad.png'),
          () => new Worker('/src/png-worker.js', { type: 'module' }),
          { label: 'PNG', message: { decoderURL: assetUrl('png/decoder.mjs') } });
        return 'unexpected success';
      } catch (error) { return error.message; }
    }));
  }, [Array.from(corrupt), Array.from(hdr)]);
  expect(messages[0]).toContain('CRC');
  expect(messages[1]).toContain('not supported');
});
