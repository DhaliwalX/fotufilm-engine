import { test, expect } from "@playwright/test";
import { openChart } from "./photo-fixture.js";
import { installNativeBackend } from "./native-backend-fixture.js";

// UI contract only; CPU/Metal rendering is covered by DigitalReferenceReceiverTests.
test("CMY controls reach the edit, reset together, and follow the output medium", async ({ page }) => {
  await page.addInitScript(installNativeBackend);
  await page.addInitScript(() => {
    const backend = window.fotufilmNative;
    backend.loadStocks = async () => [{
      id: "gold200", name: "Gold 200", defaultMedium: "screen",
      available: ["screenCyan", "screenMagenta", "screenYellow"],
      media: [{ id: "screen", name: "Digital Reference" }, { id: "ektacolor-edge", name: "Ektacolor Edge" }],
      profile: { media: {
        screen: { screenCMY: true, viewingLights: [] },
        "ektacolor-edge": { viewingLights: [] },
      } },
    }];
    const plan = backend.planPrintFrame;
    backend.planPrintFrame = async (...args) => ({ ...await plan(...args), available: ["none"] });
    const create = backend.createSession;
    backend.createSession = (...args) => {
      const session = create(...args), render = session.render;
      session.render = (request) => {
        window.cmyLastEdit = request.edit;
        return render(request);
      };
      return session;
    };
  });
  await page.goto("/");
  await openChart(page, 480, 320);
  await page.getByRole("button", { name: "Gold 200 Film", exact: true }).click();
  await page.getByRole("radio", { name: "Print", exact: true }).click();
  const cyan = page.getByRole("slider", { name: "Cyan / Red", exact: true });
  await expect(cyan).toBeVisible();
  await cyan.focus();
  await page.keyboard.press("ArrowRight");
  await expect.poll(() => page.evaluate(() => window.cmyLastEdit?.profile?.screenCyan)).toBeGreaterThan(0);
  const reset = page.getByRole("button", { name: "Reset CMY", exact: true });
  await expect(reset).toBeEnabled();
  await reset.click();
  await expect(cyan).toHaveValue("0");
  await expect(reset).toBeDisabled();
  await page.getByRole("button", { name: "Digital Reference Output medium", exact: true }).click();
  await page.getByRole("option", { name: "Ektacolor Edge", exact: true }).click();
  await expect(cyan).toHaveCount(0);
  await expect(reset).toHaveCount(0);
});
