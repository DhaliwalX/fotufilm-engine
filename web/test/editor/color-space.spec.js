import { test, expect } from '@playwright/test'
import { writeFile } from 'node:fs/promises'

test('P3 survives input, crop, developed delivery, frames and background PNG/JPEG/WebP encoding', async ({
  page,
}, testInfo) => {
  test.setTimeout(180000)
  await page.goto('/')
  await expect(page.locator('.viewer-status > [role=status]')).toContainText(
    /\d+ × \d+/,
  )
  const report = await page.evaluate(async () => {
    const {
      preferredCanvasColorSpace,
      colorContext,
      pixelsCanvas,
      sourcePixels,
    } = await import('/src/canvas-color.js')
    const { imageSource } = await import('/src/engine.js')
    const { RenderSession } = await import('/src/render-session.js')
    const { defaultEdit } = await import('/src/editor-state.js')
    const { canvasBlob, orientImage, cropImage } = await import(
      '/src/geometry.js'
    )
    const { loadPrintFrame } = await import('/src/print-frame.js')
    const { renderPrintFrame16 } = await import('/src/print-frame-16.js')
    const { exportTiff } = await import('/src/tiff-export.js')
    const width = 120,
      height = 80,
      pixels = new Uint8ClampedArray(width * height * 4)
    for (let i = 0; i < pixels.length; i += 4) pixels.set([0, 220, 0, 255], i)
    const canvas = pixelsCanvas(pixels, width, height, 'display-p3')
    const scene = imageSource(canvas).read(0, 0, 1, 1)
    const encoded = []
    for (const type of ['image/png', 'image/jpeg', 'image/webp']) {
      const blob = await canvasBlob(canvas, type, 1),
        bitmap = await createImageBitmap(blob)
      const check = document.createElement('canvas')
      Object.assign(check, { width, height })
      const ctx = colorContext(check, 'display-p3')
      ctx.drawImage(bitmap, 0, 0)
      bitmap.close()
      encoded.push({
        type,
        sample: Array.from(ctx.getImageData(10, 10, 1, 1).data),
        file: Array.from(new Uint8Array(await blob.arrayBuffer())),
      })
    }
    const edit = {
      ...defaultEdit(),
      rotation: 1,
      crop: [
        [0.25, 0.25],
        [0.75, 0.25],
        [0.75, 0.75],
        [0.25, 0.75],
      ],
    }
    const oriented = orientImage(canvas, edit),
      cropped = await cropImage(oriented, edit)
    const sample = sourcePixels(cropped.getContext('2d'), 0, 0, 1, 1)
    const session = new RenderSession()
    try {
      const bitmap = await createImageBitmap(await canvasBlob(canvas))
      const rendered = await session.render({
        image: bitmap,
        edit,
        stock: 'gold200',
        comparison: false,
        bitDepth: 16,
        maxEdge: Infinity,
      })
      bitmap.close()
      const plain = rendered.pixels.slice()
      const plan = await loadPrintFrame(
        { ...edit, printFrame: 'mount' },
        rendered.width,
        rendered.height,
      )
      const framed = await renderPrintFrame16(
        rendered.pixels,
        rendered.width,
        rendered.height,
        plan,
        () => false,
        rendered.colorSpace,
      )
      const r = plan.placement.image,
        top = framed.height - r.y - r.height
      const interior = framed.pixels.slice(
        (top * framed.width + r.x) * 4,
        (top * framed.width + r.x) * 4 + 4,
      )
      const tiff = await exportTiff(framed)
      return {
        space: preferredCanvasColorSpace(),
        scene: Array.from(scene),
        encoded,
        crop: {
          width: cropped.width,
          height: cropped.height,
          space: sample.colorSpace,
          pixel: Array.from(sample.data),
          type: sample.data.constructor.name,
        },
        output: {
          space: rendered.colorSpace,
          width: rendered.width,
          height: rendered.height,
          pixel: Array.from(plain.slice(0, 4)),
          interior: Array.from(interior),
        },
        tiff: Array.from(new Uint8Array(await tiff.arrayBuffer())),
      }
    } finally {
      session.dispose()
    }
  })
  expect(report.space).toBe('display-p3')
  expect(report.crop.space).toBe('display-p3')
  expect([report.crop.width, report.crop.height]).toEqual([40, 60])
  expect(report.crop.type).toBe('Float16Array')
  expect(report.scene[0]).toBeGreaterThan(0)
  for (const item of report.encoded) {
    expect(Math.abs(item.sample[0]), item.type).toBeLessThanOrEqual(2)
    expect(Math.abs(item.sample[1] - 220), item.type).toBeLessThanOrEqual(2)
    expect(Math.abs(item.sample[2]), item.type).toBeLessThanOrEqual(2)
    await writeFile(
      testInfo.outputPath(`p3.${item.type.split('/')[1]}`),
      Buffer.from(item.file),
    )
  }
  expect(report.output.space).toBe('display-p3')
  expect([report.output.width, report.output.height]).toEqual([40, 60])
  expect(report.output.pixel[0]).toBeLessThan(100)
  expect(report.output.pixel[2]).toBeLessThan(100)
  expect(report.output.interior).toEqual(report.output.pixel)
  await writeFile(testInfo.outputPath('p3.tiff'), Buffer.from(report.tiff))
})

