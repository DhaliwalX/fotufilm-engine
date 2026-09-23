// Contract double only: proves that the editor can run without any browser engine assets.
export function installNativeBackend({ failPreparation = false } = {}) {
  const calls = (window.nativeCalls = []);
  const buffers = new Map(),
    catalogue = { profiles: [], revision: 0, loaded: true };
  window.nativeSampleDelay = 0;
  window.nativeLiveImages = () => buffers.size;
  const image = (blob, width, height) => {
    const handle = crypto.randomUUID();
    buffers.set(handle, blob);
    return { handle, naturalWidth: width, naturalHeight: height };
  };
  const preview = (value) => {
    const url = URL.createObjectURL(buffers.get(value.handle));
    value.src = url;
    return { image: value, url };
  };
  window.fotufilmNative = {
    version: 1,
    createSession() {
      calls.push("session");
      let closed = false;
      return {
        async render(request) {
          if (closed || request.stale?.()) return null;
          calls.push(
            request.viewport
              ? "viewport"
              : request.background
                ? "thumbnail"
                : "render",
          );
          const blob = buffers.get(request.image.handle);
          if (!blob) throw new Error("Image handle was released too early");
          return {
            blob,
            original: blob,
            width: request.image.naturalWidth,
            height: request.image.naturalHeight,
            colorSpace: "srgb",
            backend: "metal",
            elapsed: 1,
            renderMilliseconds: 1,
            viewport: request.viewport,
          };
        },
        async stages() {
          calls.push("stages");
          return [];
        },
        dispose() {
          closed = true;
          calls.push("disposeSession");
        },
      };
    },
    async prepare(session, report) {
      if (failPreparation) throw new Error("Native engine could not start");
      calls.push("prepare");
      report({ value: 100, label: "Ready", done: true });
    },
    async loadStocks() {
      return [{ id: "gold200", name: "Gold 200", media: [], available: [] }];
    },
    async importMedia(file, options) {
      calls.push(options.negative ? "importNegative" : "importMedia");
      options.onProgress?.("Reading image");
      const bitmap = await createImageBitmap(file);
      const result = image(file, bitmap.width, bitmap.height);
      bitmap.close();
      if (window.nativeHoldImports)
        await new Promise((resolve) => {
          window.nativeResolveImport = resolve;
        });
      return preview(result);
    },
    releaseImage(value) {
      calls.push("releaseImage");
      buffers.delete(value.handle);
    },
    async analyseNegative() {
      calls.push("analyseNegative");
      return { weak: false };
    },
    async convertNegative(value) {
      calls.push("convertNegative");
      return {
        image: image(
          buffers.get(value.handle),
          value.naturalWidth,
          value.naturalHeight,
        ),
        backend: "metal",
      };
    },
    async makePreview(value) {
      calls.push("makePreview");
      return preview(value);
    },
    createHistogram() {
      return {
        async analyse() {
          calls.push("histogram");
          const channel = () => {
            const bins = new Uint32Array(256);
            bins[128] = 100;
            return bins;
          };
          return {
            bins: [channel(), channel(), channel()],
            luma: channel(),
            chroma: [channel(), channel()],
            oklab: [channel(), channel(), channel()],
            count: 100,
          };
        },
        dispose() {
          calls.push("disposeHistogram");
        },
      };
    },
    async autoAdjust() {
      calls.push("autoAdjust");
      return { ev: 0.5, highlights: -0.1, shadows: 0.2 };
    },
    async planPrintFrame(edit, width, height) {
      calls.push("planPrintFrame");
      return {
        configuration: { frame: "none" },
        placement: {
          size: { width, height },
          image: { x: 0, y: 0, width, height },
        },
      };
    },
    async resolveLensPlan() {
      calls.push("lensPlan");
      return { note: "Native lens", table: [] };
    },
    outputColorSpace() {
      return "srgb";
    },
    async sampleScene() {
      calls.push("sampleScene");
      if (window.nativeHoldSamples)
        await new Promise((resolve) => {
          window.nativeResolveSample = resolve;
        });
      await new Promise((resolve) =>
        setTimeout(resolve, window.nativeSampleDelay),
      );
      return [0.18, 0.2, 0.15];
    },
    async exportImage(request) {
      calls.push("exportImage");
      window.nativeExport = { type: request.type, filename: request.filename };
    },
    async exportVideo(request) {
      calls.push("exportVideo");
      return { filename: request.filename, dispose() {} };
    },
    lenses: {
      snapshot: () => catalogue,
      subscribe: () => () => {},
      async load() {},
      async import() {},
      async remove() {},
    },
  };
}
