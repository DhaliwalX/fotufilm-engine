import test from "node:test";
import assert from "node:assert/strict";
import { createHistogram } from "../../src/backend/browser-histogram.js";

class WorkerDouble {
  static latest;
  constructor() {
    WorkerDouble.latest = this;
    this.messages = [];
  }
  postMessage(data) {
    this.messages.push(data);
  }
  terminate() {
    this.terminated = true;
  }
  answer(id, analysis) {
    this.onmessage({ data: { generation: id, analysis } });
  }
}
test("histogram supersession, cancellation and disposal reject stale requests", async (t) => {
  const original = globalThis.Worker;
  globalThis.Worker = WorkerDouble;
  t.after(() => {
    if (original) globalThis.Worker = original;
    else delete globalThis.Worker;
  });
  const histogram = createHistogram(),
    worker = WorkerDouble.latest;
  const first = histogram.analyse({ blob: new Blob() });
  const cancelled = assert.rejects(first, { name: "AbortError" });
  const second = histogram.analyse({
    blob: new Blob(),
    colorSpace: "display-p3",
  });
  await cancelled;
  worker.answer(1, "old");
  worker.answer(2, "new");
  assert.equal(await second, "new");
  assert.equal(worker.messages[1].colorSpace, "display-p3");
  const abort = new AbortController();
  const third = histogram.analyse(
    { blob: new Blob() },
    { signal: abort.signal },
  );
  const aborted = assert.rejects(third, { name: "AbortError" });
  abort.abort();
  await aborted;
  const fourth = histogram.analyse({ blob: new Blob() });
  const disposed = assert.rejects(fourth, { name: "AbortError" });
  histogram.dispose();
  await disposed;
  assert.equal(worker.terminated, true);
  await assert.rejects(histogram.analyse({ blob: new Blob() }), {
    name: "AbortError",
  });
});
test("histogram reports worker failures", async (t) => {
  const original = globalThis.Worker;
  globalThis.Worker = WorkerDouble;
  t.after(() => {
    if (original) globalThis.Worker = original;
    else delete globalThis.Worker;
  });
  const histogram = createHistogram();
  const result = histogram.analyse({ blob: new Blob() });
  const failed = assert.rejects(result, /could not start/);
  WorkerDouble.latest.onerror();
  await failed;
  histogram.dispose();
});
