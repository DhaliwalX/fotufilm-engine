import { test, expect } from "@playwright/test";
import { openChart } from "./photo-fixture.js";

test("a stalled colour compiler recovers to a usable CPU editor", async ({
  page,
}) => {
  await page.addInitScript(() => {
    const schedule = window.setTimeout;
    window.setTimeout = (callback, delay, ...args) =>
      schedule(callback, delay === 90000 ? 5000 : delay, ...args);
  });
  await page.route("**/negative/gpu.mjs*", (route) => route.abort());
  await page.route("**/src/developer-worker.js*", async (route) => {
    const response = await route.fetch();
    await route.fulfill({
      response,
      body:
        (await response.text()) +
        `
        const originalHandler = self.onmessage;
        const originalSend = self.postMessage.bind(self);
        let simulateStall = false;
        self.postMessage = (data, ...transfer) => {
          if (simulateStall && data.kind === 'gpu-ready') {
            originalSend({kind:'warmup-progress', completed:2, total:11,
              label:'Preparing colour films'});
          } else originalSend(data, ...transfer);
        };
        self.onmessage = event => {
          if (event.data.kind === 'initialize') {
            simulateStall = event.data.preferGpu;
            event.data.preferGpu = false;
          }
          return originalHandler(event);
        };
      `,
    });
  });
  await page.addInitScript(() => {
    window.recoveryWorkers = [];
    window.recoveryEvents = [];
    const Base = Worker;
    window.Worker = class extends Base {
      constructor(url, options) {
        super(url, options);
        if (String(url).includes("developer-worker")) {
          window.recoveryWorkers.push(this);
          this.addEventListener("message", ({ data }) =>
            window.recoveryEvents.push({
              kind: data.kind,
              available: data.available,
            }),
          );
        }
      }
    };
  });
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.goto("/");
  const progress = page.getByRole("progressbar", { name: "Preparing editor" });
  await expect(page.locator(".startup-progress")).toContainText(
    "Preparing colour films",
  );
  await expect(progress).toBeVisible();
  await expect(progress).not.toHaveAttribute("aria-valuenow");
  await openChart(page, 320, 192);
  await expect(page.locator(".viewer-status > [role=status]")).toContainText(
    "320 × 192",
  );
  await expect
    .poll(() => page.evaluate(() => window.recoveryWorkers.length))
    .toBe(2);
  await expect(progress).toBeHidden();
  expect(
    await page.evaluate(() =>
      window.recoveryEvents.some(
        (event) => event.kind === "gpu-ready" && event.available === false,
      ),
    ),
  ).toBe(true);
  await openChart(page, 160, 96);
  await expect(page.locator(".viewer-status > [role=status]")).toContainText(
    "160 × 96",
  );
  expect(errors).toEqual([]);
});
