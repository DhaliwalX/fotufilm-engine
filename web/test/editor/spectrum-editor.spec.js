import { test, expect } from "@playwright/test";
import { openChart } from "./photo-fixture.js";

const editorURL = process.env.FOTUFILM_TEST_URL || "/";
async function openEditor(page) {
  await page.goto(editorURL);
  await openChart(page, 800, 500);
  await expect(
    page.getByAltText("Developed photo", { exact: true }),
  ).toBeVisible();
}
async function choose(page, label, option) {
  await page.getByRole("button", { name: label }).click();
  await page.getByRole("option", { name: option, exact: true }).click();
}

test("Spectrum adjustments retain numeric editing, undo and compare", async ({
  page,
}) => {
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await openEditor(page);
  await page.getByRole("radio", { name: "Expose", exact: true }).click();
  const field = page.getByRole("textbox", {
    name: "Exposure value",
    exact: true,
  });
  await field.fill("0.5");
  await field.press("Enter");
  await expect(
    page.getByRole("slider", { name: "Exposure", exact: true }),
  ).toHaveValue("0.5");
  await page.getByRole("button", { name: "Undo (⌘Z)", exact: true }).click();
  await expect(field).toHaveValue("0");
  const compare = page.getByRole("button", {
    name: "Hold to compare with original",
  });
  await compare.focus();
  await page.keyboard.down("Space");
  await expect(
    page.getByAltText("Original photo", { exact: true }),
  ).toBeVisible();
  await page.keyboard.up("Space");
  await expect(
    page.getByAltText("Developed photo", { exact: true }),
  ).toBeVisible();
  expect(errors).toEqual([]);
});

test("Spectrum histogram pickers update the plot and compact resizing preserves it", async ({
  page,
}) => {
  await openEditor(page);
  await page
    .getByRole("button", { name: "Histogram (H)", exact: true })
    .click();
  const histogram = page.getByRole("region", {
    name: "Histogram",
    exact: true,
  });
  await expect(histogram).toHaveAttribute("aria-busy", "false");
  await choose(page, /Histogram count mode/, "Linear");
  await expect(histogram.locator("canvas")).toHaveAttribute(
    "aria-label",
    /linear pixel counts/,
  );
  await choose(page, /Histogram channels/, "Luma");
  await expect(histogram.locator("canvas")).toHaveAttribute(
    "aria-label",
    /luma/i,
  );
  const resize = histogram.getByRole("button", { name: "Resize histogram" });
  await resize.focus();
  for (let i = 0; i < 4; i++) await resize.press("Shift+ArrowLeft");
  await expect(histogram).toHaveAttribute("data-compact", "true");
  await expect(histogram.locator("canvas")).toBeVisible();
  await page
    .getByRole("button", { name: "Histogram (H)", exact: true })
    .click();
  await expect(histogram).toHaveCount(0);
  await page
    .getByRole("button", { name: "Histogram (H)", exact: true })
    .click();
  await expect(histogram).toHaveAttribute("data-compact", "true");
});

test("film development, crop and 16-bit export remain available", async ({
  page,
}) => {
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await openEditor(page);
  await page
    .getByRole("button", { name: "Portra 400 Film", exact: true })
    .click();
  await page.getByRole("radio", { name: "Develop", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "New Grain Pattern", exact: true }),
  ).toBeVisible();
  await page.getByRole("radio", { name: "Print", exact: true }).click();
  await expect(page.locator(".inspector-content")).toContainText("Output");
  await page.getByRole("button", { name: "Crop", exact: true }).first().click();
  await expect(
    page.getByRole("button", { name: "Top left crop corner" }),
  ).toBeVisible();
  await page.getByRole("button", { name: "Export (⌘S)", exact: true }).click();
  await choose(page, /PNG Format/, "TIFF · 16-bit");
  await expect(
    page.getByRole("dialog", { name: "Export image", exact: true }),
  ).toContainText("16-bit");
  await page.getByRole("button", { name: "Cancel", exact: true }).click();
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await page.getByRole("button", { name: "More options", exact: true }).click();
  await page
    .getByRole("menuitem", { name: "Import Scanned Negative…", exact: true })
    .click();
  await expect(
    page.getByRole("dialog", { name: "Import Scanned Negative", exact: true }),
  ).toContainText("Choose Negative");
  await page.keyboard.press("Escape");
  await expect(page.getByRole("dialog")).toHaveCount(0);
  expect(errors).toEqual([]);
});
