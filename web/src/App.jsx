import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { Button } from '@astryxdesign/core/Button'
import { Slider } from '@astryxdesign/core/Slider'
import { Switch } from '@astryxdesign/core/Switch'
import BlendIcon from 'reicon-react/icons/Blend'
import DownloadIcon from 'reicon-react/icons/Download'
import FlaskIcon from 'reicon-react/icons/Flask'
import GalleryAddIcon from 'reicon-react/icons/GalleryAdd'
import LoaderIcon from 'reicon-react/icons/Loader'
import UploadIcon from 'reicon-react/icons/Upload'
import WarningIcon from 'reicon-react/icons/Warning'
import { assetUrl, createDeveloper, loadPack, loadStages } from './engine.js'
import appIconUrl from './assets/app-icon.png'

// Include only controls that directly update configuration slots. Halation and coupler range
// require exporting a new pack because they reshape model data.
const SLIDERS = [
  { key: 'ev', label: 'Exposure', unit: 'ev', min: -3, max: 3, step: 0.25, def: 0 },
  { key: 'grain', label: 'Grain', unit: '×', min: 0, max: 2.5, step: 0.05, def: 1 },
  { key: 'highlights', label: 'Highlights', unit: '', min: -1, max: 1, step: 0.05, def: 0 },
  { key: 'shadows', label: 'Shadows', unit: '', min: -1, max: 1, step: 0.05, def: 0 },
  { key: 'saturation', label: 'Saturation', unit: '×', min: 0, max: 2, step: 0.05, def: 1 },
  { key: 'vibrance', label: 'Vibrance', unit: '', min: -1, max: 1, step: 0.05, def: 0 },
]

/// The engine is WebAssembly and nothing else, so a browser without it cannot develop anything.
/// Rather than offer controls that would do nothing, such a browser is shown the pipeline already
/// developed — the same scene through the same stages, rendered by the CLI and shipped as pictures.
const HAS_WASM = typeof WebAssembly === 'object' &&
  typeof WebAssembly.instantiate === 'function'

/// What the demo opens on: a hue sweep, a neutral ramp two stops over mid grey, and a
/// hue/saturation wheel, on black. Every stage of the pipeline has something to act on here —
/// flare has black to lift, halation has a bright edge to bloom off, the couplers have saturated
/// colour to inhibit — which a photograph will not reliably give you.
const DEFAULT_SCENE = 'fotufilm_tagline.png'

async function loadJson(url, missingMessage) {
  const response = await fetch(url)
  const contentType = response.headers.get('content-type') || ''
  if (!response.ok || !contentType.includes('application/json')) {
    throw new Error(missingMessage)
  }
  return response.json()
}

const STOCK_NOTES = {
  'example-monochrome-100': 'panchromatic B&W · example calibration',
  'example-negative-400': 'colour negative · example calibration',
  kodachrome25: 'reversal · the slowest, finest Kodachrome',
  kodachrome64: 'reversal · the classic slide',
  kodachrome200: 'reversal · the fast one, grain and all',
  pro160ns: 'colour negative · soft, neutral skin',
  pro400h: 'colour negative · cool & airy · fine grain',
}

const STAGE_NAMES = {
  '01-bypassed': 'Bypass',
  '02-exposure': 'Exposure',
  '03-flare': 'Flare',
  '04-diffusion': 'Diffusion',
  '05-halation': 'Halation',
  '06-couplers': 'Couplers',
  '07-development': 'H&D curve',
  '08-grain': 'Grain',
  '09-negative': 'Negative',
  '10-print': 'Output',
}

function stageName(stage) {
  return STAGE_NAMES[stage.id] || stage.label.replace(/^Stage \d+( input)? — /, '')
}

function PanelTitle({ eyebrow, title, detail }) {
  return (
    <div className="panel-title">
      <div>
        <span className="eyebrow">{eyebrow}</span>
        <h2>{title}</h2>
      </div>
      {detail && <span className="panel-detail">{detail}</span>}
    </div>
  )
}

