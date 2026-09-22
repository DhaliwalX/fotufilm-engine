// Two narrow binomial passes soften sampling noise without changing raw counts.
// Reflect at the edges to conserve mass and retain black/white endpoint peaks.
export function smoothHistogram(values) {
  let current = Array.from(values);
  const weights = [1, 4, 6, 4, 1];
  for (let pass = 0; pass < 2; pass++) {
    current = current.map((_, i) =>
      weights.reduce((sum, weight, k) => {
        let index = i + k - 2;
        while (index < 0 || index >= current.length)
          index = index < 0 ? -index - 1 : 2 * current.length - index - 1;
        return sum + (current[index] * weight) / 16;
      }, 0),
    );
  }
  return current;
}

// Quadratic midpoints stay inside adjacent values, so smoothing cannot overshoot.
export function traceHistogram(ctx, values, x, y) {
  ctx.moveTo(x(0), y(values[0]));
  for (let i = 1; i < values.length; i++) {
    const previous = i - 1;
    ctx.quadraticCurveTo(
      x(previous),
      y(values[previous]),
      (x(previous) + x(i)) / 2,
      (y(values[previous]) + y(values[i])) / 2,
    );
  }
  const last = values.length - 1;
  ctx.lineTo(x(last), y(values[last]));
}