test('sRGB canvas fallback stays correctly tagged while TIFF still carries P3', async ({
  page,
}) => {
  await page.addInitScript(() => {
    for (const proto of [
      HTMLCanvasElement.prototype,
      OffscreenCanvas.prototype,
    ]) {
      const native = proto.getContext
      proto.getContext = function (type, options) {
        return native.call(
          this,
          type,
          options
            ? { ...options, colorSpace: 'srgb', colorType: 'unorm8' }
            : options,
        )
      }
    }
  })
  await page.goto('/')
  await expect(page.locator('.viewer-status > [role=status]')).toContainText(
    /\d+ × \d+/,
  )
  const report = await page.evaluate(async () => {
    const { preferredCanvasColorSpace } = await import('/src/canvas-color.js')
    const { RenderSession } = await import('/src/render-session.js')
    const { LinearImage } = await import('/src/linear-image.js')
    const { defaultEdit } = await import('/src/editor-state.js')
    const session = new RenderSession(),
      image = new LinearImage({
        width: 1,
        height: 1,
        pixels: new Float32Array([0.2, 0.4, 0.3, 1]),
      })
    try {
      const args = {
        image,
        edit: defaultEdit(),
        stock: 'gold200',
        comparison: false,
      }
      const preview = await session.render(args),
        tiff = await session.render({ ...args, bitDepth: 16 })
      return {
        preferred: preferredCanvasColorSpace(),
        preview: preview.colorSpace,
        tiff: tiff.colorSpace,
        bits: tiff.pixels.BYTES_PER_ELEMENT * 8,
      }
    } finally {
      session.dispose()
    }
  })
  expect(report).toEqual({
    preferred: 'srgb',
    preview: 'srgb',
    tiff: 'display-p3',
    bits: 16,
  })
})

test('GPU and CPU deliver the same 16-bit P3 print samples', async ({
  page,
}) => {
  await page.goto('/')
  await expect(page.locator('.viewer-status > [role=status]')).toContainText(
    /\d+ × \d+/,
  )
  const report = await page.evaluate(async () => {
    const { createBackgroundDeveloper } = await import(
      '/src/background-developer.js'
    )
    const { createCpuDeveloper, normalPack, pixelSource } = await import(
      '/src/engine.js'
    )
    const { defaultEdit } = await import('/src/editor-state.js')
    const gpu = await createBackgroundDeveloper(null),
      cpu = await createCpuDeveloper(normalPack())
    const width = 256,
      height = 32,
      data = new Float32Array(width * height * 4)
    for (let i = 0; i < data.length; i += 4)
      data.set(
        [
          0.01 + (i % 101) / 105,
          0.01 + (i % 103) / 107,
          0.01 + (i % 97) / 99,
          1,
        ],
        i,
      )
    const source = pixelSource({ data, width, height }),
      options = { bitDepth: 16, colorSpace: 'display-p3' }
    try {
      await gpu.gpuReady
      const a = await gpu.develop(
        source,
        defaultEdit().params,
        () => {},
        () => false,
        options,
      )
      const b = await cpu.develop(
        source,
        defaultEdit().params,
        () => {},
        () => false,
        options,
      )
      let peak = 0
      for (let i = 0; i < a.pixels.length; i++)
        peak = Math.max(peak, Math.abs(a.pixels[i] - b.pixels[i]))
      return {
        backend: gpu.backend,
        bits: a.pixels.BYTES_PER_ELEMENT * 8,
        peak,
      }
    } finally {
      gpu.dispose()
      cpu.dispose()
    }
  })
  expect(report.backend).toBe('webgpu')
  expect(report.bits).toBe(16)
  expect(report.peak).toBeLessThanOrEqual(2)
})