function PipelineSteps({ stages, stageIndex, setStageIndex, disabled, includePrint = true }) {
  const sequence = includePrint
    ? [{ id: '#print', label: 'Finished print' }, ...stages]
    : stages

  return (
    <div className="stage-grid" style={{ '--stage-count': sequence.length }}>
      {sequence.map((item, i) => {
        const itemIndex = includePrint ? i - 1 : i
        const isPrint = includePrint && i === 0
        const selected = isPrint ? stageIndex == null : itemIndex === stageIndex
        return (
          <button
            key={item.id}
            className={`stage-step ${selected ? 'selected' : ''}`}
            onClick={() => setStageIndex(isPrint ? null : itemIndex)}
            disabled={disabled}
            title={item.label}
            aria-pressed={selected}
          >
            <span className="stage-number">{isPrint ? 'P' : String(i).padStart(2, '0')}</span>
            <span className="stage-name">{isPrint ? 'Print' : stageName(item)}</span>
          </button>
        )
      })}
    </div>
  )
}

/// Fits an image within the pack's fixed frame without enlarging it. Fill margins with a blurred,
/// cover-scaled copy instead of black so whole-frame flare and edge halation remain representative.
/// `frame` identifies the source region to crop from the developed result.
function fitToPack(image, width, height) {
  const canvas = document.createElement('canvas')
  canvas.width = width
  canvas.height = height
  const context = canvas.getContext('2d', { willReadFrequently: true })

  const contain = Math.min(1, width / image.width, height / image.height)
  const drawWidth = Math.round(image.width * contain)
  const drawHeight = Math.round(image.height * contain)
  const x = Math.round((width - drawWidth) / 2)
  const y = Math.round((height - drawHeight) / 2)

  if (drawWidth < width || drawHeight < height) {
    const cover = Math.max(width / image.width, height / image.height)
    context.filter = `blur(${Math.round(Math.min(width, height) / 24)}px)`
    context.drawImage(image, (width - image.width * cover) / 2,
                      (height - image.height * cover) / 2,
                      image.width * cover, image.height * cover)
    context.filter = 'none'
  }
  context.drawImage(image, x, y, drawWidth, drawHeight)

  return {
    data: context.getImageData(0, 0, width, height).data,
    frame: { x, y, width: drawWidth, height: drawHeight },
  }
}

/// What one stage added, drawn on its own.
///
/// Most stages move the print by a fraction of a code value — halation is a glow a few counts deep
/// around a highlight, adjacency is a line one pixel wide — and side by side the two frames look
/// identical. So the difference is amplified until its largest excursion just reaches the end of
/// the scale, and drawn around mid grey: lighter where the stage added, darker where it took away.
/// The gain is reported with it, because an amplified difference means nothing without one.
/// `crop` is the photograph's own rectangle within the frame: the gain is set by the largest
/// change inside it, so what happens out in the fill — which is never shown — cannot flatten it.
function differenceFrame(after, before, width, crop) {
  let peak = 0
  for (let y = crop.y; y < crop.y + crop.height; ++y) {
    for (let x = crop.x; x < crop.x + crop.width; ++x) {
      const i = (y * width + x) * 4
      for (let c = 0; c < 3; ++c) peak = Math.max(peak, Math.abs(after[i + c] - before[i + c]))
    }
  }
  // Use neutral grey when the stage produces no measurable difference.
  const gain = peak < 0.5 ? 1 : Math.min(128, 127 / peak)
  const pixels = new Uint8ClampedArray(after.length)
  for (let i = 0; i < after.length; i += 4) {
    for (let c = 0; c < 3; ++c) pixels[i + c] = 128 + (after[i + c] - before[i + c]) * gain
    pixels[i + 3] = 255
  }
  return { pixels, gain, peak }
}

