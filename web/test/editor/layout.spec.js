import { test, expect } from "@playwright/test";

test("Mac inspector tabs fit their panel and expose both scroll directions on overflow", async ({
  page,
}) => {
  await page.goto("/");
  const inspector = page.getByRole("complementary", {
    name: "Adjustments",
    exact: true,
  });
  const tabs = page.getByRole("tablist", { name: "Adjustment panels" });
  await expect(
    page.getByRole("tab", { name: "Print", exact: true }),
  ).toBeVisible();
  const bounds = await inspector.boundingBox();
  for (const tab of await tabs.getByRole("tab").all()) {
    const rect = await tab.boundingBox();
    expect(rect.x).toBeGreaterThanOrEqual(bounds.x);
    expect(rect.x + rect.width).toBeLessThanOrEqual(bounds.x + bounds.width);
  }
  // Exercise a narrower embedding as well as the normal 330px inspector.
  await page.locator(".inspector-tabs").evaluate((element) => {
    element.style.width = "180px";
  });
  const arrows = page.locator(".inspector-tabs .astryx-tab-scroll-button");
  await expect(arrows).toHaveCount(1);
  await arrows.click();
  await expect
    .poll(() => tabs.evaluate((element) => element.scrollLeft))
    .toBeGreaterThan(0);
  await expect
    .poll(() =>
      tabs.evaluate(
        (element) =>
          element.scrollWidth - element.clientWidth - element.scrollLeft,
      ),
    )
    .toBeLessThan(2);
  await expect(arrows).toHaveCount(1);
  await arrows.click();
  await expect
    .poll(() => tabs.evaluate((element) => element.scrollLeft))
    .toBeLessThan(2);
  await page.getByRole("tab", { name: "Film", exact: true }).focus();
  await page.keyboard.press("End");
  await expect(
    page.getByRole("tab", { name: "Print", exact: true }),
  ).toBeFocused();
});

test("small screens keep the canvas and provide the collapsed inspector rail", async ({
  page,
}) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/");
  await expect(page.locator(".inspector-rail")).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBe(
    390,
  );
  await page.getByRole("button", { name: "Expose", exact: true }).click();
  await expect(
    page.getByRole("tab", { name: "Expose", exact: true }),
  ).toBeVisible();
  const strip = await page.locator(".inspector-tabs").boundingBox();
  expect(strip.x).toBeGreaterThanOrEqual(0);
  expect(strip.x + strip.width).toBeLessThanOrEqual(390);
});
