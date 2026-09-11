import { test, expect } from '@playwright/test'
import { execFileSync } from 'node:child_process'
import { mkdir } from 'node:fs/promises'
import { resolve } from 'node:path'
import { existsSync } from 'node:fs'
import { createHash } from 'node:crypto'

const fixtures = resolve('build/video-fixtures')
const runtimeDir = process.env.FOTUFILM_TEST_RUNTIME_DIR || resolve('public')
async function routeRuntime(page) {
  if (!process.env.FOTUFILM_TEST_RUNTIME_DIR) return
  await page.route(
    /\/(packs\/[^?]+|fotufilm(?:-webgpu)?\.(?:mjs|wasm))(?:\?.*)?$/,
    async (route) => {
      const path = decodeURIComponent(
        new URL(route.request().url()).pathname,
      ).slice(1)
      if (path.includes('..')) throw new Error('Invalid runtime path')
      const contentType = path.endsWith('.mjs')
        ? 'text/javascript'
        : path.endsWith('.json')
          ? 'application/json'
          : path.endsWith('.wasm')
            ? 'application/wasm'
            : 'application/octet-stream'
      await route.fulfill({ path: resolve(runtimeDir, path), contentType })
    },
  )
}
test.beforeAll(async () => {
  await mkdir(fixtures, { recursive: true })
  execFileSync('ffmpeg', [
    '-hide_banner',
    '-loglevel',
    'error',
    '-y',
    '-f',
    'lavfi',
    '-i',
    'testsrc2=size=96x64:rate=12:duration=1',
    '-f',
    'lavfi',
    '-i',
    'sine=frequency=440:sample_rate=48000:duration=1',
    '-c:v',
    'libx264',
    '-pix_fmt',
    'yuv420p',
    '-color_primaries',
    'bt709',
    '-color_trc',
    'bt709',
    '-colorspace',
    'bt709',
    '-c:a',
    'aac',
    '-movflags',
    '+faststart',
    resolve(fixtures, 'source.mp4'),
  ])
  execFileSync('ffmpeg', [
    '-hide_banner',
    '-loglevel',
    'error',
    '-y',
    '-f',
    'lavfi',
    '-i',
    'testsrc2=size=96x64:rate=12:duration=1',
    '-vf',
    'select=eq(n\\,0)+eq(n\\,1)+eq(n\\,3)+eq(n\\,6)+eq(n\\,10)',
    '-fps_mode',
    'vfr',
    '-c:v',
    'libx264',
    '-pix_fmt',
    'yuv420p',
    '-movflags',
    '+faststart',
    resolve(fixtures, 'vfr.mp4'),
  ])
  execFileSync('ffmpeg', [
    '-hide_banner',
    '-loglevel',
    'error',
    '-y',
    '-f',
    'lavfi',
    '-i',
    'testsrc2=size=96x64:rate=12:duration=2',
    '-c:v',
    'libx265',
    '-x265-params',
    'log-level=error:pools=1:frame-threads=1:keyint=8:min-keyint=8:scenecut=0',
    '-tag:v',
    'hvc1',
    '-pix_fmt',
    'yuv420p10le',
    '-color_primaries',
    'bt2020',
    '-color_trc',
    'arib-std-b67',
    '-colorspace',
    'bt2020nc',
    '-movflags',
    '+faststart',
    resolve(fixtures, 'hdr.mp4'),
  ])
  execFileSync('ffmpeg', [
    '-hide_banner',
    '-loglevel',
    'error',
    '-y',
    '-i',
    resolve(fixtures, 'hdr.mp4'),
    '-c:v',
    'libx265',
    '-x265-params',
    'log-level=error:pools=1:frame-threads=1:keyint=8:min-keyint=8:scenecut=0',
    '-tag:v',
    'hvc1',
    '-pix_fmt',
    'yuv420p',
    resolve(fixtures, 'hevc-main.mp4'),
  ])
})
async function setup(page) {
  await page.route('**/video-test.html', (route) =>
    route.fulfill({
      contentType: 'text/html',
      body: '<!doctype html><title>Video pipeline test</title>',
    }),
  )
  await page.route('**/__video/*.mp4', (route) =>
    route.fulfill({
      contentType: 'video/mp4',
      path: resolve(
        fixtures,
        new URL(route.request().url()).pathname.split('/').at(-1),
      ),
    }),
  )
  await routeRuntime(page)
  await page.goto('/video-test.html')
}
for (const format of ['mp4', 'webm']) {
  test(`${format}: file-backed import, trimmed export, audio and completed disk download`, async ({
    page,
  }) => {
    await setup(page)
    const report = await page.evaluate(async (format) => {
      const { importVideo } = await import('/src/video-import.js')
      const { createVideoDestination, exportVideo } = await import(
        '/src/video-export.js'
      )
      const { defaultEdit } = await import('/src/editor-state.js')
      const { RenderSession } = await import('/src/render-session.js')
      const { Input, BlobSource, ALL_FORMATS, VideoSampleSink } = await import(
        '/node_modules/mediabunny/dist/modules/src/index.js'
      )
      const bytes = await (await fetch('/__video/source.mp4')).arrayBuffer()
      class GuardedFile extends File {
        arrayBuffer() {
          throw new Error('Must not buffer the whole input file')
        }
      }
      const file = new GuardedFile([bytes], 'source.mp4', { type: 'video/mp4' })
      const loaded = await importVideo(file)
      window.showSaveFilePicker = undefined
      const destination = await createVideoDestination(`test.${format}`)
      const session = new RenderSession(),
        progress = []
      const edit = defaultEdit()
      edit.params.ev = 0.25
      edit.video.trimStart = 0.25
      edit.video.trimEnd = 0.75
      edit.rotation = 1
      let saved, input
      try {
        const preview = await loaded.image.video.frame(0.5, 'slog3Cine')
        saved = await exportVideo({
          image: loaded.image,
          edit,
          stock: 'gold200',
          session,
          destination,
          format,
          onProgress: (p) => progress.push(p),
        })
        const exported = await (await fetch(saved.url)).blob()
        input = new Input({
          source: new BlobSource(exported),
          formats: ALL_FORMATS,
        })
        const video = await input.getPrimaryVideoTrack(),
          audio = await input.getPrimaryAudioTrack()
        const samples = new VideoSampleSink(video)
        let count = 0,
          first = null,
          last = null
        for await (const sample of samples.samples()) {
          count++
          first ??= sample.timestamp
          last = sample.timestamp + sample.duration
          sample.close()
        }
        const root = await (
          await navigator.storage.getDirectory()
        ).getDirectoryHandle('fotufilm-video-exports')
        const before = []
        for await (const entry of root.keys()) before.push(entry)
        await saved.dispose()
        const after = []
        for await (const entry of root.keys()) after.push(entry)
        return {
          importedDuration: loaded.image.video.duration,
          metadataDuration: await input.getDurationFromMetadata(),
          duration: await video.computeDuration(),
          audioDuration: await audio.computeDuration(),
          width: await video.getDisplayWidth(),
          height: await video.getDisplayHeight(),
          count,
          first,
          last,
          previewFloat: preview.linear.data instanceof Float32Array,
          progress: progress.at(-1),
          removed: before.length - after.length,
          sourceCount: session.sources.length,
        }
      } finally {
        await saved?.dispose()
        input?.dispose()
        loaded.image.video.dispose()
        await session.dispose()
      }
    }, format)
    console.log(format, report)
    expect(
      Math.abs((report.metadataDuration ?? report.duration) - 0.5),
    ).toBeLessThan(0.025)
    expect(report.importedDuration).toBeCloseTo(1, 6)
    expect(report.audioDuration).toBeGreaterThan(0.45)
    expect(report.audioDuration).toBeLessThan(0.6)
    expect(report.width).toBe(64)
    expect(report.height).toBe(96)
    expect(report.count).toBe(6)
    expect(report.first).toBeCloseTo(0, 4)
    expect(report.last).toBeGreaterThanOrEqual(0.416)
    expect(report.previewFloat).toBe(true)
    expect(report.removed).toBe(1)
    expect(report.progress.finalizing).toBe(true)
    expect(report.sourceCount).toBe(0)
  })
}
test('cancel and write failures abort the destination and release disk staging', async ({
  page,
}) => {
  await setup(page)
  const report = await page.evaluate(async () => {
    const { importVideo } = await import('/src/video-import.js')
    const { createVideoDestination, exportVideo } = await import(
      '/src/video-export.js'
    )
    const { defaultEdit } = await import('/src/editor-state.js')
    const { RenderSession } = await import('/src/render-session.js')
    const loaded = await importVideo(
      new File(
        [await (await fetch('/__video/source.mp4')).arrayBuffer()],
        'source.mp4',
        { type: 'video/mp4' },
      ),
    )
    window.showSaveFilePicker = undefined
    const root = await (
      await navigator.storage.getDirectory()
    ).getDirectoryHandle('fotufilm-video-exports', { create: true })
    const count = async () => {
      let n = 0
      for await (const _ of root.keys()) n++
      return n
    }
    const before = await count(),
      session = new RenderSession(),
      controller = new AbortController()
    let cancelled,
      failure,
      aborted = false,
      committed = false
    try {
      const destination = await createVideoDestination('cancel.mp4')
      try {
        await exportVideo({
          image: loaded.image,
          edit: defaultEdit(),
          stock: 'gold200',
          session,
          destination,
          signal: controller.signal,
          onProgress: () => controller.abort(),
        })
      } catch (e) {
        cancelled = e.name
      }
      // The save-picker path must not commit a partial file when its writer fails.
      window.showSaveFilePicker = async () => ({
        createWritable: async () => ({
          write: async () => {
            throw new DOMException('Disk full', 'QuotaExceededError')
          },
          abort: async () => {
            aborted = true
          },
          close: async () => {
            committed = true
          },
        }),
      })
      const failedDestination = await createVideoDestination('failed.mp4')
      try {
        await exportVideo({
          image: loaded.image,
          edit: defaultEdit(),
          stock: 'gold200',
          session,
          destination: failedDestination,
        })
      } catch (e) {
        failure = e.message
      }
      return {
        before,
        after: await count(),
        cancelled,
        failure,
        aborted,
        committed,
      }
    } finally {
      loaded.image.video.dispose()
      await session.dispose()
    }
  })
  expect(report.cancelled).toBe('AbortError')
  expect(report.after).toBe(report.before)
  expect(report.failure).toContain('Disk full')
  expect(report.aborted).toBe(true)
  expect(report.committed).toBe(false)
})

