import { test, expect } from "@playwright/test";
import { readFile } from "node:fs/promises";
import { openChart } from "./photo-fixture.js";

test("TIFF download carries 16-bit samples, full dimensions and an ICC profile", async ({
  page,
}) => {
  await page.goto("/");
  await openChart(page, 720, 480);
  await expect(page.locator(".viewer-status > [role=status]")).toContainText(
    "720 × 480",
  );
  await page.getByRole("tab", { name: "Expose", exact: true }).click();
  await page.getByRole("spinbutton", { name: "Exposure value", exact: true }).fill("-0.35");
  await page.getByRole("spinbutton", { name: "Exposure value", exact: true }).press("Tab");
  await page.getByRole("tab", { name: "Print", exact: true }).click();
  await page
    .getByRole("button", { name: "Export Photo…", exact: true })
    .click();
  await page.getByLabel("Format", { exact: true }).selectOption("image/tiff");
  await expect(page.getByLabel("Quality", { exact: true })).toHaveCount(0);
  await expect(page.locator(".export-detail").first()).toContainText("16-bit");
  const pending = page.waitForEvent("download");
  await page.getByRole("button", { name: "Export", exact: true }).click();
  const download = await pending,
    bytes = await readFile(await download.path());
  expect(download.suggestedFilename()).toMatch(/\.tiff$/);
  expect(bytes.readUInt16LE(2)).toBe(42);
  const tags = new Map();
  for (let i = 0; i < bytes.readUInt16LE(8); i++) {
    const at = 10 + i * 12;
    tags.set(bytes.readUInt16LE(at), {
      type: bytes.readUInt16LE(at + 2),
      count: bytes.readUInt32LE(at + 4),
      value: bytes.readUInt32LE(at + 8),
    });
  }
  expect(tags.get(256).value).toBe(720);
  expect(tags.get(257).value).toBe(480);
  expect(tags.get(258).count).toBe(4);
  expect(bytes.readUInt16LE(tags.get(258).value)).toBe(16);
  expect(
    bytes.toString(
      "ascii",
      tags.get(34675).value + 36,
      tags.get(34675).value + 40,
    ),
  ).toBe("acsp");
  const start =
    tags.get(273).count === 1
      ? tags.get(273).value
      : bytes.readUInt32LE(tags.get(273).value);
  expect(
    Array.from({ length: 100 }, (_, i) =>
      bytes.readUInt16LE(start + i * 8),
    ).some((v) => v % 257 !== 0),
  ).toBe(true);
});

test("16-bit film development preserves cropped precision and every framed interior sample", async ({
  page,
}) => {
  test.setTimeout(180000);
  await page.goto("/");
  const report = await page.evaluate(async () => {
    const { RenderSession } = await import("/src/render-session.js");
    const { LinearImage } = await import("/src/linear-image.js");
    const { defaultEdit } = await import("/src/editor-state.js");
    const { renderPrintFrame16 } = await import("/src/print-frame-16.js");
    const { loadPrintFrame } = await import("/src/print-frame.js");
    const width = 512,
      height = 128,
      pixels = new Float32Array(width * height * 4);
    for (let y = 0; y < height; y++)
      for (let x = 0; x < width; x++)
        pixels.set([x / width, y / height, 0.18, 1], (y * width + x) * 4);
    const image = new LinearImage({ pixels, width, height }),
      session = new RenderSession();
    const edit = {
      ...defaultEdit("gold200"),
      crop: [
        [0.125, 0],
        [0.875, 0],
        [0.875, 1],
        [0.125, 1],
      ],
    };
    try {
      const developed = await session.render({
        image,
        edit,
        stock: "gold200",
        bitDepth: 16,
        comparison: false,
        purpose: "export",
        maxEdge: Infinity,
      });
      const frameResults = [];
      for (const printFrame of ["film", "emulsion", "socialPortrait"]) {
        const plan = await loadPrintFrame(
          { ...edit, printFrame },
          developed.width,
          developed.height,
        );
        const result = await renderPrintFrame16(
          developed.pixels,
          developed.width,
          developed.height,
          plan,
        );
        const r = plan.placement.image,
          top = result.height - r.y - r.height,
          rim =
            printFrame === "emulsion"
              ? Math.ceil(Math.min(r.width, r.height) * 0.045)
              : 0;
        let mismatches = 0;
        for (let y = rim; y < r.height - rim; y++)
          for (let x = rim; x < r.width - rim; x++)
            for (let c = 0; c < 4; c++)
              if (
                result.pixels[((top + y) * result.width + r.x + x) * 4 + c] !==
                developed.pixels[(y * r.width + x) * 4 + c]
              )
                mismatches++;
        frameResults.push({ printFrame, mismatches });
      }
      return {
        width: developed.width,
        height: developed.height,
        sixteen: developed.pixels instanceof Uint16Array,
        levels: new Set(
          Array.from(developed.pixels).filter((_, i) => i % 4 === 0),
        ).size,
        frameResults,
      };
    } finally {
      session.dispose();
    }
  });
  expect(report.sixteen).toBe(true);
  expect(report.width).toBe(384);
  expect(report.height).toBe(128);
  expect(report.levels).toBeGreaterThan(256);
  for (const frame of report.frameResults)
    expect(frame.mismatches, frame.printFrame).toBe(0);
});
