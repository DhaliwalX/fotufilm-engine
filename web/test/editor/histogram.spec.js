import { test, expect } from "@playwright/test";
import { openChart, openPanel } from "./photo-fixture.js";

test.use({ ignoreHTTPSErrors: true });

test("histogram opens, draws, drags and reopens while zooming and cropping", async ({
  page,
}) => {
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.goto(process.env.FOTUFILM_TEST_URL || "/");
  await openChart(page);
  await expect(page.locator(".viewer-status > [role=status]")).toContainText(
    "1600 × 1000",
  );

  const toggle = page.getByRole("button", {
    name: "Histogram (H)",
    exact: true,
  });
  const histogram = page.locator(".histogram");
  const plane = page.locator(".photo-plane");
  const transform = () =>
    plane.evaluate((element) => {
      const matrix = new DOMMatrix(getComputedStyle(element).transform);
      return { x: matrix.m41, y: matrix.m42, scale: matrix.a };
    });
  await toggle.click();
  await expect(histogram).toBeVisible();
  await expect(histogram.locator("canvas")).toHaveAttribute(
    "aria-label",
    /logarithmic pixel counts/,
  );
  await expect
    .poll(() =>
      histogram.locator("canvas").evaluate((canvas) => {
        const pixels = canvas
          .getContext("2d")
          .getImageData(0, 0, canvas.width, canvas.height).data;
        return pixels.some((value, index) => index % 4 === 3 && value > 0);
      }),
    )
    .toBe(true);

  const before = await histogram.boundingBox();
  const header = await page.locator(".histogram-header span").boundingBox();
  const photoBefore = await transform();
  await page.mouse.move(header.x + 20, header.y + 8);
  await page.mouse.down();
  await page.mouse.move(header.x + 100, header.y + 58, { steps: 5 });
  await page.mouse.up();
  await expect
    .poll(async () => (await histogram.boundingBox()).x - before.x)
    .toBeCloseTo(80, 0);
  await expect
    .poll(async () => (await histogram.boundingBox()).y - before.y)
    .toBeCloseTo(50, 0);
  expect(await transform()).toEqual(photoBefore);
  await page.getByRole("button", { name: "Close histogram" }).click();
  await expect(histogram).toBeHidden();

  await page.getByRole("button", { name: "Zoom in", exact: true }).click();
  const room = await page.locator(".canvas-area").boundingBox();
  await page.mouse.move(room.x + room.width / 2, room.y + room.height / 2);
  await page.mouse.down();
  await page.mouse.move(
    room.x + room.width / 2 + 40,
    room.y + room.height / 2 + 30,
    { steps: 5 },
  );
  await page.mouse.up();
  await expect.poll(async () => (await transform()).x).toBeCloseTo(40, 0);
  await toggle.click();
  await expect(histogram).toBeVisible();
  await page.getByRole("button", { name: "Crop", exact: true }).click();
  await expect.poll(transform).toEqual({ x: 0, y: 0, scale: 1 });
  await expect(histogram).toBeVisible();
  await page.getByRole("button", { name: "Close histogram" }).click();
  await toggle.click();
  await expect(histogram).toBeVisible();
  expect(errors).toEqual([]);
});

