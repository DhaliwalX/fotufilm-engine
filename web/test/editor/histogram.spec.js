import { test, expect } from "@playwright/test";
import { openChart } from "./photo-fixture.js";

test.use({ ignoreHTTPSErrors: true });

test("histogram opens, draws, drags and reopens while zooming and cropping", async ({
  page,
}) => {
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.goto(process.env.FOTUFILM_TEST_URL || "/");
  await openChart(page);
  await expect(page.locator(".viewer-status > [role=status]")).toContainText(
    "1600 × 1000",
  );

  const toggle = page.getByRole("button", {
    name: "Histogram (H)",
    exact: true,
  });
  const histogram = page.locator(".histogram");
  const plane = page.locator(".photo-plane");
  const transform = () =>
    plane.evaluate((element) => {
      const matrix = new DOMMatrix(getComputedStyle(element).transform);
      return { x: matrix.m41, y: matrix.m42, scale: matrix.a };
    });
  await toggle.click();
  await expect(histogram).toBeVisible();
  await expect(histogram.locator("canvas")).toHaveAttribute("aria-label", /logarithmic pixel counts/);
  await expect
    .poll(() =>
      histogram.locator("canvas").evaluate((canvas) => {
        const pixels = canvas
          .getContext("2d")
          .getImageData(0, 0, canvas.width, canvas.height).data;
        return pixels.some((value, index) => index % 4 === 3 && value > 0);
      }),
    )
    .toBe(true);

  const before = await histogram.boundingBox();
  const header = await page.locator(".histogram-header span").boundingBox();
  const photoBefore = await transform();
  await page.mouse.move(header.x + 20, header.y + 8);
  await page.mouse.down();
  await page.mouse.move(header.x + 100, header.y + 58, { steps: 5 });
  await page.mouse.up();
  await expect
    .poll(async () => (await histogram.boundingBox()).x - before.x)
    .toBeCloseTo(80, 0);
  await expect
    .poll(async () => (await histogram.boundingBox()).y - before.y)
    .toBeCloseTo(50, 0);
  expect(await transform()).toEqual(photoBefore);
  await page.getByRole("button", { name: "Close histogram" }).click();
  await expect(histogram).toBeHidden();

  await page.getByRole("button", { name: "Zoom in", exact: true }).click();
  const room = await page.locator(".canvas-area").boundingBox();
  await page.mouse.move(room.x + room.width / 2, room.y + room.height / 2);
  await page.mouse.down();
  await page.mouse.move(
    room.x + room.width / 2 + 40,
    room.y + room.height / 2 + 30,
    { steps: 5 },
  );
  await page.mouse.up();
  await expect.poll(async () => (await transform()).x).toBeCloseTo(40, 0);
  await toggle.click();
  await expect(histogram).toBeVisible();
  await page.getByRole("button", { name: "Crop", exact: true }).click();
  await expect.poll(transform).toEqual({ x: 0, y: 0, scale: 1 });
  await expect(histogram).toBeVisible();
  await page.getByRole("button", { name: "Close histogram" }).click();
  await toggle.click();
  await expect(histogram).toBeVisible();
  expect(errors).toEqual([]);
});
