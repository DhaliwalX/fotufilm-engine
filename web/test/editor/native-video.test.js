import test from "node:test";
import assert from "node:assert/strict";
import { createDesktopBackend } from "../../src/backend/desktop/host.js";
import { createNativeBackend } from "../../src/backend/native.js";
import { APP_SETTINGS } from "../../src/app-settings.js";
import { defaultEdit } from "../../src/editor-state.js";

const FORMATS = [
  { id: "mp4", label: "MPEG-4 · H.264", extension: "mp4", type: "video/mp4", quality: true, bits: 8 },
  { id: "prores422", label: "Apple ProRes 422", extension: "mov", type: "video/quicktime", quality: false, bits: 10 },
];

// A native host double: records every call and answers the video ones.
function host({ capabilities, binary = true } = {}) {
  const calls = [];
  const channel = {
    binary,
    capabilities,
    async postMessage(message, payload) {
      calls.push({ ...message, payload });
      switch (message.method) {
        case "prepare":
          return { stocks: ["gold200"], catalogue: [{ id: "gold200", name: "Gold 200", media: [], available: [] }] };
        case "beginVideo":
          return { handle: "upload-1" };
        case "importVideo":
        case "importPath":
          return {
            handle: 7,
            naturalWidth: 64,
            naturalHeight: 48,
            video: { start: 0, duration: 1 },
            preview: new Uint8Array([137, 80, 78, 71]),
            ...(message.params.playback
              ? { playback: new Uint8Array([82, 73, 70, 70]), playbackType: "audio/wav" }
              : {}),
          };
        default:
          return {};
      }
    },
  };
  return { backend: createDesktopBackend(channel), calls };
}

const movie = (size) =>
  new File([new Uint8Array(size)], "clip.mov", { type: "video/quicktime" });

test("an engine host uploads a movie in binary chunks and plays the host's clock", async () => {
  const { backend, calls } = host({
    capabilities: {
      video: true,
      videoExportTypes: FORMATS,
      videoBitrates: [{ id: "automatic", label: "Automatic" }],
      videoFrameRates: [24, 30],
    },
  });
  const { image } = await backend.importMedia(movie(9 * 1024 * 1024));
  const appends = calls.filter(({ method }) => method === "appendVideo");
  assert.equal(appends.length, 2);
  assert.equal(appends[0].payload.byteLength, 8 * 1024 * 1024);
  assert.equal(appends[1].params.offset, 8 * 1024 * 1024);
  assert.equal(appends[0].params.data, undefined);
  assert.equal(calls.find(({ method }) => method === "importVideo").params.playback, true);
  // The upload is released once the movie is open; the movie's own lease stays.
  assert.equal(calls.at(-1).method, "release");
  assert.equal(calls.at(-1).params.handle, "upload-1");
  assert.equal(image.handle, 7);
  assert.equal((await fetch(image.video.playbackUrl).then((r) => r.blob())).type, "audio/wav");
  assert.deepEqual(backend.videoExportTypes.map(({ id }) => id), ["mp4", "prores422"]);
  assert.deepEqual(backend.videoBitrates.map(({ id }) => id), ["automatic"]);
  assert.deepEqual(backend.videoFrameRates, [24, 30]);
});

test("a host without capabilities keeps base64 chunks and plays the original file", async () => {
  const { backend, calls } = host({ capabilities: undefined, binary: false });
  const file = movie(600 * 1024);
  const { image } = await backend.importMedia(file);
  const appends = calls.filter(({ method }) => method === "appendVideo");
  assert.equal(appends.length, 2);
  assert.equal(typeof appends[0].params.data, "string");
  assert.equal(calls.find(({ method }) => method === "importVideo").params.playback, false);
  assert.equal((await fetch(image.video.playbackUrl).then((r) => r.blob())).size, file.size);
  assert.equal(backend.videoExportTypes, undefined);
});

test("an engine without video declines movies before uploading them", async () => {
  const { backend, calls } = host({ capabilities: { video: false } });
  await assert.rejects(backend.importMedia(movie(16)), /cannot open videos/);
  assert.equal(calls.length, 0);
});

test("a movie opened by path is a video with the host's clock", async () => {
  const { backend, calls } = host({ capabilities: { video: true, importPath: true } });
  const { image } = await backend.importPath("/clips/clip.mov");
  assert.equal(calls[0].params.playback, true);
  assert.equal(image.video.duration, 1);
  assert.ok(image.video.playbackUrl.startsWith("blob:"));
});

test("a video export names the chosen format's container for the save panel", async () => {
  const { backend, calls } = host({ capabilities: { video: true, videoExportTypes: FORMATS } });
  await backend.exportVideo({
    image: { handle: 7, video: { start: 0, duration: 1 } },
    edit: defaultEdit("gold200"),
    stock: "gold200",
    format: "prores422",
    quality: "high",
    filename: "clip-gold200.mov",
  });
  const exported = calls.find(({ method }) => method === "exportVideo");
  assert.equal(exported.params.type, "video/quicktime");
  assert.equal(exported.params.format, "prores422");
});

test("Video Quality reaches the engine where it develops movies on a pipeline", async () => {
  assert.equal(APP_SETTINGS.videoProcessing, "full");
  assert.equal(host({ capabilities: { video: true } }).backend.videoProcessing, false);
  assert.equal(
    host({ capabilities: { video: false, videoProcessing: true } }).backend.videoProcessing,
    false,
  );
  const { backend, calls } = host({
    capabilities: { video: true, videoExportTypes: FORMATS, videoProcessing: true },
  });
  assert.equal(backend.videoProcessing, true);
  // The native binding carries the capability through.
  assert.equal(createNativeBackend(backend).videoProcessing, true);
  const request = {
    image: { handle: 7, video: { start: 0, duration: 1 } },
    edit: defaultEdit("gold200"),
    stock: "gold200",
    format: "mp4",
    filename: "clip-gold200.mp4",
  };
  await backend.exportVideo({ ...request, videoProcessing: "fast" });
  await backend.exportVideo(request);
  const exports = calls.filter(({ method }) => method === "exportVideo");
  assert.deepEqual(exports.map(({ params }) => params.videoProcessing), ["fast", "full"]);
});
