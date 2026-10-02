import { openEditor } from "./photo-fixture.js";
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
        const out = {
          width: image.naturalWidth,
          height: image.naturalHeight,
          hdr: image.hdr,
          fullPeak: Math.max(...values(full.source)),
          correctedPeak: Math.max(...values(corrected.source)),
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
    expect(result.correctedPeak).toBeGreaterThan(1.5);
    expect([result.width, result.height]).toEqual(
      name === "rotated" ? [64, 96] : [96, 64],
    );
  }
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
