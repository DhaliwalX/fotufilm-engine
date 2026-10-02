import { test, expect } from "@playwright/test";
import { openChart } from "./photo-fixture.js";
import { installNativeBackend } from "./native-backend-fixture.js";

test("paper picker updates preview and border, survives medium changes, and resets", async ({ page }) => {
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.addInitScript(installNativeBackend);
  await page.addInitScript(() => {
    const host = window.fotufilmNative;
    host.loadStocks = async () => [{
      id: "gold200", name: "Gold 200", defaultMedium: "newsprint-color",
      available: ["paperColor"],
      media: [
        { id: "newsprint-color", name: "Color Newsprint" },
        { id: "newsprint-bw", name: "B&W Newsprint" },
        { id: "screen", name: "Digital Reference" },
      ],
      profile: { media: {
        "newsprint-color": { paperColor: "#0a0a0a", viewingLights: [] },
        "newsprint-bw": { paperColor: "#f2ecdd", viewingLights: [] },
        screen: { viewingLights: [] },
      } },
    }];
    const createSession = host.createSession;
    host.createSession = () => {
      const session = createSession();
      const render = session.render;
      session.render = (request) => {
        window.lastPaperRender = request.edit;
        return render(request);
      };
      return session;
    };
    const plan = host.planPrintFrame;
    host.planPrintFrame = async (edit, ...args) => {
      window.lastPaperFrame = edit;
      return { ...await plan(edit, ...args), available: ["none"] };
    };
  });
  await page.goto("/");
  await openChart(page, 480, 320);
  await expect(page.getByAltText("Developed photo", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Gold 200 Film", exact: true }).click();
  await page.getByRole("radio", { name: "Print", exact: true }).click();
  const medium = page.getByRole("button", { name: /Output medium/ });
  const choose = async (name) => {
    await medium.click();
    await page.getByRole("option", { name, exact: true }).click();
  };
  await choose("Color Newsprint");
  const picker = page.getByLabel("Paper Color", { exact: true });
  await expect(picker).toHaveValue("#0a0a0a");
  const reset = page.getByRole("button", { name: "Use Default Paper", exact: true });
  await expect(reset).toBeDisabled();
  await picker.fill("#d6c2a0");
  await picker.blur();
  await expect.poll(() => page.evaluate(() => window.lastPaperRender?.profile?.paperColor)).toBe("#d6c2a0");
  await expect.poll(() => page.evaluate(() => window.lastPaperFrame?.profile?.paperColor)).toBe("#d6c2a0");
  await choose("B&W Newsprint");
  await expect(picker).toHaveValue("#d6c2a0");
  await choose("Digital Reference");
  await expect(picker).toHaveCount(0);
  await choose("B&W Newsprint");
  await reset.click();
  await expect(picker).toHaveValue("#f2ecdd");
  await expect(reset).toBeDisabled();
  await page.getByRole("button", { name: /^Undo \(/ }).click();
  await expect(picker).toHaveValue("#d6c2a0");
  expect(errors).toEqual([]);
});