/// A PNG blob URL for one developed frame, cut back to the rectangle the photograph landed in.
async function frameUrl(pixels, width, height, crop) {
  const canvas = document.createElement('canvas')
  canvas.width = crop.width
  canvas.height = crop.height
  // Negative offsets: the surrounding fill is drawn outside the canvas and clipped away.
  canvas.getContext('2d').putImageData(new ImageData(pixels, width, height), -crop.x, -crop.y)
  const blob = await new Promise((resolve) => canvas.toBlob(resolve, 'image/png'))
  return URL.createObjectURL(blob)
}

const ZOOM_MIN = 1
const ZOOM_MAX = 4
const ZOOM_STEP = 0.25

/// The image stays at its natural aspect ratio while the surface handles inspection. The film
/// engine only renders one frame at a time, so zooming here is deliberately display-only: it does
/// not re-run the pipeline or change the exported pixels.
function ZoomableImage({ src, alt }) {
  const [zoom, setZoom] = useState(ZOOM_MIN)
  const [offset, setOffset] = useState({ x: 0, y: 0 })
  const [dragging, setDragging] = useState(false)
  const dragRef = useRef(null)

  useEffect(() => {
    setZoom(ZOOM_MIN)
    setOffset({ x: 0, y: 0 })
  }, [src])

  const setZoomLevel = useCallback((next) => {
    const level = Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, next))
    setZoom(level)
    if (level === ZOOM_MIN) setOffset({ x: 0, y: 0 })
  }, [])

  const reset = useCallback(() => {
    setZoom(ZOOM_MIN)
    setOffset({ x: 0, y: 0 })
  }, [])

  const onPointerDown = (event) => {
    if (zoom === ZOOM_MIN) return
    event.currentTarget.setPointerCapture(event.pointerId)
    dragRef.current = { x: event.clientX, y: event.clientY, offset }
    setDragging(true)
  }

  const onPointerMove = (event) => {
    const drag = dragRef.current
    if (!drag) return
    setOffset({
      x: drag.offset.x + event.clientX - drag.x,
      y: drag.offset.y + event.clientY - drag.y,
    })
  }

  const endPointerDrag = (event) => {
    if (dragRef.current && event.currentTarget.hasPointerCapture(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId)
    }
    dragRef.current = null
    setDragging(false)
  }

  const onWheel = (event) => {
    event.preventDefault()
    setZoomLevel(zoom + (event.deltaY < 0 ? ZOOM_STEP : -ZOOM_STEP))
  }

  const onKeyDown = (event) => {
    if (event.key === '+' || event.key === '=') {
      event.preventDefault()
      setZoomLevel(zoom + ZOOM_STEP)
    } else if (event.key === '-' || event.key === '_') {
      event.preventDefault()
      setZoomLevel(zoom - ZOOM_STEP)
    } else if (event.key === '0') {
      event.preventDefault()
      reset()
    }
  }

  return (
    <div
      className={`zoom-surface ${zoom > ZOOM_MIN ? 'is-zoomed' : ''} ${dragging ? 'is-panning' : ''}`}
      onWheel={onWheel}
      onDoubleClick={() => setZoomLevel(zoom === ZOOM_MIN ? 2 : ZOOM_MIN)}
      onKeyDown={onKeyDown}
      tabIndex={0}
      aria-label="Image inspection surface. Use the mouse wheel or controls to zoom, and drag when zoomed in."
    >
      <img
        className="zoom-image"
        src={src}
        alt={alt}
        draggable="false"
        style={{ transform: `translate(${offset.x}px, ${offset.y}px) scale(${zoom})` }}
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={endPointerDrag}
        onPointerCancel={endPointerDrag}
      />
      <div className="zoom-controls" aria-label="Image zoom controls">
        <button
          type="button"
          onClick={() => setZoomLevel(zoom - ZOOM_STEP)}
          disabled={zoom === ZOOM_MIN}
          aria-label="Zoom out"
          title="Zoom out"
        >
          −
        </button>
        <output aria-live="polite">{Math.round(zoom * 100)}%</output>
        <button
          type="button"
          onClick={() => setZoomLevel(zoom + ZOOM_STEP)}
          disabled={zoom === ZOOM_MAX}
          aria-label="Zoom in"
          title="Zoom in"
        >
          +
        </button>
        <button
          type="button"
          className="zoom-reset"
          onClick={reset}
          disabled={zoom === ZOOM_MIN && offset.x === 0 && offset.y === 0}
          aria-label="Reset zoom"
          title="Reset zoom"
        >
          Reset
        </button>
      </div>
    </div>
  )
}

