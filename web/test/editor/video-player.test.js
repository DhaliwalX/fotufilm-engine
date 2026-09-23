import test from "node:test";
import assert from "node:assert/strict";
import { createPlayback } from "../../src/video-player/playback.js";
import { videoTimeLabel, clampPlayhead } from "../../src/video-player/time.js";

class Media extends EventTarget {
  currentTime = 0;
  paused = true;
  ended = false;
  muted = false;
  playbackRate = 1;
  playCalls = 0;
  play() {
    this.playCalls++;
    this.paused = false;
    this.dispatchEvent(new Event("play"));
    return Promise.resolve();
  }
  pause() {
    this.paused = true;
    this.dispatchEvent(new Event("pause"));
  }
}
function fixture(start = 0, end = 10) {
  const media = new Media(),
    renders = [],
    states = [],
    frames = new Map();
  let id = 0;
  const player = createPlayback(media, {
    start,
    end,
    onState: (s) => states.push(s),
    onTime: (t) => renders.push(t),
    requestFrame: (fn) => {
      frames.set(++id, fn);
      return id;
    },
    cancelFrame: (key) => frames.delete(key),
  });
  return {
    media,
    player,
    renders,
    states,
    frames,
    tick(now) {
      const pending = [...frames.values()];
      frames.clear();
      pending.forEach((fn) => fn(now));
    },
  };
}
test("timecode carries fractional seconds into minutes and supports hour-long clips", () => {
  assert.equal(videoTimeLabel(59.999), "01:00.00");
  assert.equal(videoTimeLabel(3661.25), "1:01:01.25");
  assert.equal(videoTimeLabel(NaN), "00:00.00");
  assert.equal(clampPlayhead(12, 2, 8), 7.999);
  assert.equal(clampPlayhead(-1, 2, 8), 2);
});
test("scrubbing pauses playback and stays inside the trimmed range", () => {
  const f = fixture(2, 8);
  f.player.toggle();
  f.player.seek(20);
  assert.equal(f.media.paused, true);
  assert.equal(f.renders.at(-1), 7.999);
  f.player.skip(-5);
  assert.ok(Math.abs(f.media.currentTime - 2.999) < 0.00001);
  f.player.seek(0);
  assert.equal(f.media.currentTime, 2);
  f.player.dispose();
});
test("playback supplies roughly 30 previews per second and pause commits the final time", () => {
  const f = fixture();
  f.player.toggle();
  for (let t = 0; t < 1000; t += 16) {
    f.media.currentTime = t / 1000;
    f.tick(t);
  }
  assert.ok(f.renders.length >= 29 && f.renders.length <= 32);
  f.media.currentTime = 1.01;
  f.player.pause();
  assert.equal(f.renders.at(-1), 1.01);
  assert.equal(f.frames.size, 0);
  f.player.dispose();
});
test("trim boundaries stop playback, or loop the selection without ending at the file duration", () => {
  const f = fixture(1, 3);
  f.player.toggle();
  f.media.currentTime = 3.05;
  f.tick(100);
  assert.equal(f.media.paused, true);
  assert.equal(f.media.currentTime, 2.999);
  f.player.configure({ start: 1, end: 3, loop: true });
  f.player.toggle();
  f.media.currentTime = 3.01;
  f.tick(200);
  assert.equal(f.media.currentTime, 1);
  assert.equal(f.media.paused, false);
  f.player.dispose();
});
test("muting and playback speed affect preview only; disabled controls cannot resume", () => {
  const f = fixture();
  f.player.configure({ start: 0, end: 10, muted: true, rate: 0.5 });
  assert.equal(f.media.muted, true);
  assert.equal(f.media.playbackRate, 0.5);
  f.player.configure({ disabled: true });
  f.player.toggle();
  assert.equal(f.media.playCalls, 0);
  f.player.dispose();
});
test("an interrupted play promise cannot show a spurious error or restart a disposed player", async () => {
  const f = fixture();
  let reject;
  f.media.play = () =>
    new Promise((_, fail) => {
      reject = fail;
    });
  f.player.toggle();
  f.player.pause();
  reject(new Error("late rejection"));
  await Promise.resolve();
  assert.equal(f.states.at(-1).error, null);
  f.player.dispose();
  const count = f.states.length;
  f.media.dispatchEvent(new Event("play"));
  assert.equal(f.states.length, count);
  assert.equal(f.frames.size, 0);
});
