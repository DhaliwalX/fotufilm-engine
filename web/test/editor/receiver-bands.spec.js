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
const picker = (page, name) =>
  page.locator("button[aria-haspopup=listbox]")
    .and(page.getByRole("button", { name: new RegExp(` ${name}$`) }));

test("a slide reads through saved receiver bands, which also start new photos", async ({
  page,
}, testInfo) => {
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto("/");
  await openChart(page);
  await ready(page);
  await page.getByRole("searchbox", { name: "Search films" }).fill("Velvia 50");
  await page.locator(".stock-row", { hasText: "Velvia 50" }).first().click();
  await ready(page);
  await openPanel(page, "Print");
  await picker(page, "Output medium").click();
  await page.getByRole("option", { name: "Digital Reference", exact: true }).click();
  await ready(page);
  const paper = await pixels(page);

  await page.getByRole("button", { name: "Receiver bands" }).click();
  const red = page.getByRole("textbox", { name: "Red Band peak" });
  await red.fill("630");
  await red.press("Tab");
  await ready(page);
  const moved = await pixels(page);
  expect(moved).not.toEqual(paper);

  await page.getByRole("button", { name: "Save Bands…" }).click();
  await page.getByRole("textbox", { name: "Name" }).fill("Minilab");
  await page.getByRole("button", { name: "Save", exact: true }).click();
  await expect(picker(page, "Saved Bands")).toContainText("Minilab");

  await page.getByRole("button", { name: "Reset Bands" }).click();
  await ready(page);
  await expect.poll(() => pixels(page)).toEqual(paper);
  await picker(page, "Saved Bands").click();
  await page.getByRole("option", { name: "Minilab", exact: true }).click();
  await ready(page);
  await expect(red).toHaveValue("630");
  await expect.poll(() => pixels(page)).toEqual(moved);

  await page.getByText("Use for New Photos", { exact: true }).click();
  await expect(page.getByRole("switch", { name: "Use for New Photos" })).toBeChecked();
  expect(
    await page.evaluate(() =>
      JSON.parse(localStorage.getItem("fotufilm.setting.receiverBands")),
    ),
  ).toEqual({ red: 630, green: 545, blue: 470 });
  await page.screenshot({ path: testInfo.outputPath("receiver-bands.png") });
  expect(errors).toEqual([]);
});