/// What a browser with no WebAssembly gets: the same pipeline, already developed.
///
/// There is no engine to run here and so nothing to upload a photograph to — offering the upload
/// anyway would be offering a button that cannot work. The frames come from the same
/// `fotufilm --stages` run the working demo reproduces in the tab, through one stock, and the
/// difference view is the one the CLI amplified when it wrote them.
function StaticPipeline() {
  const [index, setIndex] = useState(null)
  const [at, setAt] = useState(0)
  const [showDelta, setShowDelta] = useState(false)
  const [error, setError] = useState(null)

  useEffect(() => {
    loadJson(assetUrl('fallback/index.json'), 'no rendered pipeline to fall back to')
      .then(setIndex)
      .catch((e) => setError(e.message))
  }, [])

  const stage = index?.stages[at]
  const file = stage && showDelta && stage.delta ? stage.delta : stage?.file

  return (
    <div className="studio-shell">
      <AppHeader backend="Preview" />
      <main className="workspace static-workspace">
        <aside className="control-panel panel">
          <PanelTitle eyebrow="About" title="Rendered preview" />
          <div className="fallback-message">
            <WarningIcon aria-hidden="true" />
            <p>
              This browser cannot run WebAssembly, so this is a pre-rendered {index?.name || 'film'}
              pipeline. Every stage is still available to inspect.
            </p>
          </div>
        </aside>

        <section className="viewer panel">
          {file ? (
            <figure className="image-frame">
              <div className="image-stage">
                <ZoomableImage src={assetUrl(`fallback/${file}`)} alt={stage.label} />
              </div>
              <figcaption className="viewer-bar">
                <span className="viewer-label">
                  {showDelta && stage.delta ? `Difference · ${stageName(stage)}` : stageName(stage)}
                </span>
              </figcaption>
            </figure>
          ) : (
            <div className="loading-state">
              {error ? <WarningIcon /> : <LoaderIcon className="spin" />}
              <p>{error ? 'Nothing to show' : 'Loading preview'}</p>
            </div>
          )}
        </section>

        <aside className="pipeline-panel panel">
          <PanelTitle eyebrow="Pipeline" title="All stages" detail={`${index?.stages.length || 0} steps`} />
          <PipelineSteps
            stages={index?.stages || []}
            stageIndex={at}
            setStageIndex={setAt}
            disabled={!index}
            includePrint={false}
          />
          <Switch
            className="delta-switch"
            label="Show stage difference"
            labelPosition="start"
            labelSpacing="spread"
            size="sm"
            value={showDelta}
            onChange={setShowDelta}
            isDisabled={!stage?.delta}
            width="100%"
          />
        </aside>
      </main>
      <p className="pipeline-note">Film profiles © 2026 MUAStudio Inc. · <a href={assetUrl('packs/FILM-PROFILES.txt')}>CC BY-SA 4.0</a></p>
    </div>
  )
}

