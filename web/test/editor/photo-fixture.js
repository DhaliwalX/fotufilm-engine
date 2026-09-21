// A deterministic input keeps UI assertions independent of the bundled EXR demo.
export async function openChart(page) {
  const bytes = await page.evaluate(async () => {
    const canvas = document.createElement("canvas");
    canvas.width = 1600;
    canvas.height = 1000;
    const context = canvas.getContext("2d");
    const colors = [
      "#d83228",
      "#31ae52",
      "#3353d6",
      "#cdbbaa",
      "#222222",
      "#eeeeee",
    ];
    colors.forEach((color, index) => {
      context.fillStyle = color;
      context.fillRect(
        ((index % 3) * 1600) / 3,
        Math.floor(index / 3) * 500,
        1600 / 3,
        500,
      );
    });
    const blob = await new Promise((resolve) => canvas.toBlob(resolve));
    return Array.from(new Uint8Array(await blob.arrayBuffer()));
  });
  await page.locator("input[type=file][multiple]").setInputFiles({
    name: "Color chart.png",
    mimeType: "image/png",
    buffer: Buffer.from(bytes),
  });
}