test('video UI imports, seeks, changes log encoding, undoes, trims and exports', async ({
  page,
}, info) => {
  test.skip(
    !existsSync(resolve(runtimeDir, 'packs/index.json')),
    'Build the browser runtime or set FOTUFILM_TEST_RUNTIME_DIR.',
  )
  await routeRuntime(page)
  await page.route('**/demo-scene.exr*', (route) =>
    route.fulfill({ status: 404, body: '' }),
  )
  await page.goto('/')
  await page
    .locator('input[type=file][multiple]')
    .setInputFiles(resolve(fixtures, 'source.mp4'))
  await expect(page.getByLabel('Video controls')).toBeVisible()
  await expect(page.locator('.viewer-status > [role=status]')).toContainText(
    '96 × 64',
  )
  await page
    .getByRole('combobox', { name: 'Input color space' })
    .selectOption('appleLog2')
  await page.getByRole('button', { name: 'Undo (⌘Z)', exact: true }).click()
  await expect(
    page.getByRole('combobox', { name: 'Input color space' }),
  ).toHaveValue('standard')
  await page
    .getByRole('combobox', { name: 'Input color space' })
    .selectOption('slog3Cine')
  await page.getByRole('slider', { name: 'Video position' }).fill('0.5')
  await expect(page.locator('.video-timeline output')).toContainText('0:00.50')
  await page.getByRole('spinbutton', { name: 'Trim in' }).fill('0.25')
  await page.getByRole('spinbutton', { name: 'Trim out' }).fill('0.75')
  await page.screenshot({
    path: info.outputPath('video-editor.png'),
    fullPage: true,
  })
  await page.evaluate(() => {
    window.showSaveFilePicker = undefined
  })
  await page.getByRole('button', { name: 'Export (⌘S)', exact: true }).click()
  await expect(page.getByRole('dialog', { name: 'Export video' })).toBeVisible()
  await page.getByRole('button', { name: 'Export', exact: true }).click()
  await expect(
    page.getByRole('link', { name: /Download source-normal.mp4/ }),
  ).toBeVisible()
  await page.getByRole('button', { name: 'Dismiss', exact: true }).click()
  await expect(page.locator('.video-download')).toHaveCount(0)
})

