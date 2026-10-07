import { readFile } from "node:fs/promises";
import { test, expect } from "@playwright/test";
import { openChart } from "./photo-fixture.js";
import { installNativeBackend } from "./native-backend-fixture.js";

test("a scanned negative holds one native image while it is open", async ({
  page,
}) => {
  await page.addInitScript(installNativeBackend, { negativeScans: true });
  await page.goto("/");
  await openChart(page, 480, 320);
  await expect(
    page.getByAltText("Developed photo", { exact: true }),
  ).toBeVisible();
  // A scan of its own: the same bytes as the open photo would show that photo instead.
  const bytes = await page.evaluate(async () => {
    const canvas = document.createElement("canvas");
    canvas.width = 120;
    canvas.height = 80;
    const context = canvas.getContext("2d");
    context.fillStyle = "#c87838";
    context.fillRect(0, 0, 120, 80);
    const blob = await new Promise((resolve) => canvas.toBlob(resolve));
    return Array.from(new Uint8Array(await blob.arrayBuffer()));
  });
  const chooser = page.waitForEvent("filechooser");
  await page.getByRole("button", { name: "More options", exact: true }).click();
  await page
    .getByRole("menuitem", { name: "Import Scanned Negative…", exact: true })
    .click();
  await (await chooser).setFiles({
    name: "negative.png",
    mimeType: "image/png",
    buffer: Buffer.from(bytes),
  });
  await expect
    .poll(() => page.evaluate(() => window.nativeLiveImages()))
    .toBe(2);
  await page.locator(".filmstrip-item").last().hover();
  await page
    .getByRole("button", { name: "Close negative.png", exact: true })
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

test("opening several photos decodes the first and the others when chosen", async ({
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
  const imports = () =>
    page.evaluate(
      () => window.nativeCalls.filter((call) => call === "importMedia").length,
    );
  await page.locator("input[type=file][multiple]").setInputFiles(
    // A trailing byte after the image makes each a different file from the chart.
    ["one.png", "two.png", "three.png"].map((name, index) => ({
      name,
      mimeType: "image/png",
      buffer: Buffer.concat([Buffer.from(bytes), Buffer.from([index])]),
    })),
  );
  await expect(page.locator(".filmstrip-item")).toHaveCount(4);
  await expect(
    page.getByRole("button", { name: "Select one.png", exact: true }),
  ).toHaveAttribute("aria-current", "true");
  expect(await imports()).toBe(2);
  await expect
    .poll(() => page.evaluate(() => window.nativeLiveImages()))
    .toBe(2);
  // The waiting photographs show thumbnails without being decoded.
  await expect(page.locator(".filmstrip-preview img")).toHaveCount(4);
  await page
    .getByRole("button", { name: "Select three.png", exact: true })
    .click();
  await expect(
    page.getByRole("button", { name: "Select three.png", exact: true }),
  ).toHaveAttribute("aria-current", "true");
  expect(await imports()).toBe(3);
  await expect
    .poll(() => page.evaluate(() => window.nativeLiveImages()))
    .toBe(3);
  // Closing the photo shown opens its waiting neighbour.
  await page.locator(".filmstrip-item").last().hover();
  await page
    .getByRole("button", { name: "Close three.png", exact: true })
    .click();
  await expect(
    page.getByRole("button", { name: "Select two.png", exact: true }),
  ).toHaveAttribute("aria-current", "true");
  expect(await imports()).toBe(4);
  await expect
    .poll(() => page.evaluate(() => window.nativeLiveImages()))
    .toBe(3);
});
