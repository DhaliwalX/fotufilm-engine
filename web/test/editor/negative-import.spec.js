import { openEditor, openPanel } from "./photo-fixture.js";
import { test, expect } from "@playwright/test";

test.use({ ignoreHTTPSErrors: true });

// A scan the page draws: clear orange film around a frame whose densest end is a bright sky.
async function scanBytes(page) {
  return page.evaluate(async () => {
    const canvas = document.createElement("canvas");
    canvas.width = 480;
    canvas.height = 320;
    const context = canvas.getContext("2d");
    context.fillStyle = "rgb(230, 150, 90)";
    context.fillRect(0, 0, 480, 320);
    const gradient = context.createLinearGradient(30, 0, 450, 0);
    gradient.addColorStop(0, "rgb(200, 110, 60)");
    gradient.addColorStop(1, "rgb(50, 22, 12)");
    context.fillStyle = gradient;
    context.fillRect(30, 30, 420, 260);
    const blob = await new Promise((resolve) => canvas.toBlob(resolve));
    return Array.from(new Uint8Array(await blob.arrayBuffer()));
  });
}

async function importNegative(page, file) {
  const chooser = page.waitForEvent("filechooser");
  await page.getByRole("button", { name: "More options", exact: true }).click();
  await page
    .getByRole("menuitem", { name: "Import Scanned Negative…", exact: true })
    .click();
  await (await chooser).setFiles(file);
}

// The shown photo's mean RGB.
const shownMean = (page) =>
  page.getByAltText("Developed photo", { exact: true }).evaluate(async (image) => {
    await image.decode();
    const canvas = document.createElement("canvas");
    canvas.width = image.naturalWidth;
    canvas.height = image.naturalHeight;
    const context = canvas.getContext("2d");
    context.drawImage(image, 0, 0);
    const { data } = context.getImageData(0, 0, canvas.width, canvas.height);
    const mean = [0, 0, 0];
    for (let i = 0; i < data.length; i += 4)
      for (let c = 0; c < 3; c++) mean[c] += data[i + c] / (data.length / 4);
    return mean;
  });

test("a scanned negative opens as a document, read as a film and printed", async ({ page }) => {
  test.setTimeout(240000);
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await openEditor(page);
  await importNegative(page, {
    name: "Roll 12 frame 3.png",
    mimeType: "image/png",
    buffer: Buffer.from(await scanBytes(page)),
  });
  const status = page.locator(".viewer-status > [role=status]");
  await expect(status).toContainText("480 × 320", { timeout: 120000 });
  await expect(page.getByRole("dialog")).toHaveCount(0);

  // Film, Expose and Print are the panels; the library offers the films with a negative to read.
  const panels = page.getByRole("radiogroup", { name: "Adjustment panels" });
  await expect(panels.getByRole("radio")).toHaveCount(3);
  const library = page.getByRole("complementary", { name: "Film library" });
  await expect(library.getByRole("button", { name: /^Velvia 50 / })).toHaveCount(0);

  // Read against the estimated base, the print is a positive: the dense sky prints light.
  await openPanel(page, "Film");
  await expect(page.getByText("Estimated", { exact: true })).toBeVisible();
  const estimated = await shownMean(page);
  expect(Math.max(...estimated)).toBeGreaterThan(20);

  // Picking clear film reads the scan against it; the light source is the desktop's.
  await page.getByRole("button", { name: "Pick Clear Film", exact: true }).click();
  await page.locator(".photo-plane").click({ position: { x: 6, y: 6 } });
  await expect(page.getByText("Sampled", { exact: true })).toBeVisible();
  await expect(page.getByText("Light Source", { exact: true })).toHaveCount(0);
  await expect(status).toContainText("480 × 320");

  // The light controls act on the print; nothing reaches a scene the scan never had.
  await openPanel(page, "Expose");
  await expect(page.getByRole("switch", { name: "Regional" })).toHaveCount(0);
  await expect(page.getByText("Source Illuminant", { exact: true })).toHaveCount(0);
  const before = await shownMean(page);
  const exposure = page.getByRole("spinbutton", { name: "Exposure value", exact: true });
  await exposure.fill("1");
  await exposure.press("Tab");
  await expect
    .poll(async () => (await shownMean(page))[1] - before[1], { timeout: 60000 })
    .toBeGreaterThan(8);
  const lit = await shownMean(page);
  const saturation = page.getByRole("spinbutton", { name: "Saturation value", exact: true });
  await saturation.fill("0");
  await saturation.press("Tab");
  await expect
    .poll(async () => {
      const [r, g, b] = await shownMean(page);
      return Math.max(Math.abs(r - g), Math.abs(g - b));
    }, { timeout: 60000 })
    .toBeLessThan(Math.max(Math.abs(lit[0] - lit[1]), Math.abs(lit[1] - lit[2])) / 2 + 1);

  // Normal reads it without a film: a positive photograph, with a photograph's panels.
  await library.getByRole("button", { name: "Normal No film", exact: true }).click();
  await expect(panels.getByRole("radio")).toHaveCount(4);
  await expect.poll(async () => Math.max(...(await shownMean(page)))).toBeGreaterThan(20);
  await openPanel(page, "Film");
  await expect(page.getByText("Sampled", { exact: true })).toBeVisible();
  expect(errors).toEqual([]);
});

test("a RAW negative reports malformed input and opens with its orientation", async ({ page }) => {
  test.setTimeout(240000);
  const { makeDNG } = await import("./raw-fixture.js");
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await openEditor(page);
  await importNegative(page, { name: "broken.dng", mimeType: "", buffer: Buffer.from("invalid") });
  await expect(page.getByRole("alert")).toContainText("Could not decode RAW");
  await importNegative(page, {
    name: "negative.dng",
    mimeType: "",
    buffer: Buffer.from(makeDNG({ orientation: 6, baselineExposure: 2 })),
  });
  await expect(page.locator(".viewer-status > [role=status]")).toContainText("192 × 320", {
    timeout: 120000,
  });
  expect(errors).toEqual([]);
});
