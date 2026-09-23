import test from "node:test";
import assert from "node:assert/strict";
import { createTransport } from "../../src/backend/macos/transport.js";

test("macOS IPC passes data, carries failures, and rejects an invalid host", async () => {
  assert.throws(() => createTransport({}), /Invalid/);
  const sent = [];
  const call = createTransport({
    async postMessage(message) {
      sent.push(message);
      return { backend: "Halide/Metal" };
    },
  });
  assert.equal(
    (await call("render", { maxEdge: null, callback: undefined })).backend,
    "Halide/Metal",
  );
  assert.deepEqual(sent[0].params, { maxEdge: null });
  const failure = createTransport({
    async postMessage() {
      throw new Error("Metal unavailable");
    },
  });
  await assert.rejects(failure("prepare"), /Metal unavailable/);
});

test("cancelled native imports release a late image lease", async () => {
  const sent = [],
    controller = new AbortController();
  let deliver;
  const call = createTransport({
    postMessage(message) {
      sent.push(message);
      if (message.method === "import")
        return new Promise((resolve) => {
          deliver = resolve;
        });
      return Promise.resolve(true);
    },
  });
  const importing = call("import", {}, { signal: controller.signal });
  controller.abort();
  deliver({ handle: "late-image" });
  await assert.rejects(importing, { name: "AbortError" });
  assert.deepEqual(
    sent.map((message) => message.method),
    ["import", "cancel", "release"],
  );
  assert.equal(sent[0].id, sent[1].id);
  assert.equal(sent[2].params.handle, "late-image");
});

test("already cancelled requests never cross IPC", async () => {
  const controller = new AbortController();
  controller.abort();
  const call = createTransport({
    postMessage() {
      assert.fail("Unexpected native request");
    },
  });
  await assert.rejects(call("render", {}, { signal: controller.signal }), {
    name: "AbortError",
  });
});
