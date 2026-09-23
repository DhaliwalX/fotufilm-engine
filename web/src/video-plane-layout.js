// Byte layout is shared by CPU and GPU decoders, including high-bit-depth planes.
export function videoPlaneLayout(frame) {
  const { format, colorSpace = {} } = frame;
  const planar = /^(I420|I422|I444)(A)?(P10|P12)?$/.exec(format);
  const nv12 = format === "NV12",
    rgb = /^(RGBA|RGBX|BGRA|BGRX)$/.test(format);
  if (!planar && !nv12 && !rgb)
    throw new Error(
      `The browser cannot expose ${format || "this video’s"} pixels without color conversion. Try a different browser or codec.`,
    );
  const depth = planar?.[3] ? Number(planar[3].slice(1)) : 8;
  const coefficients = {
    bt709: [0.2126, 0.0722],
    "bt2020-ncl": [0.2627, 0.0593],
    smpte170m: [0.299, 0.114],
    bt470bg: [0.299, 0.114],
  };
  const [kr, kb] = coefficients[colorSpace.matrix || "bt709"] || [];
  if (!rgb && kr === undefined)
    throw new Error(`Unsupported video YUV matrix: ${colorSpace.matrix}.`);
  const result = {
    nv12,
    rgb,
    depth,
    kr,
    kb,
    bytes: depth > 8 ? 2 : 1,
    maximum: 2 ** depth - 1,
    scale: 2 ** (depth - 8),
    full: colorSpace.fullRange === true,
    subX: planar?.[1] === "I444" ? 1 : 2,
    subY: planar?.[1] === "I420" || nv12 ? 2 : 1,
  };
  if (frame.data) validatePlanes(frame, result);
  return result;
}
function validatePlanes(frame, info) {
  const {
    width,
    height,
    displayWidth = width,
    displayHeight = height,
    rotation = 0,
    data,
    layout,
  } = frame;
  if (
    ![width, height, displayWidth, displayHeight].every(
      (n) => Number.isInteger(n) && n > 0,
    ) ||
    Math.max(width * height, displayWidth * displayHeight) > 40_000_000 ||
    ![0, 90, 180, 270].includes(rotation)
  )
    throw new Error("Invalid video frame dimensions or rotation.");
  const planes = info.rgb ? 1 : info.nv12 ? 2 : 3;
  for (let i = 0; i < planes; i++) {
    const rows = i === 0 ? height : Math.ceil(height / info.subY);
    const columns =
      i === 0 ? width : Math.ceil(width / info.subX) * (info.nv12 ? 2 : 1);
    const rowBytes = columns * (info.rgb ? 4 : info.bytes),
      p = layout[i];
    if (
      !p ||
      !Number.isInteger(p.offset) ||
      p.offset < 0 ||
      !Number.isInteger(p.stride) ||
      p.stride < rowBytes ||
      p.offset + (rows - 1) * p.stride + rowBytes > data.byteLength
    )
      throw new Error("Invalid video plane layout.");
  }
}
