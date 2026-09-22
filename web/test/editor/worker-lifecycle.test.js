import test from "node:test";
import assert from "node:assert/strict";
import { createBackgroundDeveloper } from "../../src/background-developer.js";

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

test("negative warmup is shared and the compiled worker is checked out exclusively", async (t) => {
  install(t);
  const pool = await import("../../src/negative-worker-pool.js?reuse");
  const first = pool.prepareNegativeWorker("https://example.test/negative/");
  assert.equal(
    pool.prepareNegativeWorker("https://example.test/negative/"),
    first,
  );
  const worker = FakeWorker.instances[0];
  worker.send({ kind: "done", backend: "webgpu" });
  assert.equal(await first, true);
  assert.equal(pool.takeNegativeWorker(), worker);
  const concurrent = pool.takeNegativeWorker();
  assert.notEqual(concurrent, worker);
  pool.returnNegativeWorker(worker);
  pool.returnNegativeWorker(concurrent);
  assert.equal(concurrent.terminated, true);
  assert.equal(pool.takeNegativeWorker(), worker);
});

test("failed GPU warmup disposes its worker and unsupported browsers skip it", async (t) => {
  install(t);
  const pool = await import("../../src/negative-worker-pool.js?failure");
  const ready = pool.prepareNegativeWorker("https://example.test/negative/");
  const worker = FakeWorker.instances[0];
  worker.send({ kind: "error", error: "device lost" });
  assert.equal(await ready, false);
  assert.equal(worker.terminated, true);
  assert.notEqual(pool.takeNegativeWorker(), worker);
  Object.defineProperty(globalThis.navigator, "gpu", {
    configurable: true,
    value: undefined,
  });
  const unsupported = await import(
    "../../src/negative-worker-pool.js?unsupported"
  );
  const count = FakeWorker.instances.length;
  assert.equal(
    await unsupported.prepareNegativeWorker("https://example.test/negative/"),
    false,
  );
  assert.equal(FakeWorker.instances.length, count);
});
