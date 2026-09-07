import { test, expect } from "@playwright/test";
import { readFile } from "node:fs/promises";

async function ready(page) {
  await expect(page.locator(".viewer-status > [role=status]")).toContainText(
    /\d+ × \d+/,
  );
}
async function sample(page) {
  await page.goto("/");
  await expect(
    page.getByRole("heading", { name: "Open a photo" }),
  ).toBeVisible();
  await page.getByRole("button", { name: "Open sample chart" }).click();
  await ready(page);
}
async function framePixels(page) {
  return page.locator(".photo-plane > img").evaluate(async (image) => {
    await image.decode();
    const canvas = document.createElement("canvas");
    canvas.width = 100;
    canvas.height = 64;
    const ctx = canvas.getContext("2d");
    ctx.drawImage(image, 0, 0, 100, 64);
    return Array.from(ctx.getImageData(0, 0, 100, 64).data);
  });
}

test("real WebGPU editor: normal, film, adjustments, history, crop and full-size export", async ({
  page,
}, testInfo) => {
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await sample(page);
  const normal = await framePixels(page);
  // The upper-left sample is red; Normal must retain its colour and positive polarity.
  const red = (10 * 100 + 10) * 4;
  expect(normal[red]).toBeGreaterThan(normal[red + 1] + 40);
  await page.getByRole("searchbox", { name: "Search films" }).fill("Gold 200");
  await page.getByTitle("Gold 200", { exact: true }).click();
  await ready(page);
  await expect(page.locator(".backend-label")).toHaveText("WebGPU");
  const film = await framePixels(page);
  expect(film).not.toEqual(normal);
  await page.getByRole("tab", { name: "Light & Color" }).click();
  await page
    .getByRole("spinbutton", { name: "Exposure value", exact: true })
    .fill("0.8");
  await page
    .getByRole("spinbutton", { name: "Exposure value", exact: true })
    .press("Tab");
  await ready(page);
  expect(await framePixels(page)).not.toEqual(film);
  await page.getByRole("button", { name: "Undo (⌘Z)", exact: true }).click();
  await expect(
    page.getByRole("spinbutton", { name: "Exposure value", exact: true }),
  ).toHaveValue("0");
  await ready(page);
  expect(await framePixels(page)).toEqual(film);
  await page.getByRole("button", { name: "Redo (⇧⌘Z)", exact: true }).click();
  await expect(
    page.getByRole("spinbutton", { name: "Exposure value", exact: true }),
  ).toHaveValue("0.8");
  await page
    .getByRole("spinbutton", { name: "Temperature value", exact: true })
    .fill("5000");
  await page
    .getByRole("spinbutton", { name: "Temperature value", exact: true })
    .press("Tab");
  await ready(page);
  await page
    .getByRole("button", { name: "Histogram (H)", exact: true })
    .click();
  await expect(
    page.getByLabel("Red, green and blue tonal distribution"),
  ).toBeVisible();
  await page.getByRole("tab", { name: "Crop", exact: true }).click();
  await ready(page);
  await page
    .getByRole("combobox", { name: "Aspect ratio", exact: true })
    .click();
  await page.getByRole("option", { name: "1:1", exact: true }).click();
  await page.getByRole("button", { name: "Done", exact: true }).click();
  await ready(page);
  await expect(page.locator(".viewer-status > [role=status]")).toContainText(
    "1000 × 1000",
  );
  await page.getByRole("button", { name: "Export (⌘S)", exact: true }).click();
  const downloadPromise = page.waitForEvent("download");
  await page.getByRole("button", { name: "Export", exact: true }).click();
  const download = await downloadPromise;
  const png = await readFile(await download.path());
  expect(png.readUInt32BE(16)).toBe(1000);
  expect(png.readUInt32BE(20)).toBe(1000);
  expect(download.suggestedFilename()).toBe("Color-chart-gold200.png");
  expect(errors).toEqual([]);
  await ready(page);
  await page.screenshot({ path: testInfo.outputPath("editor.png") });
});

test("CPU fallback, keyboard compare, per-photo edits and saved edit files", async ({
  page,
}) => {
  await page.addInitScript(() =>
    Object.defineProperty(navigator, "gpu", { value: undefined }),
  );
  await sample(page);
  await page.getByRole("searchbox").fill("Gold 200");
  await page.getByTitle("Gold 200", { exact: true }).click();
  await ready(page);
  await expect(page.locator(".backend-label")).toHaveText("CPU");
  await page.getByRole("tab", { name: "Light & Color" }).click();
  await page
    .getByRole("spinbutton", { name: "Exposure value", exact: true })
    .fill("1");
  await page
    .getByRole("spinbutton", { name: "Exposure value", exact: true })
    .press("Tab");
  await ready(page);
  await page.locator(".canvas-area").focus();
  await page.keyboard.down("Space");
  await expect(page.locator(".original-badge")).toBeVisible();
  await page.keyboard.up("Space");
  await expect(page.locator(".original-badge")).toBeHidden();
  await page.getByRole("button", { name: "More options" }).click();
  const savedPromise = page.waitForEvent("download");
  await page.getByRole("button", { name: "Save edits…", exact: true }).click();
  const saved = await savedPromise,
    text = await readFile(await saved.path(), "utf8");
  expect(JSON.parse(text).edit.params.ev).toBe(1);
  await page.getByRole("button", { name: "Reset all edits" }).click();
  await page
    .locator('input[type=file][accept=".json"]')
    .setInputFiles({
      name: "saved.json",
      mimeType: "application/json",
      buffer: Buffer.from(text),
    });
  await expect(
    page.getByRole("spinbutton", { name: "Exposure value", exact: true }),
  ).toHaveValue("1");
  const png = await page
    .locator(".photo-plane > img")
    .evaluate(async (image) =>
      Array.from(new Uint8Array(await (await fetch(image.src)).arrayBuffer())),
    );
  await page
    .locator("input[type=file][multiple]")
    .setInputFiles([
      { name: "second.png", mimeType: "image/png", buffer: Buffer.from(png) },
    ]);
  await ready(page);
  await expect(
    page.getByRole("spinbutton", { name: "Exposure value", exact: true }),
  ).toHaveValue("0");
  await page
    .getByRole("button", { name: "Select Color chart.png", exact: true })
    .click();
  await expect(
    page.getByRole("spinbutton", { name: "Exposure value", exact: true }),
  ).toHaveValue("1");
});

test("mobile layout and missing runtime errors remain usable", async ({
  page,
}) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.route("**/packs/index.json", (route) =>
    route.fulfill({ status: 404, body: "Missing" }),
  );
  await page.goto("/");
  await expect(page.getByRole("alert")).toContainText(
    "The film library could not be loaded",
  );
  await expect(
    page.getByRole("button", { name: "Open images", exact: true }),
  ).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBe(
    390,
  );
  await page
    .getByRole("button", { name: "Toggle film sidebar", exact: true })
    .click();
  await expect(page.getByRole("searchbox")).toBeVisible();
  await page
    .getByRole("button", { name: "Toggle film sidebar", exact: true })
    .click();
  await expect(page.getByRole("searchbox")).toBeHidden();
});
