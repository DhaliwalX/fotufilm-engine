import { test, expect } from "@playwright/test";

const editorURL = process.env.FOTUFILM_TEST_URL || "/";

test("Spectrum panel choices fit the inspector and support keyboard navigation", async ({
  page,
}) => {
  await page.goto(editorURL);
  const inspector = page.getByRole("complementary", {
    name: "Adjustments",
    exact: true,
  });
  const panels = page.getByRole("radiogroup", { name: "Adjustment panels" });
  for (const width of [1440, 1024, 834]) {
    await page.setViewportSize({ width, height: 960 });
    const bounds = await inspector.boundingBox();
    await expect(panels.getByRole("radio")).toHaveCount(4);
    for (const panel of await panels.getByRole("radio").all()) {
      const rect = await panel.boundingBox();
      expect(rect.x).toBeGreaterThanOrEqual(bounds.x);
      expect(rect.x + rect.width).toBeLessThanOrEqual(bounds.x + bounds.width);
    }
  }
  await page.getByRole("radio", { name: "Film", exact: true }).focus();
  await page.keyboard.press("ArrowRight");
  await expect(
    page.getByRole("radio", { name: "Expose", exact: true }),
  ).toBeFocused();
  await page.keyboard.press("Space");
  await expect(
    page.getByRole("radio", { name: "Expose", exact: true }),
  ).toBeChecked();
});

test("small screens keep the canvas and provide the collapsed inspector rail", async ({
  page,
}) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto(editorURL);
  await expect(page.locator(".inspector-rail")).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBe(
    390,
  );
  await page.getByRole("button", { name: "Expose", exact: true }).click();
  await expect(
    page.getByRole("radio", { name: "Expose", exact: true }),
  ).toBeVisible();
  const strip = page.getByRole("radiogroup", { name: "Adjustment panels" });
  await expect
    .poll(async () => {
      const bounds = await strip.boundingBox();
      return bounds.x >= 0 && bounds.x + bounds.width <= 390;
    })
    .toBe(true);
});

test("inspector revisits preserve reading position and respect reduced motion", async ({
  page,
}) => {
  await page.goto(editorURL);
  const expose = page.getByRole("radio", { name: "Expose", exact: true });
  const film = page.getByRole("radio", { name: "Film", exact: true });
  const content = page.locator("#inspector-content");
  await expose.click();
  await expect(
    content.getByRole("button", { name: "Light", exact: true }),
  ).toBeVisible();
  await content.evaluate((element) => {
    element.scrollTop = 900;
  });
  await expect
    .poll(() => content.evaluate((element) => element.scrollTop))
    .toBeGreaterThan(400);
  const position = await content.evaluate((element) => element.scrollTop);
  await film.click();
  await expect(film).toBeFocused();
  await expect
    .poll(() => content.evaluate((element) => element.scrollTop))
    .toBe(0);
  await expose.click();
  await expect(expose).toBeFocused();
  await expect
    .poll(() => content.evaluate((element) => element.scrollTop))
    .toBe(position);
  await page.emulateMedia({ reducedMotion: "reduce" });
  await film.click();
  await expect(page.locator("#inspector-content > fieldset").last()).toHaveCSS(
    "animation-name",
    "none",
  );
});
