import { test, expect } from "@playwright/test";
import { openPanel } from "./photo-fixture.js";
import { installNativeBackend } from "./native-backend-fixture.js";

// A small scan, as a PNG the page draws.
async function scanBytes(page) {
  return page.evaluate(async () => {
    const canvas = document.createElement("canvas");
    canvas.width = 120;
    canvas.height = 80;
    const context = canvas.getContext("2d");
    context.fillStyle = "#c87838";
    context.fillRect(0, 0, 120, 80);
    context.fillStyle = "#5a2a10";
    context.fillRect(10, 12, 100, 56);
    const blob = await new Promise((resolve) => canvas.toBlob(resolve));
    return Array.from(new Uint8Array(await blob.arrayBuffer()));
  });
}

test("a scanned negative opens in the editor, read as the film chosen in the library", async ({
  page,
}) => {
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.addInitScript(installNativeBackend, { negativeScans: true });
  await page.goto("/");
  await expect(page.getByRole("progressbar")).toHaveCount(0);

  const chooser = page.waitForEvent("filechooser");
  await page.getByRole("button", { name: "More options", exact: true }).click();
  await page.getByRole("menuitem", { name: "Import Scanned Negative…", exact: true }).click();
  await (await chooser).setFiles({
    name: "Roll 12 frame 3.png",
    mimeType: "image/png",
    buffer: Buffer.from(await scanBytes(page)),
  });

  // No dialog: the scan is a document, decoded as a negative, on the film its base looks like.
  await expect(page.getByAltText("Developed photo", { exact: true })).toBeVisible();
  await expect(page.getByRole("dialog")).toHaveCount(0);
  expect(await page.evaluate(() => window.nativeCalls.includes("importNegative"))).toBe(true);
  const lastEdit = () => page.evaluate(() => window.nativeRenders.at(-1));
  await expect.poll(async () => (await lastEdit())?.stock).toBe("portra400");
  expect((await lastEdit()).negative).toEqual({ border: null, lightFrame: null });

  // The library offers the films with a negative to read, and Normal, which reads it without one.
  const library = page.getByRole("complementary", { name: "Film library" });
  await expect(library.getByRole("button", { name: "Gold 200 Film" })).toBeVisible();
  await expect(library.getByRole("button", { name: "E100 Film" })).toHaveCount(0);
  await library.getByRole("button", { name: "Normal No film" }).click();
  await expect.poll(async () => (await lastEdit())?.stock).toBe(null);
  expect((await lastEdit()).negative).toEqual({ border: null, lightFrame: null });
  await library.getByRole("button", { name: "Gold 200 Film" }).click();
  await expect.poll(async () => (await lastEdit())?.stock).toBe("gold200");

  // Film, Expose and Print are the panels; the Film panel picks the clear film base.
  const panels = page.getByRole("radiogroup", { name: "Adjustment panels" });
  await expect(panels.getByRole("radio")).toHaveCount(3);
  await openPanel(page, "Film");
  await page.getByRole("button", { name: "Pick Clear Film", exact: true }).click();
  await page.locator(".photo-plane").click({ position: { x: 4, y: 4 } });
  await expect
    .poll(async () => (await lastEdit())?.negative?.border)
    .toEqual([0.8, 0.45, 0.2]);
  await expect(page.getByText("Sampled", { exact: true })).toBeVisible();

  // The Print panel is the editor's own.
  await openPanel(page, "Print");
  await expect(page.getByRole("button", { name: "Export Photo…", exact: true })).toBeVisible();
  expect(errors).toEqual([]);
});
