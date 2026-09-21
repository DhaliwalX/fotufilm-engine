import test from "node:test";
import assert from "node:assert/strict";
import { AutoAdjustmentController } from "../../src/auto-adjustment.js";
import { defaultEdit, historyReducer } from "../../src/editor-state.js";
import { measureTone } from "../../src/tone-base.js";

function harness() {
  const calls = [],
    errors = [],
    applied = [];
  const current = {
    image: {},
    session: {},
    disabled: false,
    history: { present: defaultEdit(), past: [], future: [], group: null },
  };
  const controller = new AutoAdjustmentController({
    snapshot: () => current,
    onState() {},
    onError: (message) => errors.push(message),
    apply: (params) => {
      applied.push(params);
      current.history = historyReducer(current.history, {
        type: "edit",
        patch: { params: { ...current.history.present.params, ...params } },
      });
    },
    solve: (args) =>
      new Promise((resolve, reject) => calls.push({ args, resolve, reject })),
  });
  const dispatch = (action) => {
    const before = current.history;
    current.history = historyReducer(before, action);
    controller.changed(action, before, current.history);
  };
  return { current, calls, errors, applied, controller, dispatch };
}
const flush = () => new Promise((resolve) => setImmediate(resolve));
const solution = { ev: 1.25, highlights: -0.2, shadows: 0.3 };

test('reset or loading identical settings disengages Auto even when no slider moves', async () => {
  const h = harness();
  h.controller.toggle();
  h.calls[0].resolve({ ev: 0, highlights: 0, shadows: 0 });
  await flush();
  assert.equal(h.controller.state.active, true);
  h.dispatch({ type: 'edit', patch: defaultEdit(), restoring: true });
  assert.equal(h.controller.state.active, false);
  assert.equal(h.current.history.past.length, 0);
});

test("Auto is one undoable edit; switching it off retains solved values", async () => {
  const h = harness();
  h.controller.toggle();
  h.calls[0].resolve(solution);
  await flush();
  assert.equal(h.controller.state.active, true);
  assert.equal(h.current.history.past.length, 1);
  h.controller.toggle();
  assert.equal(h.controller.state.active, false);
  assert.equal(h.current.history.present.params.ev, 1.25);
  h.dispatch({ type: "undo" });
  assert.equal(h.current.history.present.params.ev, 0);
  h.dispatch({ type: "redo" });
  assert.equal(h.current.history.present.params.ev, 1.25);
  assert.equal(h.controller.state.active, false);
});

test("a film change cancels an older solve and applies only the new film", async () => {
  const h = harness();
  h.controller.toggle();
  h.dispatch({ type: "edit", patch: { stock: "gold200" } });
  assert.equal(h.calls.length, 2);
  assert.equal(h.calls[0].args.signal.aborted, true);
  h.calls[1].resolve(solution);
  await flush();
  h.calls[0].resolve({ ...solution, ev: -3 });
  await flush();
  assert.deepEqual(h.applied, [solution]);
  assert.equal(h.current.history.present.stock, "gold200");
  h.dispatch({ type: "edit", patch: { profile: { printCorrection: 0.5 } } });
  assert.equal(h.calls.length, 3);
  h.calls[2].resolve(solution);
  await flush();
});

test("manual tone edits, history restoration and cancellation defeat late results", async () => {
  for (const action of [
    (h) =>
      h.dispatch({
        type: "edit",
        patch: { params: { ...h.current.history.present.params, ev: -1 } },
      }),
    (h) => h.dispatch({ type: "load", edit: defaultEdit("gold200") }),
    (h) => h.controller.toggle(),
    (h) => {
      h.current.image = {};
      h.controller.cancel();
    },
  ]) {
    const h = harness();
    h.controller.toggle();
    action(h);
    h.calls[0].resolve(solution);
    await flush();
    assert.deepEqual(h.applied, []);
    assert.equal(h.controller.state.active, false);
    assert.equal(h.calls[0].args.signal.aborted, true);
  }
});

test("unrelated sliders retain Auto after a solve; failures leave edit values intact", async () => {
  const h = harness();
  h.controller.toggle();
  h.calls[0].resolve(solution);
  await flush();
  h.dispatch({
    type: "edit",
    patch: { params: { ...h.current.history.present.params, saturation: 1.2 } },
  });
  assert.equal(h.controller.state.active, true);
  h.dispatch({ type: "edit", patch: { stock: "gold200" } });
  h.calls[1].reject(new Error("Unavailable film"));
  await flush();
  assert.equal(h.controller.state.active, false);
  assert.equal(h.current.history.present.params.ev, solution.ev);
  assert.deepEqual(h.errors, ["Unavailable film"]);
});

test("regional metering yields to cancellation before reading more pixels", async () => {
  const controller = new AbortController();
  let reads = 0;
  const source = {
    width: 4,
    height: 100,
    read: (_, top, w, h) => {
      reads++;
      controller.abort();
      return new Float32Array(w * h * 4).fill(0.18);
    },
  };
  await assert.rejects(
    measureTone(source, {}, (x) => x, [1, 1, 1], { signal: controller.signal }),
    { name: "AbortError" },
  );
  assert.equal(reads, 1);
});
