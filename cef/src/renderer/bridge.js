// Installs the native transport before any page script runs. `host` is the renderer's native
// object; it never reaches the page. The transport matches web/src/backend/desktop/transport.js:
// postMessage({id, method, params}, payload?) resolves with the host's result, and progress
// arrives as "fotufilm-native-progress" events.
(function install(host, globalName, capabilities) {
  "use strict";
  const pending = new Map();
  let sequence = 0;

  function failure(value) {
    const error = new Error(value?.message || "The native host failed.");
    if (value?.name) error.name = value.name;
    return error;
  }

  host.listen((kind, key, ok, json, payload) => {
    const value = json ? JSON.parse(json) : null;
    if (kind === "reply") {
      const call = pending.get(key);
      if (!call) return;
      pending.delete(key);
      if (!ok) return call.reject(failure(value));
      if (!payload) return call.resolve(value);
      // Named ranges of one payload become views of it, without a copy.
      const { payloads, ...rest } = value ?? {};
      if (!payloads) return call.resolve({ ...rest, payload });
      for (const [name, [offset, length]] of Object.entries(payloads))
        rest[name] = new Uint8Array(payload, offset, length);
      call.resolve(rest);
    } else if (kind === "event") {
      const type =
        key === "progress" ? "fotufilm-native-progress" : `fotufilm-native-${key}`;
      window.dispatchEvent(new CustomEvent(type, { detail: value }));
    }
  });

  // A payload travels in shared memory beside the message rather than inside its JSON.
  function bytes(payload) {
    if (payload == null) return [];
    if (payload instanceof ArrayBuffer) return [payload, 0, payload.byteLength];
    if (ArrayBuffer.isView(payload))
      return [payload.buffer, payload.byteOffset, payload.byteLength];
    throw new TypeError("A native payload must be an ArrayBuffer or a view of one.");
  }

  const transport = Object.freeze({
    // postMessage takes a second argument of bytes, carried in shared memory.
    binary: true,
    // What the engine's platform services let the editor offer (fotufilm_capabilities).
    capabilities: Object.freeze(JSON.parse(capabilities || "{}")),
    postMessage(message, payload) {
      return new Promise((resolve, reject) => {
        const key = ++sequence;
        pending.set(key, { resolve, reject });
        try {
          host.send(
            key,
            String(message?.id ?? key),
            String(message?.method ?? ""),
            JSON.stringify(message?.params ?? {}),
            ...bytes(payload),
          );
        } catch (error) {
          pending.delete(key);
          reject(error);
        }
      });
    },
  });
  Object.defineProperty(window, globalName, { value: transport });
})
