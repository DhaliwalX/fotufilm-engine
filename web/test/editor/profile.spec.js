import { test, expect } from "@playwright/test";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const cases = [
  { stock: "gold200", controls: {} },
  { stock: "gold200", format: "16mm", controls: { expired: 7, bleach: 0.65 } },
  {
    stock: "gold200",
    controls: {
      halation: 1.5,
      halationColour: 0.7,
      couplers: 1.4,
      couplerReach: 1.7,
      couplerSelf: 0.5,
    },
  },
  {
    stock: "hp5plus400",
    controls: { grainMottle: "heavy", grainModel: "discs" },
  },
  {
    stock: "hp5plus400",
    controls: { grainModel: "crystals", enlarger: "condenser" },
  },
  {
    stock: "gold200",
    medium: "screen",
    controls: {
      digitalReference: "graded-print",
      screenGrade: 3,
      screenExposure: 0.7,
    },
  },
];

for (const settings of cases) {
  test(`on-device profile matches native: ${JSON.stringify(settings)}`, async ({
    page,
  }) => {
    const request = { ...settings, width: 320, height: 192 };
    const stock = JSON.parse(
      readFileSync(
        resolve(`../Sources/FotufilmCore/Stocks/${settings.stock}.json`),
      ),
    );
    const native = execFileSync(
      resolve("../.build/release/fotufilm-web-profile"),
      {
        input: JSON.stringify({ ...request, stock }),
        maxBuffer: 8 * 1024 * 1024,
      },
    );
    await page.goto("/");
    const report = await page.evaluate(
      async ({ request, native }) => {
        const { loadFilmProfile } = await import("/src/film-profile.js");
        const { parsePack } = await import("/src/engine.js");
        const bytes = await loadFilmProfile(request);
        const actual = parsePack(bytes),
          reference = parsePack(new Uint8Array(native).buffer);
        const differences = {};
        for (const field of ["configuration", "exposure", "film", "paper"]) {
          if (actual[field].length !== reference[field].length)
            throw new Error(`${field} size differs`);
          let peak = 0;
          actual[field].forEach((value, index) => {
            peak = Math.max(
              peak,
              Math.abs(value - reference[field][index]) /
                (1 + Math.abs(reference[field][index])),
            );
          });
          differences[field] = peak;
        }
        return {
          differences,
          featureMask: actual.featureMask,
          nativeMask: reference.featureMask,
          width: actual.width,
          height: actual.height,
          cached: bytes === (await loadFilmProfile(request)),
        };
      },
      { request, native: Array.from(native) },
    );
    console.log(settings, report);
    expect(report.width).toBe(320);
    expect(report.height).toBe(192);
    expect(report.featureMask).toBe(report.nativeMask);
    expect(report.cached).toBe(true);
    for (const peak of Object.values(report.differences))
      expect(peak).toBeLessThan(0.00001);
  });
}

test("invalid controls fail without poisoning the profile worker", async ({
  page,
}) => {
  await page.goto("/");
  const report = await page.evaluate(async () => {
    const { loadFilmProfile } = await import("/src/film-profile.js");
    const request = {
      stock: "gold200",
      width: 100,
      height: 80,
      controls: { expired: -1 },
    };
    let message;
    try {
      await loadFilmProfile(request);
    } catch (error) {
      message = error.message;
    }
    const valid = await loadFilmProfile({
      ...request,
      controls: { expired: 1 },
    });
    return { message, bytes: valid.byteLength };
  });
  expect(report.message).toContain("outside its supported range");
  expect(report.bytes).toBeGreaterThan(1_000_000);
});
