import { test, expect } from "@playwright/test";
import { openChart, openPanel } from "./photo-fixture.js";

async function ready(page) {
  await expect(page.locator(".viewer-status > [role=status]")).toContainText(
    /1600 × 1000/,
  );
  await expect(page.locator(".error-banner")).toHaveCount(0);
}
async function pixels(page) {
  return page.locator(".photo-plane > img").evaluate(async (image) => {
    await image.decode();
    const canvas = document.createElement("canvas");
    canvas.width = 100;
    canvas.height = 64;
    const ctx = canvas.getContext("2d");
    ctx.drawImage(image, 0, 0, 100, 64);
    let hash = 2166136261;
    for (const value of ctx.getImageData(0, 0, 100, 64).data)
      hash = Math.imul(hash ^ value, 16777619) >>> 0;
    return hash;
  });
}
async function choose(page, name, option) {
  await page.locator("button[aria-haspopup=listbox]").filter({ has: page.locator("*") })
    .and(page.getByRole("button", { name: new RegExp(` ${name}$`) })).click();
  await page.getByRole("option", { name: option, exact: true }).click();
  await ready(page);
}

test("Layered Transport develops with film settings and another medium", async ({
  page,
}, testInfo) => {
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto("/");
  await openChart(page);
  await ready(page);
  await page.getByRole("searchbox", { name: "Search films" }).fill("Portra 400");
  await page.locator(".stock-row", { hasText: "Portra 400" }).first().click();
  await ready(page);
  await openPanel(page, "Film");
  const legacy = await pixels(page);
  await choose(page, "Halation Model", "Layered Transport");
  const layered = await pixels(page);
  expect(layered).not.toEqual(legacy);

  // A film setting used to put the browser back on Legacy; it is now prepared at its size.
  const halation = page.getByRole("textbox", { name: "Halation value", exact: true });
  await halation.fill("2");
  await halation.press("Tab");
  await ready(page);
  const stronger = await pixels(page);
  expect(stronger).not.toEqual(layered);
  await expect(page.getByRole("button", { name: "Layered Transport Halation Model" })).toBeVisible();

  await openPanel(page, "Print");
  await choose(page, "Output medium", "Digital Reference");
  expect(await pixels(page)).not.toEqual(stronger);
  await openPanel(page, "Film");
  await expect(page.getByRole("button", { name: "Layered Transport Halation Model" })).toBeVisible();
  await page.screenshot({ path: testInfo.outputPath("layered-settings.png") });
  expect(errors).toEqual([]);
});