test('all log video inputs agree through CPU and WebGPU film rendering', async ({
  page,
}) => {
  test.setTimeout(180000)
  test.skip(
    !existsSync(resolve(runtimeDir, 'fotufilm-webgpu.wasm')),
    'Build the browser runtime or set FOTUFILM_TEST_RUNTIME_DIR.',
  )
  await setup(page)
  const report = await page.evaluate(async () => {
    const { importVideo } = await import('/src/video-import.js')
    const { VIDEO_ENCODINGS } = await import('/src/video-color.js')
    const { defaultEdit } = await import('/src/editor-state.js')
    const { rawSource } = await import('/src/raw-source.js')
    const { loadPack, createDeveloper, createCpuDeveloper, linearSource } =
      await import('/src/engine.js')
    const loaded = await importVideo(
      new File(
        [await (await fetch('/__video/source.mp4')).arrayBuffer()],
        'source.mp4',
        { type: 'video/mp4' },
      ),
    )
    const pack = await loadPack('/packs/gold200.pack'),
      gpu = await createDeveloper(pack),
      cpu = await createCpuDeveloper(pack)
    const values = []
    try {
      for (const encoding of VIDEO_ENCODINGS) {
        const frame = await loaded.image.video.frame(0.5, encoding.id)
        const source = linearSource(rawSource(frame, defaultEdit(), 96))
        const controls = {
          ...defaultEdit().params,
          grain: 0,
          ev: -0.5,
          seed: 0,
        }
        const a = await gpu.develop(source, controls),
          b = await cpu.develop(source, controls)
        let peak = 0,
          total = 0
        for (let i = 0; i < a.pixels.length; i++) {
          const d = Math.abs(a.pixels[i] - b.pixels[i])
          peak = Math.max(peak, d)
          total += d
        }
        values.push({
          encoding: encoding.id,
          peak,
          mean: total / a.pixels.length,
        })
      }
      return { backend: gpu.backend, values }
    } finally {
      gpu.dispose()
      cpu.dispose()
      loaded.image.video.dispose()
    }
  })
  console.log('Video film parity:', report)
  expect(report.backend).toBe('webgpu')
  for (const row of report.values) {
    expect(row.peak).toBeLessThanOrEqual(3)
    expect(row.mean).toBeLessThan(0.25)
  }
})

