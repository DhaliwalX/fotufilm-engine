import { test, expect } from "@playwright/test";
import { openChart } from "./photo-fixture.js";

async function recordWorkers(page) {
  await page.addInitScript(() => {
    window.engineEvents = [];
    window.engineWorkers = [];
    const OriginalWorker = window.Worker;
    window.Worker = class extends OriginalWorker {
      constructor(url, options) {
        super(url, options);
        const id = window.engineWorkers.push(String(url));
        this.addEventListener("message", ({ data }) => {
          if (
            ["warmup-progress", "gpu-ready", "result", "done"].includes(
              data.kind,
            )
          )
            window.engineEvents.push({
              id,
              kind: data.kind,
              completed: data.completed,
              available: data.available,
              backend: data.backend,
              label: data.label,
            });
        });
      }
    };
  });
}

test("startup compiles GPU families before import and reuses the prepared workers", async ({
  page,
}) => {
  test.setTimeout(300000);
  await recordWorkers(page);
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.goto("/");
  const progress = page.getByRole("progressbar", { name: "Preparing editor" });
  await expect(progress).toBeVisible();
  await expect(page.getByRole("button", { name: "Add media" })).toBeEnabled();
  await page
    .locator(".startup-progress .fotufilm-brand img")
    .evaluateAll((images) =>
      Promise.all(images.map((image) => image.decode())),
    );
  await page.screenshot({ path: "build/startup-progress.png" });
  await page.waitForFunction(
    () => window.engineEvents.some((e) => e.kind === "gpu-ready"),
    null,
    { timeout: 240000 },
  );
  const prepared = await page.evaluate(() => window.engineEvents);
  expect(prepared.find((e) => e.kind === "gpu-ready")?.available).toBe(true);
  expect(
    prepared
      .filter((e) => e.kind === "warmup-progress")
      .map((e) => e.completed),
  ).toEqual([0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]);
  await expect(progress).toBeHidden({ timeout: 30000 });
  await openChart(page, 320, 192);
  await page.waitForFunction(() =>
    window.engineEvents.some(
      (e) => e.kind === "result" && e.backend === "webgpu",
    ),
  );
  expect(
    await page.evaluate(
      () =>
        window.engineWorkers.filter((url) =>
          url.includes("/developer-worker.js"),
        ).length,
    ),
  ).toBe(1);
  const result = await page.evaluate(async () => {
    const { convertNegative } = await import("/src/negative-conversion.js");
    const { LinearImage } = await import("/src/linear-image.js");
    const image = new LinearImage({
      pixels: new Float32Array(64 * 48 * 4).fill(0.5),
      width: 64,
      height: 48,
    });
    const converted = await convertNegative(image, {
      parameters: [0, 0, 0, 1, 1, 1, 1, 0],
    });
    return {
      backend: converted.backend,
      workers: window.engineWorkers.filter((url) =>
        url.includes("/negative-conversion-worker.js"),
      ).length,
    };
  });
  expect(result).toEqual({ backend: "webgpu", workers: 1 });
  expect(errors).toEqual([]);
});

test("unsupported GPU finishes startup and leaves the editor usable", async ({
  page,
}) => {
  await page.addInitScript(() =>
    Object.defineProperty(navigator, "gpu", { value: undefined }),
  );
  await recordWorkers(page);
  await page.goto("/");
  await expect(
    page.getByRole("progressbar", { name: "Preparing editor" }),
  ).toBeHidden({ timeout: 30000 });
  await openChart(page, 96, 64);
  await expect(page.locator(".viewer-status > [role=status]")).toContainText(
    "96 × 64",
  );
  expect(
    await page.evaluate(
      () => window.engineEvents.find((e) => e.kind === "gpu-ready")?.available,
    ),
  ).toBe(false);
});

test("mobile loader fades away after a failed GPU download", async ({
  page,
}) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.emulateMedia({ reducedMotion: "reduce" });
  await recordWorkers(page);
  await page.route("**/fotufilm-webgpu.mjs*", (route) => route.abort());
  await page.route("**/negative/gpu.mjs*", (route) => route.abort());
  await page.goto("/");
  await page.waitForFunction(() =>
    window.engineEvents.some((e) => e.kind === "gpu-ready"),
  );
  await expect(page.locator(".startup-progress")).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Add media" })).toBeEnabled();
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBe(
    390,
  );
  expect(
    await page.evaluate(
      () => window.engineEvents.find((e) => e.kind === "gpu-ready")?.available,
    ),
  ).toBe(false);
});