test("histogram mode and resize work without moving or changing the source photo", async ({
  page,
}) => {
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.goto(process.env.FOTUFILM_TEST_URL || "/");
  await openChart(page, 800, 500);
  await expect(page.locator(".viewer-status > [role=status]")).toContainText(
    "800 × 500",
  );
  await page
    .getByRole("button", { name: "Histogram (H)", exact: true })
    .click();
  const panel = page.getByRole("region", { name: "Histogram", exact: true });
  await expect(panel).toHaveAttribute("aria-busy", "false");
  const image = page.getByAltText("Developed photo", { exact: true });
  const source = await image.getAttribute("src");
  const mode = panel.getByRole("combobox", { name: "Histogram count mode" });
  await mode.selectOption("linear");
  await expect(panel.locator("canvas")).toHaveAttribute(
    "aria-label",
    /linear pixel counts/,
  );
  const original = await panel.boundingBox();
  const handle = await panel
    .getByRole("button", { name: "Resize histogram" })
    .boundingBox();
  const transform = await page
    .locator(".photo-plane")
    .evaluate((e) => e.style.transform);
  await page.mouse.move(
    handle.x + handle.width / 2,
    handle.y + handle.height / 2,
  );
  await page.mouse.down();
  await page.mouse.move(
    handle.x + handle.width / 2 + 100,
    handle.y + handle.height / 2 + 50,
    { steps: 5 },
  );
  await page.mouse.up();
  await expect
    .poll(async () => (await panel.boundingBox()).width)
    .toBeCloseTo(original.width + 100, 0);
  await expect
    .poll(async () => (await panel.boundingBox()).height)
    .toBeCloseTo(original.height + 50, 0);
  expect(
    await page.locator(".photo-plane").evaluate((e) => e.style.transform),
  ).toBe(transform);
  const grown = await panel.boundingBox();
  await panel.getByRole("button", { name: "Resize histogram" }).focus();
  await page.keyboard.press("ArrowLeft");
  await expect
    .poll(async () => (await panel.boundingBox()).width)
    .toBeCloseTo(grown.width - 8, 0);
  expect(await image.getAttribute("src")).toBe(source);
  await panel.getByRole("button", { name: "Close histogram" }).click();
  await page
    .getByRole("button", { name: "Histogram (H)", exact: true })
    .click();
  await expect(mode).toHaveValue("linear");
  expect((await panel.boundingBox()).width).toBeCloseTo(grown.width - 8, 0);
  await page.setViewportSize({ width: 390, height: 720 });
  await expect
    .poll(async () => {
      const p = await panel.boundingBox(),
        v = await page.locator(".canvas-area").boundingBox();
      return (
        p.x >= v.x &&
        p.y >= v.y &&
        p.x + p.width <= v.x + v.width + 1 &&
        p.y + p.height <= v.y + v.height + 1
      );
    })
    .toBe(true);
  expect(errors).toEqual([]);
});

test("touch resize keeps the chart sharp and the panel inside the viewer", async ({
  browser,
}) => {
  const context = await browser.newContext({
    hasTouch: true,
    deviceScaleFactor: 2,
    viewport: { width: 1200, height: 1000 },
  });
  try {
    const page = await context.newPage();
    await page.goto(process.env.FOTUFILM_TEST_URL || "http://127.0.0.1:5173/");
    await openChart(page, 400, 300);
    await expect(page.locator(".viewer-status > [role=status]")).toContainText(
      "400 × 300",
    );
    await page
      .getByRole("button", { name: "Histogram (H)", exact: true })
      .tap();
    const panel = page.getByRole("region", { name: "Histogram", exact: true });
    await expect(panel).toHaveAttribute("aria-busy", "false");
    const before = await panel.boundingBox(),
      handle = await panel
        .getByRole("button", { name: "Resize histogram" })
        .boundingBox();
    const cdp = await context.newCDPSession(page),
      x = handle.x + handle.width / 2,
      y = handle.y + handle.height / 2;
    await cdp.send("Input.dispatchTouchEvent", {
      type: "touchStart",
      touchPoints: [{ x, y }],
    });
    for (let i = 1; i <= 4; i++)
      await cdp.send("Input.dispatchTouchEvent", {
        type: "touchMove",
        touchPoints: [{ x: x + (60 * i) / 4, y: y + (30 * i) / 4 }],
      });
    await cdp.send("Input.dispatchTouchEvent", {
      type: "touchEnd",
      touchPoints: [],
    });
    await expect
      .poll(async () => (await panel.boundingBox()).width)
      .toBeCloseTo(before.width + 60, 0);
    await expect
      .poll(async () => (await panel.boundingBox()).height)
      .toBeCloseTo(before.height + 30, 0);
    await expect
      .poll(() =>
        panel
          .locator("canvas")
          .evaluate((c) =>
            Math.abs(c.width - c.clientWidth * devicePixelRatio),
          ),
      )
      .toBeLessThanOrEqual(1);
  } finally {
    await context.close();
  }
});

