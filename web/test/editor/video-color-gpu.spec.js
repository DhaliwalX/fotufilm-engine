import { test, expect } from "@playwright/test";

test("GPU video decode matches CPU across curves, planes, ranges and orientation", async ({
  page,
}) => {
  await page.goto("/src/generated/video-color.json");
  const report = await page.evaluate(async () => {
    const { VideoColorGPU } = await import("/src/video-color-gpu.js");
    const { decodeVideoPlanes, VIDEO_ENCODINGS } = await import(
      "/src/video-color.js"
    );
    const { orientVideoPixels } = await import("/src/video-frame-geometry.js");
    const gpu = await VideoColorGPU.create();
    if (!gpu) throw new Error("This check requires a WebGPU adapter.");
    let peak = 0,
      cases = 0;
    try {
      for (const format of [
        "RGBA",
        "BGRA",
        "RGBX",
        "BGRX",
        "NV12",
        "I420",
        "I422",
        "I444",
        "I420P10",
        "I422P12",
        "I444P10",
      ]) {
        const width = 17,
          height = 6,
          deep = /P1/.test(format),
          bytes = deep ? 2 : 1,
          maximum = format.endsWith("P12") ? 4095 : deep ? 1023 : 255;
        const rgb = /^(R|B)/.test(format),
          stride = width * (rgb ? 4 : bytes) + 8;
        const layout = [0, 1, 2].map((i) => ({
          offset: 4 + i * stride * height,
          stride,
        }));
        const data = new Uint8Array(stride * height * 3 + 8),
          view = new DataView(data.buffer);
        for (let plane = 0; plane < 3; plane++)
          for (let y = 0; y < height; y++)
            for (let x = 0; x < (rgb ? width * 4 : width); x++) {
              const offset = layout[plane].offset + y * stride + x * bytes,
                value = (x * 71 + y * 53 + plane * 119) % maximum;
              if (deep) view.setUint16(offset, value, true);
              else data[offset] = value;
            }
        for (const fullRange of [false, true])
          for (const { id } of VIDEO_ENCODINGS) {
            const frame = {
              data,
              layout,
              format,
              width,
              height,
              colorSpace: {
                matrix: "bt709",
                primaries: "bt709",
                transfer: "bt709",
                fullRange,
              },
              rotation: 0,
              displayWidth: width,
              displayHeight: height,
            };
            for (const rotation of [0, 90, 180, 270]) {
              frame.rotation = rotation;
              frame.displayWidth = rotation % 180 ? height : width;
              frame.displayHeight = rotation % 180 ? width : height;
              const actual = await gpu.decode(frame, id);
              const expected = orientVideoPixels(
                decodeVideoPlanes(frame, id),
                frame,
                width,
                height,
              ).linear.data;
              for (let i = 0; i < expected.length; i++) {
                const error =
                  Math.abs(actual[i] - expected[i]) /
                  Math.max(1, Math.abs(expected[i]));
                if (!Number.isFinite(actual[i]) || error > 0.0003)
                  throw new Error(
                    `${format}/${id}/${rotation} pixel ${i}: ${actual[i]} != ${expected[i]} (${error})`,
                  );
                peak = Math.max(peak, error);
              }
              cases++;
            }
          }
      }
      const frame = {
        data: new Uint8Array([0, 128, 255, 255, 255, 64, 128, 255]),
        layout: [{ offset: 0, stride: 8 }],
        format: "RGBA",
        width: 2,
        height: 1,
        rotation: 0,
        displayWidth: 5,
        displayHeight: 2,
      };
      for (const transfer of [
        "arib-std-b67",
        "smpte2084",
        "linear",
        "iec61966-2-1",
        "bt709",
      ])
        for (const primaries of ["bt709", "bt2020", "smpte432"]) {
          frame.colorSpace = { transfer, primaries };
          const actual = await gpu.decode(frame, "standard"),
            expected = orientVideoPixels(
              decodeVideoPlanes(frame, "standard"),
              frame,
              2,
              1,
            ).linear.data;
          for (let i = 0; i < expected.length; i++) {
            const error =
              Math.abs(actual[i] - expected[i]) /
              Math.max(1, Math.abs(expected[i]));
            if (error > 0.0003 || !Number.isFinite(actual[i]))
              throw new Error(`${transfer}/${primaries}: ${error}`);
            peak = Math.max(peak, error);
          }
          cases++;
        }
      return { cases, peak };
    } finally {
      gpu.dispose();
    }
  });
  console.log("VIDEO_GPU_PARITY", report);
  expect(report.cases).toBe(895);
});

