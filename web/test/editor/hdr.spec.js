import { openEditor, openPanel } from "./photo-fixture.js";
import { readFile } from "node:fs/promises";
import { test, expect } from "@playwright/test";

test("JPEG gain maps preserve scene highlights through orientation, lens correction and full-size rendering", async ({
  page,
}) => {
  await openEditor(page);
  for (const name of ["gainmap", "rotated", "rec2020"]) {
    const bytes = [
      ...(await readFile(
        new URL(
          `../../../build/ultrahdr/fixtures/${name}.jpg`,
          import.meta.url,
        ),
      )),
    ];
    const result = await page.evaluate(
      async ({ bytes, name }) => {
        const { importPhoto } = await import("/src/photo-import.js");
        const { defaultEdit } = await import("/src/editor-state.js");
        const { RenderSession } = await import("/src/render-session.js");
        const { image, url } = await importPhoto(
          new File([new Uint8Array(bytes)], name + ".jpg", {
            type: "image/jpeg",
          }),
        );
        const session = new RenderSession(),
          edit = defaultEdit();
        const full = await session.source(image, edit, Infinity, false);
        const standard = await session.source(
          image,
          { ...edit, sourceInterpretation: "standardRange" },
          Infinity,
          false,
        );
        const automatic = await session.source(
          image,
          { ...edit, sourceInterpretation: "fullRange" },
          Infinity,
          false,
        );
        const corrected = await session.source(
          image,
          { ...edit, lens: { ...edit.lens, enabled: true, distortion: 0.2 } },
          Infinity,
          false,
        );
        const values = (source) =>
          [...source.read(0, 0, source.width, source.height)].filter(
            (_, i) => i % 4 !== 3,
          );
        const fullPixels = values(full.source),
          standardPixels = values(standard.source);
        const renderEdit = { ...edit, params: { ...edit.params, ev: -2 } };
        const developed = await session.render({
          image,
          edit: renderEdit,
          maxEdge: Infinity,
          comparison: false,
        });
        const developedSDR = await session.render({
          image,
          edit: { ...renderEdit, sourceInterpretation: "standardRange" },
          maxEdge: Infinity,
          comparison: false,
        });
        const displayed = (frame) =>
          frame.canvas
            .getContext("2d")
            .getImageData(0, 0, image.naturalWidth, image.naturalHeight).data;
        const output = displayed(developed),
          outputSDR = displayed(developedSDR);
        const meanDifference =
          output.reduce(
            (sum, value, i) => sum + Math.abs(value - outputSDR[i]),
            0,
          ) / output.length;
        const out = {
          width: image.naturalWidth,
          height: image.naturalHeight,
          hdr: image.hdr,
          fullPeak: Math.max(...fullPixels),
          standardPeak: Math.max(...standardPixels),
          automaticSame:
            JSON.stringify(fullPixels) ===
            JSON.stringify(values(automatic.source)),
          correctedPeak: Math.max(...values(corrected.source)),
          ordinary: !image.standardImage.hdr,
          meanDifference,
        };
        URL.revokeObjectURL(url);
        return out;
      },
      { bytes, name },
    );
    expect(result.hdr.format).toBe("JPEG gain map");
    expect(result.hdr.referenceGain).toBeGreaterThan(0.45);
    expect(result.hdr.referenceGain).toBeLessThan(0.55);
    expect(result.fullPeak).toBeGreaterThan(1.5);
    expect(result.standardPeak).toBeLessThanOrEqual(1);
    expect(result.correctedPeak).toBeGreaterThan(1.5);
    expect(result.meanDifference).toBeGreaterThan(1);
    expect(result.automaticSame).toBe(true);
    expect([result.width, result.height]).toEqual(
      name === "rotated" ? [64, 96] : [96, 64],
    );
  }
});

