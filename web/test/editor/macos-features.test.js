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

test('background pictures wait while a movie plays and follow the paused frame', async () => {
  const calls = [];
  const session = createSession(async (_, request) => {
    calls.push(request.maxEdge);
    return { presented: { frame: calls.length, original: 0 } };
  }, async () => []);
  const movie = { image: { handle: 'video', video: {} }, edit: defaultEdit(), interactive: true, maxEdge: 640 };
  await session.render(movie);
  const thumbnail = session.render({ ...movie, interactive: false, background: true, maxEdge: 160 });
  await session.render(movie);
  assert.deepEqual(calls, [640, 640]);
  await session.render({ ...movie, interactive: false, maxEdge: 1600 });
  await thumbnail;
  assert.deepEqual(calls, [640, 640, 1600, 160]);
  session.dispose();
});

test('a playing movie asks for its original only while the comparison shows it', async () => {
  const calls = [];
  const session = createSession(async (_, request) => {
    calls.push(request);
    return { presented: { frame: calls.length, original: 0 } };
  }, async () => []);
  const request = { image: { handle: 'video', video: {} }, edit: defaultEdit(), interactive: true };
  await session.render(request);
  await session.render({ ...request, compare: true });
  await session.render({ ...request, interactive: false });
  await session.render({ ...request, image: { handle: 'photo' } });
  assert.deepEqual(calls.map(request => request.original), [false, true, true, true]);
  session.dispose();
});

test('a newer request cancels the stale render the host is still developing', async () => {
  const calls = [];
  let settled = true;
  const session = createSession((_, request, { signal }) => {
    calls.push(request.maxEdge);
    return new Promise((resolve, reject) => {
      if (request.maxEdge === 1600) signal.addEventListener('abort', () => reject(new DOMException('', 'AbortError')));
      else resolve({ presented: { frame: 1 } });
    });
  }, async () => []);
  const request = { image: { handle: 'photo' }, edit: defaultEdit(), present: 'preview' };
  const refinement = session.render({ ...request, maxEdge: 1600, stale: () => !settled });
  await new Promise((resolve) => setTimeout(resolve));
  settled = false;
  const draft = session.render({ ...request, maxEdge: 800, interactive: true });
  assert.equal(await refinement, null);
  assert.equal((await draft).presented.frame, 1);
  // A request still current is never cut short.
  const current = session.render({ ...request, maxEdge: 900 });
  const next = session.render({ ...request, maxEdge: 700 });
  assert.equal((await current).presented.frame, 1);
  await next;
  assert.deepEqual(calls, [1600, 800, 900, 700]);
  session.dispose();
});

test('an unchanged original crosses the bridge once and is reused', async () => {
  const calls = [];
  const session = createSession(async (_, request) => {
    calls.push(request);
    const answer = { preview: 'AA==', previewType: 'image/png', originalKey: 'photo|frame' };
    if (request.haveOriginal !== 'photo|frame') answer.original = 'AA==';
    return answer;
  }, async () => []);
  const request = { image: { handle: 'photo' }, edit: defaultEdit() };
  const first = await session.render(request);
  const second = await session.render({ ...request, maxEdge: 64 });
  assert.equal(calls[0].haveOriginal, undefined);
  assert.equal(calls[1].haveOriginal, 'photo|frame');
  assert.equal(second.original, first.original);
  session.dispose();
});
