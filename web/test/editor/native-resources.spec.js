import { readFile } from "node:fs/promises";
import { test, expect } from "@playwright/test";
import { openChart } from "./photo-fixture.js";
import { installNativeBackend } from "./native-backend-fixture.js";

test("negative dialog releases provisional native images and transfers an accepted positive", async ({
  page,
}) => {
  await page.addInitScript(installNativeBackend);
  await page.goto("/");
  await openChart(page, 480, 320);
  await expect(
    page.getByAltText("Developed photo", { exact: true }),
  ).toBeVisible();
  const bytes = await page.evaluate(async () =>
    Array.from(
      new Uint8Array(
        await (
          await fetch(document.querySelector('img[alt="Developed photo"]').src)
        ).arrayBuffer(),
      ),
    ),
  );
  async function openNegative() {
    await page
      .getByRole("button", { name: "More options", exact: true })
      .click();
    await page
      .getByRole("menuitem", { name: "Import Scanned Negative…", exact: true })
      .click();
    await page.locator(".negative-import input[type=file]").setInputFiles({
      name: "negative.png",
      mimeType: "image/png",
      buffer: Buffer.from(bytes),
    });
    await expect(page.getByAltText("Converted positive preview")).toBeVisible();
  }
  await openNegative();
  await expect
    .poll(() => page.evaluate(() => window.nativeLiveImages()))
    .toBe(3);
  await page
    .getByRole("dialog")
    .getByRole("button", { name: "Cancel", exact: true })
    .click();
  await expect
    .poll(() => page.evaluate(() => window.nativeLiveImages()))
    .toBe(1);
  await openNegative();
  await page
    .getByRole("button", { name: "Import Positive", exact: true })
    .click();
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await expect
    .poll(() => page.evaluate(() => window.nativeLiveImages()))
    .toBe(2);
  await page.locator(".filmstrip-item").last().hover();
  await page
    .getByRole("button", { name: "Close negative.png — Positive", exact: true })
    .click();
  await expect
    .poll(() => page.evaluate(() => window.nativeLiveImages()))
    .toBe(1);
});

test("cancelling a native colour sample discards its late result", async ({
  page,
}) => {
  await page.addInitScript(installNativeBackend);
  await page.goto("/");
  await openChart(page, 480, 320);
  await expect(
    page.getByAltText("Developed photo", { exact: true }),
  ).toBeVisible();
  await page.evaluate(() => {
    window.nativeHoldSamples = true;
  });
  await page.getByRole("button", { name: "Selective", exact: true }).click();
  await page
    .getByRole("button", { name: "Sample a Point", exact: true })
    .click();
  await page.locator(".photo-plane").click({ position: { x: 100, y: 80 } });
  await expect
    .poll(() => page.evaluate(() => !!window.nativeResolveSample))
    .toBe(true);
  await page
    .getByRole("button", { name: "Click the Photo…", exact: true })
    .click();
  await page.evaluate(() => window.nativeResolveSample());
  await page.getByRole("button", { name: "More options", exact: true }).click();
  const download = page.waitForEvent("download");
  await page
    .getByRole("menuitem", { name: "Save edits…", exact: true })
    .click();
  const saved = JSON.parse(
    await readFile(await (await download).path(), "utf8"),
  );
  expect(saved.edit.selective).toBeNull();
});

test("a cancelled native import releases its late image and retains the current photograph", async ({
  page,
}) => {
  await page.addInitScript(installNativeBackend);
  await page.goto("/");
  await openChart(page, 480, 320);
  const photo = page.getByAltText("Developed photo", { exact: true });
  await expect(photo).toBeVisible();
  const original = await photo.getAttribute("src");
  await page.evaluate(() => {
    window.nativeHoldImports = true;
  });
  await openChart(page, 360, 240);
  await expect
    .poll(() => page.evaluate(() => !!window.nativeResolveImport))
    .toBe(true);
  await page
    .locator(".import-status")
    .getByRole("button", { name: "Cancel", exact: true })
    .click();
  await page.evaluate(() => window.nativeResolveImport());
  await expect
    .poll(() => page.evaluate(() => window.nativeLiveImages()))
    .toBe(1);
  await expect(photo).toHaveAttribute("src", original);
  await expect(
    page.getByRole("button", { name: "Close Color chart.png", exact: true }),
  ).toHaveCount(0);
});
