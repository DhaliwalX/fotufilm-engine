import { readFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { resolve } from "node:path";
import { test, expect } from "@playwright/test";
import { openChart, openPanel } from "./photo-fixture.js";

test("lens worker tables agree with native and invalid requests leave the worker usable", async ({
  page,
}) => {
  await page.goto("/");
  for (const adjustment of [
    { distortion: 0, vignetting: 0, redCyan: 0, blueYellow: 0 },
    { distortion: -1, vignetting: 1, redCyan: -0.7, blueYellow: 0.4 },
    { distortion: 1, vignetting: -1, redCyan: 1, blueYellow: -1 },
  ]) {
    const request = { kind: "lens", adjustment };
    const native = execFileSync(
      resolve("../.build/release/fotufilm-web-profile"),
      { input: JSON.stringify(request) },
    );
    const result = await page.evaluate(
      async ({ request, reference }) => {
        const { loadFilmProfile } = await import("/src/film-profile.js");
        const { readLensTable } = await import("/src/lens-correction.js");
        const table = readLensTable(await loadFilmProfile(request));
        const expected = readLensTable(new Uint8Array(reference).buffer);
        let peak = 0;
        table.forEach((v, i) => {
          peak = Math.max(peak, Math.abs(v - expected[i]));
        });
        return peak;
      },
      { request, reference: [...native] },
    );
    expect(result).toBeLessThan(2e-6);
  }
  const recovered = await page.evaluate(async () => {
    const { loadFilmProfile } = await import("/src/film-profile.js");
    let rejected = false;
    try {
      await loadFilmProfile({
        kind: "lens",
        adjustment: { distortion: 2, vignetting: 0, redCyan: 0, blueYellow: 0 },
      });
    } catch {
      rejected = true;
    }
    const result = await loadFilmProfile({
      kind: "lens",
      adjustment: { distortion: 0.1, vignetting: 0, redCyan: 0, blueYellow: 0 },
    });
    return { rejected, size: result.byteLength };
  });
  expect(recovered).toEqual({ rejected: true, size: 16384 });
});

async function pixels(page) {
  return page.locator(".photo-plane > img").evaluate(async (image) => {
    await image.decode();
    const canvas = document.createElement("canvas");
    canvas.width = 100;
    canvas.height = 64;
    const ctx = canvas.getContext("2d");
    ctx.drawImage(image, 0, 0, 100, 64);
    let hash = 2166136261;
    for (const value of ctx.getImageData(0, 0, 100, 64).data)
      hash = Math.imul(hash ^ value, 16777619) >>> 0;
    return hash;
  });
}

test("Lens controls retain edits on bypass, undo, save/load and export without clipping", async ({
  page,
}, testInfo) => {
  test.setTimeout(180000);
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.goto("/");
  await openChart(page);
  await expect(page.locator(".viewer-status > [role=status]")).toContainText(
    /1600 × 1000/,
  );
  await openPanel(page, "Expose");
  const toggle = page.getByRole("switch", {
    name: "Lens Correction",
    exact: true,
  });
  const before = await pixels(page);
  await toggle.click();
  const input = page.getByRole("spinbutton", {
    name: "Distortion value",
    exact: true,
  });
  await input.fill("0.8");
  await input.press("Tab");
  await expect.poll(() => pixels(page)).not.toEqual(before);
  await expect.poll(() => page.locator(".photo-plane > img").evaluate((image) => image.naturalWidth)).toBe(1600);
  const corrected = await pixels(page);
  await toggle.click();
  await expect.poll(() => pixels(page)).toEqual(before);
  await toggle.click();
  await expect(input).toHaveValue("0.8");
  await expect.poll(() => pixels(page)).toEqual(corrected);
  await page.getByRole("button", { name: "Reset Lens", exact: true }).click();
  await expect.poll(() => pixels(page)).toEqual(before);
  await page.getByRole("button", { name: "Undo (⌘Z)", exact: true }).click();
  await expect(input).toHaveValue("0.8");
  await expect.poll(() => pixels(page)).toEqual(corrected);
  await input.scrollIntoViewIfNeeded();
  const inspector = await page
    .getByRole("complementary", { name: "Adjustments", exact: true })
    .boundingBox();
  for (const row of await page.locator(".lens-adjustments .adjustment").all()) {
    const bounds = await row.boundingBox();
    expect(bounds.x).toBeGreaterThanOrEqual(inspector.x);
    expect(bounds.x + bounds.width).toBeLessThanOrEqual(
      inspector.x + inspector.width,
    );
  }
  await page.screenshot({ path: testInfo.outputPath("lens-correction.png") });
  await page.getByRole("button", { name: "More options", exact: true }).click();
  const download = page.waitForEvent("download");
  await page.getByRole("button", { name: "Save edits…", exact: true }).click();
  const saved = await readFile(await (await download).path());
  expect(JSON.parse(saved).edit.lens).toEqual({
    enabled: true,
    amount: 1,
    profileID: null,
    distortion: 0.8,
    vignetting: 0,
    redCyan: 0,
    blueYellow: 0,
  });
  await page
    .locator('input[type=file][accept=".json"]')
    .setInputFiles({
      name: "lens.json",
      mimeType: "application/json",
      buffer: saved,
    });
  await expect.poll(() => pixels(page)).toEqual(corrected);
  await page.getByRole("button", { name: "Export (⌘S)", exact: true }).click();
  const exported = page.waitForEvent("download");
  await page.getByRole("button", { name: "Export", exact: true }).click();
  const png = await readFile(await (await exported).path());
  expect(png.readUInt32BE(16)).toBe(1600);
  expect(png.readUInt32BE(20)).toBe(1000);
  expect(errors).toEqual([]);
  await expect(page.locator(".error-banner")).toHaveCount(0);
});
