import { loadCameraProfiles, resolveCameraProfile, estimateAsShotKelvin } from './camera-profile.js'
import { relatedAssetUrl } from './runtime-assets.js'

// One worker per import releases the decoder's entire WASM heap on completion.
self.onmessage = async ({ data: { bytes, decoderURL, negative = false } }) => {
  let module, input
  try {
    let lastStage,
      lastPercent = -1
    globalThis.onRawProgress = (stage, iteration, expected) => {
      // LibRaw uses (0, 2)/(1, 2) as start/end sentinels for whole operations.
      // Percentages are useful only for callbacks that count actual rows or passes.
      const percent = expected > 2 ? Math.floor((100 * iteration) / expected) : -1
      if (stage === lastStage && percent === lastPercent) return
      lastStage = stage
      lastPercent = percent
      self.postMessage({
        status: percent >= 0 ? `${stage} · ${percent}%` : stage,
      })
    }
    self.postMessage({ status: 'Loading RAW decoder' })
    const factory = (await import(/* @vite-ignore */ decoderURL)).default
    module = await factory({ locateFile: name => relatedAssetUrl(name, decoderURL) })
    if (
      [
        '_raw_scene_scale',
        '_raw_make',
        '_raw_model',
        '_raw_camera_channels',
        '_raw_lens_model',
        '_raw_lens_make',
        '_raw_focal_length',
        '_raw_aperture',
        '_raw_camera_wb',
        '_raw_camera_to_xyz',
      ].some((name) => typeof module[name] !== 'function')
    )
      throw new Error(
        'The RAW decoder is out of date. Rebuild the RAW runtime and reload the editor.',
      )
    input = module._malloc(bytes.byteLength)
    if (!input) throw new Error('Not enough memory to open this RAW image.')
    module.HEAPU8.set(new Uint8Array(bytes), input)
    if (negative && typeof module._raw_open_negative !== 'function')
      throw new Error('The RAW decoder needs updating for negative import. Reload the editor.')
    const open = negative ? module._raw_open_negative : module._raw_open
    if (open(input, bytes.byteLength))
      throw new Error(module.UTF8ToString(module._raw_error()))
    const camera = {
      make: module.UTF8ToString(module._raw_make()),
      model: module.UTF8ToString(module._raw_model()),
      channels: module._raw_camera_channels(),
      whiteBalance: [0, 1, 2].map((c) => module._raw_camera_wb(c)),
      cameraToXYZ: Array.from({ length: 9 }, (_, i) => module._raw_camera_to_xyz(i)),
    }
    const lensModel = module.UTF8ToString(module._raw_lens_model())
    const positive = (value) => Number.isFinite(value) && value > 0 ? value : null
    const lensShot = lensModel ? {
      lensModel, lensMaker: module.UTF8ToString(module._raw_lens_make()) || null,
      cameraModel: camera.model, focalLength: positive(module._raw_focal_length()),
      aperture: positive(module._raw_aperture()),
    } : null
    let profile = null, sceneKelvin = null
    if (negative) {
      // Reflectance-based scene corrections and photographic highlight recovery
      // are inappropriate for transmission through an already-developed negative.
      self.postMessage({ status: 'Decoding RAW negative without highlight reconstruction' })
    } else {
      self.postMessage({ status: 'Loading camera spectral profiles' })
      const catalog = await loadCameraProfiles(relatedAssetUrl('camera-profiles.json', decoderURL))
      profile = resolveCameraProfile(camera, catalog)
      sceneKelvin = estimateAsShotKelvin(camera, catalog.whiteLocus)
      self.postMessage({
        status: profile
          ? `Preparing ${camera.make} ${camera.model} spectral correction · estimated ${Math.round(profile.kelvin)} K`
          : 'No matching spectral correction · using RAW decoder color',
      })
    }
    self.postMessage({ status: 'Unpacking RAW sensor data' })
    if (module._raw_unpack()) throw new Error(module.UTF8ToString(module._raw_error()))
    self.postMessage({ status: 'Preparing sensor pixels' })
    if (module._raw_process()) throw new Error(module.UTF8ToString(module._raw_error()))
    const width = module._raw_width(),
      height = module._raw_height(),
      colors = module._raw_colors(),
      sceneScale = module._raw_scene_scale()
    self.postMessage({ status: 'Copying decoded RAW pixels' })
    const start = module._raw_pixels() / 2
    const pixels = module.HEAPU16.slice(start, start + width * height * colors)
    self.postMessage({ width, height, colors, sceneScale, profile, sceneKelvin, lensShot, pixels }, [
      pixels.buffer,
    ])
  } catch (error) {
    self.postMessage({ error: error.message || 'Could not decode RAW image.' })
  } finally {
    module?._raw_close()
    if (input) module._free(input)
  }
}
