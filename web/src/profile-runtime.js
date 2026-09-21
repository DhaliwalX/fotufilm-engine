import {
  WASI,
  File,
  OpenFile,
  ConsoleStdout,
  PreopenDirectory,
} from "@bjorn3/browser_wasi_shim";

// A read-only virtual resource directory is all the native builder sees. No photograph,
// host filesystem, account data or network capability is exposed to the Swift module.
export async function createProfileRuntime(binary, reflectance) {
  const wasi = new WASI(
    ["fotufilm-web-profile"],
    ["FOTUFILM_RESOURCES=/resources"],
    [
      new OpenFile(new File([])),
      ConsoleStdout.lineBuffered((message) => console.debug(message)),
      ConsoleStdout.lineBuffered((message) => console.warn(message)),
      new PreopenDirectory("/resources", [
        [
          "rec2020-reflectance-prior.coeff",
          new File(reflectance, { readonly: true }),
        ],
      ]),
    ],
    { debug: false },
  );
  const module =
    binary instanceof WebAssembly.Module
      ? binary
      : await WebAssembly.compile(binary);
  const instance = await WebAssembly.instantiate(module, {
    wasi_snapshot_preview1: wasi.wasiImport,
  });
  wasi.initialize(instance);
  const api = instance.exports;
  return {
    prepare(request) {
      const input = new TextEncoder().encode(JSON.stringify(request));
      const pointer = api.profile_input(input.length);
      if (!pointer) throw new Error("The film settings request is too large.");
      new Uint8Array(api.memory.buffer, pointer, input.length).set(input);
      const status = api.profile_prepare();
      const output = new Uint8Array(
        api.memory.buffer,
        api.profile_output(),
        api.profile_output_size(),
      ).slice();
      if (status) throw new Error(new TextDecoder().decode(output));
      return output.buffer;
    },
  };
}
