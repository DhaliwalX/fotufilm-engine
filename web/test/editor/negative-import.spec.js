import { test, expect } from "@playwright/test";

test.use({ ignoreHTTPSErrors: true });
test("automatic negative preview, cancellation and full-resolution import", async ({
  page,
}) => {
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.goto(process.env.FOTUFILM_TEST_URL || "/");
  const status = page.locator(".viewer-status > [role=status]");
  await expect(status).toContainText(/\d+ × \d+/);
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
      .getByRole("button", { name: "Import Scanned Negative…", exact: true })
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
  await dialog
    .getByRole("checkbox", { name: "Black & white", exact: true })
    .check();
  await expect(
    dialog.getByRole("button", { name: "Import Positive", exact: true }),
  ).toBeEnabled();
  await expect(dialog.locator("img")).toHaveAttribute(
    "alt",
    "Converted positive preview",
  );
  await dialog
    .getByRole("button", { name: "Show Negative", exact: true })
    .click();
  await expect(dialog.locator("img")).toHaveAttribute(
    "alt",
    "Original negative",
  );
  await dialog
    .getByRole("button", { name: "Show Positive", exact: true })
    .click();
  const bounds = await dialog.evaluate((element) => ({
    client: element.clientWidth,
    scroll: element.scrollWidth,
  }));
  expect(bounds.scroll).toBeLessThanOrEqual(bounds.client);
  await dialog
    .locator("img")
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
  await expect(status).toContainText(/\d+ × \d+/);
  await page.getByRole("button", { name: "More options", exact: true }).click();
  await page
    .getByRole("button", { name: "Import Scanned Negative…", exact: true })
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
  await expect(dialog.locator("img")).toHaveAttribute(
    "alt",
    "Converted positive preview",
  );
  await dialog
    .getByRole("button", { name: "Import Positive", exact: true })
    .click();
  await expect(dialog).toBeHidden();
  await expect(status).toContainText("192 × 320");
  expect(errors).toEqual([]);
});
