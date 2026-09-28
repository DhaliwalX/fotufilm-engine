import test from "node:test";
import assert from "node:assert/strict";
import {
  clipSummary,
  frameRateLabel,
  playbackEdge,
} from "../../src/video-player/playback-quality.js";

test("playback plays at the Mac app's quality edges, Fine by default", () => {
  assert.equal(playbackEdge("draft"), 640);
  assert.equal(playbackEdge("full"), 3840);
  assert.equal(playbackEdge("nonsense"), 1920);
});

test("the clip summary reads as the Mac app's", () => {
  assert.equal(frameRateLabel(24), "24 fps");
  assert.equal(frameRateLabel(29.97002997), "29.97 fps");
  assert.equal(frameRateLabel(0), "Variable fps");
  assert.equal(
    clipSummary({ width: 3840, height: 2160, frameRate: 25, audio: true }),
    "3840 × 2160   25 fps   audio",
  );
  assert.equal(clipSummary({ width: 1920, height: 1080, frameRate: 24, audio: false }), "1920 × 1080   24 fps");
});
