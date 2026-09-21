import { execFileSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { test, expect } from "@playwright/test";

test("Auto solves Normal, negative, reversal and monochrome identically to the native engine", async ({
  page,
}) => {
  await page.goto("/");
  await expect(page.locator(".viewer-status > [role=status]")).toContainText(
    /\d+ × \d+/,
  );
  for (const stock of [null, "gold200", "ektachromee100", "hp5plus400"]) {
    for (const correction of [0, 0.6]) {
      const request = {
        kind: "auto-adjust",
        stock,
        printCorrection: correction,
        regionStops: Array.from({ length: 2048 }, (_, i) => -10 + i / 100),
      };
      const definition = stock
        ? JSON.parse(
            await readFile(
              resolve(`../Sources/FotufilmCore/Stocks/${stock}.json`),
            ),
          )
        : null;
      const native = JSON.parse(
        execFileSync(resolve("../.build/release/fotufilm-web-profile"), {
          input: JSON.stringify({ ...request, stock: definition }),
        }),
      );
      const actual = await page.evaluate(async (request) => {
        const { loadFilmProfile } = await import("/src/film-profile.js");
        return JSON.parse(
          new TextDecoder().decode(await loadFilmProfile(request)),
        );
      }, request);
      for (const key of Object.keys(native))
        expect(actual[key]).toBeCloseTo(native[key], 5);
    }
  }
  const recovery = await page.evaluate(async () => {
    const { loadFilmProfile } = await import("/src/film-profile.js");
    let error;
    try {
      await loadFilmProfile({
        kind: "auto-adjust",
        stock: null,
        regionStops: [],
      });
    } catch (value) {
      error = value.message;
    }
    const result = JSON.parse(
      new TextDecoder().decode(
        await loadFilmProfile({
          kind: "auto-adjust",
          stock: null,
          regionStops: [-3],
        }),
      ),
    );
    return { error, result };
  });
  expect(recovery.error).toContain("Invalid automatic exposure measurement");
  expect(recovery.result.exposureEV).toBeGreaterThan(2);
});

test("Auto measures neutrally and uses the current crop and source interpretation", async ({
  page,
}) => {
  await page.goto("/");
  await expect(page.locator(".viewer-status > [role=status]")).toContainText(
    /\d+ × \d+/,
  );
  const measured = await page.evaluate(async () => {
    const { LinearImage } = await import("/src/linear-image.js");
    const { defaultEdit } = await import("/src/editor-state.js");
    const { RenderSession } = await import("/src/render-session.js");
    const { solveAutoAdjustment } = await import("/src/auto-adjustment.js");
    const pixels = new Float32Array(128 * 64 * 4);
    for (let y = 0; y < 64; y++)
      for (let x = 0; x < 128; x++) {
        const light = x < 64 ? 0.018 : 1.8;
        pixels.set([light, light, light, 1], (y * 128 + x) * 4);
      }
    const standardPixels = new Float32Array(pixels).map((v, i) =>
      i % 4 === 3 ? v : v / 10,
    );
    const standard = new LinearImage({
      pixels: standardPixels,
      width: 128,
      height: 64,
    });
    const image = new LinearImage({ pixels, width: 128, height: 64 }, standard);
    const session = new RenderSession(),
      edit = defaultEdit();
    const original = await solveAutoAdjustment({ image, edit, session });
    const modified = await solveAutoAdjustment({
      image,
      session,
      edit: {
        ...edit,
        params: {
          ...edit.params,
          ev: 2,
          temperature: 2300,
          tint: 80,
          highlights: -1,
          shadows: 1,
        },
      },
    });
    const cropped = await solveAutoAdjustment({
      image,
      session,
      edit: {
        ...edit,
        crop: [
          [0, 0],
          [0.5, 0],
          [0.5, 1],
          [0, 1],
        ],
      },
    });
    const sdr = await solveAutoAdjustment({
      image,
      session,
      edit: { ...edit, sourceInterpretation: "standardRange" },
    });
    return { original, modified, cropped, sdr };
  });
  expect(measured.original).toEqual(measured.modified);
  expect(measured.cropped.ev).toBeGreaterThan(measured.original.ev + 2);
  expect(measured.sdr.ev).toBeGreaterThan(measured.original.ev + 2);
});

test("Auto menu and shortcut apply undoable settings, re-solve on film changes and disengage for manual edits", async ({ page }, testInfo) => {
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.goto("/");
  await expect(page.locator(".viewer-status > [role=status]")).toContainText(
    /\d+ × \d+/,
  );
  await page.getByRole("tab", { name: "Expose", exact: true }).click();
  const exposure = page.getByRole("spinbutton", {
    name: "Exposure value",
    exact: true,
  });
  await page.getByRole("button", { name: "More options", exact: true }).click();
  await page.getByRole("button", { name: "Auto Adjust", exact: true }).click();
  await expect(page.locator(".viewer-status > [role=status]")).toContainText(
    /\d+ × \d+/,
  );
  const normalEV = await exposure.inputValue();
  expect(Number(normalEV)).not.toBe(0);
  await page.getByRole("button", { name: "Undo (⌘Z)", exact: true }).click();
  await expect(exposure).toHaveValue("0");
  await exposure.focus();
  await page.keyboard.press("Meta+Shift+A");
  await expect(exposure).toHaveValue(normalEV);
  await page
    .getByRole("searchbox", { name: "Search films", exact: true })
    .fill("Gold 200");
  await page.getByTitle("Gold 200", { exact: true }).click();
  await expect(page.locator(".viewer-status > [role=status]")).toContainText(
    /\d+ × \d+/,
  );
  await page.getByRole("button", { name: "More options", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "Auto Adjust", exact: true }),
  ).toHaveAttribute("aria-pressed", "true");
  await page.screenshot({ path: testInfo.outputPath('auto-adjust.png') });
  const savedDownload = page.waitForEvent("download");
  await page.getByRole("button", { name: "Save edits…", exact: true }).click();
  const saved = JSON.parse(await readFile(await (await savedDownload).path()));
  expect(saved.edit.params.ev).toBeCloseTo(
    Number(await exposure.inputValue()),
    2,
  );
  expect(saved.edit.autoAdjustment).toBeUndefined();
  await exposure.fill("1.1");
  await exposure.press("Tab");
  await page.getByRole("button", { name: "More options", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "Auto Adjust", exact: true }),
  ).toHaveAttribute("aria-pressed", "false");
  expect(errors).toEqual([]);
});
