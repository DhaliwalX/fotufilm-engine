import catalog from "./generated/video-color.json" with { type: "json" };
import { videoTransform } from "./video-color.js";
import { videoPlaneLayout } from "./video-plane-layout.js";

export function videoColorParameters(frame, encoding) {
  const { matrix } = videoTransform(encoding, frame.colorSpace);
  const p = videoPlaneLayout(frame),
    words = new Uint32Array(36),
    f = new Float32Array(words.buffer);
  words.set([
    frame.width,
    frame.height,
    frame.displayWidth,
    frame.displayHeight,
    frame.rotation,
    p.bytes,
    p.rgb ? (frame.format.startsWith("BG") ? 2 : 1) : 0,
    p.nv12 ? 1 : 0,
  ]);
  for (let i = 0; i < 3; i++) {
    words[8 + i] = frame.layout[i]?.offset || 0;
    words[11 + i] = frame.layout[i]?.stride || 0;
  }
  words[14] = p.subX;
  words[15] = p.subY;
  f[16] = p.kr || 0;
  f[17] = p.kb || 0;
  f.set(matrix, 20);
  f[30] = p.full ? 0 : 16 * p.scale;
  f[31] = p.full ? p.maximum : 219 * p.scale;
  f[32] = 128 * p.scale;
  f[33] = p.full ? p.maximum : 224 * p.scale;
  words[34] = catalog.encodings[encoding]?.curveIndex || 0;
  words[35] =
    encoding !== "standard"
      ? 0
      : ({ "arib-std-b67": 1, smpte2084: 2, linear: 3, "iec61966-2-1": 4 }[
          frame.colorSpace?.transfer
        ] ?? 5);
  return words;
}
