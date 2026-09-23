import { test, expect } from "@playwright/test";

test("worker keeps CPU conversion available when WebGPU cannot initialize", async ({
  page,
  context,
}) => {
  await context.route("**/src/video-color-gpu.js", (route) =>
    route.fulfill({
      contentType: "text/javascript",
      body: "export class VideoColorGPU {static async create() {return null}}",
    }),
  );
  await page.goto("/src/generated/video-color.json");
  const result = await page.evaluate(async () => {
    const { prepareVideoColor, convertVideoFrame } = await import(
      "/src/video-color-client.js"
    );
    const { decodeVideoPlanes } = await import("/src/video-color.js");
    const frame = {
      data: new Uint8Array([30, 80, 120, 255, 250, 230, 210, 255]),
      layout: [{ offset: 0, stride: 8 }],
      format: "RGBA",
      width: 2,
      height: 1,
      displayWidth: 2,
      displayHeight: 1,
      rotation: 0,
      colorSpace: {},
    };
    const expected = decodeVideoPlanes(frame, "appleLog2");
    const ready = await prepareVideoColor(),
      result = await convertVideoFrame(frame, "appleLog2");
    return { ready, actual: [...result.linear.data], expected: [...expected] };
  });
  expect(result.ready).toBe(false);
  expect(result.actual).toEqual(result.expected);
});

test("an invalid frame fails without disabling future GPU conversions", async ({
  page,
}) => {
  await page.goto("/src/generated/video-color.json");
  const result = await page.evaluate(async () => {
    const { prepareVideoColor, convertVideoFrame } = await import(
      "/src/video-color-client.js"
    );
    await prepareVideoColor();
    let error = "";
    try {
      await convertVideoFrame(
        {
          data: new Uint8Array(1),
          layout: [],
          format: "RGBA",
          width: 2,
          height: 1,
          displayWidth: 2,
          displayHeight: 1,
        },
        "appleLog",
      );
    } catch (e) {
      error = e.message;
    }
    return { error, ready: await prepareVideoColor() };
  });
  expect(result.error).toContain("plane layout");
  expect(result.ready).toBe(true);
});
