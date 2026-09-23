import { test, expect } from "@playwright/test";

for (const [width, height] of [
  [1280, 720],
  [3840, 2160],
])
  test(`worker conversion preserves pixels at ${width}×${height}`, async ({
    page,
  }) => {
    await page.goto("/src/generated/video-color.json");
    const report = await page.evaluate(
      async ({ width, height }) => {
        const { convertVideoFrame, prepareVideoColor } = await import(
          "/src/video-color-client.js"
        );
        const { decodeVideoPlanes } = await import("/src/video-color.js");
        if (!(await prepareVideoColor()))
          throw new Error("Worker WebGPU conversion is unavailable.");
        const size = width * height;
        const data = new Uint8Array(size * 1.5);
        for (let i = 0; i < data.length; i++) data[i] = (i * 7) % 256;
        const frame = {
          data,
          layout: [
            { offset: 0, stride: width },
            { offset: size, stride: width / 2 },
            { offset: size * 1.25, stride: width / 2 },
          ],
          format: "I420",
          width,
          height,
          displayWidth: width,
          displayHeight: height,
          rotation: 0,
          colorSpace: { matrix: "bt709" },
        };
        await convertVideoFrame({ ...frame, data: data.slice() }, "slog3Cine");
        const cpu = [],
          gpu = [];
        let expected, actual;
        for (let i = 0; i < 4; i++) {
          let t = performance.now();
          expected = decodeVideoPlanes(frame, "slog3Cine");
          cpu.push(performance.now() - t);
          t = performance.now();
          actual = await convertVideoFrame(
            { ...frame, data: data.slice() },
            "slog3Cine",
          );
          gpu.push(performance.now() - t);
        }
        let peak = 0;
        for (let i = 0; i < expected.length; i++)
          peak = Math.max(
            peak,
            Math.abs(expected[i] - actual.linear.data[i]) /
              Math.max(1, Math.abs(expected[i])),
          );
        const median = (a) => a.sort((a, b) => a - b)[2];
        return { width, height, cpuMs: median(cpu), gpuMs: median(gpu), peak };
      },
      { width, height },
    );
    console.log("VIDEO_GPU_BENCHMARK", report);
    expect(report.peak).toBeLessThan(0.0003);
  });
