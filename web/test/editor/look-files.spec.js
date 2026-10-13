import { readFile } from "node:fs/promises";
import { openEditor, openPanel } from "./photo-fixture.js";
import { test, expect } from "@playwright/test";

// Paste Settings and presets onto several photos chosen in the strip, and presets shared as look
// files. These read the edit's controls, not the developed picture.

const exposure = (page) =>
  page.getByRole("textbox", { name: "Exposure value", exact: true });

async function setExposure(page, value) {
  await openPanel(page, "Expose");
  await exposure(page).fill(value);
  await exposure(page).press("Tab");
}

async function moreOptions(page, ...items) {
  await page.getByRole("button", { name: "More options" }).click();
  for (const item of items) await page.getByRole("menuitem", { name: item }).click();
}

// Three small photographs, opened together: the first is shown, the others wait in the strip.
async function openThree(page) {
  const bytes = await page.evaluate(async () => {
    const shades = ["#d83228", "#31ae52", "#3353d6"];
    return Promise.all(
      shades.map(async (color) => {
        const canvas = document.createElement("canvas");
        canvas.width = 320;
        canvas.height = 200;
        const context = canvas.getContext("2d");
        context.fillStyle = color;
        context.fillRect(0, 0, 320, 200);
        const blob = await new Promise((resolve) => canvas.toBlob(resolve));
        return Array.from(new Uint8Array(await blob.arrayBuffer()));
      }),
    );
  });
  await page.locator("input[type=file][multiple]").setInputFiles(
    ["a.png", "b.png", "c.png"].map((name, i) => ({
      name,
      mimeType: "image/png",
      buffer: Buffer.from(bytes[i]),
    })),
  );
  await expect(photo(page, "a.png")).toHaveAttribute("aria-current", "true");
}

const photo = (page, name) =>
  page.getByLabel("Open photos").getByRole("button", { name: `Select ${name}` });

async function show(page, name) {
  await photo(page, name).click();
  await expect(photo(page, name)).toHaveAttribute("aria-current", "true", {
    timeout: 30000,
  });
}

test("Paste Settings goes onto every photo chosen in the strip", async ({
  page,
}, testInfo) => {
  test.setTimeout(120000);
  await openEditor(page);
  await openThree(page);
  await setExposure(page, "0.8");
  await moreOptions(page, /^Copy Settings…/);
  await page
    .getByRole("dialog", { name: "Copy Settings" })
    .getByRole("button", { name: "Copy", exact: true })
    .click();

  // Shift-click chooses the run of photos without showing another.
  await photo(page, "c.png").click({ modifiers: ["Shift"] });
  for (const name of ["a.png", "b.png", "c.png"])
    await expect(photo(page, name)).toHaveAttribute("aria-pressed", "true");
  await expect(photo(page, "a.png")).toHaveAttribute("aria-current", "true");
  // Command-click takes one back out.
  await photo(page, "b.png").click({ modifiers: ["ControlOrMeta"] });
  await expect(photo(page, "b.png")).toHaveAttribute("aria-pressed", "false");
  await page.screenshot({ path: testInfo.outputPath("chosen.png"), animations: "disabled" });

  await page.getByRole("button", { name: "More options" }).click();
  await page.getByRole("menuitem", { name: /^Paste Settings to 2 Photos/ }).click();

  await show(page, "c.png");
  await openPanel(page, "Expose");
  await expect(exposure(page)).toHaveValue("0.8");
  // The paste is a step of its own history: Undo takes it back.
  await page.getByRole("button", { name: /^Undo \(/ }).click();
  await expect(exposure(page)).toHaveValue("0");
  await show(page, "b.png");
  await openPanel(page, "Expose");
  await expect(exposure(page)).toHaveValue("0");

  // A plain click chose b alone; ⌘A chooses every photo, Escape the one shown again.
  await expect(photo(page, "c.png")).not.toHaveAttribute("aria-pressed", "true");
  await page.locator("body").press("ControlOrMeta+a");
  await expect(photo(page, "a.png")).toHaveAttribute("aria-pressed", "true");
  await page.locator("body").press("Escape");
  await expect(photo(page, "a.png")).not.toHaveAttribute("aria-pressed", "true");
});

test("a preset exports as a look file and imports again", async ({ page }, testInfo) => {
  test.setTimeout(120000);
  await openEditor(page);
  await openThree(page);
  await setExposure(page, "0.8");
  await moreOptions(page, "Presets", "Save Preset…");
  const save = page.getByRole("dialog", { name: "Save Preset" });
  await save.getByRole("textbox", { name: "Name" }).fill("Bright / warm");
  await save.getByRole("button", { name: "Save", exact: true }).click();

  await moreOptions(page, "Presets", "Manage Presets…");
  const presets = page.getByRole("dialog", { name: "Presets" });
  const download = page.waitForEvent("download");
  await presets.getByRole("button", { name: "Export Bright / warm" }).click();
  const file = await download;
  expect(file.suggestedFilename()).toBe("Bright warm.fotufilmlook");
  const text = await readFile(await file.path(), "utf8");
  const look = JSON.parse(text);
  expect(look.format).toBe("fotufilm-look");
  expect(look.presets[0].name).toBe("Bright / warm");
  expect(look.presets[0].settings.edit.params.ev).toBe(0.8);
  await page.screenshot({ path: testInfo.outputPath("presets.png"), animations: "disabled" });

  // Deleted, then brought back from the file.
  await presets.getByRole("button", { name: "Delete Bright / warm" }).click();
  await page
    .getByRole("dialog", { name: "Delete Preset" })
    .getByRole("button", { name: "Delete" })
    .click();
  await expect(page.getByText("No presets yet.")).toBeVisible();
  await page.keyboard.press("Escape");

  const looks = page.locator('input[type=file][accept=".fotufilmlook"]');
  await looks.setInputFiles({
    name: "Bright warm.fotufilmlook",
    mimeType: "application/octet-stream",
    buffer: Buffer.from(text),
  });
  const imported = page.getByRole("dialog", { name: "Presets" });
  await expect(imported.getByText("Bright / warm")).toBeVisible();
  await page.keyboard.press("Escape");

  // The look applies as the preset did.
  await page.getByRole("button", { name: "Reset all edits" }).click();
  await openPanel(page, "Expose");
  await expect(exposure(page)).toHaveValue("0");
  await moreOptions(page, "Presets", "Bright / warm");
  await expect(exposure(page)).toHaveValue("0.8");

  // A file that is not a look says so.
  await looks.setInputFiles({
    name: "Notes.fotufilmlook",
    mimeType: "application/octet-stream",
    buffer: Buffer.from("{}"),
  });
  await expect(page.getByText(/Notes\.fotufilmlook: This file is not a Fotufilm look\./)).toBeVisible();
});
