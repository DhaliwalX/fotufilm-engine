import { expect } from "@playwright/test";

export const viewerStatus = (page) =>
  page.locator(".viewer-status > [role=status]");

// The editor opens with an empty canvas.
export async function openEditor(page, url = "/") {
  await page.goto(url);
  await expect(page.locator(".viewer-status .document-name")).toHaveText(
    "No photo open",
  );
}

// Open the editor on the chart and wait for its first preview.
export async function openEditorWithChart(page, width, height) {
  await openEditor(page);
  await openChart(page, width, height);
  await expect(viewerStatus(page)).toContainText(/\d+ × \d+/);
}

// Show one of the inspector's adjustment panels: Film, Expose, Develop or Print.
export const openPanel = (page, name) =>
  page
    .getByRole("radiogroup", { name: "Adjustment panels" })
    .getByRole("radio", { name, exact: true })
    .click();

// Generate a deterministic photo for editor interactions.
export async function openChart(page, width = 1600, height = 1000) {
  const bytes = await page.evaluate(
    async ({ width, height }) => {
      const canvas = document.createElement("canvas");
      canvas.width = width;
      canvas.height = height;
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
          ((index % 3) * width) / 3,
          (Math.floor(index / 3) * height) / 2,
          width / 3,
          height / 2,
        );
      });
      const blob = await new Promise((resolve) => canvas.toBlob(resolve));
      return Array.from(new Uint8Array(await blob.arrayBuffer()));
    },
    { width, height },
  );
  await page.locator("input[type=file][multiple]").setInputFiles({
    name: "Color chart.png",
    mimeType: "image/png",
    buffer: Buffer.from(bytes),
  });
}
