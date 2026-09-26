import { openEditor } from "./photo-fixture.js";
import { test, expect } from "@playwright/test";

test("large background development stays responsive and discards superseded detail", async ({
  page,
}) => {
  await openEditor(page);
  const report = await page.evaluate(async () => {
    const { createBackgroundDeveloper } = await import(
      "/src/background-developer.js"
    );
    const { defaultEdit } = await import("/src/editor-state.js");
    const developer = await createBackgroundDeveloper(null);
    await developer.gpuReady;
    const source = (width, height) => ({
      width,
      height,
      read(x, y, w, h) {
        const pixels = new Float32Array(w * h * 4);
        for (let i = 0; i < pixels.length; i += 4) {
          pixels[i] = 0.18;
          pixels[i + 1] = 0.3;
          pixels[i + 2] = 0.6;
          pixels[i + 3] = 1;
        }
        return pixels;
      },
    });
    let ticks = 0,
      gap = 0,
      last = performance.now(),
      cancelled = false;
    const timer = setInterval(() => {
      const now = performance.now();
      gap = Math.max(gap, now - last);
      last = now;
      ticks++;
    }, 10);
    try {
      const pending = developer.develop(
        source(6000, 4000),
        defaultEdit().params,
        () => {},
        () => cancelled,
      );
      setTimeout(() => {
        cancelled = true;
      }, 30);
      const abandoned = await pending;
      const detailed = await developer.develop(
        source(3200, 2000),
        defaultEdit().params,
      );
      const small = await developer.develop(
        source(320, 200),
        defaultEdit().params,
      );
      return {
        backend: developer.backend,
        abandoned: abandoned === null,
        ticks,
        gap,
        large: detailed.pixels.length,
        small: small.pixels.length,
        pixel: Array.from(detailed.pixels.slice(0, 4)),
      };
    } finally {
      clearInterval(timer);
      developer.dispose();
    }
  });
  console.log("Background development:", report);
  expect(report.backend).toBe("webgpu");
  expect(report.abandoned).toBe(true);
  expect(report.large).toBe(3200 * 2000 * 4);
  expect(report.small).toBe(320 * 200 * 4);
  expect(report.ticks).toBeGreaterThan(4);
  expect(report.gap).toBeLessThan(200);
  expect(report.pixel[3]).toBe(255);
});

test("zoom waits for movement to settle before requesting high resolution", async ({
  page,
}) => {
  const { openChart } = await import("./photo-fixture.js");
  await page.addInitScript(() => {
    const NativeWorker = window.Worker;
    window.developmentRequests = [];
    window.Worker = class extends NativeWorker {
      postMessage(message, ...args) {
        if (message.kind === "develop")
          window.developmentRequests.push({
            width: message.width,
            height: message.height,
            region: message.output?.region,
            time: performance.now(),
          });
        return super.postMessage(message, ...args);
      }
    };
  });
  await page.goto("/");
  await openChart(page, 3200, 2000);
  const status = page.locator(".viewer-status > [role=status]");
  await expect(status).toContainText("1600 × 1000");
  await expect(page.locator(".viewport-detail")).toBeVisible();
  await page.evaluate(() => {
    window.developmentRequests = [];
  });
  await page.getByLabel("Photo preview", { exact: true }).hover();
  for (let i = 0; i < 12; i++) {
    await page.mouse.wheel(0, -60);
    await page.waitForTimeout(30);
  }
  const during = await page.evaluate(() => window.developmentRequests);
  expect(during.every(request => !request.region)).toBe(true);
  await expect(page.locator(".viewport-detail")).toBeVisible();
  const after = await page.evaluate(() => window.developmentRequests);
  expect(after.some(request => request.region)).toBe(true);
  expect(after.every(request => request.region || Math.max(request.width, request.height) <= 1600)).toBe(true);
  await expect(status).toContainText("1600 × 1000");
});
