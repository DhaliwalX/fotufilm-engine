import { test, expect } from "@playwright/test";
import { makeDNG } from "./raw-fixture.js";

// Exercise the phone CPU path without repeating the GPU startup suite.
test.beforeEach(async ({ page }) => {
  await page.addInitScript(() =>
    Object.defineProperty(navigator, "gpu", { value: undefined }),
  );
});

async function preview(page, failWorker = false) {
  return page.evaluate(async (failWorker) => {
    const { developImportPreview } = await import("/src/normal-preview.js");
    const { developNormalReference } = await import("/src/engine.js");
    const { defaultEdit } = await import("/src/editor-state.js");
    const OriginalWorker = window.Worker;
    let workerCount = 0;
    window.Worker = class extends OriginalWorker {
      constructor(url, options) {
        workerCount++;
        super(
          failWorker
            ? 'data:text/javascript,throw new Error("preview worker stopped")'
            : url,
          options,
        );
      }
    };
    try {
      const source = {
        width: 96,
        height: 64,
        read(x, y, width, height) {
          const pixels = new Float32Array(width * height * 4);
          for (let i = 0; i < pixels.length; i += 4)
            pixels.set([0.12, 0.18, 0.3, 1], i);
          return pixels;
        },
      };
      const result = await developImportPreview(source, defaultEdit().params);
      const reference = await developNormalReference(
        source,
        defaultEdit().params,
        undefined,
        undefined,
        { colorSpace: result.colorSpace },
      );
      return {
        workerCount,
        same: result.pixels.every((v, i) => v === reference.pixels[i]),
        length: result.pixels.length,
      };
    } finally {
      window.Worker = OriginalWorker;
    }
  }, failWorker);
}

test("import placeholder uses no additional WASM runtime and matches the linear reference", async ({
  page,
}) => {
  await page.goto("/");
  await expect(page.locator(".startup-progress")).toHaveCount(0, {
    timeout: 180000,
  });
  const runtimes = [];
  page.on("request", (request) => {
    if (/fotufilm(?:-webgpu)?\.(?:wasm|mjs)/.test(request.url()))
      runtimes.push(request.url());
  });
  expect(await preview(page)).toEqual({
    workerCount: 1,
    same: true,
    length: 96 * 64 * 4,
  });
  expect(runtimes).toEqual([]);
});

test("a failed import worker keeps the decoded image and uses the same bounded transform", async ({
  page,
}) => {
  await page.goto("/");
  expect(await preview(page, true)).toEqual({
    workerCount: 1,
    same: true,
    length: 96 * 64 * 4,
  });
});

test("cancelling during import preview startup terminates the worker without recovery", async ({
  page,
}) => {
  await page.goto("/");
  const result = await page.evaluate(async () => {
    const { developImportPreview } = await import("/src/normal-preview.js");
    const OriginalWorker = window.Worker;
    const controller = new AbortController();
    let terminated = 0,
      reads = 0;
    window.Worker = class extends OriginalWorker {
      constructor(url, options) {
        super("data:text/javascript,self.onmessage=()=>{}", options);
        queueMicrotask(() => controller.abort());
      }
      terminate() {
        terminated++;
        super.terminate();
      }
    };
    try {
      await developImportPreview(
        {
          width: 1,
          height: 1,
          read() {
            reads++;
          },
        },
        {},
        { signal: controller.signal },
      );
      return { error: null };
    } catch (error) {
      return { error: error.name, terminated, reads };
    } finally {
      window.Worker = OriginalWorker;
    }
  });
  expect(result).toEqual({ error: "AbortError", terminated: 1, reads: 0 });
});

test("a 12-megapixel DNG opens after its import-preview worker fails", async ({
  page,
}) => {
  test.setTimeout(180000);
  await page.goto("/");
  await expect(page.locator(".startup-progress")).toHaveCount(0, {
    timeout: 180000,
  });
  await page.evaluate(() => {
    const OriginalWorker = window.Worker;
    window.Worker = class extends OriginalWorker {
      constructor(url, options) {
        super(
          String(url).includes("developer-worker")
            ? 'data:text/javascript,throw new Error("preview worker stopped")'
            : url,
          options,
        );
      }
    };
  });
  await page.locator("input[type=file][multiple]").setInputFiles({
    name: "synthetic-12mp.dng",
    mimeType: "image/x-adobe-dng",
    buffer: Buffer.from(makeDNG({ width: 4032, height: 3024 })),
  });
  await expect(
    page.getByAltText("Developed photo", { exact: true }),
  ).toBeVisible({ timeout: 120000 });
  await expect(page.locator(".viewer-status > [role=status]")).toContainText(
    "1600 × 1200",
  );
});
