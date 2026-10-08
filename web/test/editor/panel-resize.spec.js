import { test, expect } from "@playwright/test";

// The editor grid's side columns: the film list's and the darkroom panel's widths.
const widths = (page) =>
  page.evaluate(() => {
    // Nothing yet while the page is still loading.
    const editor = document.querySelector(".editor");
    if (!editor) return { film: null, inspector: null };
    const columns = getComputedStyle(editor)
      .gridTemplateColumns.split(" ")
      .map((value) => Math.round(parseFloat(value)));
    return { film: columns[0], inspector: columns[2] };
  });

// Drags the edge named `name` by `dx` pixels.
async function drag(page, name, dx) {
  const edge = page.getByRole("separator", { name });
  const box = await edge.boundingBox();
  const x = box.x + box.width / 2,
    y = box.y + box.height / 2;
  await page.mouse.move(x, y);
  await page.mouse.down();
  await page.mouse.move(x + dx / 2, y, { steps: 4 });
  await page.mouse.move(x + dx, y, { steps: 4 });
  await page.mouse.up();
}

test("both side panels resize by their edges and keep their widths", async ({
  page,
}, testInfo) => {
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.goto("/");
  await page.evaluate(() => localStorage.removeItem("fotufilm.panelWidths"));
  await page.reload();
  await expect(
    page.getByRole("separator", { name: "Resize film list" }),
  ).toBeVisible();
  await expect.poll(() => widths(page)).toEqual({ film: 236, inspector: 330 });

  // The film list widens to the right, the darkroom panel to the left.
  await drag(page, "Resize film list", 100);
  await drag(page, "Resize darkroom panel", -120);
  await expect.poll(() => widths(page)).toEqual({ film: 336, inspector: 450 });
  // The panels keep their places: the film list on the left, the picture between.
  const left = (selector) =>
    page.evaluate(
      (s) => Math.round(document.querySelector(s).getBoundingClientRect().left),
      selector,
    );
  expect(await left(".film-sidebar")).toBe(0);
  expect(await left(".viewer")).toBe(336);
  expect(await left(".inspector")).toBe(1440 - 450);
  await page.mouse.move(700, 400);
  await page.screenshot({ path: testInfo.outputPath("resized.png") });

  // Each stops at its bounds.
  await drag(page, "Resize film list", -400);
  await expect.poll(async () => (await widths(page)).film).toBe(180);

  // Arrow keys move an edge, Shift further; Return puts it back.
  const film = page.getByRole("separator", { name: "Resize film list" });
  await film.focus();
  await page.keyboard.press("ArrowRight");
  await expect.poll(async () => (await widths(page)).film).toBe(196);
  await page.keyboard.press("Shift+ArrowRight");
  await expect.poll(async () => (await widths(page)).film).toBe(260);
  await expect(film).toHaveAttribute("aria-valuenow", "260");
  await page.keyboard.press("Enter");
  await expect.poll(async () => (await widths(page)).film).toBe(236);

  // The widths come back on the next visit.
  await drag(page, "Resize film list", 64);
  await page.reload();
  await expect.poll(() => widths(page)).toEqual({ film: 300, inspector: 450 });

  // A double-click resets an edge.
  await page
    .getByRole("separator", { name: "Resize darkroom panel" })
    .dblclick();
  await expect.poll(async () => (await widths(page)).inspector).toBe(330);

  // A narrow window takes room back for the picture, and gives it back as it widens.
  await page.setViewportSize({ width: 1000, height: 960 });
  await page.getByRole("separator", { name: "Resize darkroom panel" }).focus();
  await page.keyboard.press("End");
  await expect
    .poll(async () => (await widths(page)).inspector)
    .toBe(1000 - 300 - 420);
  await page.setViewportSize({ width: 1440, height: 960 });
  await expect.poll(async () => (await widths(page)).inspector).toBe(280);

  // A collapsed film list has no edge to drag, and keeps its width for when it opens.
  await page.getByRole("button", { name: "Toggle film sidebar" }).click();
  await expect(
    page.getByRole("separator", { name: "Resize film list" }),
  ).toHaveCount(0);
  await expect.poll(async () => (await widths(page)).film).toBe(60);
  await page.getByRole("button", { name: "Toggle film sidebar" }).click();
  await expect.poll(async () => (await widths(page)).film).toBe(300);

  // The phone's stacked layout has no edges at all.
  await page.setViewportSize({ width: 600, height: 900 });
  await expect(page.getByRole("separator")).toHaveCount(0);
  expect(errors).toEqual([]);
});
