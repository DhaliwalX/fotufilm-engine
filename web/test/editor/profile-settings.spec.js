import { readFile } from "node:fs/promises";
import { test, expect } from "@playwright/test";
import { openChart } from "./photo-fixture.js";

async function ready(page) {
  await expect(page.locator(".viewer-status > [role=status]")).toContainText(
    /1600 × 1000/,
  );
  await expect(page.locator(".error-banner")).toHaveCount(0);
}
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

test("native film settings update pixels, undo, save and full-size export", async ({
  page,
}, testInfo) => {
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto("/");
  await openChart(page);
  await ready(page);
  await page.getByRole("searchbox", { name: "Search films" }).fill("Gold 200");
  await page.getByTitle("Gold 200", { exact: true }).click();
  await ready(page);
  await page.getByRole("tab", { name: "Film", exact: true }).click();
  const before = await pixels(page);
  await page
    .getByRole("spinbutton", { name: "Expired value", exact: true })
    .fill("10");
  await page
    .getByRole("spinbutton", { name: "Expired value", exact: true })
    .press("Tab");
  await ready(page);
  const aged = await pixels(page);
  expect(aged).not.toEqual(before);
  await page.getByRole("button", { name: "Undo (⌘Z)", exact: true }).click();
  await expect(
    page.getByRole("spinbutton", { name: "Expired value", exact: true }),
  ).toHaveValue("0");
  await ready(page);
  await expect.poll(() => pixels(page)).toEqual(before);
  await page.getByRole("button", { name: "Redo (⇧⌘Z)", exact: true }).click();
  await ready(page);
  await expect.poll(() => pixels(page)).toEqual(aged);
  await page.getByRole("tab", { name: "Develop", exact: true }).click();
  await page
    .getByRole("combobox", { name: "Grain Model", exact: true })
    .click();
  await page
    .getByRole("option", { name: "Organic Crystals", exact: true })
    .click();
  await ready(page);
  expect(await pixels(page)).not.toEqual(aged);
  await page.getByRole("tab", { name: "Film", exact: true }).click();
  await page.getByRole("combobox", { name: "Format", exact: true }).click();
  await page.getByRole("option", { name: "16mm", exact: true }).click();
  await ready(page);
  await page.screenshot({ path: testInfo.outputPath("film-settings.png") });
  const image = await page.locator(".photo-plane > img").getAttribute("src");
  expect(image).toMatch(/^blob:/);
  await page.getByRole("button", { name: "More options", exact: true }).click();
  const savedPromise = page.waitForEvent("download");
  await page.getByRole("button", { name: "Save edits…", exact: true }).click();
  const saved = JSON.parse(
    await readFile(await (await savedPromise).path(), "utf8"),
  );
  expect(saved.edit.format).toBe("16mm");
  expect(saved.edit.profile).toMatchObject({
    expired: 10,
    grainModel: "crystals",
  });
  await page.getByRole("button", { name: "Export (⌘S)", exact: true }).click();
  const exportPromise = page.waitForEvent("download");
  await page.getByRole("button", { name: "Export", exact: true }).click();
  const png = await readFile(await (await exportPromise).path());
  expect(png.readUInt32BE(16)).toBe(1600);
  expect(png.readUInt32BE(20)).toBe(1000);
  expect(errors).toEqual([]);
});
