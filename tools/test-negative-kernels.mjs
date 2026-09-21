#!/usr/bin/env node
// Generate the native references with WebNegativeScanRequestTests and
// FOTUFILM_SCAN_REFERENCE_DIRECTORY=build/negative-reference before running.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
const require = createRequire(new URL("../web/package.json", import.meta.url));
const { chromium, expect } = require("@playwright/test");
const browser = await chromium.launch({ channel: "chrome" });
try {
  const page = await browser.newPage();
  await page.goto(process.argv[2] || "http://127.0.0.1:5173/");
  await expect(page.locator(".viewer-status > [role=status]")).toContainText(
    /\d+ × \d+/,
  );
  for (const stock of ["gold200", "hp5plus400"]) {
    const fixture = JSON.parse(
      await readFile(
        new URL(`../build/negative-reference/${stock}.json`, import.meta.url),
        "utf8",
      ),
    );
    const report = await page.evaluate(
      async ({ stock, fixture }) => {
        const {
          parsePack,
          createDeveloper,
          createCpuDeveloper,
          encodeTileInto,
          pixelSource,
        } = await import("/src/engine.js");
        const { loadFilmProfile } = await import("/src/film-profile.js");
        const { createBackgroundDeveloper } = await import(
          "/src/background-developer.js"
        );
        const bytes = await loadFilmProfile({ ...fixture.request, stock });
        const prepared = JSON.parse(new TextDecoder().decode(bytes));
        const unpack = (encoded) =>
          parsePack(
            Uint8Array.from(atob(encoded), (v) => v.charCodeAt(0)).buffer,
          );
        const native = unpack(fixture.result.profile),
          pack = unpack(prepared.profile);
        const maxError = (a, b) => {
          if (a.length !== b.length)
            throw new Error("Reference length differs");
          let error = 0;
          for (let i = 0; i < a.length; i++) {
            if (!Number.isFinite(a[i]) || !Number.isFinite(b[i]))
              throw new Error("Nonfinite reference sample");
            error = Math.max(error, Math.abs(a[i] - b[i]));
          }
          return error;
        };
        const { width, height } = fixture.request;
        const gpu = await createDeveloper(pack),
          cpu = await createCpuDeveloper(pack);
        const results = {};
        try {
          for (const [label, developer] of [
            ["gpu", gpu],
            ["cpu", cpu],
          ]) {
            developer.setFrame(width, height);
            // Read the kernel's linear Display P3 output before delivery encoding;
            // compare directly with native printPositiveChecked, not another web path.
            developer.module.HEAPF32.set(
              developer.configuration,
              developer.configPtr / 4,
            );
            const input = new Float32Array(width * height * 4);
            for (let i = 0; i < width * height; i++)
              input.set([...fixture.density.slice(i * 3, i * 3 + 3), 1], i * 4);
            const region = { x: 0, y: 0, width, height };
            developer.decodeRegion(input, region);
            const code = await developer.run(region);
            if (code) throw new Error(`Render failed: ${code}`);
            const output = developer.regionOutput(region),
              actual = [];
            const offsets = developer.outputOffsets(region);
            const stride = label === "gpu" ? 4 : 1;
            for (let i = 0; i < width * height; i++)
              for (let c = 0; c < 3; c++)
                actual.push(output[i * stride + offsets[c]]);
            results[label] = {
              backend: developer.backend,
              error: maxError(actual, fixture.positive),
            };
          }
        } finally {
          gpu.dispose();
          cpu.dispose();
        }
        const background = await createBackgroundDeveloper(pack);
        try {
          await background.gpuReady;
          const data = new Float32Array(width * height * 4);
          for (let i = 0; i < width * height; i++)
            data.set([...fixture.density.slice(i * 3, i * 3 + 3), 1], i * 4);
          const delivered = await background.develop(
            pixelSource({ width, height, data }),
            {},
            undefined,
            undefined,
            { bitDepth: 16, colorSpace: "display-p3" },
          );
          const expected = new Uint16Array(width * height * 4);
          const tile = {
            x: 0,
            y: 0,
            width,
            height,
            region: { x: 0, y: 0, width, height },
          };
          encodeTileInto(
            expected,
            width,
            fixture.positive,
            tile,
            pack.seed,
            3,
            [0, 1, 2],
            "display-p3",
          );
          results.background = {
            backend: background.backend,
            error: maxError(delivered.pixels, expected),
          };
        } finally {
          background.dispose();
        }
        return {
          stock,
          ...results,
          configurationError: maxError(
            pack.configuration,
            native.configuration,
          ),
          calibration: prepared.calibration,
        };
      },
      { stock, fixture },
    );
    assert.equal(
      report.gpu.backend,
      "webgpu",
      "Actual WebGPU is required for this parity check",
    );
    assert.ok(report.gpu.error < 0.0002, JSON.stringify(report));
    assert.ok(report.cpu.error < 0.0002, JSON.stringify(report));
    assert.equal(report.background.backend, "webgpu");
    assert.ok(report.background.error <= 1, JSON.stringify(report));
    assert.ok(report.configurationError < 0.0002, JSON.stringify(report));
    for (const key of [
      "border",
      "baseDensity",
      "recordChannels",
      "minimumSample",
      "maximumSample",
    ])
      for (let i = 0; i < 3; i++)
        assert.ok(
          Math.abs(
            report.calibration[key][i] - fixture.result.calibration[key][i],
          ) < 0.0002,
        );
    console.log(JSON.stringify(report));
  }
} finally {
  await browser.close();
}
