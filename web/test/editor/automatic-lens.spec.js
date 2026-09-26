import { openPanel } from "./photo-fixture.js";
import { readFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { resolve } from "node:path";
import { test, expect } from "@playwright/test";
import { readPhotoMetadata } from "../../src/photo-metadata.js";
import { makeDNG } from "./raw-fixture.js";
import {
  captureTags,
  lensShot,
  lensOpcodes,
  measuredProfile,
} from "./lens-fixture.js";
const fixture = (options = {}) =>
  makeDNG({
    width: 320,
    height: 192,
    ...options,
    extraTags: [
      ...captureTags,
      [50829, 4, [0, 0, 192, 320]],
      [50720, 4, [300, 180]],
      [50719, 4, [10, 6]],
      [51022, 7, lensOpcodes(options)],
    ],
  });

test("embedded DNG, profile precedence and correction Amount match the native lens plan", async ({
  page,
}) => {
  const metadata = await readPhotoMetadata(new Blob([fixture()]));
  await page.goto("/");
  for (const [amount, profile, deliveredSize] of [
    [0, null],
    [0.5, null],
    [1, null],
    [0.7, measuredProfile],
    [1, null, [320, 192]],
  ]) {
    const request = {
      kind: "lens-plan",
      amount,
      deliveredSize,
      profile,
      shot: lensShot,
      embeddedTIFF: metadata.embeddedTIFF,
      adjustment: {
        distortion: 0.15,
        vignetting: -0.3,
        redCyan: 0.2,
        blueYellow: -0.1,
      },
    };
    const native = JSON.parse(
      execFileSync(resolve("../.build/release/fotufilm-web-profile"), {
        input: JSON.stringify(request),
      }),
    );
    const actual = await page.evaluate(async (request) => {
      const { loadFilmProfile } = await import("/src/film-profile.js");
      return JSON.parse(
        new TextDecoder().decode(await loadFilmProfile(request)),
      );
    }, request);
    expect(actual.measurement).toBe(profile ? "profile" : "embedded");
    expect(actual.note).toBe(native.note);
    expect(actual.profileID).toBe(native.profileID);
    expect(actual.table.length).toBe(4096);
    expect(
      Math.max(...actual.table.map((v, i) => Math.abs(v - native.table[i]))),
    ).toBeLessThan(3e-6);
  }
});

test("unsupported DNG geometry is explained while usable vignetting remains enabled", async ({
  page,
}) => {
  const metadata = await readPhotoMetadata(
    new Blob([fixture({ tangential: 0.1 })]),
  );
  await page.goto("/");
  const result = await page.evaluate(async (metadata) => {
    const { resolveLensPlan } = await import("/src/lens-plan.js");
    const { defaultLens } = await import("/src/lens-correction.js");
    const plan = await resolveLensPlan(
      { lensMetadata: metadata },
      { ...defaultLens(), enabled: true },
    );
    return {
      measurement: plan.measurement,
      note: plan.note,
      geometry: [...plan.table].filter((_, i) => i % 4 !== 3),
      gain: plan.table.at(-1),
    };
  }, metadata);
  expect(result.measurement).toBe("embedded");
  expect(result.note).toContain("off axis");
  expect(result.geometry.every((v) => v === 1)).toBe(true);
  expect(result.gain).toBeGreaterThan(1);
});

test("DNG correction, imported profile matching, persistent library and removal work in the Lens panel", async ({
  page,
}, testInfo) => {
  test.setTimeout(180000);
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  const file = {
    name: "Synthetic lens.dng",
    mimeType: "image/x-adobe-dng",
    buffer: Buffer.from(fixture()),
  };
  const open = async () => {
    await page.locator("input[type=file][multiple]").setInputFiles(file);
    await expect(page.locator(".viewer-status > [role=status]")).toContainText(
      "320 × 192",
    );
    await openPanel(page, "Expose");
    await page
      .getByRole("switch", { name: "Lens Correction", exact: true })
      .click();
    await expect(page.locator(".lens-plan-note")).toContainText(
      /stored in the file|Synthetic 35mm/,
    );
  };
  await page.goto("/");
  await open();
  await expect(page.locator(".lens-plan-note")).toContainText(
    "stored in the file",
  );
  const amount = page.getByRole("spinbutton", {
    name: "Amount value",
    exact: true,
  });
  await expect(amount).toHaveValue("100");
  await amount.fill("50");
  await amount.press("Tab");
  await expect(amount).toHaveValue("50");
  await page.locator(".lens-profile-library > summary").click();
  await page.getByLabel("Import lens profiles", { exact: true }).setInputFiles({
    name: "synthetic.json",
    mimeType: "application/json",
    buffer: Buffer.from(JSON.stringify([measuredProfile])),
  });
  await expect(page.locator(".lens-plan-note")).toHaveText(
    measuredProfile.model,
  );
  await expect(amount).toHaveValue("50");
  await expect(
    page.getByRole("combobox", { name: "Profile", exact: true }),
  ).toContainText("Automatic");
  await page.getByRole("combobox", { name: "Profile", exact: true }).click();
  await page
    .getByRole("option", { name: "Fotufilm Synthetic 35mm f/2", exact: true })
    .click();
  await expect(
    page.getByRole("combobox", { name: "Profile", exact: true }),
  ).toContainText("Synthetic 35mm");
  await page.getByRole("button", { name: "More options", exact: true }).click();
  const saveDownload = page.waitForEvent("download");
  await page.getByRole("button", { name: "Save edits…", exact: true }).click();
  const saved = JSON.parse(
    await readFile(await (await saveDownload).path(), "utf8"),
  );
  expect(saved.edit.lens.profileID).toBe(measuredProfile.id);
  expect(saved.edit.lens.amount).toBe(0.5);
  await page.getByLabel("Import lens profiles", { exact: true }).setInputFiles({
    name: "bad.json",
    mimeType: "application/json",
    buffer: Buffer.from(
      JSON.stringify([{ ...measuredProfile, calibrations: [] }]),
    ),
  });
  await expect(
    page.locator(".lens-profile-library p[role=alert]"),
  ).toBeVisible();
  await expect(page.locator(".lens-plan-note")).toHaveText(
    measuredProfile.model,
  );
  await page.screenshot({ path: testInfo.outputPath("automatic-lens.png") });
  await page.reload();
  await open();
  await expect(page.locator(".lens-plan-note")).toHaveText(
    measuredProfile.model,
  );
  await page.locator(".lens-profile-library > summary").click();
  await page
    .getByRole("button", { name: "Remove Imported Profiles", exact: true })
    .click();
  await expect(page.locator(".lens-plan-note")).toContainText(
    "stored in the file",
  );
  await expect(
    page.getByRole("combobox", { name: "Profile", exact: true }),
  ).toHaveCount(0);
  expect(errors).toEqual([]);
  await expect(page.locator(".error-banner")).toHaveCount(0);
});

test("automatic lens correction keeps full RAW pixels through film, crop and export", async ({
  page,
}) => {
  await page.goto("/");
  await page.locator("input[type=file][multiple]").setInputFiles({
    name: "lens.dng",
    mimeType: "image/x-adobe-dng",
    buffer: Buffer.from(fixture()),
  });
  await expect(page.locator(".viewer-status > [role=status]")).toContainText(
    "320 × 192",
  );
  await openPanel(page, "Expose");
  await page
    .getByRole("switch", { name: "Lens Correction", exact: true })
    .click();
  await expect(page.locator(".lens-plan-note")).toContainText(
    "stored in the file",
  );
  await page
    .getByRole("searchbox", { name: "Search films", exact: true })
    .fill("Gold 200");
  await page.getByTitle("Gold 200", { exact: true }).click();
  await page
    .getByRole("spinbutton", { name: "Exposure value", exact: true })
    .fill("1");
  await page
    .getByRole("spinbutton", { name: "Exposure value", exact: true })
    .press("Tab");
  await page.getByRole("button", { name: "Crop", exact: true }).click();
  await page
    .getByRole("combobox", { name: "Aspect ratio", exact: true })
    .click();
  await page.getByRole("option", { name: "1:1", exact: true }).click();
  await page.getByRole("button", { name: "Done", exact: true }).click();
  await page.getByRole("button", { name: "Export (⌘S)", exact: true }).click();
  const download = page.waitForEvent("download");
  await page.getByRole("button", { name: "Export", exact: true }).click();
  const png = await readFile(await (await download).path());
  expect(png.readUInt32BE(16)).toBe(192);
  expect(png.readUInt32BE(20)).toBe(192);
  await expect(page.locator(".error-banner")).toHaveCount(0);
});
