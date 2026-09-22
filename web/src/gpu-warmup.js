import { assetUrl, loadPack, normalPack, createDeveloper } from "./engine.js";

export const GPU_WARMUP_GROUPS = 6;

export const gpuFamily = (pack) =>
  pack.featureMask & (1 << 29)
    ? "normal"
    : pack.featureMask & (1 << 14)
      ? pack.featureMask & (1 << 7)
        ? "print-monochrome"
        : "print-color"
      : pack.featureMask & (1 << 7)
        ? "monochrome"
        : "color";
export const gpuCompatible = (pack) =>
  !pack.transport && !(pack.featureMask & (1 << 28));

function printPack(pack) {
  const featureMask = pack.featureMask | (1 << 14);
  return {
    ...pack,
    featureMask,
    ladder: pack.ladder.map((rung) => ({
      ...rung,
      featureMask: rung.featureMask | (1 << 14),
    })),
  };
}

// Keep this developer alive: Halide caches pipelines on its device, not globally.
// Warm the shipped kernel families at common preview workgroup sizes. Unusual
// image sizes can still require a new workgroup specialization on first use.
export async function prepareFilmGpu(report, readyFamilies) {
  let gpu;
  let completed = 0;
  const progress = (label) =>
    report({ completed, total: GPU_WARMUP_GROUPS, label });
  try {
    progress("Loading image engine");
    gpu = await createDeveloper(normalPack());
    if (gpu.backend !== "webgpu") {
      gpu.dispose();
      return null;
    }
    const color = await loadPack(assetUrl("packs/gold200.pack"));
    const mono = await loadPack(assetUrl("packs/trix400.pack"));
    for (const [label, pack] of [
      ["Preparing preview", normalPack()],
      ["Preparing colour films", color],
      ["Preparing black & white films", mono],
      ["Preparing colour printing", printPack(color)],
      ["Preparing black & white printing", printPack(mono)],
    ]) {
      progress(label);
      gpu.usePack(pack);
      for (const [width, height] of [
        [960, 540],
        [1920, 1080],
      ])
        await gpu.probe({ width, height });
      readyFamilies.add(gpuFamily(pack));
      completed++;
    }
    progress("Preparing 16-bit export");
    gpu.usePack(normalPack());
    await gpu.probe({ width: 960, height: 540, bitDepth: 16 });
    completed++;
    progress("Image engine ready");
    return gpu;
  } catch (error) {
    gpu?.dispose();
    throw error;
  }
}
