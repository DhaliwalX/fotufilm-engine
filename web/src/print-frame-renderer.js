import { colorContext, canvasColorSpace } from "./canvas-color.js";
import { frameNoise } from "./frame-texture.js";
import { yieldToBrowser } from "./yield.js";
const encode = (v) =>
  v <= 0.0031308
    ? Math.max(0, v) * 12.92
    : 1.055 * Math.min(1, v) ** (1 / 2.4) - 0.055;
export function framePalette(plan, colorSpace) {
  if (colorSpace !== "display-p3") return plan.palette;
  const c = plan.configuration;
  return Object.fromEntries(
    Object.entries({
      base: c.baseRGB,
      edge: c.edgeRGB,
      rebate: c.rebateRGB,
      card: [0.86, 0.86, 0.86],
      cutout: c.cutoutRGB ?? [0.96, 0.96, 0.96],
      ...(c.edgeTransmission ? { edgeTransmission: c.edgeTransmission } : {}),
      barcode: c.barcodeRGB ?? [0, 0, 0],
      ...(c.barcodeTransmission
        ? { barcodeTransmission: c.barcodeTransmission }
        : {}),
    }).map(([key, rgb]) => [key, rgb.map(encode)]),
  );
}
const fill = (ctx, rect) =>
  ctx.fillRect(rect.x, rect.y, rect.width, rect.height);
const inset = (r, d) => ({
  x: r.x + d,
  y: r.y + d,
  width: r.width - 2 * d,
  height: r.height - 2 * d,
});
const ellipse = (ctx, x, y, width, height) => {
  ctx.beginPath();
  ctx.ellipse(
    x + width / 2,
    y + height / 2,
    width / 2,
    height / 2,
    0,
    0,
    2 * Math.PI,
  );
  ctx.fill();
};