test("small histograms show only the graph and restore controls when enlarged", async ({
  page,
}) => {
  await page.goto(process.env.FOTUFILM_TEST_URL || "/");
  await openChart(page, 400, 300);
  await expect(page.locator(".viewer-status > [role=status]")).toContainText(
    "400 × 300",
  );
  const toggle = page.getByRole("button", {
    name: "Histogram (H)",
    exact: true,
  });
  await toggle.click();
  const panel = page.getByRole("region", { name: "Histogram", exact: true });
  await expect(panel).toHaveAttribute("aria-busy", "false");
  const mode = panel.getByRole("combobox", { name: "Histogram count mode" });
  await mode.selectOption("linear");
  const resize = panel.getByRole("button", { name: "Resize histogram" });
  const dragSize = async (width, height) => {
    const before = await panel.boundingBox(),
      handle = await resize.boundingBox();
    const x = handle.x + handle.width / 2,
      y = handle.y + handle.height / 2;
    await page.mouse.move(x, y);
    await page.mouse.down();
    await page.mouse.move(
      x + width - before.width,
      y + height - before.height,
      { steps: 12 },
    );
    await page.mouse.up();
  };
  await dragSize(190, 110);
  await expect(panel).toHaveAttribute("data-compact", "true");
  await expect(panel.locator(".histogram-header")).toBeHidden();
  await expect(panel.locator(".histogram-ticks")).toBeHidden();
  await expect(panel.locator(".histogram-axes")).toBeHidden();
  await expect(resize.locator("span")).toHaveCSS("opacity", "0");
  await expect
    .poll(async () => {
      const p = await panel.boundingBox(),
        c = await panel.locator("canvas").boundingBox();
      return c.width / p.width > 0.9 && c.height / p.height > 0.8;
    })
    .toBe(true);
  const photo = await page.locator(".photo-plane").getAttribute("style");
  const beforeMove = await panel.boundingBox();
  await panel.getByRole("group", { name: "Move histogram" }).focus();
  await page.keyboard.press("ArrowRight");
  expect((await panel.boundingBox()).x).toBeCloseTo(beforeMove.x + 8, 0);
  const graph = await panel.locator("canvas").boundingBox();
  await page.mouse.move(graph.x + 30, graph.y + 30);
  await page.mouse.down();
  await page.mouse.move(graph.x + 60, graph.y + 50, { steps: 5 });
  await page.mouse.up();
  expect((await panel.boundingBox()).x).toBeCloseTo(beforeMove.x + 38, 0);
  expect(await page.locator(".photo-plane").getAttribute("style")).toBe(photo);
  await resize.focus();
  await page.keyboard.press("ArrowRight");
  expect((await panel.boundingBox()).width).toBeCloseTo(198, 0);
  await dragSize(290, 190);
  await expect(panel).toHaveAttribute("data-compact", "true");
  await dragSize(340, 240);
  await expect(panel).toHaveAttribute("data-compact", "false");
  await expect(mode).toBeVisible();
  await expect(mode).toHaveValue("linear");
  await expect(panel.locator(".histogram-header")).toHaveCSS("opacity", "1");
  await page.emulateMedia({ reducedMotion: "reduce" });
  await dragSize(128, 72);
  await expect(panel).toHaveAttribute("data-compact", "true");
  await expect(panel.locator(".histogram-header")).toHaveCSS(
    "transition-duration",
    "0s",
  );
  const smallest = await panel.boundingBox();
  expect(smallest.width).toBe(128);
  expect(smallest.height).toBe(72);
  await panel.getByRole("group", { name: "Move histogram" }).focus();
  await page.keyboard.press("h");
  await expect(panel).toBeHidden();
  await toggle.click();
  await expect(panel).toHaveAttribute("data-compact", "true");
});

test("RGB, luma and chroma views retain their mode across compact resizing and reopening", async ({
  page,
}) => {
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto(process.env.FOTUFILM_TEST_URL || "/");
  await openChart(page, 400, 300);
  await expect(page.locator(".viewer-status > [role=status]")).toContainText(
    "400 × 300",
  );
  const toggle = page.getByRole("button", {
    name: "Histogram (H)",
    exact: true,
  });
  await toggle.click();
  const panel = page.getByRole("region", { name: "Histogram", exact: true });
  await expect(panel).toHaveAttribute("aria-busy", "false");
  const view = panel.getByRole("combobox", { name: "Histogram channels" });
  const canvas = panel.locator("canvas");
  await expect(view).toHaveValue("rgb");
  await view.selectOption("luma");
  await expect(canvas).toHaveAttribute("aria-label", /Luma brightness/);
  await view.selectOption("chroma");
  await expect(canvas).toHaveAttribute("aria-label", /Chroma Cb and Cr/);
  await expect(panel.locator(".histogram-ticks")).toContainText("−0.5");
  await panel
    .getByRole("combobox", { name: "Histogram count mode" })
    .selectOption("linear");
  // Rapid switches interrupt and reverse the curve transition safely.
  for (const mode of ["rgb", "luma", "chroma"]) await view.selectOption(mode);
  const source = await page
    .getByAltText("Developed photo", { exact: true })
    .getAttribute("src");
  const resize = panel.getByRole("button", { name: "Resize histogram" });
  await resize.focus();
  for (let i = 0; i < 5; i++) await page.keyboard.press("Shift+ArrowDown");
  for (let i = 0; i < 5; i++) await page.keyboard.press("Shift+ArrowLeft");
  await expect(panel).toHaveAttribute("data-compact", "true");
  await expect(panel.locator(".histogram-header")).toBeHidden();
  for (let i = 0; i < 5; i++) await page.keyboard.press("Shift+ArrowRight");
  await expect(view).toBeVisible();
  await expect(view).toHaveValue("chroma");
  await toggle.click();
  await toggle.click();
  await expect(view).toHaveValue("chroma");
  await expect(canvas).toHaveAttribute("aria-label", /linear pixel counts/);
  await expect(panel).toHaveAttribute("aria-busy", "false");
  await expect
    .poll(() =>
      canvas.evaluate((c) =>
        c
          .getContext("2d")
          .getImageData(0, 0, c.width, c.height)
          .data.some((v, i) => i % 4 === 3 && v > 0),
      ),
    )
    .toBe(true);
  expect(
    await page
      .getByAltText("Developed photo", { exact: true })
      .getAttribute("src"),
  ).toBe(source);
  expect(errors).toEqual([]);
});

