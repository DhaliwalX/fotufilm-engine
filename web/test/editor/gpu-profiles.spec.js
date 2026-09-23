import { test, expect } from "@playwright/test";

test("background WebGPU matches CPU for film, filters, chemistry and resolved grain", async ({
  page,
}) => {
  test.setTimeout(180000);
  await page.goto("/");
  const results = await page.evaluate(async () => {
    const { loadPack, parsePack, createCpuDeveloper, pixelSource } =
      await import("/src/engine.js");
    const { createBackgroundDeveloper } = await import(
      "/src/background-developer.js"
    );
    const { loadFilmProfile } = await import("/src/film-profile.js");
    const width = 320,
      height = 224,
      data = new Float32Array(width * height * 4);
    for (let y = 0; y < height; y++)
      for (let x = 0; x < width; x++) {
        const light = x > width * 0.65 && y < height * 0.4 ? 8 : 1;
        data.set(
          [
            (0.02 + x / width) * light,
            (0.04 + y / height) * light,
            0.18 * light,
            1,
          ],
          (y * width + x) * 4,
        );
      }
    const source = pixelSource({ width, height, data });
    const initial = await loadPack("/packs/gold200.pack");
    let warmed;
    const gpu = await createBackgroundDeveloper(
        initial,
        () => {},
        () => warmed?.(),
      ),
      cpu = await createCpuDeveloper(initial),
      results = [];
    try {
      await gpu.gpuReady;
      for (const settings of [
        { stock: "gold200", controls: {} },
        { stock: "velvia50", controls: {} },
        {
          stock: "gold200",
          filters: ["blackpromist-1/2", "w80a"],
          filterMetering: "throughTheLens",
          controls: {
            bleach: 0.5,
            couplers: 1.5,
            chromaticFringeAmount: 0.3,
            chromaticFringeRadius: 100,
          },
        },
        {
          stock: "hp5plus400",
          controls: { grainMottle: "heavy" },
        },
        {
          stock: "hp5plus400",
          controls: { grainModel: "crystals", enlarger: "condenser" },
        },
      ]) {
        const pack = parsePack(
          await loadFilmProfile({ ...settings, width, height }),
        );
        gpu.usePack(pack);
        cpu.usePack(pack);
        const controls = {
          seed: 123,
          ev: 0.3,
          highlights: -0.3,
          shadows: 0.4,
          localTone: true,
          temperature: 4800,
          tint: 12,
        };
        const nextWarm = new Promise((resolve) => {
          warmed = resolve;
        });
        let a = await gpu.develop(source, controls);
        if (gpu.backend !== "webgpu") {
          await nextWarm;
          a = await gpu.develop(source, controls);
        }
        const b = await cpu.develop(source, controls);
        let peak = 0,
          total = 0;
        for (let i = 0; i < a.pixels.length; i++) {
          const delta = Math.abs(a.pixels[i] - b.pixels[i]);
          peak = Math.max(peak, delta);
          total += delta;
        }
        results.push({
          settings,
          backend: gpu.backend,
          peak,
          mean: total / a.pixels.length,
        });
      }
      return results;
    } finally {
      gpu.dispose();
      cpu.dispose();
    }
  });
  console.log("Advanced GPU profiles:", JSON.stringify(results));
  for (const result of results) {
    expect(result.backend).toBe("webgpu");
    expect(result.mean).toBeLessThan(0.25);
    expect(result.peak).toBeLessThanOrEqual(3);
  }
});
