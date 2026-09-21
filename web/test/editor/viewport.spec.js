import { test, expect } from "@playwright/test";
import { openChart } from "./photo-fixture.js";

test("GPU and CPU visible film tiles agree with full-frame grain and spatial effects", async ({
  page,
}) => {
  test.setTimeout(180000);
  await page.goto("/");
  await expect(page.locator(".viewer-status > [role=status]")).toContainText(
    /\d+ × \d+/,
  );
  const report = await page.evaluate(async () => {
    const { loadPack, assetUrl, pixelSource } = await import("/src/engine.js");
    const { createBackgroundDeveloper } = await import(
      "/src/background-developer.js"
    );
    const { defaultEdit } = await import("/src/editor-state.js");
    const pack = await loadPack(assetUrl("packs/gold200.pack"));
    const width = 640,
      height = 480;
    const data = new Float32Array(width * height * 4);
    for (let y = 0; y < height; y++)
      for (let x = 0; x < width; x++)
        data.set(
          [
            x > 305 && x < 340 ? 4 : 0.1 + x / width,
            y / height,
            (x % 43) / 43,
            1,
          ],
          (y * width + x) * 4,
        );
    const source = pixelSource({ width, height, data });
    const reports = [];
    for (const preferGpu of [false, true]) {
      const dev = await createBackgroundDeveloper(pack, undefined, undefined, {
        preferGpu,
      });
      await dev.gpuReady;
      try {
        for (const bitDepth of [8, 16]) {
          const full = await dev.develop(
            source,
            defaultEdit().params,
            undefined,
            undefined,
            { bitDepth },
          );
          for (const region of [
            { x: 193, y: 117, width: 239, height: 181 },
            { x: 0, y: 301, width: 205, height: 179 },
          ]) {
            const reads = [];
            const roi = await dev.develop(
              {
                width,
                height,
                read(x, y, w, h) {
                  reads.push({ x, y, w, h });
                  return source.read(x, y, w, h);
                },
              },
              defaultEdit().params,
              undefined,
              undefined,
              { bitDepth, region },
            );
            const crop = pixelSource({ width, height, data: full.pixels }).read(
              region.x,
              region.y,
              region.width,
              region.height,
            );
            let peak = 0;
            for (let i = 0; i < crop.length; i++)
              peak = Math.max(peak, Math.abs(roi.pixels[i] - crop[i]));
            reports.push({
              backend: dev.backend,
              bitDepth,
              peak,
              count: roi.pixels.length,
              expected: crop.length,
              readPixels: reads.reduce((n, r) => n + r.w * r.h, 0),
            });
          }
        }
      } finally {
        dev.dispose();
      }
    }
    return reports;
  });
  console.log(JSON.stringify(report));
  expect(report.some((r) => r.backend === "webgpu")).toBe(true);
  for (const r of report) {
    expect(r.peak).toBeLessThanOrEqual(r.bitDepth === 16 ? 2 : 1);
    expect(r.count).toBe(r.expected);
    expect(r.readPixels).toBeLessThan(640 * 480);
  }
});

for (const pixelRatio of [1, 2])
  test.describe(`Display scale ${pixelRatio}`, () => {
    test.use({ deviceScaleFactor: pixelRatio });
    test("settled viewer renders visible display pixels and updates after panning", async ({
      page,
    }) => {
      await page.goto("/");
      await openChart(page, 3200, 2000);
      const detail = page.locator(".viewport-detail");
      await expect(detail).toBeVisible();
      const viewer = page.getByLabel("Photo preview", { exact: true });
      await viewer.hover();
      for (let i = 0; i < 18; i++) {
        await page.mouse.wheel(0, -60);
        await page.waitForTimeout(20);
      }
      await expect(detail).toBeVisible();
      const check = async () =>
        detail.evaluate((img) => ({
          natural: [img.naturalWidth, img.naturalHeight],
          render: [+img.dataset.renderWidth, +img.dataset.renderHeight],
          frame: [+img.dataset.frameWidth, +img.dataset.frameHeight],
          bounds: [
            img.getBoundingClientRect().width,
            img.getBoundingClientRect().height,
          ],
          viewport: [
            img.closest(".canvas-area").clientWidth,
            img.closest(".canvas-area").clientHeight,
          ],
          dpr: devicePixelRatio,
          left: img.style.left,
          top: img.style.top,
        }));
      await expect
        .poll(async () => (await check()).frame[0])
        .toBeGreaterThan(3200);
      const before = await check();
      await page.screenshot({
        path: `../build/web-viewport-dpr${pixelRatio}.png`,
      });
      expect(before.natural).toEqual(before.render);
      for (let i = 0; i < 2; i++) {
        expect(before.render[i]).toBeLessThanOrEqual(
          before.viewport[i] * before.dpr + 2,
        );
        expect(
          Math.abs(before.bounds[i] * before.dpr - before.render[i]),
        ).toBeLessThan(1);
      }
      const bounds = await viewer.boundingBox();
      await page.mouse.move(
        bounds.x + bounds.width / 2,
        bounds.y + bounds.height / 2,
      );
      await page.mouse.down();
      await page.mouse.move(
        bounds.x + bounds.width / 2 + 120,
        bounds.y + bounds.height / 2 + 80,
        { steps: 10 },
      );
      await page.mouse.up();
      await expect(detail).toBeVisible();
      await expect.poll(async () => (await check()).left).not.toBe(before.left);
      await page
        .getByRole("button", { name: "Zoom to fit (0)", exact: true })
        .click();
      await expect(detail).toBeVisible();
      await expect
        .poll(async () => (await check()).frame[0])
        .toBeLessThan(3200);
    });
  });

