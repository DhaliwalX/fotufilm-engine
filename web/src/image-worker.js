// An import owns its worker. Success, failure, cancellation and timeout all
// release the decoder heap, and late file reads never resurrect cancelled work.
export function decodeImageWorker(
  file,
  createWorker,
  {
    signal,
    onProgress = () => {},
    label,
    message = {},
    maxBytes = 512 * 1024 * 1024,
  } = {},
) {
  return new Promise((resolve, reject) => {
    if (file.size > maxBytes)
      return reject(
        new Error(
          `${label} files above ${maxBytes / 1024 / 1024} MB are not supported.`,
        ),
      );
    if (signal?.aborted)
      return reject(new DOMException("Import cancelled.", "AbortError"));
    // Keep each new Worker(new URL(...)) literal at its importer so Vite can
    // bundle the worker's dependency graph for production and sub-path hosting.
    const worker = createWorker();
    let settled = false;
    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      signal?.removeEventListener("abort", abort);
      worker.terminate();
      if (error) reject(error);
      else resolve(value);
    };
    const abort = () =>
      finish(new DOMException("Import cancelled.", "AbortError"));
    const timer = setTimeout(
      () => finish(new Error(`${label} decoding timed out.`)),
      180000,
    );
    signal?.addEventListener("abort", abort, { once: true });
    worker.onerror = () =>
      finish(new Error(`The ${label} decoder could not run.`));
    worker.onmessage = ({ data }) => {
      if (data.status) onProgress(data.status);
      else if (data.error) finish(new Error(data.error));
      else finish(null, data.result);
    };
    file
      .arrayBuffer()
      .then((bytes) => {
        if (!settled) worker.postMessage({ ...message, bytes }, [bytes]);
      })
      .catch((error) => finish(error));
  });
}
