import test from "node:test";
import assert from "node:assert/strict";
import { inflateSync, crc32 } from "node:zlib";
import { playbackCursor } from "../../src/video-import.js";
import { storedPng } from "../../src/png-stored.js";

function fakeSink(times) {
  const opened = [],
    live = new Set();
  const sample = (timestamp) => {
    const item = {
      timestamp,
      clone: () => ({ timestamp }),
      close: () => live.delete(item),
    };
    live.add(item);
    return item;
  };
  return {
    opened,
    live,
    samples(start) {
      opened.push(start);
      let index = Math.max(
        0,
        times.findLastIndex((time) => time <= start),
      );
      return {
        async next() {
          return index < times.length
            ? { done: false, value: sample(times[index++]) }
            : { done: true };
        },
        async return() {
          return { done: true };
        },
      };
    },
  };
}

test("playback cursor reads successive frames from one decode pass", async () => {
  const times = Array.from({ length: 100 }, (_, i) => i / 25);
  const sink = fakeSink(times);
  const cursor = playbackCursor(sink);
  for (let i = 0; i < 50; i++)
    assert.equal((await cursor.sample(i / 25 + 0.01)).timestamp, i / 25);
  // A request exactly on a frame boundary lands on that frame.
  assert.equal((await cursor.sample(2)).timestamp, 2);
  assert.deepEqual(sink.opened, [0.01]);
  // Seeking backwards or far ahead restarts decoding at the requested time.
  assert.equal((await cursor.sample(0.5)).timestamp, 0.48);
  assert.equal((await cursor.sample(3.5)).timestamp, 3.48);
  assert.deepEqual(sink.opened, [0.01, 0.5, 3.5]);
  cursor.close();
  await cursor.sample(0).catch(() => {});
  cursor.close();
  await new Promise((resolve) => setTimeout(resolve));
  assert.equal(sink.live.size, 0);
});

test("playback cursor returns nothing before the first frame", async () => {
  const cursor = playbackCursor(fakeSink([0.5, 0.54]));
  assert.equal(await cursor.sample(0.1), null);
  assert.equal((await cursor.sample(0.52)).timestamp, 0.5);
});

function chunks(png) {
  const view = new DataView(png.buffer),
    found = [];
  for (let at = 8; at < png.length; ) {
    const length = view.getUint32(at),
      type = String.fromCharCode(...png.subarray(at + 4, at + 8)),
      data = png.subarray(at + 8, at + 8 + length);
    assert.equal(
      view.getUint32(at + 8 + length),
      crc32(png.subarray(at + 4, at + 8 + length)),
    );
    found.push({ type, data });
    at += 12 + length;
  }
  return found;
}

test("stored preview PNG holds the exact RGB pixels and colour space", async () => {
  for (const [width, height, colorSpace, primaries] of [
    [3, 2, "srgb", 1],
    [301, 229, "display-p3", 12],
  ]) {
    const pixels = new Uint8ClampedArray(width * height * 4).map((_, i) =>
      i % 4 === 3 ? 255 : (i * 37) & 255,
    );
    const png = new Uint8Array(
      await storedPng(pixels, width, height, colorSpace).arrayBuffer(),
    );
    const [header, cicp, ...rest] = chunks(png);
    assert.equal(header.type, "IHDR");
    assert.deepEqual(
      [...header.data],
      [
        0,
        0,
        width >> 8,
        width & 255,
        0,
        0,
        height >> 8,
        height & 255,
        8,
        2,
        0,
        0,
        0,
      ],
    );
    assert.deepEqual([cicp.type, ...cicp.data], ["cICP", primaries, 13, 0, 1]);
    assert.equal(rest.at(-1).type, "IEND");
    const rows = inflateSync(rest[0].data);
    assert.equal(rows.length, (width * 3 + 1) * height);
    for (let y = 0; y < height; y++) {
      assert.equal(rows[y * (width * 3 + 1)], 0);
      for (let x = 0; x < width; x++)
        for (let c = 0; c < 3; c++)
          assert.equal(
            rows[y * (width * 3 + 1) + 1 + x * 3 + c],
            pixels[(y * width + x) * 4 + c],
          );
    }
  }
});
