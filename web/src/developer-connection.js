// A stalled GPU compiler must not retain the worker or block editor startup.
// Restart once on the CPU, replaying an in-flight preview with its original pack.
export function createDeveloperConnection({
  startupTimeoutMs = 60000,
  warmupTimeoutMs = 90000,
} = {}) {
  let worker, initialization, pack, pending, timer;
  let closed = false,
    ready = false,
    warming = false;
  const connection = {
    onmessage: null,
    onerror: null,
    start(options) {
      initialization = options;
      pack = options.pack;
      connect(options.preferGpu);
    },
    postMessage(data, transfer) {
      if (closed) return;
      if (data.kind === "develop") {
        if (data.packChanged) pack = data.pack;
        pending = { ...data, packChanged: true, pack };
      }
      worker.postMessage(data, transfer);
    },
    terminate() {
      closed = true;
      clearTimeout(timer);
      worker?.terminate();
      pending = null;
    },
  };
  function arm(milliseconds, callback) {
    clearTimeout(timer);
    timer = setTimeout(callback, milliseconds);
  }
  function fail(message) {
    connection.terminate();
    connection.onerror?.({ message });
  }
  function recover() {
    if (closed) return;
    console.warn(
      "GPU preparation stalled; restarting the image engine on the CPU.",
    );
    connect(false);
  }
  function connect(preferGpu) {
    worker?.terminate();
    const current = new Worker(
      new URL("./developer-worker.js", import.meta.url),
      {
        type: "module",
      },
    );
    worker = current;
    warming = preferGpu;
    arm(startupTimeoutMs, () =>
      preferGpu
        ? recover()
        : fail(
            "The image engine could not start. Try opening the image again.",
          ),
    );
    const reply = (data, transfer) => {
      if (!closed && current === worker) current.postMessage(data, transfer);
    };
    current.onerror = (event) => {
      if (closed || current !== worker) return;
      if (warming) recover();
      else fail(event.message || "The background image engine stopped.");
    };
    current.onmessage = ({ data }) => {
      if (closed || current !== worker) return;
      if (data.kind === "ready") {
        clearTimeout(timer);
        if (warming) arm(warmupTimeoutMs, recover);
        const alreadyReady = ready;
        ready = true;
        if (pending) reply(pending);
        if (alreadyReady) return;
      } else if (data.kind === "warmup-progress" && warming) {
        arm(warmupTimeoutMs, recover);
      } else if (data.kind === "gpu-ready") {
        warming = false;
        clearTimeout(timer);
      } else if (data.kind === "result" || data.kind === "error") {
        pending = null;
      }
      connection.onmessage?.({ data, reply });
    };
    reply({ ...initialization, pack, preferGpu });
  }
  return connection;
}
