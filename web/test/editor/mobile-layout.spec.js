import { test, expect } from "@playwright/test";
import { openChart } from "./photo-fixture.js";

async function settle(page) {
  await page.locator(".editor").evaluate(async (editor) => {
    await Promise.all(
      editor
        .getAnimations({ subtree: true })
        .map((animation) => animation.finished.catch(() => {})),
    );
  });
}

test("phone tools have touch targets and panels leave the image visible", async ({
  page,
}) => {
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.addInitScript(() =>
    Object.defineProperty(navigator, "gpu", { value: undefined }),
  );
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/");
  await openChart(page, 480, 320);
  await expect(
    page.getByAltText("Developed photo", { exact: true }),
  ).toBeVisible();
  for (const [width, height] of [
    [320, 568],
    [390, 844],
    [430, 932],
    [812, 375],
  ]) {
    await page.setViewportSize({ width, height });
    await settle(page);
    const targets = await page
      .locator(".toolbar button")
      .evaluateAll((buttons) =>
        buttons
          .map((button) => button.getBoundingClientRect())
          .filter((rect) => rect.width > 0)
          .map(({ x, y, width, height }) => ({ x, y, width, height })),
      );
    for (const target of targets) {
      expect(target.width).toBeGreaterThanOrEqual(44);
      expect(target.height).toBeGreaterThanOrEqual(44);
      expect(target.x).toBeGreaterThanOrEqual(0);
      expect(target.y).toBeGreaterThanOrEqual(0);
      expect(target.x + target.width).toBeLessThanOrEqual(width);
    }
    await page.getByRole("button", { name: "Expose", exact: true }).click();
    await expect(
      page.getByRole("complementary", { name: "Adjustments" }),
    ).toBeVisible();
    await settle(page);
    const viewer = await page.locator(".viewer").boundingBox();
    const panel = await page.locator(".inspector").boundingBox();
    expect(viewer.height).toBeGreaterThan(100);
    expect(viewer.y + viewer.height).toBeLessThanOrEqual(panel.y + 1);
    expect(panel.x).toBe(0);
    expect(panel.width).toBe(width);
    await expect(
      page.getByRole("textbox", { name: "Exposure value", exact: true }),
    ).toBeVisible();
    await page
      .getByRole("button", { name: "Close adjustments", exact: true })
      .click();
    await expect(
      page.getByRole("button", { name: "Toggle adjustments", exact: true }),
    ).toBeFocused();
    await page.getByRole("button", { name: "Film", exact: true }).click();
    await expect(
      page.getByRole("searchbox", { name: "Search films" }),
    ).toHaveCount(0);
    await page.getByRole("button", { name: "Toggle film sidebar", exact: true }).click();
    await expect(
      page.getByRole("button", { name: "Film", exact: true }),
    ).toBeFocused();
    expect(
      await page.evaluate(() => document.documentElement.scrollWidth),
    ).toBe(width);
  }
  await page.setViewportSize({ width: 390, height: 844 });
  await page.getByRole("button", { name: "Expose", exact: true }).click();
  await settle(page);
  await page.screenshot({ path: "build/phone-adjustments.png" });
  await page.getByRole("button", { name: "Close adjustments" }).click();
  await settle(page);
  await page.screenshot({ path: "build/phone-editor.png" });
  expect((await page.locator(".toolbar").boundingBox()).y).toBe(0);
  expect(errors).toEqual([]);
});

test("rotating from desktop collapses the panels and keeps desktop geometry on return", async ({
  page,
}) => {
  await page.addInitScript(() =>
    Object.defineProperty(navigator, "gpu", { value: undefined }),
  );
  await page.setViewportSize({ width: 1440, height: 960 });
  await page.goto("/");
  await expect(
    page.getByRole("complementary", { name: "Adjustments" }),
  ).toBeVisible();
  await page.setViewportSize({ width: 390, height: 844 });
  await expect(page.locator(".editor")).toHaveClass(
    /film-collapsed.*inspector-collapsed/,
  );
  await expect(
    page.getByRole("button", { name: "Expose", exact: true }),
  ).toBeVisible();
  await page.setViewportSize({ width: 1440, height: 960 });
  await page
    .getByRole("button", { name: "Toggle adjustments", exact: true })
    .click();
  await settle(page);
  const panel = await page.locator(".inspector").boundingBox();
  expect(panel.width).toBe(330);
  expect(panel.x + panel.width).toBe(1440);
  await page
    .getByRole("button", { name: "Toggle film sidebar", exact: true })
    .click();
  await expect(
    page.getByRole("searchbox", { name: "Search films" }),
  ).toBeVisible();
});

test("phone edits, undo and menus remain accessible with touch and reduced motion", async ({
  browser,
  baseURL,
}) => {
  const context = await browser.newContext({
    viewport: { width: 390, height: 844 },
    isMobile: true,
    hasTouch: true,
    reducedMotion: "reduce",
    colorScheme: "dark",
  });
  const page = await context.newPage();
  await page.addInitScript(() =>
    Object.defineProperty(navigator, "gpu", { value: undefined }),
  );
  try {
    await page.goto(baseURL || "http://127.0.0.1:5173/");
    await openChart(page, 320, 240);
    await expect(
      page.getByAltText("Developed photo", { exact: true }),
    ).toBeVisible();
    await page.getByRole("button", { name: "Expose", exact: true }).tap();
    const exposure = page.getByRole("textbox", {
      name: "Exposure value",
      exact: true,
    });
    await exposure.fill("0.5");
    await exposure.press("Enter");
    expect(
      await exposure.evaluate(
        (input) =>
          input.closest(".number-field").getBoundingClientRect().height,
      ),
    ).toBeGreaterThanOrEqual(40);
    await page.getByRole("button", { name: "Close adjustments" }).tap();
    await page.getByRole("button", { name: "Undo (⌘Z)", exact: true }).tap();
    await page.getByRole("button", { name: "Expose", exact: true }).tap();
    await expect(exposure).toHaveValue("0");
    await page.getByRole("button", { name: "Close adjustments" }).tap();
    await page.getByRole("button", { name: "Add media", exact: true }).tap();
    await expect(
      page.getByRole("menuitem", { name: "Negative", exact: true }),
    ).toBeVisible();
    await page.keyboard.press("Escape");
    await page.getByRole("button", { name: "More options", exact: true }).tap();
    await page.getByRole("menuitem", { name: "Crop", exact: true }).tap();
    await expect(
      page
        .locator(".darkroom-heading")
        .getByRole("heading", { name: "Crop", exact: true }),
    ).toBeVisible();
    await page.getByRole("button", { name: "Close adjustments" }).tap();
    await page.getByRole("button", { name: "Export (⌘S)", exact: true }).tap();
    await expect(page.getByRole("dialog")).toBeVisible();
    expect(
      await page.evaluate(() => document.documentElement.scrollWidth),
    ).toBe(390);
  } finally {
    await context.close();
  }
});