function perforations(ctx, g, dimensions) {
  if (!g.perforation || !dimensions) return;
  const { width, height, radius, edge } = dimensions;
  ctx.save();
  if (g.horizontalTransport) {
    ctx.translate(0, g.heightMM);
    ctx.rotate(-Math.PI / 2);
  }
  const across = g.horizontalTransport ? g.heightMM : g.widthMM,
    along = g.horizontalTransport ? g.widthMM : g.heightMM;
  ctx.beginPath();
  ctx.rect(0, 0, across, along);
  ctx.clip();
  const rows = g.rows === 2 ? [edge, across - edge - width] : [edge];
  rows.forEach((x, row) => {
    let index = 0;
    for (
      let centre = g.perforation === "sixteen" ? 0 : g.pitchMM / 2;
      centre <= along;
      centre += g.pitchMM, index++
    ) {
      const outline = perforationOutline(
        x,
        centre,
        width,
        height,
        radius,
        g.perforation === "bellHowell",
        row * 4096 + index,
      );
      ctx.beginPath();
      outline.forEach(([px, py], i) => (i ? ctx.lineTo(px, py) : ctx.moveTo(px, py)));
      ctx.closePath();
      ctx.fill();
    }
  });
  ctx.restore();
}
// One punched hole's edge, as PrintFrameRenderer.perforationOutline traces it: the die's shape
// every 0.04 mm, each point moved along its outward normal by the hole's own wander, shift and
// size, from the same noise.
export function perforationOutline(x, centre, width, height, radius, bellHowell, hole) {
  const line = (a, b, normal) => ({
    length: Math.hypot(b[0] - a[0], b[1] - a[1]),
    point: (t) => [[a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t], normal],
  });
  const arc = (c, r, a0, a1) => ({
    length: r * Math.abs(a1 - a0),
    point: (t) => {
      const angle = a0 + (a1 - a0) * t,
        n = [Math.cos(angle), Math.sin(angle)];
      return [[c[0] + n[0] * r, c[1] + n[1] * r], n];
    },
  });
  const y = centre - height / 2;
  let pieces;
  if (bellHowell) {
    const r = width / 2,
      half = height / 2,
      c = [x + r, centre];
    const flat = Math.asin(Math.min(1, half / r)),
      run = r * Math.cos(flat);
    pieces = [
      line([c[0] - run, c[1] - half], [c[0] + run, c[1] - half], [0, -1]),
      arc(c, r, -flat, flat),
      line([c[0] + run, c[1] + half], [c[0] - run, c[1] + half], [0, 1]),
      arc(c, r, Math.PI - flat, Math.PI + flat),
    ];
  } else {
    const r = Math.min(radius, width / 2, height / 2);
    pieces = [
      line([x + r, y], [x + width - r, y], [0, -1]),
      arc([x + width - r, y + r], r, -Math.PI / 2, 0),
      line([x + width, y + r], [x + width, y + height - r], [1, 0]),
      arc([x + width - r, y + height - r], r, 0, Math.PI / 2),
      line([x + width - r, y + height], [x + r, y + height], [0, 1]),
      arc([x + r, y + height - r], r, Math.PI / 2, Math.PI),
      line([x, y + height - r], [x, y + r], [-1, 0]),
      arc([x + r, y + r], r, Math.PI, (3 * Math.PI) / 2),
    ];
  }
  const perimeter = pieces.reduce((sum, piece) => sum + piece.length, 0);
  // Each hole's own noise is its seed, so the coordinates stay small and exact.
  const own = Math.imul(hole, 3) >>> 0;
  const noise = (x, y, seed) => frameNoise(x, y, (seed + own) >>> 0);
  const shift = [0.015 * noise(0.5, 0.5, 401), 0.015 * noise(1.5, 0.5, 401)];
  const grow = 0.012 * noise(2.5, 0.5, 401);
  // Around a circle in the noise, so the wander closes where the trace began.
  const wander = (s) => {
    const turn = (2 * Math.PI * s) / perimeter;
    const ring = (wavelength, seed) => {
      const r = perimeter / (2 * Math.PI * wavelength);
      return noise(r * Math.cos(turn), r * Math.sin(turn), seed);
    };
    return 0.04 * ring(0.5, 211) + 0.015 * ring(0.1, 307);
  };
  const outline = [];
  let travelled = 0;
  for (const piece of pieces) {
    if (!(piece.length > 0)) continue;
    const steps = Math.max(1, Math.ceil(piece.length / 0.04));
    for (let step = 0; step < steps; step++) {
      const t = step / steps;
      const [point, normal] = piece.point(t);
      const d = grow + wander(travelled + piece.length * t);
      outline.push([point[0] + shift[0] + normal[0] * d, point[1] + shift[1] + normal[1] * d]);
    }
    travelled += piece.length;
  }
  return outline;
}
function edgePrinting(ctx, g, printing) {
  if (!printing) return;
  ctx.save();
  if (!g.horizontalTransport) {
    ctx.translate(g.widthMM, 0);
    ctx.rotate(Math.PI / 2);
  }
  ctx.beginPath();
  ctx.rect(
    0,
    0,
    g.horizontalTransport ? g.widthMM : g.heightMM,
    g.horizontalTransport ? g.heightMM : g.widthMM,
  );
  ctx.clip();
  // Like the native renderer, use system vector lettering; no scanned logos or invented roll codes.
  ctx.font = "100px Helvetica, Arial, sans-serif";
  ctx.textBaseline = "alphabetic";
  for (const mark of printing.marks) {
    const m = ctx.measureText(mark.text);
    const width = m.actualBoundingBoxLeft + m.actualBoundingBoxRight;
    const height = m.actualBoundingBoxAscent + m.actualBoundingBoxDescent;
    if (!width || !height) continue;
    ctx.save();
    ctx.translate(mark.xMM, mark.yMM + mark.heightMM);
    ctx.scale(mark.widthMM / width, -mark.heightMM / height);
    ctx.fillText(mark.text, m.actualBoundingBoxLeft, m.actualBoundingBoxAscent);
    ctx.restore();
  }
  ctx.restore();
}
// The DX barcode's bars, in the edge printing's coordinates (FilmEdgePrinting.barcode).
function edgeBars(ctx, g, bars) {
  if (!bars?.length) return;
  ctx.save();
  if (!g.horizontalTransport) {
    ctx.translate(g.widthMM, 0);
    ctx.rotate(Math.PI / 2);
  }
  ctx.beginPath();
  ctx.rect(
    0,
    0,
    g.horizontalTransport ? g.widthMM : g.heightMM,
    g.horizontalTransport ? g.heightMM : g.widthMM,
  );
  ctx.clip();
  for (const bar of bars) ctx.fillRect(bar.xMM, bar.yMM, bar.widthMM, bar.heightMM);
  ctx.restore();
}
function carrier(ctx, photo, width) {
  const outer = inset(photo, -width);
  const corners = [
    [outer.x, outer.y],
    [outer.x + outer.width, outer.y],
    [outer.x + outer.width, outer.y + outer.height],
    [outer.x, outer.y + outer.height],
  ];
  const normals = [
    [0, -1],
    [1, 0],
    [0, 1],
    [-1, 0],
  ];
  ctx.beginPath();
  for (let side = 0; side < 4; side++) {
    const from = corners[side],
      to = corners[(side + 1) % 4],
      length = Math.hypot(to[0] - from[0], to[1] - from[1]);
    const count = Math.max(2, Math.ceil(length / 0.5));
    for (let i = 0; i <= count; i++) {
      const t = i / count,
        along = length * t;
      const wobble =
        frameNoise(along * 0.35, side * 7.3, 409) +
        0.4 * frameNoise(along * 1.6, side * 3.1, 613);
      const amount = Math.max(
        -width * 0.25,
        Math.min(width * 0.25, wobble * 0.22),
      );
      const x = from[0] + (to[0] - from[0]) * t + normals[side][0] * amount;
      const y = from[1] + (to[1] - from[1]) * t + normals[side][1] * amount;
      if (side === 0 && i === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    }
  }
  ctx.closePath();
  ctx.fill();
}
async function lustre(ctx, size, photo, stale) {
  let state = 0x5052494e54534854n;
  const random = () => {
    state = BigInt.asUintN(
      64,
      state * 6364136223846793005n + 1442695040888963407n,
    );
    return Number(state >> 40n) / 16777216;
  };
  ctx.fillStyle = "rgb(31 31 31 / 0.035)";
  const pitch = 0.17;
  for (let row = 0, y = 0; y < size.height; row++, y += pitch) {
    if (row % 64 === 0) {
      await yieldToBrowser();
      if (stale()) return;
    }
    for (let x = 0; x < size.width; x += pitch) {
      const px = x + random() * pitch,
        py = y + random() * pitch;
      if (
        px < photo.x ||
        px > photo.x + photo.width ||
        py < photo.y ||
        py > photo.y + photo.height
      )
        ellipse(ctx, px, py, 0.065, 0.065);
    }
  }
}

/** The letters and holes of a Film Border as coverage masks over its developed strip, in the
 * frame's pixels: the 16-bit compositor blends them into the strip's own samples. */
export function stripMasks(plan) {
  const c = plan.configuration,
    p = plan.placement,
    m = plan.materialSize;
  const mask = (draw) => {
    const canvas = document.createElement("canvas");
    canvas.width = p.size.width;
    canvas.height = p.size.height;
    const ctx = canvas.getContext("2d");
    ctx.translate(0, canvas.height);
    ctx.scale(p.scale, -p.scale);
    if (p.rotated) {
      ctx.translate(m.height, 0);
      ctx.rotate(Math.PI / 2);
    }
    ctx.fillStyle = "#fff";
    draw(ctx);
    return ctx.getImageData(0, 0, canvas.width, canvas.height).data;
  };
  return {
    letters: mask((ctx) => edgePrinting(ctx, c.geometry, c.edgePrinting)),
    bars: mask((ctx) => edgeBars(ctx, c.geometry, c.edgeBars)),
    holes: mask((ctx) => {
      perforations(ctx, c.geometry, plan.perforation);
      for (const notch of c.sheetNotches?.notches || [])
        ellipse(
          ctx,
          m.width - 30 + notch.position * 20,
          m.height - notch.depth * 20,
          notch.width * 20,
          notch.depth * 40,
        );
    }),
  };
}

/** One finishing path for previews, comparisons and exports. Photograph pixels are copied
 * at integer coordinates and never covered. */
export async function renderPrintFrame(
  image,
  plan,
  stale = () => false,
  {
    omitPhoto = false,
    colorSpace = canvasColorSpace(image),
    rawColors = false,
    // `image` is a Film Border's whole developed strip (`plan.strip`), the frame's canvas.
    developed = false,
  } = {},
) {
  if (!plan || plan.configuration.frame === "none") return image;
  const c = plan.configuration,
    p = plan.placement,
    m = plan.materialSize,
    palette = framePalette(plan, colorSpace);
  const color = (rgb) =>
    colorSpace === "display-p3" && !rawColors
      ? `color(display-p3 ${rgb.join(" ")})`
      : `rgb(${rgb.map((v) => v * 255).join(" ")})`;
  const canvas = document.createElement("canvas");
  canvas.width = p.size.width;
  canvas.height = p.size.height;
  const ctx = colorContext(canvas, rawColors ? "srgb" : colorSpace);
  if (!ctx)
    throw new Error(
      "The framed image is too large. Choose a smaller export size.",
    );
  if (developed && image) {
    ctx.drawImage(image, 0, 0);
    if (c.frame === "filmPositive") {
      // The inverted scan's black point sits just past the developed base, so the rebate
      // stands a little above the open holes, its grain kept.
      const r = p.image;
      ctx.save();
      ctx.globalCompositeOperation = "screen";
      ctx.fillStyle = color(palette.base);
      ctx.beginPath();
      ctx.rect(0, 0, canvas.width, canvas.height);
      ctx.rect(r.x, canvas.height - r.y - r.height, r.width, r.height);
      ctx.fill("evenodd");
      ctx.restore();
    }
  } else {
    ctx.fillStyle = color(c.slideMount ? palette.card : palette.base);
    ctx.fillRect(0, 0, canvas.width, canvas.height);
  }
  // 135 exposed to its edges in a medium-format camera: the picture lies under the edge printing
  // and is punched with the perforations, so it goes down first.
  const exposed = c.geometry?.exposesEdges === true,
    top = canvas.height - p.image.y - p.image.height;
  const placePhoto = () => {
    if (omitPhoto) ctx.clearRect(p.image.x, top, p.image.width, p.image.height);
    else {
      // Integer placement preserves the delivered photograph without resampling.
      const pixels = image
        .getContext("2d")
        .getImageData(0, 0, image.width, image.height);
      ctx.putImageData(pixels, p.image.x, top);
    }
  };
  if (exposed && !developed) placePhoto();
  // Shared native geometry is lower-left. Physical material drawing stays in that space.
  ctx.save();
  ctx.translate(0, canvas.height);
  ctx.scale(p.scale, -p.scale);
  if (p.rotated) {
    ctx.translate(m.height, 0);
    ctx.rotate(Math.PI / 2);
  }
  const r = p.image,
    s = p.scale;
  const photo = p.rotated
    ? {
        x: r.y / s,
        y: m.height - (r.x + r.width) / s,
        width: r.height / s,
        height: r.width / s,
      }
    : { x: r.x / s, y: r.y / s, width: r.width / s, height: r.height / s };
  if (c.slideMount) {
    const mount = c.slideMount,
      x = (mount.mountMM - mount.apertureWidth) / 2,
      y = (mount.mountMM - mount.apertureHeight) / 2;
    ctx.save();
    ctx.beginPath();
    ctx.roundRect(
      x,
      y,
      mount.apertureWidth,
      mount.apertureHeight,
      mount.cornerRadiusMM,
    );
    ctx.clip();
    ctx.fillStyle = color(palette.base);
    ctx.fillRect(x, y, mount.apertureWidth, mount.apertureHeight);
    ctx.fillStyle = "rgb(0 0 0 / .18)";
    ctx.fillRect(x, y + mount.apertureHeight - 0.35, mount.apertureWidth, 0.35);
    ctx.fillRect(x, y, 0.35, mount.apertureHeight);
    ctx.restore();
  } else if (c.sheet) {
    ctx.fillStyle = color(palette.rebate);
    if (c.sheet.rebateMM) carrier(ctx, photo, c.sheet.rebateMM);
    if (c.hasLustre)
      await lustre(ctx, m, inset(photo, -c.sheet.rebateMM), stale);
  } else if (c.geometry) {
    // On a developed strip a negative's letters pass a share of the rebate's light, grain and
    // glow included; lighter letters are laid over the dark rebate. Blending encoded values
    // stands in for blending light, as natively. Over a picture exposed to the edges the denser
    // of the edge printer's exposure and the camera's develops, nearly.
    const marking = (rgb, shared) => {
      if (exposed) return [rgb, shared ? "darken" : "lighten"];
      const used = developed ? shared : null;
      return [used || rgb, !developed ? "source-over" : used ? "multiply" : "screen"];
    };
    const [ink, inkBlend] = marking(palette.edge, palette.edgeTransmission);
    ctx.fillStyle = color(ink);
    ctx.globalCompositeOperation = inkBlend;
    edgePrinting(ctx, c.geometry, c.edgePrinting);
    const [bar, barBlend] = marking(palette.barcode || [0, 0, 0], palette.barcodeTransmission);
    ctx.fillStyle = color(bar);
    ctx.globalCompositeOperation = barBlend;
    edgeBars(ctx, c.geometry, c.edgeBars);
    ctx.globalCompositeOperation = "source-over";
    ctx.fillStyle = color(palette.cutout);
    perforations(ctx, c.geometry, plan.perforation);
    for (const notch of c.sheetNotches?.notches || [])
      ellipse(
        ctx,
        m.width - 30 + notch.position * 20,
        m.height - notch.depth * 20,
        notch.width * 20,
        notch.depth * 40,
      );
  }
  ctx.restore();
  if (stale()) return null;
  ctx.imageSmoothingEnabled = false;
  // A developed strip already holds the photograph in place.
  if (!developed && !exposed) placePhoto();
  return canvas;
}
