import { test, expect } from "@playwright/test";
import { openChart } from "./photo-fixture.js";

test("rectangle crop, native perspective, reset and independent corners", async ({
  page,
}, testInfo) => {
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto("/");
  await openChart(page);
  await expect(page.locator(".viewer-status > [role=status]")).toContainText(
    "1600 × 1000",
  );
  await page.getByRole("button", { name: "Crop", exact: true }).click();
  const corner = page.getByRole("button", {
    name: "Top left crop corner",
    exact: true,
  });
  const polygon = page.locator(".crop-overlay polygon");
  const initial = await polygon.getAttribute("points");
  await corner.press("ArrowRight");
  const moved = (await polygon.getAttribute("points")).split(" ");
  expect(moved[0]).not.toBe(initial.split(" ")[0]);
  expect(moved[3]).not.toBe(initial.split(" ")[3]);
  await page
    .getByRole("spinbutton", { name: "Vertical value", exact: true })
    .fill("8");
  await page
    .getByRole("spinbutton", { name: "Vertical value", exact: true })
    .press("Tab");
  await expect(page.locator(".viewer-status > [role=status]")).toContainText(
    "1600 × 1000",
  );
  await expect(
    page.getByLabel("Crop selection", { exact: true }),
  ).toBeVisible();
  await page.screenshot({ path: testInfo.outputPath("perspective-crop.png") });
  await page.getByRole("button", { name: "Reset Crop", exact: true }).click();
  await expect(
    page.getByRole("spinbutton", { name: "Vertical value", exact: true }),
  ).toHaveValue("0");
  expect(await polygon.getAttribute("points")).toBe(initial);
  await page
    .getByRole("button", { name: "Four-Corner Crop", exact: true })
    .click();
  await corner.press("ArrowDown");
  const free = (await polygon.getAttribute("points")).split(" ");
  expect(free[0]).not.toBe(initial.split(" ")[0]);
  expect(free.slice(1)).toEqual(initial.split(" ").slice(1));
  await expect(page.locator(".error-banner")).toHaveCount(0);
  expect(errors).toEqual([]);
});
