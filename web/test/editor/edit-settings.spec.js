import { openEditorWithChart, openPanel, viewerStatus } from "./photo-fixture.js";
import { test, expect } from "@playwright/test";

const exposure = (page) =>
  page.getByRole("textbox", { name: "Exposure value", exact: true });

async function setExposure(page, value) {
  await openPanel(page, "Expose");
  await exposure(page).fill(value);
  await exposure(page).press("Tab");
}

async function moreOptions(page, item) {
  await page.getByRole("button", { name: "More options" }).click();
  await page.getByRole("menuitem", { name: item }).click();
}

test("Copy Settings carries the chosen sections to another photo, and presets keep them", async ({
  page,
}, testInfo) => {
  test.setTimeout(180000);
  await openEditorWithChart(page);
  await page.getByRole("searchbox", { name: "Search films" }).fill("Gold 200");
  await page.getByRole("button", { name: "Gold 200 Film", exact: true }).click();
  await setExposure(page, "0.8");

  await moreOptions(page, /^Copy Settings…/);
  const dialog = page.getByRole("dialog", { name: "Copy Settings" });
  // The look is ticked; a photograph's own framing is not.
  await expect(dialog.getByRole("checkbox", { name: "Stock" })).toBeChecked();
  await expect(dialog.getByRole("checkbox", { name: "Exposure" })).toBeChecked();
  await expect(dialog.getByRole("checkbox", { name: "Geometry" })).not.toBeChecked();
  await page.screenshot({ path: testInfo.outputPath("copy-settings.png"), animations: "disabled" });
  await dialog.getByRole("button", { name: "Copy", exact: true }).click();

  // A second photograph opens on its own edit, then takes the copied one.
  const png = await page
    .locator(".photo-plane > img")
    .evaluate(async (image) =>
      Array.from(new Uint8Array(await (await fetch(image.src)).arrayBuffer())),
    );
  await page
    .locator("input[type=file][multiple]")
    .setInputFiles([{ name: "second.png", mimeType: "image/png", buffer: Buffer.from(png) }]);
  await expect(viewerStatus(page)).toContainText(/\d+ × \d+/);
  await openPanel(page, "Expose");
  await expect(exposure(page)).toHaveValue("0");
  await moreOptions(page, /^Paste Settings/);
  await expect(exposure(page)).toHaveValue("0.8");
  // The paste is one step: Undo takes it all back, Redo puts it back.
  await page.getByRole("button", { name: /^Undo \(/ }).click();
  await expect(exposure(page)).toHaveValue("0");
  await page.getByRole("button", { name: /^Redo \(/ }).click();
  await expect(exposure(page)).toHaveValue("0.8");

  // Only the chosen sections go into a preset.
  await moreOptions(page, "Presets");
  await page.getByRole("menuitem", { name: "Save Preset…" }).click();
  const save = page.getByRole("dialog", { name: "Save Preset" });
  await save.getByRole("textbox", { name: "Name" }).fill("Bright");
  await save.getByRole("button", { name: "Check None" }).click();
  await save.getByText("Exposure", { exact: true }).click();
  await expect(save.getByRole("checkbox", { name: "Exposure" })).toBeChecked();
  await page.screenshot({ path: testInfo.outputPath("save-preset.png"), animations: "disabled" });
  await save.getByRole("button", { name: "Save", exact: true }).click();

  await page.getByRole("button", { name: "Reset all edits" }).click();
  await openPanel(page, "Expose");
  await expect(exposure(page)).toHaveValue("0");
  await moreOptions(page, "Presets");
  await page.getByRole("menuitem", { name: "Bright" }).click();
  await expect(exposure(page)).toHaveValue("0.8");

  // The film column's Presets tab lists them beside the films; the one in effect reads as chosen.
  await page.getByRole("button", { name: "Reset all edits" }).click();
  await page.getByRole("radio", { name: "Presets", exact: true }).click();
  const bright = page.getByRole("button", { name: "Bright Preset", exact: true });
  await expect(bright).toHaveAttribute("aria-pressed", "false");
  await bright.click();
  await expect(bright).toHaveAttribute("aria-pressed", "true");
  await expect(exposure(page)).toHaveValue("0.8");
  await expect(bright.locator("img")).toBeVisible({ timeout: 30000 });
  await page.screenshot({ path: testInfo.outputPath("presets-tab.png"), animations: "disabled" });
  await page.getByRole("searchbox", { name: "Search presets" }).fill("dark");
  await expect(page.getByText("No matching presets.")).toBeVisible();
  await page.getByRole("radio", { name: "Films", exact: true }).click();
  await expect(page.getByRole("searchbox", { name: "Search films" })).toBeVisible();

  // Presets outlive the page; deleting one asks first.
  await page.reload();
  await openEditorWithChart(page);
  await moreOptions(page, "Presets");
  await page.getByRole("menuitem", { name: "Manage Presets…" }).click();
  const presets = page.getByRole("dialog", { name: "Presets" });
  await expect(presets.getByText("Bright")).toBeVisible();
  await page.screenshot({ path: testInfo.outputPath("presets.png"), animations: "disabled" });
  await presets.getByRole("button", { name: "Delete Bright" }).click();
  await page.getByRole("dialog", { name: "Delete Preset" }).getByRole("button", { name: "Delete" }).click();
  await expect(page.getByText("No presets yet.")).toBeVisible();
});
