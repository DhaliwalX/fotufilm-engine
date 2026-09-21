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

test("halation curves, chemistry and printer controls retain settings across media, save and export", async ({
  page,
}, testInfo) => {
  test.setTimeout(180000);
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto("/");
  await openChart(page);
  await ready(page);
  await page.getByRole("searchbox", { name: "Search films" }).fill("Gold 200");
  await page.getByTitle("Gold 200", { exact: true }).click();
  await ready(page);
  const choose = async (name, option) => {
    await page.getByRole("combobox", { name, exact: true }).click();
    await page.getByRole("option", { name: option, exact: true }).click();
  };
  const number = async (name, value) => {
    const input = page.getByRole("spinbutton", {
      name: `${name} value`,
      exact: true,
    });
    await input.fill(String(value));
    await input.press("Tab");
  };
  await page.getByRole("tab", { name: "Film", exact: true }).click();
  await expect(page.locator(".inspector-section").first()).toContainText(
    "Loaded Film",
  );
  await number("Halation Return", 12);
  const curve = page.getByRole("slider", {
    name: "Return Spectrum 650 nm",
    exact: true,
  });
  await curve.focus();
  await curve.press("ArrowUp");
  await expect(curve).toHaveAttribute("aria-valuenow", "0.1");
  await page
    .getByRole("button", { name: "Use Film Return", exact: true })
    .click();
  await expect(
    page.getByRole("button", { name: "Use Film Return", exact: true }),
  ).toBeDisabled();
  await ready(page);
  await page.getByRole("tab", { name: "Develop", exact: true }).click();
  const before = await pixels(page);
  await choose("Bleach Bypass", "Half");
  await expect.poll(() => pixels(page)).not.toEqual(before);
  await number("Couplers", 1.5);
  await page.getByRole("tab", { name: "Print", exact: true }).click();
  await choose("Output medium", "Kodak Ektacolor Edge Paper");
  const printer = page.getByRole("switch", {
    name: "Simulated Printer",
    exact: true,
  });
  const lamp = page.getByRole("spinbutton", {
    name: "Lamp Temperature value",
    exact: true,
  });
  await expect(lamp).toBeDisabled();
  await printer.click();
  await expect(printer).toBeChecked();
  await expect(lamp).toBeEnabled();
  await expect(
    page.getByRole("spinbutton", {
      name: "Channel Contrast Match value",
      exact: true,
    }),
  ).toBeDisabled();
  await number("Paper Exposure", 0.5);
  await choose("Viewing Illuminant", "Tungsten · 2856 K");
  await ready(page);
  await page.screenshot({ path: testInfo.outputPath("printer-controls.png") });
  await choose("Output medium", "Negative");
  await expect(printer).toHaveCount(0);
  await choose("Negative Viewing", "Scanner");
  await choose("Output medium", "Kodak Ektacolor Edge Paper");
  await expect(printer).toBeChecked();
  await expect(
    page.getByRole("spinbutton", { name: "Paper Exposure value", exact: true }),
  ).toHaveValue("0.5");
  await ready(page);
  await page.getByRole("button", { name: "More options", exact: true }).click();
  const download = page.waitForEvent("download");
  await page.getByRole("button", { name: "Save edits…", exact: true }).click();
  const savedBytes = await readFile(await (await download).path());
  const saved = JSON.parse(savedBytes);
  expect(saved.edit.profile).toMatchObject({
    halationSpectrum: [0, 0, 0, 0, 0, 0.1, 0],
    bleach: 0.5,
    couplers: 1.5,
    printerEnabled: true,
    printerExposure: 0.5,
    printLight: "tungsten",
    negativeViewing: "scanner",
  });
  expect(saved.edit.profile).not.toHaveProperty("halationReturn");
  await page
    .locator('input[type=file][accept=".json"]')
    .setInputFiles({
      name: "print-edits.json",
      mimeType: "application/json",
      buffer: savedBytes,
    });
  await ready(page);
  await page.getByRole("button", { name: "Export (⌘S)", exact: true }).click();
  const exportDownload = page.waitForEvent("download");
  await page.getByRole("button", { name: "Export", exact: true }).click();
  const png = await readFile(await (await exportDownload).path());
  expect(png.readUInt32BE(16)).toBe(1600);
  expect(png.readUInt32BE(20)).toBe(1000);
  expect(errors).toEqual([]);
  await expect(page.locator(".error-banner")).toHaveCount(0);
});
