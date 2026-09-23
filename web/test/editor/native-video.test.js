import test from 'node:test';
import assert from 'node:assert/strict';
import { importVideo } from '../../src/backend/macos/video-import.js';

const movie = () => new File([new Uint8Array(1200000)], 'sample.mov', { type: 'video/quicktime' });
test('native video transfers bounded ordered chunks with separate playback and poster URLs', async () => {
  const calls = [];
  const call = async (method, params) => {
    calls.push([method, params]);
    if (method === 'beginVideo') return { handle: 'upload' };
    if (method === 'importVideo') return { handle: 'video', preview: 'AA==', video: { start: 0, duration: 2 } };
  };
  const result = await importVideo(call, movie());
  try {
    const chunks = calls.filter(([m]) => m === 'appendVideo').map(([, p]) => p);
    assert.deepEqual(chunks.map(c => c.offset), [0, 524288, 1048576]);
    assert.ok(chunks.every(c => atob(c.data).length <= 524288));
    assert.equal(chunks.reduce((n, c) => n + atob(c.data).length, 0), 1200000);
    assert.equal(result.image.handle, 'video');
    assert.equal(result.image.video.duration, 2);
    assert.notEqual(result.image.video.playbackUrl, result.url);
    assert.deepEqual(calls.at(-1), ['release', { handle: 'upload' }]);
  } finally {
    URL.revokeObjectURL(result.url);
    URL.revokeObjectURL(result.image.video.playbackUrl);
  }
});
test('cancelling video transfer releases the partial file without finishing import', async () => {
  const abort = new AbortController(), calls = [];
  const call = async (method, params) => {
    calls.push([method, params]);
    if (method === 'beginVideo') return { handle: 'upload' };
    if (method === 'appendVideo') abort.abort();
  };
  await assert.rejects(importVideo(call, movie(), { signal: abort.signal }), { name: 'AbortError' });
  assert.equal(calls.some(([m]) => m === 'importVideo'), false);
  assert.deepEqual(calls.at(-1), ['release', { handle: 'upload' }]);
});
test('failed native decode releases temporary video transfer', async () => {
  const calls = [];
  const call = async (method, params) => {
    calls.push([method, params]);
    if (method === 'beginVideo') return { handle: 'upload' };
    if (method === 'importVideo') throw new Error('Unsupported codec');
  };
  await assert.rejects(importVideo(call, movie()), /Unsupported codec/);
  assert.deepEqual(calls.at(-1), ['release', { handle: 'upload' }]);
});
