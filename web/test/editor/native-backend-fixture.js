// Contract double only: proves that the editor can run without any browser engine assets.
export function installNativeBackend({ failPreparation = false, negativeScans = false } = {}) {
  const calls = (window.nativeCalls = []);
  // Every edit a render was asked for, newest last.
  const renders = (window.nativeRenders = []);
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
          if (!request.background) renders.push(request.edit);
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
      return [
        { id: "gold200", name: "Gold 200", media: [], available: [], readsNegative: true },
        { id: "portra400", name: "Portra 400", media: [], available: [], readsNegative: true },
        { id: "e100", name: "E100", media: [], available: [], readsNegative: false },
      ];
    },
    async importMedia(file, options) {
      calls.push(options.negative ? "importNegative" : "importMedia");
      options.onProgress?.("Reading image");
      const bitmap = await createImageBitmap(file);
      const result = image(file, bitmap.width, bitmap.height);
      bitmap.close();
      // A scan opened as a negative document says which films its base looks like.
      if (options.negative && negativeScans)
        result.negative = {
          suggestions: [{ films: [{ id: "portra400", name: "Portra 400" }], likelihood: 0.6 }],
          lightFrames: [],
        };
      if (window.nativeHoldImports)
        await new Promise((resolve) => {
          window.nativeResolveImport = resolve;
        });
      return preview(result);
    },
    async thumbnail(source) {
      calls.push("drawThumbnail");
      return URL.createObjectURL(source.file);
    },
    releaseImage(value) {
      calls.push("releaseImage");
      buffers.delete(value.handle);
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
        available: ["none"],
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
    ...(negativeScans && {
      negativeScans: {
        async sampleFilmBase() {
          calls.push("sampleFilmBase");
          return [0.8, 0.45, 0.2];
        },
        async lightFrames() {
          return [];
        },
        async addLightFrame() {
          return { id: "light", name: "Light 1" };
        },
        async removeLightFrame() {},
      },
    }),
    lenses: {
      snapshot: () => catalogue,
      subscribe: () => () => {},
      async load() {},
      async import() {},
      async remove() {},
    },
  };
}
