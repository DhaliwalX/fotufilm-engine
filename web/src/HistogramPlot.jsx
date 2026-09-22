import { useEffect, useMemo, useRef, useState } from "react";
import { smoothHistogram, traceHistogram } from "./histogram-curves.js";
import {
  histogramViews,
  histogramPalette,
  histogramCountAxis,
  histogramCountHeight,
} from "./histogram-views.js";

export default function HistogramPlot({
  analysis,
  scale,
  view,
  compact,
  move,
  moveLabel,
  containerRef,
}) {
  const ref = useRef(null),
    previous = useRef(null),
    transition = useRef(null);
  const chrome = useRef({
    value: compact ? 0 : 1,
    from: compact ? 0 : 1,
    to: compact ? 0 : 1,
    start: 0,
  });
  const [size, setSize] = useState({
    width: 280,
    height: 140,
    ratio: devicePixelRatio || 1,
  });
  const [theme, setTheme] = useState(0);
  const mode = histogramViews[view];
  const plot = useMemo(() => {
    if (!analysis) return null;
    const bins = [
      ...analysis.bins,
      analysis.luma,
      ...analysis.chroma,
      ...analysis.oklab,
    ].map(smoothHistogram);
    const active = mode.channels;
    const peak = Math.max(1, ...active.flatMap((c) => bins[c]));
    const axis = histogramCountAxis(peak, scale);
    const normal = (n) => histogramCountHeight(n, axis.max, scale);
    return {
      axis,
      values: bins.map((channel) => channel.map(normal)),
      alpha: bins.map((_, c) => (active.includes(c) ? 1 : 0)),
    };
  }, [analysis, mode, scale]);
  useEffect(() => {
    const canvas = ref.current;
    const update = () =>
      setSize({
        width: canvas.clientWidth,
        height: canvas.clientHeight,
        ratio: devicePixelRatio || 1,
      });
    const observer = new ResizeObserver(update);
    observer.observe(canvas);
    const query = matchMedia("(prefers-color-scheme: dark)");
    const change = () => setTheme((t) => t + 1);
    query.addEventListener("change", change);
    window.addEventListener("resize", update);
    update();
    return () => {
      observer.disconnect();
      query.removeEventListener("change", change);
      window.removeEventListener("resize", update);
    };
  }, []);
  useEffect(() => {
    // Keep the last graph while analysis is pending; the panel marks it busy.
    // This also lets new counts animate from what was actually on screen.
    if (!analysis) return;
    const canvas = ref.current,
      ctx = canvas.getContext("2d");
    const { width, height, ratio } = size;
    canvas.width = Math.round(width * ratio);
    canvas.height = Math.round(height * ratio);
    ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
    const colors = getComputedStyle(canvas);
    const palette = histogramPalette.map((name) =>
      colors.getPropertyValue(`--histogram-${name}`).trim(),
    );
    const muted = colors.getPropertyValue("--muted").trim(),
      border = colors.getPropertyValue("--border").trim();
    const { axis } = plot;
    const reducedMotion = matchMedia(
      "(prefers-reduced-motion: reduce)",
    ).matches;
    const start = performance.now();
    if (transition.current?.target !== plot) {
      transition.current = {
        target: plot,
        from: previous.current || plot,
        start,
      };
    }
    const motion = transition.current;
    let animation;
    const decoration = chrome.current,
      destination = compact ? 0 : 1;
    if (decoration.to !== destination) {
      decoration.from = decoration.value;
      decoration.to = destination;
      decoration.start = start;
    }
    const draw = (now) => {
      const progress = reducedMotion
        ? 1
        : Math.min(1, (now - motion.start) / 200);
      const t = 1 - (1 - progress) ** 3;
      ctx.clearRect(0, 0, width, height);
      const chromeProgress = reducedMotion
        ? 1
        : Math.min(1, (now - decoration.start) / 180);
      const ease = 1 - (1 - chromeProgress) ** 3;
      decoration.value =
        decoration.from + (decoration.to - decoration.from) * ease;
      const visibility = decoration.value;
      const left = 3 + 31 * visibility,
        right = Math.max(left + 1, width - 3),
        top = 3 + 5 * visibility,
        bottom = height - 3 - 3 * visibility;
      const x = (i) => left + (i / 255) * (right - left),
        y = (v) => bottom - v * (bottom - top);
      ctx.font = "10px -apple-system, sans-serif";
      ctx.textAlign = "right";
      ctx.textBaseline = "middle";
      ctx.globalAlpha = visibility;
      let lastTickY = Infinity;
      for (const count of visibility > 0 ? axis.ticks : []) {
        const fraction = histogramCountHeight(count, axis.max, scale);
        if (lastTickY - y(fraction) < 15 && count !== axis.max) continue;
        lastTickY = y(fraction);
        ctx.fillStyle = muted;
        ctx.fillText(
          count >= 1000
            ? `${Number((count / 1000).toFixed(1))}k`
            : Math.round(count),
          left - 5,
          y(fraction),
        );
        ctx.strokeStyle = border;
        ctx.lineWidth = 0.6;
        ctx.beginPath();
        ctx.moveTo(left, y(fraction));
        ctx.lineTo(right, y(fraction));
        ctx.stroke();
      }
      if (mode.centered && visibility > 0) {
        ctx.strokeStyle = muted;
        ctx.globalAlpha = visibility * 0.45;
        ctx.setLineDash([3, 4]);
        ctx.beginPath();
        ctx.moveTo(x(127.5), top);
        ctx.lineTo(x(127.5), bottom);
        ctx.stroke();
        ctx.setLineDash([]);
      }
      ctx.globalAlpha = 1;
      const frame = { values: [], alpha: [] };
      for (let c = 0; c < plot.values.length; c++) {
        // Retain the departing curve's shape while it fades away.
        const destination = plot.alpha[c]
          ? plot.values[c]
          : motion.from.values[c];
        const origin = motion.from.alpha[c]
          ? motion.from.values[c]
          : destination;
        const values = destination.map(
          (v, i) => origin[i] + (v - origin[i]) * t,
        );
        const alpha =
          motion.from.alpha[c] + (plot.alpha[c] - motion.from.alpha[c]) * t;
        frame.values.push(values);
        frame.alpha.push(alpha);
        if (alpha < 0.001) continue;
        ctx.beginPath();
        traceHistogram(ctx, values, x, y);
        ctx.lineTo(right, bottom);
        ctx.lineTo(left, bottom);
        ctx.closePath();
        ctx.fillStyle = palette[c];
        ctx.globalAlpha = 0.12 * alpha;
        ctx.fill();
        ctx.beginPath();
        traceHistogram(ctx, values, x, y);
        ctx.globalAlpha = alpha;
        ctx.strokeStyle = palette[c];
        ctx.lineWidth = 1.4;
        ctx.stroke();
      }
      ctx.globalAlpha = 1;
      // Continue from the displayed frame when a user changes mode mid-transition.
      previous.current = frame;
      if (progress < 1 || chromeProgress < 1)
        animation = requestAnimationFrame(draw);
    };
    draw(performance.now());
    return () => cancelAnimationFrame(animation);
  }, [analysis, plot, scale, mode, compact, size, theme]);
  return (
    <div
      className="histogram-plot-wrap"
      ref={containerRef}
      {...move}
      tabIndex={compact ? 0 : undefined}
      role={compact ? "group" : undefined}
      aria-label={compact ? moveLabel : undefined}
      title={
        compact
          ? "Drag graph to move; drag lower-right corner to resize. Arrow keys move when focused."
          : undefined
      }
    >
      <div className="histogram-axes">
        <span title="Smoothed counts from the sampled display preview">
          Pixel count
        </span>
        <span className="histogram-legend">
          {mode.legend.map(([label, color]) => (
            <i key={label} style={{ color: `var(--histogram-${color})` }}>
              {label}
            </i>
          ))}
        </span>
      </div>
      <canvas
        ref={ref}
        className="histogram-plot"
        aria-label={`${mode.description}, ${scale === "log" ? "logarithmic" : "linear"} pixel counts`}
      />
      <div
        className={`histogram-ramp${mode.centered ? " histogram-chroma-ramp" : ""}`}
      />
      <div className="histogram-ticks">
        {mode.ticks.map((tick) => (
          <span key={tick}>{tick}</span>
        ))}
      </div>
    </div>
  );
}
