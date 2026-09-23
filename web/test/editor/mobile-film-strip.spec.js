import { test, expect } from "@playwright/test";
import { openChart } from "./photo-fixture.js";

for (const reducedMotion of ["no-preference", "reduce"]) {
  test(`mobile Film opens horizontal previews (${reducedMotion})`, async ({
    page,
  }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.emulateMedia({ reducedMotion });
    await page.addInitScript(() =>
      Object.defineProperty(navigator, "gpu", { value: undefined }),
    );
    await page.goto("/");
    await openChart(page, 480, 320);
    await expect(
      page.getByAltText("Developed photo", { exact: true }),
    ).toBeVisible();
    const film = page.getByRole("button", { name: "Film", exact: true });
    await film.click();
    const library = page.getByRole("complementary", { name: "Film library" });
    await expect(library).toBeVisible();
    await expect(
      page.getByRole("complementary", { name: "Adjustments" }),
    ).toHaveCount(0);
    await expect(film).toHaveAttribute("aria-expanded", "true");
    await expect(
      library.locator(".stock-list > div .stock-thumb img").first(),
    ).toBeVisible();
    const strip = library.locator(".stock-list");
    const geometry = await strip.evaluate((el) => {
      const buttons = [...el.querySelectorAll("button")]
        .slice(0, 3)
        .map((b) => b.getBoundingClientRect());
      return {
        overflow: el.scrollWidth > el.clientWidth,
        height: el.scrollHeight - el.clientHeight,
        tops: buttons.map((r) => r.top),
        widths: buttons.map((r) => r.width),
      };
    });
    expect(geometry.overflow).toBe(true);
    expect(geometry.height).toBeLessThanOrEqual(1);
    expect(new Set(geometry.tops).size).toBe(1);
    geometry.widths.forEach((width) => expect(width).toBe(126));
    await strip.evaluate((el) =>
      el.scrollTo({ left: 600, behavior: "instant" }),
    );
    await expect
      .poll(() => strip.evaluate((el) => el.scrollLeft))
      .toBeGreaterThan(300);
    const search = page.getByRole("searchbox", { name: "Search films" });
    await expect(search).toHaveCount(0);
    await expect(library.locator("[data-symbol=check]")).toHaveCount(0);
    const gold = library.getByRole("button", {
      name: "Gold 200 Film",
      exact: true,
    });
    await gold.click();
    await expect(gold).toHaveAttribute("aria-pressed", "true");
    await expect(library).toBeVisible();

    await page.getByRole("button", { name: "Expose", exact: true }).click();
    await expect(
      page.getByRole("complementary", { name: "Adjustments" }),
    ).toBeVisible();
    await page.getByRole("radio", { name: "Film", exact: true }).click();
    await expect(library).toBeVisible();
    await expect(gold).toBeInViewport();
    await page
      .getByRole("button", { name: "Film settings", exact: true })
      .click();
    await expect(
      page.getByRole("complementary", { name: "Adjustments" }),
    ).toBeVisible();
    await expect(
      page.getByRole("button", { name: "Halation", exact: true }),
    ).toBeVisible();
    await page
      .getByRole("button", { name: "Close adjustments", exact: true })
      .click();
    await film.click();
    for (const [width, height] of [
      [320, 568],
      [812, 375],
      [390, 844],
    ]) {
      await page.setViewportSize({ width, height });
      await page.waitForTimeout(300);
      expect(
        await page.evaluate(() => document.documentElement.scrollWidth),
      ).toBe(width);
      expect(
        (await page.locator(".viewer").boundingBox()).height,
      ).toBeGreaterThan(100);
      await expect(film).toBeInViewport();
    }
    if (reducedMotion === "no-preference")
      await page.screenshot({ path: "build/mobile-film-strip.png" });
    await film.click();
    await expect(library).toHaveCount(0);
  });
}
