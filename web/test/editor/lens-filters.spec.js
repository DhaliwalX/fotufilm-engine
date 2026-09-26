import { readFile } from "node:fs/promises";
import { test, expect } from "@playwright/test";
import { openChart, openPanel } from "./photo-fixture.js";

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

test("Mac filter stack edits change pixels and survive ordering, undo, save and export", async ({
  page,
}, testInfo) => {
  test.setTimeout(180000);
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto("/");
  await openChart(page);
  await page.getByRole("searchbox", { name: "Search films" }).fill("Gold 200");
  await page.getByTitle("Gold 200", { exact: true }).click();
  await expect(page.locator(".viewer-status > [role=status]")).toContainText(
    /1600 × 1000/,
  );
  await openPanel(page, "Expose");
  const choose = async (name, option) => {
    await page.getByRole("combobox", { name, exact: true }).click();
    await page.getByRole("option", { name: option, exact: true }).click();
  };
  const before = await pixels(page);
  await choose("Add Filter", "85B");
  await expect.poll(() => pixels(page)).not.toEqual(before);
  const amber = await pixels(page);
  await choose("Add Filter", "Black Pro-Mist 1/2");
  await expect.poll(() => pixels(page)).not.toEqual(amber);
  const mist = await pixels(page);
  await choose("Add Filter", "Fog 1");
  await expect(page.locator(".filter-note")).toContainText(
    "Only the first diffusion filter acts",
  );
  await page
    .getByRole("group", { name: "Filter 3", exact: true })
    .getByRole("button", { name: "Move filter nearer the lens", exact: true })
    .click();
  await expect(
    page.getByRole("combobox", { name: "Filter 2", exact: true }),
  ).toContainText("Fog 1");
  await expect.poll(() => pixels(page)).not.toEqual(mist);
  await choose("Metering", "None");
  await page.locator(".fitted-filter").first().scrollIntoViewIfNeeded();
  const inspector = await page
    .getByRole("complementary", { name: "Adjustments", exact: true })
    .boundingBox();
  for (const row of await page.locator(".fitted-filter").all()) {
    const bounds = await row.boundingBox();
    expect(bounds.x).toBeGreaterThanOrEqual(inspector.x);
    expect(bounds.x + bounds.width).toBeLessThanOrEqual(
      inspector.x + inspector.width,
    );
  }
  await page.screenshot({ path: testInfo.outputPath("filters.png") });
  await page
    .getByRole("button", { name: "Take Them All Off", exact: true })
    .click();
  await expect(page.locator(".fitted-filter")).toHaveCount(0);
  await expect.poll(() => pixels(page)).toEqual(before);
  await page.getByRole("button", { name: "Undo (⌘Z)", exact: true }).click();
  await expect(page.locator(".fitted-filter")).toHaveCount(3);
  await page.getByRole("button", { name: "More options", exact: true }).click();
  const saveDownload = page.waitForEvent("download");
  await page.getByRole("button", { name: "Save edits…", exact: true }).click();
  const savedBytes = await readFile(await (await saveDownload).path());
  const saved = JSON.parse(savedBytes);
  expect(saved.edit.filters).toEqual(["w85b", "fog-1", "blackpromist-1/2"]);
  expect(saved.edit.filterMetering).toBe("none");
  await page
    .locator('input[type=file][accept=".json"]')
    .setInputFiles({
      name: "filters.json",
      mimeType: "application/json",
      buffer: savedBytes,
    });
  await page.getByRole("button", { name: "Export (⌘S)", exact: true }).click();
  const exportDownload = page.waitForEvent("download");
  await page.getByRole("button", { name: "Export", exact: true }).click();
  const png = await readFile(await (await exportDownload).path());
  expect(png.readUInt32BE(16)).toBe(1600);
  expect(png.readUInt32BE(20)).toBe(1000);
  expect(errors).toEqual([]);
  await expect(page.locator(".error-banner")).toHaveCount(0);
});
