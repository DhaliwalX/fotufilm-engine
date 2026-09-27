// How the editor paces previews while an edit moves. The browser engine renders a small draft
// and waits for the edit to settle before full detail; a backend that develops faster says so
// with `previewBudget` (web/src/backend/README.md).
export const BROWSER_PREVIEW_BUDGET = Object.freeze({
  // Quiet time after the last change before the full-detail preview.
  settleMs: 300,
  // The draft's long edge while an edit moves, adapted between these bounds by render time.
  initialInteractiveEdge: 512,
  minInteractiveEdge: 256,
  maxInteractiveEdge: 800,
});

export function previewBudget(backend) {
  return { ...BROWSER_PREVIEW_BUDGET, ...(backend?.previewBudget ?? {}) };
}
