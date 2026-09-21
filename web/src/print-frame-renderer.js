import { frameNoise, emulsionTexture, emulsionRim } from "./frame-texture.js";
import { yieldToBrowser } from "./yield.js";
const color = (rgb) => `rgb(${rgb.map((v) => v * 255).join(" ")})`;
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
  for (const x of g.rows === 2 ? [edge, across - edge - width] : [edge]) {
    for (
      let centre = g.perforation === "sixteen" ? 0 : g.pitchMM / 2;
      centre <= along;
      centre += g.pitchMM
    ) {
      if (g.perforation === "bellHowell") {
        ctx.save();
        ctx.beginPath();
        ctx.rect(x, centre - height / 2, width, height);
        ctx.clip();
        ellipse(ctx, x, centre - width / 2, width, width);
        ctx.restore();
      } else {
        ctx.beginPath();
        ctx.roundRect(x, centre - height / 2, width, height, radius);
        ctx.fill();
      }
    }
  }
  ctx.restore();
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

/** One finishing path for previews, comparisons and exports. Photograph pixels are copied
 * at integer coordinates; only the intentional emulsion rim may cover their edges. */
export async function renderPrintFrame(image, plan, stale = () => false, omitPhoto = false) {
  if (!plan || plan.configuration.frame === "none") return image;
  const c = plan.configuration,
    p = plan.placement,
    m = plan.materialSize,
    palette = plan.palette;
  const canvas = document.createElement("canvas");
  canvas.width = p.size.width;
  canvas.height = p.size.height;
  const ctx = canvas.getContext("2d");
  if (!ctx)
    throw new Error(
      "The framed image is too large. Choose a smaller export size.",
    );
  ctx.fillStyle = color(c.slideMount ? palette.card : palette.base);
  ctx.fillRect(0, 0, canvas.width, canvas.height);
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
    ctx.fillStyle = color(palette.edge);
    edgePrinting(ctx, c.geometry, c.edgePrinting);
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
  const top = canvas.height - r.y - r.height;
  if (omitPhoto) ctx.clearRect(r.x, top, r.width, r.height);
  else {
    // Integer placement preserves the delivered photograph without resampling.
    const pixels = image.getContext("2d").getImageData(0, 0, image.width, image.height);
    ctx.putImageData(pixels, r.x, top);
  }
  if (c.frame === "emulsion") {
    const texture = await emulsionTexture(r.width, r.height, stale);
    if (!texture) return null;
    const layer = document.createElement("canvas");
    layer.width = texture.width;
    layer.height = texture.height;
    layer
      .getContext("2d")
      .putImageData(
        new ImageData(texture.bytes, texture.width, texture.height),
        0,
        0,
      );
    const keep = Math.ceil(Math.min(r.width, r.height) * emulsionRim);
    ctx.save();
    ctx.beginPath();
    ctx.rect(0, 0, canvas.width, canvas.height);
    ctx.rect(
      r.x + keep,
      top + keep,
      Math.max(0, r.width - 2 * keep),
      Math.max(0, r.height - 2 * keep),
    );
    ctx.clip("evenodd");
    ctx.imageSmoothingEnabled = true;
    ctx.imageSmoothingQuality = "high";
    ctx.drawImage(
      layer,
      r.x - texture.fringe * texture.unit,
      top - texture.fringe * texture.unit,
      texture.width * texture.unit * texture.step,
      texture.height * texture.unit * texture.step,
    );
    ctx.restore();
  }
  return canvas;
}
