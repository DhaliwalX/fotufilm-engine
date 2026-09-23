export function videoTimeLabel(time) {
  const hundredths = Math.round(
    Math.max(0, Number.isFinite(time) ? time : 0) * 100,
  );
  const seconds = Math.floor(hundredths / 100),
    hours = Math.floor(seconds / 3600);
  const minutes = Math.floor(seconds / 60) % 60;
  const tail = `${String(seconds % 60).padStart(2, "0")}.${String(hundredths % 100).padStart(2, "0")}`;
  return hours
    ? `${hours}:${String(minutes).padStart(2, "0")}:${tail}`
    : `${String(minutes).padStart(2, "0")}:${tail}`;
}
export const clampPlayhead = (value, start, end) =>
  Math.max(
    start,
    Math.min(
      end - Math.min(0.001, (end - start) / 2),
      Number.isFinite(value) ? value : start,
    ),
  );