test("OKLab has separate lightness and opponent scales and stays usable in compact and dark views", async ({
  page,
}) => {
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto(process.env.FOTUFILM_TEST_URL || "/");
  await openChart(page, 400, 300);
  await expect(page.locator(".viewer-status > [role=status]")).toContainText(
    "400 × 300",
  );
  await page
    .getByRole("button", { name: "Histogram (H)", exact: true })
    .click();
  const panel = page.getByRole("region", { name: "Histogram", exact: true });
  await expect(panel).toHaveAttribute("aria-busy", "false");
  const view = panel.getByRole("combobox", { name: "Histogram channels" });
  await view.selectOption("oklab-l");
  await expect(panel.locator("canvas")).toHaveAttribute(
    "aria-label",
    /OKLab perceptual lightness/,
  );
  await expect(panel.locator(".histogram-ticks")).toHaveText("00.250.50.751");
  await view.selectOption("oklab-ab");
  await expect(panel.locator(".histogram-ticks")).toHaveText(
    "−0.4−0.20+0.2+0.4",
  );
  await expect(panel.locator(".histogram-legend")).toContainText("green–red");
  await page.emulateMedia({ colorScheme: "dark" });
  await expect(panel.locator(".histogram-legend i").first()).toHaveCSS(
    "color",
    "rgb(236, 144, 191)",
  );
  await panel.getByRole("button", { name: "Resize histogram" }).focus();
  for (let i = 0; i < 4; i++) await page.keyboard.press("Shift+ArrowLeft");
  await expect(panel).toHaveAttribute("data-compact", "true");
  await expect(panel.locator(".histogram-legend")).toBeHidden();
  for (let i = 0; i < 4; i++) await page.keyboard.press("Shift+ArrowRight");
  await expect(view).toHaveValue("oklab-ab");
  await expect(view).toBeVisible();
  await expect(panel.locator("canvas")).toHaveAttribute(
    "aria-label",
    /OKLab a and b/,
  );
  expect(errors).toEqual([]);
});

test("updated counts keep the prior graph visible while analysis is pending", async ({
  page,
}) => {
  await page.addInitScript(() => {
    const NativeWorker = window.Worker;
    window.Worker = class extends NativeWorker {
      constructor(url, options) {
        super(url, options);
        this.histogram = String(url).includes("histogram.worker");
      }
      set onmessage(handler) {
        super.onmessage = this.histogram
          ? (event) => setTimeout(() => handler(event), 500)
          : handler;
      }
    };
  });
  await page.goto(process.env.FOTUFILM_TEST_URL || "/");
  await openChart(page, 400, 300);
  await expect(page.locator(".viewer-status > [role=status]")).toContainText(
    "400 × 300",
  );
  await page
    .getByRole("button", { name: "Histogram (H)", exact: true })
    .click();
  const panel = page.getByRole("region", { name: "Histogram", exact: true });
  await expect(panel).toHaveAttribute("aria-busy", "false");
  await openPanel(page, "Expose");
  const exposure = page.getByRole("spinbutton", {
    name: "Exposure value",
    exact: true,
  });
  await exposure.fill("1");
  await exposure.press("Tab");
  await expect(panel).toHaveAttribute("aria-busy", "true");
  expect(
    await panel.locator("canvas").evaluate((c) =>
      c
        .getContext("2d")
        .getImageData(0, 0, c.width, c.height)
        .data.some((v, i) => i % 4 === 3 && v > 0),
    ),
  ).toBe(true);
  await expect(panel).toHaveAttribute("aria-busy", "false");
  await expect(panel.locator("canvas")).toHaveCSS("opacity", "1");
});