test("Source Interpretation follows Mac placement, undo, saved edits and export", async ({
  page,
}, testInfo) => {
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.goto("/");
  const file = await readFile(
    new URL("../../../build/ultrahdr/fixtures/gainmap.jpg", import.meta.url),
  );
  await page.locator("input[type=file][multiple]").setInputFiles({
    name: "HDR test.jpg",
    mimeType: "image/jpeg",
    buffer: file,
  });
  await expect(page.locator(".viewer-status > [role=status]")).toContainText(
    "96 × 64",
  );
  await expect(page.locator(".pixel-readout")).toContainText("HDR");
  await openPanel(page, "Expose");
  const choice = page.getByRole("combobox", {
    name: "Highlights",
    exact: true,
  });
  await expect(choice).toContainText("Automatic");
  await choice.click();
  await page
    .getByRole("option", { name: "Standard Range", exact: true })
    .click();
  await expect(choice).toContainText("Standard Range");
  await page.getByRole("button", { name: "Undo (⌘Z)", exact: true }).click();
  await expect(choice).toContainText("Automatic");
  await choice.click();
  await page.getByRole("option", { name: "Full Range", exact: true }).click();
  await page.getByRole("button", { name: "More options", exact: true }).click();
  const savedDownload = page.waitForEvent("download");
  await page.getByRole("button", { name: "Save edits…", exact: true }).click();
  const saved = await readFile(await (await savedDownload).path());
  expect(JSON.parse(saved).edit.sourceInterpretation).toBe("fullRange");
  await page.locator('input[type=file][accept=".json"]').setInputFiles({
    name: "hdr.json",
    mimeType: "application/json",
    buffer: saved,
  });
  await expect(choice).toContainText("Full Range");
  await choice.scrollIntoViewIfNeeded();
  await page.screenshot({
    path: testInfo.outputPath("source-interpretation.png"),
  });
  await page.getByRole("button", { name: "Export (⌘S)", exact: true }).click();
  const output = page.waitForEvent("download");
  await page.getByRole("button", { name: "Export", exact: true }).click();
  const png = await readFile(await (await output).path());
  expect([png.readUInt32BE(16), png.readUInt32BE(20)]).toEqual([96, 64]);
  expect(errors).toEqual([]);
});

test("HDR worker can cancel and ordinary JPEG remains an ordinary image", async ({
  page,
}) => {
  await page.goto("/");
  const result = await page.evaluate(async () => {
    const { importPhoto } = await import("/src/photo-import.js");
    const canvas = document.createElement("canvas");
    canvas.width = canvas.height = 16;
    canvas.getContext("2d").fillRect(0, 0, 16, 16);
    const blob = await new Promise((resolve) =>
      canvas.toBlob(resolve, "image/jpeg"),
    );
    const file = new File([blob], "ordinary.jpg", { type: "image/jpeg" });
    const decoded = await importPhoto(file);
    URL.revokeObjectURL(decoded.url);
    const controller = new AbortController();
    controller.abort();
    let cancelled;
    try {
      await importPhoto(file, { signal: controller.signal });
    } catch (error) {
      cancelled = error.name;
    }
    return { ordinary: decoded.image instanceof HTMLImageElement, cancelled };
  });
  expect(result).toEqual({ ordinary: true, cancelled: "AbortError" });
  const bytes = [
    ...(await readFile(
      new URL("../../../build/ultrahdr/fixtures/gainmap.jpg", import.meta.url),
    )),
  ];
  const duringDecode = await page.evaluate(async (bytes) => {
    const { importPhoto } = await import("/src/photo-import.js");
    const controller = new AbortController();
    try {
      await importPhoto(new File([new Uint8Array(bytes)], "cancel.jpg"), {
        signal: controller.signal,
        onProgress: (stage) => {
          if (stage === "Decoding HDR highlights") controller.abort();
        },
      });
      return "finished";
    } catch (error) {
      return error.name;
    }
  }, bytes);
  expect(duringDecode).toBe("AbortError");
});