function AppHeader({ backend, developing = false, onUpload }) {
  return (
    <header className="app-header">
      <div className="brand-mark" aria-hidden="true">
        <img src={appIconUrl} alt="" />
      </div>
      <div className="brand-copy">
        <h1>fotufilm</h1>
        <p>Physical film development</p>
      </div>
      <div className="engine-pill">
        <span className={`engine-dot ${developing ? 'active' : ''}`} />
        {developing ? 'Developing' : backend || 'Starting'}
      </div>
      {onUpload && (
        <Button
          className="header-upload"
          label="Open image"
          size="md"
          variant="secondary"
          icon={<UploadIcon aria-hidden="true" />}
          isIconOnly
          tooltip="Open image"
          onClick={onUpload}
        />
      )}
    </header>
  )
}

export default function App() {
  const [stocks, setStocks] = useState([])
  const [stock, setStock] = useState(null)
  const [params, setParams] = useState(Object.fromEntries(SLIDERS.map((s) => [s.key, s.def])))
  const [source, setSource] = useState(null)
  const [originalUrl, setOriginalUrl] = useState(null)
  const [resultUrl, setResultUrl] = useState(null)
  // Stock used for the displayed print; selection may change before the next develop completes.
  const [printedStock, setPrintedStock] = useState(null)
  const [developing, setDeveloping] = useState(false)
  const [status, setStatus] = useState('starting the engine…')
  const [error, setError] = useState(null)
  const [elapsed, setElapsed] = useState(null)
  const [showOriginal, setShowOriginal] = useState(false)
  const [dragOver, setDragOver] = useState(false)
  const [backend, setBackend] = useState(null)
  // The pipeline walk. `stages` are the packs the sidecar describes, in the order the light meets
  // them; the last of them is the finished print, which is why it doubles as the ordinary result.
  const [stages, setStages] = useState([])
  const [stageIndex, setStageIndex] = useState(null)
  const [showDelta, setShowDelta] = useState(false)
  const [delta, setDelta] = useState(null)
  const inputRef = useRef(null)
  const developerRef = useRef(null)
  // The finished film, kept apart from the stages so the print can still be developed by a stock
  // that has no sidecar.
  const basePackRef = useRef(null)
  // Developed frames, by stage id. Walking back and forth through the pipeline should not
  // re-develop what has already been developed, and the difference view needs the frame before
  // this one as pixels rather than as a picture on screen.
  const framesRef = useRef(new Map())
  const framesKeyRef = useRef(null)

  // Load the default scene only if the user has not selected an image while it was fetching.
  useEffect(() => {
    if (!HAS_WASM) return
    const url = assetUrl(DEFAULT_SCENE)
    const image = new Image()
    image.onload = () => {
      setSource((current) => current ?? image)
      setOriginalUrl((current) => current ?? url)
    }
    image.onerror = () => console.warn('no default scene at', url)
    image.src = url
  }, [])

  useEffect(() => {
    if (!HAS_WASM) return
    let cancelled = false
    loadJson(assetUrl('packs/index.json'), 'no packs — run tools/build-wasm.sh')
      .then((index) => {
        if (cancelled) return
        setStocks(index)
        setStock((current) => current ?? index[0]?.id ?? null)
        setStatus(null)
      })
      .catch((e) => {
        if (!cancelled) {
          setError(e.message)
          setStatus(null)
        }
      })
    return () => {
      cancelled = true
    }
  }, [])

  // Keep one developer per stock to retain WASM buffers and the 5 MB spectral cube. Kernel loading
  // also determines whether that stock can use the GPU path.
  useEffect(() => {
    if (!stock || !HAS_WASM) return
    let cancelled = false
    setStatus(`loading ${stock}…`)
    loadPack(assetUrl(`packs/${stock}.pack`))
      .then(async (pack) => {
        // The sidecar is the optional half: without it the demo is still a darkroom, just one
        // that cannot be taken apart. A stock exported before it existed should not fail to load.
        const sequence = await loadStages(assetUrl(`packs/${stock}.stages`), pack)
          .catch((e) => {
            console.warn(`no pipeline stages for ${stock}:`, e.message)
            return []
          })
        return { pack, developer: await createDeveloper(pack), sequence }
      })
      .then(({ pack, developer, sequence }) => {
        if (cancelled) {
          developer.dispose()
          return
        }
        developerRef.current?.dispose()
        developerRef.current = developer
        basePackRef.current = pack
        setStages(sequence)
        setStageIndex(null)
        setBackend(developer.backend)
        setStatus(null)
        setError(null)
      })
      .catch((e) => {
        if (!cancelled) {
          setError(e.message)
          setStatus(null)
        }
      })
    return () => {
      cancelled = true
    }
  }, [stock])

  // Everything a developed frame depends on. When it changes the cache is stale by definition,
  // and the walk starts again from whatever is developed next.
  const frameKey = useMemo(
    () => `${stock}|${originalUrl}|${SLIDERS.map((s) => params[s.key]).join(',')}`,
    [stock, originalUrl, params])

  const acceptFile = useCallback((file) => {
    if (!file || !file.type.startsWith('image/')) return
    setError(null)
    const url = URL.createObjectURL(file)
    const image = new Image()
    image.onload = () => {
      setSource(image)
      setOriginalUrl((old) => {
        // The default scene is a file on the server, not a blob, and outlives every upload.
        if (old?.startsWith('blob:')) URL.revokeObjectURL(old)
        return url
      })
      setResultUrl(null)
      setDelta(null)
    }
    image.onerror = () => setError('could not decode that image')
    image.src = url
  }, [])

  /// One developed frame, kept. The cache is keyed by stage because the walk goes back and forth
  /// and because the difference view needs the frame before this one as pixels.
  const frameFor = useCallback(async (developer, fitted, index) => {
    // The last stage is the film with nothing switched off, so it and the plain print are the same
    // frame; sharing the entry keeps the walk from developing it twice.
    const at = index == null && stages.length > 0 ? stages.length - 1 : index
    const id = at == null ? '#print' : stages[at].id
    const cached = framesRef.current.get(id)
    if (cached) return cached
    developer.usePack(at == null ? basePackRef.current : stages[at])
    const { pixels, elapsed: ms } = await developer.develop(fitted.data, params)
    const url = await frameUrl(pixels, developer.width, developer.height, fitted.frame)
    const entry = { pixels, url, ms }
    framesRef.current.set(id, entry)
    return entry
  }, [stages, params])

  const developView = useCallback(async (index) => {
    const developer = developerRef.current
    if (!source || !developer || developing) return
    setDeveloping(true)
    setError(null)
    try {
      if (framesKeyRef.current !== frameKey) {
        for (const entry of framesRef.current.values()) URL.revokeObjectURL(entry.url)
        framesRef.current.clear()
        framesKeyRef.current = frameKey
      }
      const fitted = fitToPack(source, developer.width, developer.height)
      // Yield before synchronous conversion or CPU development so the browser can paint status.
      // Use a timeout because background tabs do not receive animation frames.
      await new Promise((resolve) => setTimeout(resolve, 32))

      const entry = await frameFor(developer, fitted, index)
      setResultUrl(entry.url)
      setElapsed(entry.ms)
      setPrintedStock(stock)

      // The first stage has nothing before it to differ from: it is the whole pipeline switched
      // off, which is the baseline rather than a step.
      if (showDelta && index != null && index > 0) {
        const id = `${stages[index].id}#delta`
        let difference = framesRef.current.get(id)
        if (!difference) {
          const before = await frameFor(developer, fitted, index - 1)
          const shown = differenceFrame(entry.pixels, before.pixels,
                                       developer.width, fitted.frame)
          difference = {
            ...shown,
            url: await frameUrl(shown.pixels, developer.width, developer.height, fitted.frame),
          }
          framesRef.current.set(id, difference)
        }
        setDelta(difference)
      } else {
        setDelta(null)
      }
    } catch (e) {
      setError(e.message)
    } finally {
      setDeveloping(false)
    }
  }, [source, developing, params, stock, frameKey, frameFor, showDelta, stages])

  // Stepping through the pipeline, or turning the difference on, re-develops on its own: the
  // frames are usually cached by then, so it costs a canvas rather than a kernel run. Only once
  // something has been developed at these settings, though — before that the button is the way in.
  useEffect(() => {
    if (framesKeyRef.current === frameKey && framesRef.current.size > 0) developView(stageIndex)
    // developView changes identity on every develop; following it here would loop.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [stageIndex, showDelta, frameKey])

  const onDrop = (e) => {
    e.preventDefault()
    setDragOver(false)
    acceptFile(e.dataTransfer.files?.[0])
  }

  // Every hook above has run, so this is a stable branch: HAS_WASM is fixed for the session.
  if (!HAS_WASM) return <StaticPipeline />

  const stage = stageIndex == null ? null : stages[stageIndex]
  const shownUrl = showOriginal
    ? originalUrl
    : (delta ? delta.url : resultUrl) || originalUrl
  const shownLabel = !originalUrl
    ? null
    : showOriginal || !resultUrl
      ? 'source · digital'
      : delta
        ? `what ${stage.label} added · ×${delta.gain.toFixed(1)}`
        : stage
          ? `${stage.label} · ${printedStock}`
          : `print · ${printedStock}`

  const selectedStock = stocks.find((item) => item.id === stock)
  const backendLabel = backend === 'webgpu'
    ? 'WebGPU'
    : backend === 'simd'
      ? 'WASM · SIMD'
      : backend
        ? 'WebAssembly'
        : null

  return (
    <div className={`studio-shell ${developing ? 'is-developing' : ''}`}>
      <AppHeader
        backend={backendLabel}
        developing={developing}
        onUpload={() => inputRef.current?.click()}
      />

      <main className="workspace">
        <aside className="control-panel panel">
          <PanelTitle eyebrow="Film setup" title="Build the look" detail="7 controls" />

          <label className="stock-field">
            <span>Film stock</span>
            <select value={stock || ''} onChange={(event) => setStock(event.target.value)}>
              {stocks.map((item) => (
                <option key={item.id} value={item.id}>{item.name}</option>
              ))}
            </select>
            <small>{STOCK_NOTES[stock] || selectedStock?.name || 'Loading stock library'}</small>
          </label>

          <div className="adjustment-grid">
            {SLIDERS.map((slider) => {
              const signed = ['ev', 'highlights', 'shadows', 'vibrance'].includes(slider.key)
              const value = params[slider.key]
              return (
                <div className="adjustment" key={slider.key}>
                  <div className="adjustment-label">
                    <span>{slider.label}</span>
                    <output>
                      {signed && value > 0 ? '+' : ''}{Number(value).toFixed(2)}{slider.unit ? ` ${slider.unit}` : ''}
                    </output>
                  </div>
                  <Slider
                    className="compact-slider"
                    label={slider.label}
                    isLabelHidden
                    valueDisplay="none"
                    min={slider.min}
                    max={slider.max}
                    step={slider.step}
                    value={value}
                    onChange={(nextValue) =>
                      setParams((current) => ({ ...current, [slider.key]: nextValue }))
                    }
                    width="100%"
                  />
                </div>
              )
            })}
          </div>

          <div className="develop-block">
            <Button
              className="develop-button"
              label={developing ? 'Developing image' : 'Develop print'}
              variant="primary"
              size="lg"
              icon={developing
                ? <LoaderIcon className="spin" aria-hidden="true" />
                : <FlaskIcon aria-hidden="true" />}
              width="100%"
              onClick={() => {
                setStageIndex(null)
                developView(null)
              }}
              isDisabled={!source || developing || !!status}
            />
            <div className="process-status" role="status">
              {error ? (
                <span className="error"><WarningIcon /> {error}</span>
              ) : status ? (
                <span>{status}</span>
              ) : elapsed != null ? (
                <span>{elapsed.toFixed(0)} ms · {selectedStock?.name || printedStock}</span>
              ) : (
                <span>Ready to develop</span>
              )}
            </div>
          </div>
        </aside>

        <section
          className={`viewer panel ${dragOver ? 'drag' : ''}`}
          onDragOver={(event) => {
            event.preventDefault()
            setDragOver(true)
          }}
          onDragLeave={() => setDragOver(false)}
          onDrop={onDrop}
          onClick={() => !originalUrl && inputRef.current?.click()}
        >
          {shownUrl ? (
            <figure className="image-frame">
              <div className="image-stage">
                <ZoomableImage src={shownUrl} alt="fotufilm preview" />
                {developing && (
                  <div className="developing-overlay">
                    <LoaderIcon className="spin" />
                    <span>Developing</span>
                  </div>
                )}
              </div>
              <figcaption className="viewer-bar">
                <span className="viewer-label">{shownLabel}</span>
                {developer && <span className="viewer-resolution">{developer.width} × {developer.height}px process</span>}
                <div className="viewer-actions">
                  {resultUrl && (
                    <button
                      className="icon-action compare-action"
                      onPointerDown={() => setShowOriginal(true)}
                      onPointerUp={() => setShowOriginal(false)}
                      onPointerCancel={() => setShowOriginal(false)}
                      onPointerLeave={() => setShowOriginal(false)}
                      title="Hold to compare with the source"
                      aria-label="Hold to compare with the source"
                    >
                      <BlendIcon />
                      <span>Compare</span>
                    </button>
                  )}
                  <button
                    className="icon-action"
                    onClick={(event) => {
                      event.stopPropagation()
                      inputRef.current?.click()
                    }}
                    title="Open a new image"
                  >
                    <GalleryAddIcon />
                    <span>Replace</span>
                  </button>
                  {resultUrl && (
                    <a
                      className="icon-action"
                      href={shownUrl}
                      download={`fotufilm-${printedStock}-${stage ? stage.id : 'print'}.png`}
                      title="Download current image"
                    >
                      <DownloadIcon />
                      <span>Export</span>
                    </a>
                  )}
                </div>
              </figcaption>
            </figure>
          ) : (
            <div className="upload-state">
              <div className="upload-icon"><GalleryAddIcon /></div>
              <h2>Open a digital negative</h2>
              <p>Drop an image here or choose a JPEG, PNG, or WebP file.</p>
              <Button
                label="Choose image"
                variant="primary"
                icon={<UploadIcon aria-hidden="true" />}
                onClick={(event) => {
                  event.stopPropagation()
                  inputRef.current?.click()
                }}
              />
            </div>
          )}
          <input
            ref={inputRef}
            type="file"
            accept="image/*"
            hidden
            onChange={(event) => acceptFile(event.target.files?.[0])}
          />
        </section>

        <aside className="pipeline-panel panel">
          <PanelTitle eyebrow="Pipeline" title="All stages" detail={`${stages.length + 1} views`} />
          <p className="pipeline-note">Select any point in the physical image-formation chain.</p>
          <PipelineSteps
            stages={stages}
            stageIndex={stageIndex}
            setStageIndex={setStageIndex}
            disabled={!resultUrl || developing}
          />
          <div className="delta-control">
            <Switch
              className="delta-switch"
              label="Show stage difference"
              labelPosition="start"
              labelSpacing="spread"
              size="sm"
              value={showDelta}
              onChange={setShowDelta}
              isDisabled={!resultUrl || developing || stageIndex == null || stageIndex === 0}
              width="100%"
            />
            {delta && (
              <span className="delta-readout">
                ×{delta.gain.toFixed(1)} gain · {delta.peak.toFixed(0)}/255 peak
              </span>
            )}
          </div>
        </aside>
      </main>
      <p className="pipeline-note">Film profiles © 2026 MUAStudio Inc. · <a href={assetUrl('packs/FILM-PROFILES.txt')}>CC BY-SA 4.0</a></p>
    </div>
  )
}
