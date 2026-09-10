// Emscripten glue and WASM must come from the same export. Relative URLs otherwise
// discard the module's query string and can reuse an older cached binary.
export function runtimeAssetUrl(name, base, location, revision) {
  const url = new URL(base + name, location)
  if (revision) url.searchParams.set('v', revision)
  return url.href
}

export function relatedAssetUrl(name, parent) {
  const url = new URL(name, parent)
  const revision = new URL(parent).searchParams.get('v')
  if (revision) url.searchParams.set('v', revision)
  return url.href
}

export function supportsWebgpuRuntime(gpu, wasm) {
  return !!gpu && typeof wasm?.Suspending === 'function' && typeof wasm?.promising === 'function'
}

export function createRuntimeLoader(resolveUrl, importModule = url => import(/* @vite-ignore */ url)) {
  const promises = new Map(), aborted = new WeakSet()
  return {
    load(kind) {
      if (!promises.has(kind)) {
        let module
        const url = resolveUrl(kind)
        const promise = importModule(url).then(({ default: factory }) => factory({
          locateFile: name => relatedAssetUrl(name, url),
          onAbort() {
            if (module) aborted.add(module)
            promises.delete(kind)
          },
        })).then(value => (module = value)).catch(error => {
          promises.delete(kind)
          throw error
        })
        promises.set(kind, promise)
      }
      return promises.get(kind)
    },
    forget(kind) { promises.delete(kind) },
    wasAborted(module) { return aborted.has(module) },
  }
}
