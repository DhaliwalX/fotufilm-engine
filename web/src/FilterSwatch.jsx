import "./FilterSwatch.css";
import { useEffect, useRef } from "react";
import { filterSwatch, isDiffusion } from "./lens-filters.js";

export default function FilterSwatch({ id, stock }) {
  const canvas = useRef(null);
  const halo = stock?.profile?.filterHalos?.[id];
  useEffect(() => {
    if (!canvas.current || !halo) return;
    const ctx = canvas.current.getContext("2d"),
      image = ctx.createImageData(26, 26);
    const values = new Float32Array(26 * 26);
    let peak = 0;
    for (let y = 0; y < 26; y++)
      for (let x = 0; x < 26; x++) {
        let value = 0.015;
        for (const [sx, sy] of [
          [0.18, 0.5],
          [0.5, 0.34],
          [0.82, 0.62],
        ]) {
          const radius = (x - sx * 26) ** 2 + (y - sy * 26) ** 2;
          value += halo.direct * Math.exp(-radius / 20);
          halo.sigmas.forEach((sigma, i) => {
            value +=
              halo.scattered *
              halo.weights[i] *
              Math.exp(-radius / (2 * Math.max(sigma, 0.5) ** 2));
          });
        }
        values[y * 26 + x] = value;
        peak = Math.max(peak, value);
      }
    values.forEach((value, i) => {
      image.data.fill(Math.min(value / peak, 1) * 255, i * 4, i * 4 + 3);
      image.data[i * 4 + 3] = 255;
    });
    ctx.putImageData(image, 0, 0);
  }, [halo]);
  return isDiffusion(id) ? (
    <canvas
      ref={canvas}
      width="26"
      height="26"
      className="filter-swatch"
      aria-hidden="true"
    />
  ) : (
    <span
      className="filter-swatch"
      style={{ background: filterSwatch(id) }}
      aria-hidden="true"
    />
  );
}
