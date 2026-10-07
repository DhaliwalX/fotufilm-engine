import test from "node:test";
import assert from "node:assert/strict";
import { createBackgroundDeveloper } from "../../src/background-developer.js";
import { createDeveloperConnection } from "../../src/developer-connection.js";

// No browser globals are read until a worker is requested.
class FakeWorker {
  static instances = [];
  constructor() {
    FakeWorker.instances.push(this);
  }
  postMessage(message) {
    this.message = message;
  }
  terminate() {
    this.terminated = true;
  }
  send(data) {
    this.onmessage?.({ data });
  }
}
function install(t, gpu = {}) {
  FakeWorker.instances = [];
  const replace = (object, name, value) => {
    const previous = Object.getOwnPropertyDescriptor(object, name);
    Object.defineProperty(object, name, { configurable: true, value });
    t.after(() =>
      previous
        ? Object.defineProperty(object, name, previous)
        : delete object[name],
    );
  };
  replace(globalThis, "Worker", FakeWorker);
  replace(globalThis.navigator, "gpu", gpu);
  replace(WebAssembly, "Suspending", function () {});
  replace(WebAssembly, "promising", function () {});
}

test("disposing during WASM startup terminates the worker and settles initialization", async (t) => {
  install(t);
  const controller = new AbortController();
  const ready = createBackgroundDeveloper(null, undefined, undefined, {
    signal: controller.signal,
  });
  controller.abort();
  assert.equal(await ready, null);
  assert.equal(FakeWorker.instances[0].terminated, true);
});

test("stalled GPU preparation restarts on CPU and preserves the pending preview", async (t) => {
  install(t);
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const ready = createBackgroundDeveloper(null, undefined, undefined, {
    warmupTimeoutMs: 1000,
  });
  const gpuWorker = FakeWorker.instances[0];
  gpuWorker.send({ kind: "ready", backend: "simd" });
  const developer = await ready;
  const pack = { id: "selected film" };
  developer.usePack(pack);
  const preview = developer.develop({ width: 20, height: 10 }, { exposure: 1 });
  t.mock.timers.tick(800);
  gpuWorker.send({ kind: "warmup-progress", completed: 2, total: 11 });
  t.mock.timers.tick(800);
  assert.equal(
    FakeWorker.instances.length,
    1,
    "real progress extends the deadline",
  );
  t.mock.timers.tick(201);
  const cpuWorker = FakeWorker.instances[1];
  assert.equal(gpuWorker.terminated, true);
  assert.equal(cpuWorker.message.preferGpu, false);
  assert.equal(cpuWorker.message.pack, pack);
  cpuWorker.send({ kind: "ready", backend: "simd" });
  assert.equal(cpuWorker.message.kind, "develop");
  assert.equal(cpuWorker.message.pack, pack);
  assert.deepEqual(cpuWorker.message.controls, { exposure: 1 });
  cpuWorker.send({ kind: "gpu-ready", available: false });
  assert.equal(await developer.gpuReady, false);
  gpuWorker.send({ kind: "result", result: "obsolete", backend: "webgpu" });
  cpuWorker.send({ kind: "result", result: "recovered", backend: "simd" });
  assert.equal(await preview, "recovered");
  t.mock.timers.tick(200000);
  assert.equal(FakeWorker.instances.length, 2);
  developer.dispose();
});

test("failed CPU startup settles initialization and terminates both attempts", async (t) => {
  install(t);
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const ready = createBackgroundDeveloper(null, undefined, undefined, {
    startupTimeoutMs: 1000,
  });
  const rejection = assert.rejects(ready, /could not start/);
  t.mock.timers.tick(1000);
  assert.equal(FakeWorker.instances[1].message.preferGpu, false);
  t.mock.timers.tick(1000);
  await rejection;
  assert.ok(FakeWorker.instances.every((worker) => worker.terminated));
});

test("pixel replies from the discarded worker cannot reach its replacement", (t) => {
  install(t);
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const connection = createDeveloperConnection({ warmupTimeoutMs: 1000 });
  let oldReply;
  connection.onmessage = ({ data, reply }) => {
    if (data.kind === "read") oldReply = reply;
  };
  connection.start({ kind: "initialize", pack: null, preferGpu: true });
  const old = FakeWorker.instances[0];
  old.send({ kind: "ready" });
  old.send({ kind: "read", id: 1 });
  t.mock.timers.tick(1000);
  const next = FakeWorker.instances[1];
  oldReply({ kind: "pixels", id: 1 });
  assert.equal(next.message.kind, "initialize");
  connection.terminate();
});
