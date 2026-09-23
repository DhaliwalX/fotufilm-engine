import { test, expect } from "@playwright/test";
import { openChart } from "./photo-fixture.js";
import { installNativeBackend } from "./native-backend-fixture.js";

test("same editor uses native handles for preview, histogram, selection, Auto and export", async ({
  page,
}) => {
  const browserAssets = [],
    errors = [];
  page.on("request", (request) => {
    if (
      /\/(?:packs|profile|negative)\/|\.wasm(?:\?|$)|\/src\/backend\/browser/.test(
        request.url(),
      )
    )
      browserAssets.push(request.url());
  });
  page.on("pageerror", (error) => errors.push(error.message));
  await page.addInitScript(installNativeBackend);
  await page.goto("/");
  await expect(page.getByRole("progressbar")).toHaveCount(0);
  await openChart(page, 480, 320);
  const photo = page.getByAltText("Developed photo", { exact: true });
  await expect(photo).toBeVisible();
  await expect
    .poll(() => page.evaluate(() => window.nativeCalls.includes("thumbnail")))
    .toBe(true);
  await page.getByRole("button", { name: "Zoom in", exact: true }).click();
  await expect
    .poll(() => page.evaluate(() => window.nativeCalls.includes("viewport")))
    .toBe(true);
  await page
    .getByRole("button", { name: "Zoom to fit (0)", exact: true })
    .click();
  await page
    .getByRole("button", { name: "Histogram (H)", exact: true })
    .click();
  await expect
    .poll(() => page.evaluate(() => window.nativeCalls.includes("histogram")))
    .toBe(true);
  await page
    .getByRole("button", { name: "Histogram (H)", exact: true })
    .click();
  await page.getByRole("button", { name: "Selective", exact: true }).click();
  await page
    .getByRole("button", { name: "Sample a Point", exact: true })
    .click();
  await page.locator(".photo-plane").click({ position: { x: 100, y: 80 } });
  await expect
    .poll(() => page.evaluate(() => window.nativeCalls.includes("sampleScene")))
    .toBe(true);
  await page.getByRole("button", { name: "More options", exact: true }).click();
  await page
    .getByRole("menuitemcheckbox", { name: "Auto Adjust", exact: true })
    .click();
  await expect
    .poll(() => page.evaluate(() => window.nativeCalls.includes("autoAdjust")))
    .toBe(true);
  await page.keyboard.press("Escape");
  await page.getByRole("button", { name: "Export (⌘S)", exact: true }).click();
  await page
    .getByRole("dialog", { name: "Export image" })
    .getByRole("button", { name: "Export", exact: true })
    .click();
  await expect
    .poll(() => page.evaluate(() => window.nativeCalls.includes("exportImage")))
    .toBe(true);
  await openChart(page, 360, 240);
  await page.locator(".filmstrip-item").first().hover();
  await page
    .getByRole("button", { name: "Close Color chart.png", exact: true })
    .first()
    .click();
  await expect
    .poll(() =>
      page.evaluate(() => window.nativeCalls.includes("releaseImage")),
    )
    .toBe(true);
  expect(browserAssets).toEqual([]);
  expect(errors).toEqual([]);
});

test("incompatible native backend displays an actionable startup failure", async ({
  page,
}) => {
  await page.addInitScript(() => {
    window.fotufilmNative = { version: -1 };
  });
  await page.goto("/");
  await expect(page.getByRole("alert")).toContainText(
    "incompatible interface version",
  );
});

test("native preparation failure leaves a visible error instead of a stuck loader", async ({
  page,
}) => {
  await page.addInitScript(installNativeBackend, { failPreparation: true });
  await page.goto("/");
  await expect(page.getByRole("alert")).toContainText(
    "Native engine could not start",
  );
  await expect(page.getByRole("progressbar")).toHaveCount(0);
});
