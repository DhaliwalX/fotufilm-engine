import { openChart, openEditor } from "./photo-fixture.js";
import { test, expect } from "@playwright/test";

test.use({ ignoreHTTPSErrors: true });
test("automatic negative preview, cancellation and full-resolution import", async ({
  page,
}) => {
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.goto(process.env.FOTUFILM_TEST_URL || "/");
  await openChart(page, 320, 192);
  const status = page.locator(".viewer-status > [role=status]");
  await expect(status).toContainText(/\d+ × \d+/);
  // The dialog shares the editor's session; let the photo reach its GPU preview
  // first so that upgrade is not mistaken for the dialog replacing the photo.
  await expect(page.locator(".backend-label")).toHaveText("WebGPU", {
    timeout: 120000,
  });
  const previous = await status.textContent();
  const bytes = await page.evaluate(async () => {
    const canvas = document.createElement("canvas");
    canvas.width = 1024;
    canvas.height = 1024;
    const context = canvas.getContext("2d"),
      pixels = context.createImageData(canvas.width, canvas.height);
    for (let y = 0; y < canvas.height; y++)
      for (let x = 0; x < canvas.width; x++) {
        const i = (y * canvas.width + x) * 4,
          t = x / (canvas.width - 1);
        pixels.data.set([30 + 180 * t, 18 + 130 * t, 8 + 70 * t, 255], i);
      }
    context.putImageData(pixels, 0, 0);
    const blob = await new Promise((resolve) => canvas.toBlob(resolve));
    return Array.from(new Uint8Array(await blob.arrayBuffer()));
  });
  async function open() {
    await page
      .getByRole("button", { name: "More options", exact: true })
      .click();
    await page
      .getByRole("menuitem", { name: "Import Scanned Negative…", exact: true })
      .click();
    const dialog = page.getByRole("dialog", {
      name: "Import Scanned Negative",
    });
    await dialog.locator("input[type=file]").setInputFiles({
      name: "Negative.png",
      mimeType: "image/png",
      buffer: Buffer.from(bytes),
    });
    await expect(
      dialog.getByRole("button", { name: "Import Positive", exact: true }),
    ).toBeEnabled();
    return dialog;
  }
  let dialog = await open();
  await dialog.getByRole("button", { name: "Cancel", exact: true }).click();
  await expect(dialog).toBeHidden();
  await expect(status).toHaveText(previous);
  dialog = await open();
  const monochrome = dialog.getByRole("switch", {
    name: "Black & white",
    exact: true,
  });
  await monochrome.focus();
  await monochrome.press("Space");
  await expect(monochrome).toBeChecked();
  await expect(
    dialog.getByRole("button", { name: "Import Positive", exact: true }),
  ).toBeEnabled();
  await expect(
    dialog.getByRole("img", { name: "Converted positive preview" }),
  ).toBeVisible();
  await dialog
    .getByRole("button", { name: "Show Negative", exact: true })
    .click();
  await expect(
    dialog.getByRole("img", { name: "Original negative" }),
  ).toBeVisible();
  await dialog
    .getByRole("button", { name: "Show Positive", exact: true })
    .click();
  const bounds = await dialog.evaluate((element) => ({
    client: element.clientWidth,
    scroll: element.scrollWidth,
  }));
  expect(bounds.scroll).toBeLessThanOrEqual(bounds.client);
  await dialog
    .getByRole("img", { name: "Converted positive preview" })
    .evaluate((image) =>
      Promise.all(image.getAnimations().map((animation) => animation.finished)),
    );
  await page.screenshot({
    path: "build/browser-tests/negative-import-preview.png",
  });
  await dialog
    .getByRole("button", { name: "Import Positive", exact: true })
    .click();
  await expect(dialog).toBeHidden();
  await expect(status).toContainText("1024 × 1024");
  expect(errors).toEqual([]);
});

