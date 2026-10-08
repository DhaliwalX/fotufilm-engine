import { test as base, expect, chromium } from "@playwright/test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// A real profile, as photo-library.spec.js runs: Chrome reads file system handles back from
// IndexedDB only outside an off-the-record context.
const test = base.extend({
  context: async ({ viewport, baseURL }, use) => {
    const profile = mkdtempSync(join(tmpdir(), "fotufilm-roll-"));
    const context = await chromium.launchPersistentContext(profile, {
      channel: "chrome",
      viewport,
      baseURL,
    });
    await use(context);
    await context.close();
    rmSync(profile, { recursive: true, force: true });
  },
  page: async ({ context }, use) =>
    use(context.pages()[0] ?? (await context.newPage())),
});

// A roll of three frames and, in a subfolder, a roll of its own, in the origin-private file
// system standing in for a folder the user picks.
async function seedRoll(page) {
  await page.evaluate(async () => {
    const root = await navigator.storage.getDirectory();
    await root.removeEntry("Roll 7", { recursive: true }).catch(() => {});
    const folder = await root.getDirectoryHandle("Roll 7", { create: true });
    const next = await folder.getDirectoryHandle("Roll 8", { create: true });
    async function write(directory, name, colour) {
      const canvas = new OffscreenCanvas(240, 160);
      const context = canvas.getContext("2d");
      context.fillStyle = colour;
      context.fillRect(0, 0, 240, 160);
      const writable = await (
        await directory.getFileHandle(name, { create: true })
      ).createWritable();
      await writable.write(await canvas.convertToBlob({ type: "image/png" }));
      await writable.close();
    }
    await write(folder, "frame 10.png", "rgb(200, 120, 70)");
    await write(folder, "frame 2.png", "rgb(190, 110, 60)");
    await write(folder, "frame 1.png", "rgb(210, 130, 80)");
    await write(next, "frame 1.png", "rgb(180, 100, 50)");
  });
}

test.beforeEach(async ({ page }) => {
  await page.addInitScript(() => {
    window.showDirectoryPicker = async () =>
      (await navigator.storage.getDirectory()).getDirectoryHandle("Roll 7");
  });
});

async function addFolder(page, negatives) {
  await page.goto("/");
  await page.evaluate(() => indexedDB.deleteDatabase("fotufilm-photo-library"));
  await seedRoll(page);
  await page.reload();
  await page.getByRole("button", { name: "Library (L)" }).click();
  const library = page.getByRole("region", { name: "Library" });
  if (negatives) {
    await library
      .getByRole("navigation", { name: "Folders" })
      .getByRole("button", { name: "Add Folder" })
      .click();
    await page.getByRole("menuitem", { name: "Add Negatives Folder…" }).click();
  } else {
    await library.getByRole("button", { name: "Add Folder" }).last().click();
  }
  await expect(library.getByRole("option")).toHaveCount(4);
  return library;
}

// The strip's frames, by the names their buttons select.
const strip = (page) =>
  page.getByLabel("Open photos").getByRole("button", { name: /^Select / });

test("opening one photo brings its roll into the strip, the photo chosen shown", async ({
  page,
}) => {
  test.setTimeout(120000);
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  const library = await addFolder(page, false);
  await library.getByRole("option", { name: "frame 2.png" }).first().dblclick();
  // The roll in the library's natural order; the subfolder is a roll of its own.
  await expect(strip(page)).toHaveCount(3);
  expect(
    await strip(page).evaluateAll((buttons) => buttons.map((b) => b.ariaLabel)),
  ).toEqual([
    "Select frame 1.png",
    "Select frame 2.png",
    "Select frame 10.png",
  ]);
  await expect(
    page.getByRole("button", { name: "Select frame 2.png" }),
  ).toHaveAttribute("aria-current", "true");
  // Opening another frame of the same roll shows it without opening the roll twice.
  await page.getByRole("button", { name: "Library (L)" }).click();
  await library.getByRole("option", { name: "frame 10.png" }).dblclick();
  await expect(strip(page)).toHaveCount(3);
  await expect(
    page.getByRole("button", { name: "Select frame 10.png" }),
  ).toHaveAttribute("aria-current", "true");
  // A photograph has no Roll panel.
  await expect(page.getByRole("radio", { name: "Roll" })).toHaveCount(0);
  expect(errors).toEqual([]);
});

test("a negative of a roll offers the Roll panel, counting the roll's frames", async ({
  page,
}, testInfo) => {
  test.setTimeout(120000);
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  const library = await addFolder(page, true);
  await library.getByRole("option", { name: "frame 1.png" }).first().dblclick();
  await expect(strip(page)).toHaveCount(3);
  await page.getByRole("radio", { name: "Roll" }).click();
  const inspector = page.getByRole("complementary", { name: "Adjustments" });
  await expect(
    inspector.locator(".info-row", { hasText: "Frames" }),
  ).toContainText("3");
  await expect(
    inspector.locator(".info-row", { hasText: "Balanced on" }),
  ).toContainText("This frame");
  await expect(
    inspector.getByRole("button", { name: "Measure Roll" }),
  ).toBeEnabled();
  await expect(
    inspector.getByRole("button", { name: "Balance This Frame Alone" }),
  ).toBeDisabled();
  await page.screenshot({ path: testInfo.outputPath("roll-panel.png") });
  expect(errors).toEqual([]);
});
