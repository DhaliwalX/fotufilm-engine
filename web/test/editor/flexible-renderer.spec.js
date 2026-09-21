import { test, expect } from "@playwright/test";

// The flexible build deliberately has an empty preset dispatch table. Every render
// must execute the runtime-gated fallback, including combinations absent at build time.
for (const stock of ["gold200", "hp5plus400", "velvia50", "cinestill800t"]) {
  test(`flexible CPU stages match the stock kernel: ${stock}`, async ({
    page,
  }) => {
    await page.goto("/");
    const result = await page.evaluate(async (stock) => {
      const { default: factory } = await import("/test/flexible.mjs");
      const { SimdDeveloper, createCpuDeveloper, loadPack, pixelSource } =
        await import("/src/engine.js");
      const pack = await loadPack(`/packs/${stock}.pack`);
      const reference = await createCpuDeveloper(pack);
      const flexible = new SimdDeveloper(await factory(), pack);
      const width = 160,
        height = 96,
        data = new Float32Array(width * height * 4);
      for (let y = 0; y < height; y++)
        for (let x = 0; x < width; x++) {
          const at = (y * width + x) * 4;
          data[at] = (x / width) ** 2 * 2;
          data[at + 1] = (y / height) ** 2;
          data[at + 2] = x > width / 2 ? 0.7 : 0.015;
          data[at + 3] = 1;
        }
      const source = pixelSource({ data, width, height });
      try {
        const a = await reference.develop(source, { seed: 42 });
        const b = await flexible.develop(source, { seed: 42 });
        let peak = 0,
          different = 0;
        for (let i = 0; i < a.pixels.length; i++) {
          peak = Math.max(peak, Math.abs(a.pixels[i] - b.pixels[i]));
          if (a.pixels[i] !== b.pixels[i]) different++;
        }
        return { peak, different };
      } finally {
        reference.dispose();
        flexible.dispose();
      }
    }, stock);
    expect(result).toEqual({ peak: 0, different: 0 });
  });
}

test("new grain, gauge and halation combinations render deterministically", async ({
  page,
}) => {
  await page.goto("/");
  const results = await page.evaluate(async () => {
    const { default: factory } = await import("/test/flexible.mjs");
    const { SimdDeveloper, parsePack, pixelSource } = await import(
      "/src/engine.js"
    );
    const { loadFilmProfile } = await import("/src/film-profile.js");
    const module = await factory(),
      width = 160,
      height = 96;
    const data = new Float32Array(width * height * 4);
    for (let y = 0; y < height; y++)
      for (let x = 0; x < width; x++) {
        const at = (y * width + x) * 4;
        data.set([0.02 + x / width, 0.04 + y / height, 0.18, 1], at);
      }
    const source = pixelSource({ data, width, height }),
      results = [];
    for (const settings of [
      { stock: "gold200", controls: {} },
      {
        stock: "gold200",
        format: "16mm",
        controls: { expired: 7, bleach: 0.65 },
      },
      {
        stock: "gold200",
        controls: {
          halation: 2,
          halationColour: 0.7,
          couplers: 1.4,
          couplerReach: 1.7,
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
    ]) {
      const pack = parsePack(
        await loadFilmProfile({ ...settings, width, height }),
      );
      const developer = new SimdDeveloper(module, pack);
      try {
        const a = await developer.develop(source, { seed: 123 });
        const b = await developer.develop(source, { seed: 123 });
        let hash = 2166136261,
          min = 255,
          max = 0;
        a.pixels.forEach((v, i) => {
          if (i % 4 !== 3) {
            min = Math.min(min, v);
            max = Math.max(max, v);
          }
          hash = Math.imul(hash ^ v, 16777619) >>> 0;
        });
        results.push({
          hash,
          min,
          max,
          same: a.pixels.every((v, i) => v === b.pixels[i]),
        });
      } finally {
        developer.dispose();
      }
    }
    return results;
  });
  expect(new Set(results.map((r) => r.hash)).size).toBe(results.length);
  for (const r of results) {
    expect(r.same).toBe(true);
    expect(r.max - r.min).toBeGreaterThan(10);
  }
});
