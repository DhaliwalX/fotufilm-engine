import test from 'node:test';
import assert from 'node:assert/strict';
import { defaultEdit } from "../../src/editor-state.js";
import { createLenses } from '../../src/backend/macos/lenses.js';
import { createSession } from '../../src/backend/macos/session.js';

test('native lens catalogue publishes imported and removed profiles to subscribers', async () => {
  let profiles = [], notifications = 0;
  const lenses = createLenses(async (method, data) => {
    if (method === 'importLensCatalogue') { profiles = data.profiles; return profiles.length; }
    if (method === 'removeLensCatalogue') { profiles = []; return true; }
    return profiles;
  });
  const off = lenses.subscribe(() => notifications++);
  await lenses.load();
  assert.equal(lenses.snapshot().loaded, true);
  assert.equal(await lenses.import(new Blob([JSON.stringify([{ id: 'lens' }])])), 1);
  assert.equal(lenses.snapshot().profiles[0].id, 'lens');
  await lenses.remove();
  assert.deepEqual(lenses.snapshot().profiles, []);
  assert.equal(notifications, 3);
  off();
  await lenses.remove();
  assert.equal(notifications, 3);
});

test('native render retains the exact sampling request and forwards inspection and mask controls', async () => {
  const calls = [];
  const session = createSession(async (method, request) => {
    calls.push({ method, request });
    return method === 'stages' ? [{ id: 'exposure' }] : { preview: '', original: '' };
  }, async () => []);
  const request = { image: { handle: 'scene' }, edit: defaultEdit(),
    maxEdge: 100, stage: 2, difference: true, showMask: true };
  const result = await session.render(request);
  assert.equal(calls[0].request.showMask, true);
  assert.equal(calls[0].request.stage, 2);
  assert.equal(calls[0].request.difference, true);
  assert.equal(result.sceneRequest, calls[0].request);
  assert.deepEqual(await session.stages('portra400', null, 'legacy'), [{ id: 'exposure' }]);
  assert.equal(calls[1].method, 'stages');
  session.dispose();
});

test('moving video uses compact previews while paused frames and photos stay lossless', async () => {
  const calls = [];
  const session = createSession(async (_, request) => {
    calls.push(request);
    return { preview: '', original: '', previewType: request.previewQuality === 'playback' ? 'image/jpeg' : 'image/png' };
  }, async () => []);
  const request = { image: { handle: 'video', video: {} }, edit: defaultEdit(), interactive: true };
  const moving = await session.render(request);
  assert.equal(moving.blob.type, 'image/jpeg');
  assert.equal(moving.original.type, 'image/jpeg');
  const paused = await session.render({ ...request, interactive: false });
  assert.equal(paused.blob.type, 'image/png');
  const photo = await session.render({ ...request, image: { handle: 'photo' } });
  assert.equal(photo.blob.type, 'image/png');
  assert.deepEqual(calls.map(request => request.previewQuality), ['playback', 'still', 'still']);
  session.dispose();
});