test("viewport session preserves selective edits, original comparison and full export dimensions", async ({
  page,
}) => {
  await page.goto("/");
  const report = await page.evaluate(async () => {
    const { RenderSession } = await import("/src/render-session.js");
    const { defaultEdit } = await import("/src/editor-state.js");
    const { pixelSource } = await import("/src/engine.js");
    const canvas = document.createElement("canvas");
    canvas.width = 240;
    canvas.height = 160;
    const ctx = canvas.getContext("2d");
    ctx.fillStyle = "#3355bb";
    ctx.fillRect(0, 0, 120, 160);
    ctx.fillStyle = "#994433";
    ctx.fillRect(120, 0, 120, 160);
    const image = await createImageBitmap(canvas);
    const edit = {
      ...defaultEdit(),
      rotation: 1,
      printFrame: "mount",
      selective: {
        kind: "color",
        sample: [0.1, 0.15, 0.3],
        range: 0.8,
        softness: 0.5,
        params: { ...defaultEdit().params, ev: 1 },
        localTone: false,
        gradeSpace: false,
      },
    };
    const session = new RenderSession(),
      width = 320,
      height = 480;
    const region = { x: 73, y: 151, width: 109, height: 177 };
    const args = { image, edit, stock: "gold200", encode: false };
    try {
      const errors = [];
      for (const showMask of [false, true]) {
        const full = await session.render({
          ...args,
          showMask,
          viewport: { width, height, region: { x: 0, y: 0, width, height } },
        });
        const roi = await session.render({
          ...args,
          showMask,
          viewport: { width, height, region },
        });
        const pixels = (c) =>
          c.getContext("2d").getImageData(0, 0, c.width, c.height).data;
        const expected = pixelSource({
          width,
          height,
          data: pixels(full.canvas),
        }).read(region.x, region.y, region.width, region.height);
        const actual = pixels(roi.canvas);
        let peak = 0;
        for (let i = 0; i < actual.length; i++)
          peak = Math.max(peak, Math.abs(actual[i] - expected[i]));
        const original = await createImageBitmap(roi.original);
        errors.push({
          peak,
          size: [roi.width, roi.height],
          original: [original.width, original.height],
        });
        original.close();
      }
      const exported = await session.render({
        ...args,
        edit: { ...edit, printFrame: "none" },
        maxEdge: Infinity,
        bitDepth: 16,
        comparison: false,
      });
      return {
        errors,
        exportSize: [exported.width, exported.height],
        bits: exported.pixels.BYTES_PER_ELEMENT * 8,
      };
    } finally {
      await session.dispose();
      image.close();
    }
  });
  for (const r of report.errors) {
    expect(r.peak).toBeLessThanOrEqual(1);
    expect(r.size).toEqual([109, 177]);
    expect(r.original).toEqual([109, 177]);
  }
  expect(report.exportSize).toEqual([160, 240]);
  expect(report.bits).toBe(16);
});

test("Layered Transport keeps its spatial support and global grain when developing a visible region", async ({
  page,
}) => {
  await page.goto("/");
  const report = await page.evaluate(async () => {
    const { loadPack, assetUrl, pixelSource, createCpuDeveloper } =
      await import("/src/engine.js");
    const { defaultEdit } = await import("/src/editor-state.js");
    const pack = await loadPack(assetUrl("packs/gold200.layered.pack"));
    const dev = await createCpuDeveloper(pack),
      width = 640,
      height = 480;
    const data = new Float32Array(width * height * 4);
    for (let y = 0; y < height; y++)
      for (let x = 0; x < width; x++)
        data.set(
          [x / width, x > 300 ? 2 : 0.2, y / height, 1],
          (y * width + x) * 4,
        );
    const source = pixelSource({ width, height, data }),
      region = { x: 177, y: 103, width: 229, height: 213 };
    try {
      const full = await dev.develop(source, defaultEdit().params);
      const roi = await dev.develop(
        source,
        defaultEdit().params,
        undefined,
        undefined,
        { region },
      );
      const expected = pixelSource({ width, height, data: full.pixels }).read(
        region.x,
        region.y,
        region.width,
        region.height,
      );
      let peak = 0;
      for (let i = 0; i < expected.length; i++)
        peak = Math.max(peak, Math.abs(expected[i] - roi.pixels[i]));
      return {
        peak,
        size: roi.pixels.length,
        expected: region.width * region.height * 4,
      };
    } finally {
      dev.dispose();
    }
  });
  expect(report.peak).toBeLessThanOrEqual(1);
  expect(report.size).toBe(report.expected);
});