test('variable frame times, silent clips and full-clip export preserve all frames', async ({
  page,
}) => {
  await setup(page)
  const report = await page.evaluate(async () => {
    const { importVideo, timedVideoSamples } = await import(
      '/src/video-import.js'
    )
    const { createVideoDestination, exportVideo } = await import(
      '/src/video-export.js'
    )
    const { defaultEdit } = await import('/src/editor-state.js')
    const { RenderSession } = await import('/src/render-session.js')
    const { Input, BlobSource, ALL_FORMATS, VideoSampleSink } = await import(
      '/node_modules/mediabunny/dist/modules/src/index.js'
    )
    const loaded = await importVideo(
      new File(
        [await (await fetch('/__video/vfr.mp4')).arrayBuffer()],
        'vfr.mp4',
        { type: 'video/mp4' },
      ),
    )
    const session = new RenderSession(),
      edit = defaultEdit()
    window.showSaveFilePicker = undefined
    let saved, input
    try {
      const before = []
      for await (const { sample, to } of timedVideoSamples(
        loaded.image.video.sink,
        0,
        loaded.image.video.duration,
      ))
        before.push([sample.timestamp, to])
      saved = await exportVideo({
        image: loaded.image,
        edit,
        stock: 'gold200',
        session,
        destination: await createVideoDestination('vfr.mp4'),
      })
      input = new Input({
        source: new BlobSource(await (await fetch(saved.url)).blob()),
        formats: ALL_FORMATS,
      })
      const track = await input.getPrimaryVideoTrack(),
        after = []
      for await (const sample of new VideoSampleSink(track).samples()) {
        after.push([sample.timestamp, sample.timestamp + sample.duration])
        sample.close()
      }
      return { before, after, audio: !!(await input.getPrimaryAudioTrack()) }
    } finally {
      await saved?.dispose()
      input?.dispose()
      loaded.image.video.dispose()
      await session.dispose()
    }
  })
  expect(report.audio).toBe(false)
  expect(report.after).toHaveLength(5)
  expect(report.after).toHaveLength(report.before.length)
  report.before.forEach((frame, index) =>
    frame.forEach((time, axis) =>
      expect(report.after[index][axis]).toBeCloseTo(time, 5),
    ),
  )
})

