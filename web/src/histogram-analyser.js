// One worker per visible histogram; request ownership and cancellation stay below React.
export function createHistogram() {
  const worker = new Worker(new URL("./histogram.worker.js", import.meta.url), {
    type: "module",
  });
  let nextId = 0,
    pending,
    closed = false,
    failure;
  const finish = (error, result) => {
    const job = pending;
    if (!job) return;
    pending = null;
    job.signal?.removeEventListener("abort", job.abort);
    if (error) job.reject(error);
    else job.resolve(result);
  };
  const cancelled = () =>
    new DOMException("Histogram cancelled.", "AbortError");
  worker.onmessage = ({ data }) => {
    if (data.generation !== pending?.id) return;
    finish(data.error ? new Error(data.error) : null, data.analysis);
  };
  worker.onerror = () => {
    failure = new Error("Histogram analysis could not start.");
    finish(failure);
    worker.terminate();
  };
  return {
    analyse(result, { signal } = {}) {
      finish(cancelled());
      if (failure) return Promise.reject(failure);
      if (closed || signal?.aborted) return Promise.reject(cancelled());
      return new Promise((resolve, reject) => {
        const id = ++nextId,
          abort = () => finish(cancelled());
        pending = { id, resolve, reject, signal, abort };
        signal?.addEventListener("abort", abort, { once: true });
        try {
          worker.postMessage({
            generation: id,
            output: result.blob,
            colorSpace: result.colorSpace || "srgb",
          });
        } catch (error) {
          finish(error);
        }
      });
    },
    dispose() {
      closed = true;
      finish(cancelled());
      worker.terminate();
    },
  };
}