test('a real 16-bit PNG retains more than 8-bit detail through orientation and crop', async ({
  page,
}) => {
  const { deflateSync } = await import('node:zlib')
  const { iccProfile } = await import('../../src/color-profiles.js')
  const chunk = (type, data) => {
    const tag = Buffer.from(type),
      contents = Buffer.concat([tag, data])
    let crc = 0xffffffff
    for (const byte of contents) {
      crc ^= byte
      for (let bit = 0; bit < 8; bit++)
        crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0)
    }
    const header = Buffer.alloc(4),
      tail = Buffer.alloc(4)
    header.writeUInt32BE(data.length)
    tail.writeUInt32BE((crc ^ 0xffffffff) >>> 0)
    return Buffer.concat([header, contents, tail])
  }
  const width = 1024,
    header = Buffer.alloc(13),
    samples = Buffer.alloc(1 + width * 8)
  header.writeUInt32BE(width)
  header.writeUInt32BE(1, 4)
  header[8] = 16
  header[9] = 6
  for (let x = 0; x < width; x++) {
    for (let c = 0; c < 3; c++)
      samples.writeUInt16BE(12000 + 20 * x, 1 + x * 8 + c * 2)
    samples.writeUInt16BE(65535, 1 + x * 8 + 6)
  }
  const bytes = Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk('IHDR', header),
    chunk(
      'iCCP',
      Buffer.concat([
        Buffer.from('Display P3\0\0'),
        deflateSync(iccProfile('display-p3')),
      ]),
    ),
    chunk('IDAT', deflateSync(samples)),
    chunk('IEND', Buffer.alloc(0)),
  ])
  await page.goto('/')
  await expect(page.locator('.viewer-status > [role=status]')).toContainText(
    /\d+ × \d+/,
  )
  const result = await page.evaluate(async (bytes) => {
    const { importPhoto } = await import('/src/photo-import.js')
    const { rawSource } = await import('/src/raw-source.js')
    const { defaultEdit } = await import('/src/editor-state.js')
    const { image, url } = await importPhoto(
      new File([new Uint8Array(bytes)], 'Deep gradient.png', {
        type: 'image/png',
      }),
    )
    try {
      const edit = {
        ...defaultEdit(),
        rotation: 1,
        crop: [
          [0, 0.1],
          [1, 0.1],
          [1, 0.9],
          [0, 0.9],
        ],
      }
      const source = rawSource(image, edit),
        data = source.read(0, 0, source.width, source.height)
      return {
        count: new Set(Array.from(data).filter((_, i) => i % 4 === 0)).size,
        width: source.width,
        height: source.height,
        bits: image.deep?.bitDepth,
        first: image.linear.data[0],
        last: image.linear.data[(image.naturalWidth - 1) * 4],
      }
    } finally {
      URL.revokeObjectURL(url)
    }
  }, Array.from(bytes))
  expect(result.width).toBe(1)
  expect(result.height).toBe(819)
  expect(result.count).toBeGreaterThan(700)
  expect(result.bits).toBe(16)
  const decode = v => ((v + 0.055) / 1.055) ** 2.4
  expect(result.first).toBeCloseTo(decode(12000 / 65535), 4)
  expect(result.last).toBeCloseTo(decode((12000 + 20 * 1023) / 65535), 4)
})