test('HEVC HDR keeps native ten-bit planes and camera highlight headroom', async ({
  page,
}) => {
  await setup(page)
  const report = await page.evaluate(async () => {
    const { importVideo, sampleImage } = await import('/src/video-import.js')
    const loaded = await importVideo(
      new File(
        [await (await fetch('/__video/hdr.mp4')).arrayBuffer()],
        'hdr.mp4',
        { type: 'video/mp4' },
      ),
    )
    try {
      const sample = await loaded.image.video.sink.getSample(0)
      try {
        const linear = await sampleImage(sample, 'appleLog2')
        let peak = 0,
          negative = false
        for (let i = 0; i < linear.linear.data.length; i++)
          if (i % 4 !== 3) {
            peak = Math.max(peak, linear.linear.data[i])
            negative ||= linear.linear.data[i] < 0
          }
        return {
          format: sample.format,
          peak,
          negative,
          width: linear.naturalWidth,
          height: linear.naturalHeight,
        }
      } finally {
        sample.close()
      }
    } finally {
      loaded.image.video.dispose()
    }
  })
  expect(report.format).toMatch(/P10/)
  expect(report.peak).toBeGreaterThan(1)
  expect(report.negative).toBe(true)
  expect(report.width).toBe(96)
  expect(report.height).toBe(64)
})

for (const [filename, depth] of [
  ['hdr.mp4', 10],
  ['hevc-main.mp4', 8],
]) {
  test(`software HEVC ${depth}-bit pixels and B-frame ordering match FFmpeg across GOPs`, async ({
    page,
  }) => {
    await setup(page)
    const pixels = execFileSync('ffmpeg', [
      '-hide_banner',
      '-loglevel',
      'error',
      '-i',
      resolve(fixtures, filename),
      '-f',
      'rawvideo',
      '-pix_fmt',
      depth === 10 ? 'yuv420p10le' : 'yuv420p',
      '-',
    ])
    const bytesPerFrame = 96 * 64 * 1.5 * (depth === 10 ? 2 : 1),
      expected = []
    for (let offset = 0; offset < pixels.length; offset += bytesPerFrame)
      expected.push(
        createHash('sha256')
          .update(pixels.subarray(offset, offset + bytesPerFrame))
          .digest('hex'),
      )
    const report = await page.evaluate(async (filename) => {
      const { registerSoftwareHEVC } = await import('/src/hevc-decoder.js')
      registerSoftwareHEVC()
      const { importVideo } = await import('/src/video-import.js')
      const loaded = await importVideo(
        new File(
          [await (await fetch(`/__video/${filename}`)).arrayBuffer()],
          filename,
          { type: 'video/mp4' },
        ),
      )
      try {
        const frames = []
        for await (const sample of loaded.image.video.sink.samples()) {
          try {
            const bytes = new Uint8Array(sample.allocationSize())
            await sample.copyTo(bytes)
            const digest = await crypto.subtle.digest('SHA-256', bytes)
            frames.push({
              hash: Array.from(new Uint8Array(digest), (n) =>
                n.toString(16).padStart(2, '0'),
              ).join(''),
              timestamp: sample.timestamp,
            })
          } finally {
            sample.close()
          }
        }
        // Random access exercises a decoder started on a later keyframe.
        const sample = await loaded.image.video.sink.getSample(1.75)
        const timestamp = sample.timestamp
        sample.close()
        return { frames, timestamp, duration: loaded.image.video.duration }
      } finally {
        loaded.image.video.dispose()
      }
    }, filename)
    expect(report.frames.map((frame) => frame.hash)).toEqual(expected)
    expect(report.frames).toHaveLength(24)
    report.frames.forEach((frame, index) =>
      expect(frame.timestamp).toBeCloseTo(index / 12, 5),
    )
    expect(report.timestamp).toBeCloseTo(1.75, 5)
    expect(report.duration).toBeCloseTo(2, 5)
  })
}
