import { test, expect } from "@playwright/test";
import { openChart } from "./photo-fixture.js";

async function open(page) {
  await page.addInitScript(() => {
    Object.defineProperty(navigator, "gpu", { value: undefined });
    window.viewportStarts = [];
    const WorkerBase = Worker;
    window.Worker = class extends WorkerBase {
      postMessage(data, ...options) {
        if (
          window.recordViewport &&
          data.kind === "develop" &&
          data.output?.region
        )
          window.viewportStarts.push(performance.now() - window.lastPhotoMove);
        return super.postMessage(data, ...options);
      }
    };
    document.addEventListener(
      "pointermove",
      (event) => {
        if (event.target.closest(".canvas-area"))
          window.lastPhotoMove = performance.now();
      },
      true,
    );
  });
  await page.goto("/");
  await openChart(page, 1600, 1000);
  await expect(page.locator(".viewport-detail")).toBeVisible();
}
async function pixels(detail) {
  return detail.evaluate((img) => {
    const rect = img.getBoundingClientRect(),
      room = img.closest(".canvas-area");
    return {
      width: img.naturalWidth,
      height: img.naturalHeight,
      dpr: devicePixelRatio,
      screen: [rect.width, rect.height],
      room: [room.clientWidth, room.clientHeight],
      x: img.dataset.regionX,
      y: img.dataset.regionY,
      frame: Number(img.dataset.frameWidth),
    };
  });
}
function displayResolution(value) {
  for (const [axis, count] of [value.width, value.height].entries()) {
    expect(Math.abs(count - value.screen[axis] * value.dpr)).toBeLessThan(2);
    expect(count).toBeLessThanOrEqual(value.room[axis] * value.dpr + 2);
  }
}

test.describe("debounced Retina viewport", () => {
  test.use({ viewport: { width: 1100, height: 800 }, deviceScaleFactor: 2 });
  test("paused panning updates full display detail before pointer release without dropping the old surface", async ({
    page,
  }) => {
    await open(page);
    const detail = page.locator(".viewport-detail"),
      viewer = page.getByLabel("Photo preview", { exact: true });
    await viewer.hover();
    await page.mouse.wheel(0, -100);
    for (let i = 0; i < 14; i++) await page.mouse.wheel(0, -100);
    await expect
      .poll(async () => (await pixels(detail)).frame)
      .toBeGreaterThan(2000);
    await expect
      .poll(async () => {
        const value = await pixels(detail);
        return Math.abs(value.width - value.screen[0] * value.dpr);
      })
      .toBeLessThan(2);
    const before = await pixels(detail);
    const bounds = await viewer.boundingBox();
    await page.evaluate(() => {
      window.recordViewport = true;
      window.detailGaps = 0;
      window.detailObserver = new MutationObserver(() => {
        if (!document.querySelector(".viewport-detail")) window.detailGaps++;
      });
      window.detailObserver.observe(document.querySelector(".photo-plane"), {
        subtree: true,
        childList: true,
      });
    });
    await page.mouse.move(
      bounds.x + bounds.width / 2,
      bounds.y + bounds.height / 2,
    );
    await page.mouse.down();
    for (let i = 1; i <= 12; i++) {
      await page.mouse.move(
        bounds.x + bounds.width / 2 + i * 7,
        bounds.y + bounds.height / 2 + i * 3,
      );
      await expect(detail).toBeVisible();
    }
    // Still holding the pointer: the old settling-only renderer cannot pass.
    await expect.poll(async () => (await pixels(detail)).x).not.toBe(before.x);
    displayResolution(await pixels(detail));
    expect(await page.evaluate(() => window.detailGaps)).toBe(0);
    const starts = await page.evaluate(() => window.viewportStarts);
    expect(starts.length).toBeGreaterThan(0);
    expect(starts.every((delay) => delay >= 280)).toBe(true);
    await page.mouse.up();
  });
});

test("phone pinch zoom and one-finger continuation refresh the visible region", async ({
  page,
  context,
}) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await open(page);
  const detail = page.locator(".viewport-detail");
  const before = await pixels(detail);
  const bounds = await page
    .getByLabel("Photo preview", { exact: true })
    .boundingBox();
  const x = bounds.x + bounds.width / 2,
    y = bounds.y + bounds.height / 2;
  const cdp = await context.newCDPSession(page);
  const touch = (id, x, y) => ({ id, x, y, radiusX: 4, radiusY: 4, force: 1 });
  await cdp.send("Input.dispatchTouchEvent", {
    type: "touchStart",
    touchPoints: [touch(1, x - 30, y), touch(2, x + 30, y)],
  });
  for (let i = 1; i <= 8; i++)
    await cdp.send("Input.dispatchTouchEvent", {
      type: "touchMove",
      touchPoints: [touch(1, x - 30 - i * 8, y), touch(2, x + 30 + i * 8, y)],
    });
  await expect
    .poll(async () => (await pixels(detail)).frame)
    .toBeGreaterThan(before.frame * 2);
  const pinched = await pixels(detail);
  displayResolution(pinched);
  await cdp.send("Input.dispatchTouchEvent", {
    type: "touchEnd",
    touchPoints: [touch(2, x + 94, y)],
  });
  await cdp.send("Input.dispatchTouchEvent", {
    type: "touchMove",
    touchPoints: [touch(1, x - 64, y + 25)],
  });
  await expect.poll(async () => (await pixels(detail)).x).not.toBe(pinched.x);
  displayResolution(await pixels(detail));
  await cdp.send("Input.dispatchTouchEvent", {
    type: "touchEnd",
    touchPoints: [],
  });
  await expect(
    page.getByAltText("Original photo", { exact: true }),
  ).toHaveCount(0);
});
