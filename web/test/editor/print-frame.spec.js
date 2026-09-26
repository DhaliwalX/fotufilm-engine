import { openEditor, openEditorWithChart, openPanel } from "./photo-fixture.js";
import { execFileSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { test, expect } from "@playwright/test";

test("all frame materials and placements agree with native, preserving every photo pixel", async ({
  page,
}, testInfo) => {
  await openEditor(page);
  const gallery = [];
  const frames = [
    "none",
    "film",
    "slideMount",
    "paper",
    "paper5x7",
    "paper8x10",
    "paper5x5",
    "carrier",
    "mount",
    "darkMount",
    "socialSquare",
    "socialPortrait",
    "socialStory",
  ];
  for (const frame of frames) {
    const stock = frame === "slideMount" ? "ektachromee100" : "gold200";
    const request = {
      kind: "print-frame",
      stock,
      frame,
      format: "35mm",
      medium: frame === "slideMount" ? "ilfochrome-cps-1k" : "ektacolor-edge",
      width: 150,
      height: 100,
    };
    const definition = JSON.parse(
      await readFile(resolve(`../Sources/FotufilmCore/Stocks/${stock}.json`)),
    );
    const native = JSON.parse(
      execFileSync(resolve("../.build/release/fotufilm-web-profile"), {
        input: JSON.stringify({ ...request, stock: definition }),
      }),
    );
    const actual = await page.evaluate(async (request) => {
      const { loadFilmProfile } = await import("/src/film-profile.js");
      const { renderPrintFrame } = await import("/src/print-frame-renderer.js");
      const plan = JSON.parse(
        new TextDecoder().decode(await loadFilmProfile(request)),
      );
      const source = document.createElement("canvas");
      source.width = request.width;
      source.height = request.height;
      const ctx = source.getContext("2d"),
        data = ctx.createImageData(source.width, source.height);
      for (let y = 0; y < source.height; y++)
        for (let x = 0; x < source.width; x++)
          data.data.set(
            [
              (x * 255) / source.width,
              (y * 255) / source.height,
              (x + y) % 256,
              255,
            ],
            (y * source.width + x) * 4,
          );
      ctx.putImageData(data, 0, 0);
      const output = await renderPrintFrame(source, plan);
      const p = plan.placement,
        r = p.image;
      const copied = output
        .getContext("2d")
        .getImageData(
          r.x,
          output.height - r.y - r.height,
          r.width,
          r.height,
        ).data;
      let mismatches = 0;
      for (let y = 0; y < r.height; y++)
        for (let x = 0; x < r.width; x++)
          for (let c = 0; c < 4; c++)
            if (
              copied[(y * r.width + x) * 4 + c] !==
              data.data[(y * r.width + x) * 4 + c]
            )
              mismatches++;
      return {
        plan,
        mismatches,
        width: output.width,
        height: output.height,
        url: output.toDataURL(),
      };
    }, request);
    expect(actual.plan.configuration.frame).toBe(frame);
    expect(actual.plan.placement).toEqual(native.placement);
    expect(actual.plan.available).toEqual(native.available);
    expect(actual.plan.renderMedium).toEqual(native.renderMedium);
    for (const key of Object.keys(native.palette))
      for (let i = 0; i < 3; i++)
        expect(actual.plan.palette[key][i]).toBeCloseTo(
          native.palette[key][i],
          4,
        );
    expect(actual.mismatches, frame).toBe(0);
    expect([actual.width, actual.height]).toEqual([
      native.placement.size.width,
      native.placement.size.height,
    ]);
    gallery.push({ frame, url: actual.url });
  }
  await page.evaluate((gallery) => {
    document.body.replaceChildren();
    const grid = document.createElement("div");
    grid.style.cssText =
      "display:grid;grid-template-columns:repeat(5,1fr);gap:20px;padding:24px;background:#ececec;font:13px system-ui;color:#222";
    for (const item of gallery) {
      const card = document.createElement("figure"),
        image = document.createElement("img"),
        caption = document.createElement("figcaption");
      image.src = item.url;
      image.style.cssText = "width:100%;height:220px;object-fit:contain";
      caption.textContent = item.frame;
      card.append(image, caption);
      grid.append(card);
    }
    document.body.append(grid);
  }, gallery);
  await page.screenshot({
    path: testInfo.outputPath("print-frames.png"),
    fullPage: true,
  });
});

test("film framing develops the actual negative, while crop mode and video remain unframed", async ({
  page,
}) => {
  await openEditor(page);
  const actual = await page.evaluate(async () => {
    const { defaultEdit } = await import("/src/editor-state.js");
    const { RenderSession } = await import("/src/render-session.js");
    const { LinearImage } = await import("/src/linear-image.js");
    const width = 96,
      height = 64,
      pixels = new Float32Array(width * height * 4);
    for (let i = 0; i < pixels.length; i += 4)
      pixels.set([0.02 + i / pixels.length, 0.18, 0.3, 1], i);
    const image = new LinearImage({ pixels, width, height }),
      session = new RenderSession();
    const edit = {
      ...defaultEdit("gold200"),
      printFrame: "film",
      profile: { negativeViewing: "scanner" },
    };
    const render = (edit, extra = {}) =>
      session.render({
        image,
        edit,
        stock: "gold200",
        comparison: true,
        ...extra,
      });
    const framed = await render(edit);
    const plain = await render({
      ...edit,
      printFrame: "none",
      medium: "negative",
      profile: { negativeViewing: "light-box" },
    });
    const p = framed.framePlan.placement,
      r = p.image;
    const a = framed.canvas
      .getContext("2d")
      .getImageData(
        r.x,
        framed.height - r.y - r.height,
        r.width,
        r.height,
      ).data;
    const b = plain.canvas
      .getContext("2d")
      .getImageData(0, 0, plain.width, plain.height).data;
    let difference = 0;
    for (let i = 0; i < a.length; i++)
      difference = Math.max(difference, Math.abs(a[i] - b[i]));
    const original = await createImageBitmap(framed.original),
      originalSize = [original.width, original.height];
    original.close();
    const cropped = await render(edit, { cropMode: true });
    const video = { video: { start: 0, frame: async () => image } };
    const clip = await session.render({
      image: video,
      edit,
      stock: "gold200",
      comparison: false,
    });
    const stale = await import("/src/print-frame-renderer.js").then(
      ({ renderPrintFrame }) =>
        renderPrintFrame(plain.canvas, framed.framePlan, () => true),
    );
    await session.dispose();
    return {
      difference,
      size: [framed.width, framed.height],
      originalSize,
      cropSize: [cropped.width, cropped.height],
      clipSize: [clip.width, clip.height],
      stale: stale === null,
      savedMedium: edit.medium,
      savedViewing: edit.profile.negativeViewing,
    };
  });
  expect(actual.difference).toBe(0);
  expect(actual.originalSize).toEqual(actual.size);
  expect(actual.cropSize).toEqual([96, 64]);
  expect(actual.clipSize).toEqual([96, 64]);
  expect(actual.stale).toBe(true);
  expect(actual.savedMedium).toBe(null);
  expect(actual.savedViewing).toBe("scanner");
});

test("frame picker is undoable, saves its choice, exports the displayed dimensions and respects reduced motion", async ({
  page,
}, testInfo) => {
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await openEditorWithChart(page);
  await openPanel(page, "Print");
  const picker = page.getByRole("combobox", { name: "Frame", exact: true });
  await expect(picker).toBeEnabled();
  await picker.click();
  await page.getByRole("option", { name: "Story", exact: true }).click();
  await expect(page.locator(".photo-plane")).toHaveClass(/framed/);
  await expect(page.locator(".viewer-status > [role=status]")).toContainText(
    /\d+ × \d+/,
  );
  const previewRatio = await page
    .locator(".photo-plane > img")
    .evaluate((image) => image.naturalWidth / image.naturalHeight);
  expect(previewRatio).toBeCloseTo(9 / 16, 2);
  await page.getByRole("button", { name: "Undo (⌘Z)", exact: true }).click();
  await expect(picker).toHaveText("None");
  await page.getByRole("button", { name: "Redo (⇧⌘Z)", exact: true }).click();
  await expect(picker).toHaveText("Story");
  await page.getByRole("button", { name: "More options", exact: true }).click();
  const savedDownload = page.waitForEvent("download");
  await page.getByRole("button", { name: "Save edits…", exact: true }).click();
  const saved = JSON.parse(await readFile(await (await savedDownload).path()));
  expect(saved.edit.printFrame).toBe("socialStory");
  await page.emulateMedia({ reducedMotion: "reduce" });
  expect(
    await page
      .locator(".photo-plane")
      .evaluate((el) => getComputedStyle(el).transitionDuration),
  ).toBe("0s");
  await page.screenshot({ path: testInfo.outputPath("story-editor.png") });
  await page
    .getByRole("button", { name: "Export Photo…", exact: true })
    .click();
  const dimensions = (await page.locator(".export-detail").first().innerText())
    .match(/(\d+) × (\d+)/)
    .slice(1)
    .map(Number);
  const output = page.waitForEvent("download");
  await page.getByRole("button", { name: "Export", exact: true }).click();
  const download = await output;
  const bytes = await readFile(await download.path());
  expect(bytes.subarray(1, 4).toString()).toBe("PNG");
  const width = bytes.readUInt32BE(16),
    height = bytes.readUInt32BE(20);
  expect([width, height]).toEqual(dimensions);
  expect(width / height).toBeCloseTo(9 / 16, 2);
  expect(width).toBeGreaterThan(1000);
  expect(errors).toEqual([]);
});

test("physical perforations stay on the film edges through every gauge and portrait rotation", async ({
  page,
}) => {
  await openEditor(page);
  const results = await page.evaluate(async () => {
    const { defaultEdit } = await import("/src/editor-state.js");
    const { loadPrintFrame } = await import("/src/backend/browser-print-frame.js");
    const { renderPrintFrame } = await import("/src/print-frame-renderer.js");
    const results = [];
    for (const format of ["35mm", "super35", "16mm", "super8"])
      for (const [width, height] of [
        [300, 200],
        [200, 300],
      ]) {
        const plan = await loadPrintFrame(
          { ...defaultEdit("gold200"), printFrame: "film", format },
          width,
          height,
        );
        const source = document.createElement("canvas");
        source.width = width;
        source.height = height;
        source.getContext("2d").fillRect(0, 0, width, height);
        const output = await renderPrintFrame(source, plan),
          ctx = output.getContext("2d");
        const g = plan.configuration.geometry,
          hole = plan.perforation,
          p = plan.placement;
        let x = hole.edge + hole.width / 2,
          y = g.perforation === "sixteen" ? hole.height / 4 : g.pitchMM / 2;
        if (g.horizontalTransport) [x, y] = [y, g.heightMM - x];
        if (p.rotated) [x, y] = [plan.materialSize.height - y, x];
        const pixel = [
          ...ctx.getImageData(
            Math.floor(x * p.scale),
            Math.floor(output.height - y * p.scale),
            1,
            1,
          ).data,
        ];
        const expected = plan.palette.cutout.map((v) => Math.round(v * 255));
        results.push({ format, width, pixel, expected });
      }
    return results;
  });
  for (const result of results)
    for (let i = 0; i < 3; i++)
      expect(
        Math.abs(result.pixel[i] - result.expected[i]),
        `${result.format} width=${result.width}`,
      ).toBeLessThanOrEqual(1);
});
