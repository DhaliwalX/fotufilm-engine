{{flutter_js}}
{{flutter_build_config}}
// Flutter's loader runs the WebAssembly build in Chromium alone unless told otherwise. Safari and
// Firefox run it too; a browser without what it needs still gets the JavaScript build.
_flutter.loader.load({
  serviceWorkerSettings: {
    serviceWorkerVersion: {{flutter_service_worker_version}}
  },
  config: {
    wasmAllowList: { blink: true, webkit: true, gecko: true }
  }
});
