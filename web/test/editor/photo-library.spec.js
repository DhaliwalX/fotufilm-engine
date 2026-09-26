import { test as base, expect, chromium } from "@playwright/test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Chrome 153 crashes when an off-the-record context (Playwright's default)
// reads a file system handle back from IndexedDB, so this runs in a real profile.
const test = base.extend({
  context: async ({ viewport, baseURL }, use) => {
    const profile = mkdtempSync(join(tmpdir(), "fotufilm-library-"));
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

// A folder in the origin-private file system stands in for one the user picks:
// its handles persist in IndexedDB exactly like a picked folder's.
async function seedFolder(page) {
  await page.evaluate(async () => {
    const root = await navigator.storage.getDirectory();
    await root.removeEntry("Roll 1", { recursive: true }).catch(() => {});
    const folder = await root.getDirectoryHandle("Roll 1", { create: true });
    const day = await folder.getDirectoryHandle("Day 2", { create: true });
    async function write(directory, name, blob) {
      const writable = await (
        await directory.getFileHandle(name, { create: true })
      ).createWritable();
      await writable.write(blob);
      await writable.close();
    }
    async function picture(width, height, type, paint) {
      const canvas = new OffscreenCanvas(width, height);
      paint(canvas.getContext("2d"), width, height);
      return canvas.convertToBlob({ type, quality: 0.92 });
    }
    const halves = (top, bottom) => (context, width, height) => {
      context.fillStyle = top;
      context.fillRect(0, 0, width, height / 2);
      context.fillStyle = bottom;
      context.fillRect(0, height / 2, width, height / 2);
    };
    // A landscape JPEG whose EXIF says "rotate 90° clockwise": the thumbnail must
    // come out portrait with the red half on the right.
    const jpeg = new Uint8Array(
      await (
        await picture(1200, 800, "image/jpeg", halves("#d02020", "#2040d0"))
      ).arrayBuffer(),
    );
    const tiff = [
      0x49, 0x49, 42, 0, 8, 0, 0, 0, 1, 0, 0x12, 1, 3, 0, 1, 0, 0, 0, 6, 0, 0,
      0, 0, 0, 0, 0,
    ];
    const app1 = [
      0xff,
      0xe1,
      0,
      8 + tiff.length,
      0x45,
      0x78,
      0x69,
      0x66,
      0,
      0,
      ...tiff,
    ];
    const rotated = new Uint8Array(jpeg.length + app1.length);
    rotated.set(jpeg.subarray(0, 2));
    rotated.set(app1, 2);
    rotated.set(jpeg.subarray(2), 2 + app1.length);
    await write(
      folder,
      "IMG_0002.jpg",
      new Blob([rotated], { type: "image/jpeg" }),
    );
    await write(
      folder,
      "IMG_0010.jpg",
      await picture(1600, 1000, "image/jpeg", halves("#e8c070", "#305030")),
    );
    await write(folder, "notes.txt", new Blob(["not a photo"]));
    await write(
      day,
      "IMG_0003.png",
      await picture(900, 900, "image/png", halves("#20a060", "#f0f0f0")),
    );
  });
}

test.beforeEach(async ({ page }) => {
  await page.addInitScript(() => {
    window.showDirectoryPicker = async () =>
      (await navigator.storage.getDirectory()).getDirectoryHandle("Roll 1");
  });
});

test("library folders persist, thumbnail through Halide, rate and reopen edits", async ({
  page,
}, testInfo) => {
  test.setTimeout(180000);
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.goto("/");
  await page.evaluate(() => indexedDB.deleteDatabase("fotufilm-photo-library"));
  await seedFolder(page);
  await page.reload();

  await page.getByRole("button", { name: "Library (L)" }).click();
  const library = page.getByRole("region", { name: "Library" });
  await expect(library.getByText("Add a folder to browse")).toBeVisible();
  await library.getByRole("button", { name: "Add Folder" }).last().click();

  const tiles = library.getByRole("option");
  await expect(tiles).toHaveCount(3);
  await expect(library.locator(".library-folder[aria-current]")).toContainText(
    "Roll 1",
  );
  // Natural name order: 2, 3 (in Day 2), 10.
  await expect(tiles.nth(0)).toHaveAttribute("aria-label", "IMG_0002.jpg");
  await expect(tiles.nth(2)).toHaveAttribute("aria-label", "IMG_0010.jpg");

  const thumbnails = library.locator(".library-thumb img");
  await expect(thumbnails).toHaveCount(3);
  const rotated = await tiles
    .nth(0)
    .locator("img")
    .evaluate(async (image) => {
      await image.decode();
      const canvas = new OffscreenCanvas(
        image.naturalWidth,
        image.naturalHeight,
      );
      const context = canvas.getContext("2d");
      context.drawImage(image, 0, 0);
      const pixel = (x, y) => [...context.getImageData(x, y, 1, 1).data];
      return {
        size: [image.naturalWidth, image.naturalHeight],
        left: pixel(20, image.naturalHeight / 2),
        right: pixel(image.naturalWidth - 20, image.naturalHeight / 2),
      };
    });
  expect(rotated.size).toEqual([320, 480]);
  expect(rotated.right[0]).toBeGreaterThan(rotated.right[2] + 80);
  expect(rotated.left[2]).toBeGreaterThan(rotated.left[0] + 80);
  await page.screenshot({ path: testInfo.outputPath("library-grid.png") });

  // Rate from the keyboard and filter by rating.
  await tiles.nth(2).click();
  await page.keyboard.press("4");
  await expect(tiles.nth(2).locator(".library-stars .on")).toHaveCount(4);
  await library.getByRole("button", { name: "Rating" }).click();
  await page.getByRole("option", { name: "★★★ or more", exact: true }).click();
  await expect(tiles).toHaveCount(1);
  await library.getByRole("button", { name: "Rating" }).click();
  await page.getByRole("option", { name: "Any rating", exact: true }).click();
  await expect(tiles).toHaveCount(3);

  // Open a photo, rotate it, and the library keeps the edit.
  const status = page.locator(".viewer-status > [role=status]");
  await tiles.nth(2).dblclick();
  await expect(library).toBeHidden();
  await expect(status).toContainText("1600 × 1000");
  await page.keyboard.press("c");
  await page.getByRole("button", { name: "Rotate Left" }).click();
  await page.keyboard.press("Escape");
  await expect(status).toContainText("1000 × 1600");
  await page.keyboard.press("l");
  await expect(tiles.nth(2).locator(".library-badge.edited")).toBeVisible();

  // After a reload the folder, rating and edit are still there.
  await page.reload();
  await page.getByRole("button", { name: "Library (L)" }).click();
  await expect(tiles).toHaveCount(3);
  await expect(tiles.nth(2).locator(".library-stars .on")).toHaveCount(4);
  await expect(tiles.nth(2).locator(".library-badge.edited")).toBeVisible();
  await tiles.nth(2).click();
  await page.keyboard.press("Enter");
  await expect(status).toContainText("1000 × 1600");
  await page.screenshot({ path: testInfo.outputPath("library-reopened.png") });

  // Removing the folder forgets it; the files stay.
  await page.keyboard.press("l");
  await library.locator(".library-folder-row").hover();
  await library.getByRole("button", { name: "Roll 1 options" }).click();
  await page.getByRole("menuitem", { name: "Remove from Library…" }).click();
  await page.getByRole("button", { name: "Remove" }).click();
  await expect(library.getByText("Add a folder to browse")).toBeVisible();
  expect(
    await page.evaluate(
      async () =>
        (
          await (
            await navigator.storage.getDirectory()
          ).getDirectoryHandle("Roll 1")
        ).name,
    ),
  ).toBe("Roll 1");
  expect(errors).toEqual([]);
});