test("RAW negative import recovers after malformed input and applies orientation", async ({
  page,
}) => {
  const { makeDNG } = await import("./raw-fixture.js");
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.goto(process.env.FOTUFILM_TEST_URL || "/");
  const status = page.locator(".viewer-status > [role=status]");
  await page.getByRole("button", { name: "More options", exact: true }).click();
  await page
    .getByRole("menuitem", { name: "Import Scanned Negative…", exact: true })
    .click();
  const dialog = page.getByRole("dialog", { name: "Import Scanned Negative" });
  const picker = dialog.locator("input[type=file]");
  await expect(picker).toHaveAttribute("accept", /\.dng/);
  await picker.setInputFiles({
    name: "broken.dng",
    mimeType: "",
    buffer: Buffer.from("invalid"),
  });
  await expect(dialog.getByRole("alert")).toContainText("Could not decode RAW");
  await expect(
    dialog.getByRole("button", { name: "Import Positive", exact: true }),
  ).toBeDisabled();
  await picker.setInputFiles({
    name: "negative.dng",
    mimeType: "",
    buffer: Buffer.from(makeDNG({ orientation: 6, baselineExposure: 2 })),
  });
  await expect(
    dialog.getByRole("button", { name: "Import Positive", exact: true }),
  ).toBeEnabled();
  await expect(dialog.getByRole("alert")).toBeHidden();
  await expect(
    dialog.getByRole("img", { name: "Converted positive preview" }),
  ).toBeVisible();
  await dialog
    .getByRole("button", { name: "Import Positive", exact: true })
    .click();
  await expect(dialog).toBeHidden();
  await expect(status).toContainText("192 × 320");
  expect(errors).toEqual([]);
});

test("negative adjustments update the positive live and carry into the imported photo", async ({
  page,
}) => {
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await openEditor(page);
  await page.getByRole("button", { name: "More options", exact: true }).click();
  await page
    .getByRole("menuitem", { name: "Import Scanned Negative…", exact: true })
    .click();
  const dialog = page.getByRole("dialog", { name: "Import Scanned Negative" });
  const bytes = await page.evaluate(async () => {
    const canvas = document.createElement("canvas");
    canvas.width = 640;
    canvas.height = 400;
    const context = canvas.getContext("2d");
    const gradient = context.createLinearGradient(0, 0, 640, 0);
    gradient.addColorStop(0, "rgb(200, 120, 70)");
    gradient.addColorStop(1, "rgb(40, 20, 10)");
    context.fillStyle = gradient;
    context.fillRect(0, 0, 640, 400);
    const blob = await new Promise((resolve) => canvas.toBlob(resolve));
    return Array.from(new Uint8Array(await blob.arrayBuffer()));
  });
  await dialog.locator("input[type=file]").setInputFiles({
    name: "Gradient.png",
    mimeType: "image/png",
    buffer: Buffer.from(bytes),
  });
  const positive = dialog.getByRole("img", {
    name: "Converted positive preview",
  });
  await expect(positive).toBeVisible();
  const pixels = () =>
    positive.evaluate((canvas) =>
      Array.from(
        canvas.getContext("2d").getImageData(0, 0, canvas.width, 1).data,
      ),
    );
  const changes = async (name, value) => {
    const before = await pixels();
    const field = dialog.getByLabel(`${name} value`, { exact: true });
    await field.fill(String(value));
    await field.press("Tab");
    await expect.poll(pixels).not.toEqual(before);
  };
  await changes("Exposure", 1);
  await changes("Contrast", 0.5);
  const monochrome = dialog.getByRole("switch", {
    name: "Black & white",
    exact: true,
  });
  await monochrome.focus();
  await monochrome.press("Space");
  await expect(
    dialog.getByRole("slider", { name: "Temperature", exact: true }),
  ).toBeDisabled();
  await monochrome.press("Space");
  await dialog
    .getByRole("button", { name: "Import Positive", exact: true })
    .click();
  await expect(dialog).toBeHidden();
  // The positive opens in Crop; its adjustments wait in Expose.
  await page.getByRole("radio", { name: "Expose" }).click();
  await expect(page.getByLabel("Exposure value", { exact: true })).toHaveValue(
    "1",
  );
  expect(errors).toEqual([]);
});
