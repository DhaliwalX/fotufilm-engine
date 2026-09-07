import { Button } from '@astryxdesign/core/Button'
import { TextInput } from '@astryxdesign/core/TextInput'
import { Switch } from '@astryxdesign/core/Switch'
import { TabList, Tab } from '@astryxdesign/core/TabList'
import { Selector } from '@astryxdesign/core/Selector'
import { PreviewQueue, previewLabel } from './preview-queue.js'
import { IMAGE_ACCEPT, isRawFile, importRaw } from './raw-import.js'
import { useCallback, useEffect, useMemo, useReducer, useRef, useState } from 'react'
import { RenderSession, loadStockIndex } from './render-session.js'
import {
  defaultEdit,
  fullCrop,
  historyReducer,
  initialHistory,
  cropForRatio,
  rotatedCrop,
  flippedCrop,
  parseEdit,
} from './editor-state.js'
import { canvasBlob, outputSize } from './geometry.js'
import {
  Adjustment,
  Adjustments,
  Icon,
  ImageCanvas,
  Modal,
  Section,
  ToolButton,
} from './EditorControls.jsx'

const stageNames = [
  'Bypass',
  'Exposure',
  'Flare',
  'Diffusion',
  'Halation',
  'Couplers',
  'Development',
  'Grain',
  'Negative',
  'Output',
]
const ratios = ['free', 'original', '1:1', '3:2', '2:3', '4:3', '3:4', '16:9', '9:16']
const isTyping = (target) =>
  target instanceof HTMLElement &&
  (!!target.closest(
    'input, select, textarea, dialog, [role=slider], [role=combobox], [role=switch]',
  ) ||
    target.isContentEditable)
const cleanName = (name) =>
  name
    .replace(/\.[^.]+$/, '')
    .replace(/[^\p{L}\p{N}_-]+/gu, '-')
    .slice(0, 100) || 'photo'
function download(blob, name) {
  const url = URL.createObjectURL(blob),
    link = document.createElement('a')
  link.href = url
  link.download = name
  link.click()
  setTimeout(() => URL.revokeObjectURL(url), 60000)
}
function StockRow({ stock, active, image, session, onSelect }) {
  const ref = useRef(null),
    [url, setUrl] = useState(null)
  useEffect(() => {
    if (!image || !session) return
    let cancelled = false,
      objectUrl
    const observer = new IntersectionObserver((entries) => {
      if (!entries.some((entry) => entry.isIntersecting)) return
      observer.disconnect()
      // Wait until the main preview has been queued before thumbnail work.
      timer = setTimeout(
        () =>
          session
            .render({
              image,
              stock: stock.id,
              edit: defaultEdit(stock.id),
              maxEdge: 160,
              background: true,
              stale: () => cancelled,
            })
            .then((result) => {
              if (!result || cancelled) return
              objectUrl = URL.createObjectURL(result.blob)
              setUrl(objectUrl)
            })
            .catch(() => {}),
        400,
      )
    })
    let timer
    observer.observe(ref.current)
    return () => {
      cancelled = true
      clearTimeout(timer)
      observer.disconnect()
      if (objectUrl) URL.revokeObjectURL(objectUrl)
      setUrl(null)
    }
  }, [image, session, stock.id])
  return (
    <button
      ref={ref}
      className={`stock-row ${active ? 'selected' : ''}`}
      aria-pressed={active}
      onClick={onSelect}
      title={stock.name}
    >
      <span className="stock-thumb">{url ? <img src={url} alt="" /> : <Icon name="film" />}</span>
      <span className="stock-copy">
        <span>{stock.name}</span>
        <small>{stock.kind || 'Film'}</small>
      </span>
      {active && <Icon name="check" />}
    </button>
  )
}

export default function App() {
  const [history, dispatch] = useReducer(historyReducer, initialHistory)
  const edit = history.present
  const [stocks, setStocks] = useState([]),
    [files, setFiles] = useState([]),
    [activeId, setActiveId] = useState(null)
  const active = files.find((file) => file.id === activeId)
  const [panel, setPanel] = useState('film'),
    [filmOpen, setFilmOpen] = useState(() => window.innerWidth > 620),
    [inspectorOpen, setInspectorOpen] = useState(true)
  const [search, setSearch] = useState(''),
    [zoom, setZoom] = useState(1),
    [compare, setCompare] = useState(false)
  const [histogram, setHistogram] = useState(false),
    [dragOver, setDragOver] = useState(false)
  const [result, setResult] = useState(null),
    [status, setStatus] = useState('Loading films'),
    [error, setError] = useState(null),
    [importStatus, setImportStatus] = useState(null)
  const [dialog, setDialog] = useState(null),
    [exporting, setExporting] = useState(false),
    [exportType, setExportType] = useState('image/png'),
    [exportSize, setExportSize] = useState('full'),
    [quality, setQuality] = useState(95)
  const [stage, setStage] = useState(null),
    [stages, setStages] = useState([]),
    [difference, setDifference] = useState(false)
  const [session, setSession] = useState(null),
    [retry, setRetry] = useState(0)
  const input = useRef(null),
    editInput = useRef(null),
    histories = useRef(new Map()),
    urls = useRef(new Set()),
    loadGeneration = useRef(0),
    importController = useRef(null)
  const [cropPreview, setCropPreview] = useState(false)
  const cropMode = panel === 'crop' && inspectorOpen && !cropPreview
  const [zoomReadout, setZoomReadout] = useState(100)
  const previewEditJSON = JSON.stringify(
    cropMode ? { ...edit, crop: fullCrop(), ratio: 'free', straighten: 0 } : edit,
  )
  const [settledEdit, setSettledEdit] = useState(previewEditJSON)
  useEffect(() => {
    const timer = setTimeout(() => setSettledEdit(previewEditJSON), 250)
    return () => clearTimeout(timer)
  }, [previewEditJSON])
  const interacting = !!history.group || settledEdit !== previewEditJSON
  const [interactiveEdge, setInteractiveEdge] = useState(512)
  const previewEdge = Math.min(
    Math.max(active?.image.naturalWidth || 1600, active?.image.naturalHeight || 1600),
    cropMode ? 1600 : interacting ? interactiveEdge : Math.round(1600 * zoom),
  )
  const previewKey = JSON.stringify([
    activeId,
    previewEditJSON,
    stage,
    difference,
    cropMode,
    previewEdge,
  ])
  const previewEdit = useMemo(() => JSON.parse(previewEditJSON), [previewEditJSON])
  const selectedStock = stocks.find((stock) => stock.id === edit.stock)
  const stockId = edit.stock || stocks[0]?.id
  const patch = useCallback((value, group) => dispatch({ type: 'edit', patch: value, group }), [])
  const endEdit = useCallback(() => dispatch({ type: 'end' }), [])
  const setParam = (key, value) => patch({ params: { ...edit.params, [key]: value } }, key)
  const setInspector = (value) => {
    endEdit()
    setPanel(value)
    if (value === 'crop') setCropPreview(false)
    setInspectorOpen(true)
    setCompare(false)
  }

  const alive = useRef(false)
  const previewQueue = useRef(null)
  const lastRenderedPreview = useRef(null)
  const currentPreview = useRef(null)
  currentPreview.current = { activeId, key: previewKey, exporting, cropMode }
  useEffect(() => {
    const renderer = new RenderSession()
    alive.current = true
    previewQueue.current = new PreviewQueue((text) => {
      if (alive.current && !currentPreview.current?.exporting) setStatus(text)
    })
    setSession(renderer)
    return () => {
      alive.current = false
      previewQueue.current.close()
      renderer.dispose()
      importController.current?.abort()
      loadGeneration.current++
      for (const url of urls.current) URL.revokeObjectURL(url)
      urls.current.clear()
    }
  }, [])
  useEffect(() => {
    let cancelled = false
    setError(null)
    setStatus('Loading films')
    loadStockIndex()
      .then((index) => {
        if (!cancelled) {
          setStocks(index)
          setStatus(null)
        }
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
  }, [retry])
  useEffect(() => {
    if (activeId) histories.current.set(activeId, history)
  }, [history, activeId])

  const replaceResult = useCallback((next) => {
    setResult((previous) => {
      for (const url of [previous?.url, previous?.originalUrl])
        if (url) {
          URL.revokeObjectURL(url)
          urls.current.delete(url)
        }
      return next
    })
  }, [])
  useEffect(() => {
    if (!active || !stockId || !session || exporting) return
    const currentFile = () => alive.current && currentPreview.current?.activeId === active.id
    const request = {
      image: active.image,
      edit: previewEdit,
      stock: stockId,
      maxEdge: previewEdge,
      stage,
      difference,
      cropMode,
      stale: () => !currentFile() || currentPreview.current.exporting,
    }
    const frame = requestAnimationFrame(() => {
      const stock = stocks.find((item) => item.id === previewEdit.stock)
      const queued = {
        fileId: active.id, filename: active.name, edit: previewEdit,
        stockName: stock?.name,
        mediumName: stock?.media.find((medium) => medium.id === previewEdit.medium)?.name,
        edge: previewEdge, cropMode, stage, difference,
        stageLabel: stages[stage]?.label,
      }
      const label = previewLabel(queued, lastRenderedPreview.current)
      previewQueue.current
        .submit((onProgress) => session.render({ ...request, onProgress }), label)
        .then((next) => {
          if (
            !next ||
            !currentFile() ||
            currentPreview.current.exporting ||
            currentPreview.current.cropMode !== cropMode
          )
            return
          if (interacting) {
            if (next.renderMilliseconds > 65)
              setInteractiveEdge((edge) => Math.max(256, Math.round(edge * 0.8)))
            else if (next.renderMilliseconds < 25)
              setInteractiveEdge((edge) => Math.min(800, Math.round(edge * 1.1)))
          }
          const url = URL.createObjectURL(next.blob),
            originalUrl = URL.createObjectURL(next.original)
          urls.current.add(url)
          urls.current.add(originalUrl)
          replaceResult({
            ...next,
            url,
            originalUrl,
            key: previewKey,
            fileId: active.id,
            stock: previewEdit.stock,
            stage,
          })
          lastRenderedPreview.current = queued
          setError(null)
        })
        .catch((error) => {
          if (currentFile()) {
            setError(error.message)
            if (!previewQueue.current.running) setStatus(null)
          }
        })
    })
    return () => cancelAnimationFrame(frame)
  }, [
    active,
    previewEdit,
    previewEdge,
    interacting,
    previewKey,
    stockId,
    session,
    stage,
    difference,
    cropMode,
    exporting,
    retry,
    replaceResult,
  ])

  useEffect(() => {
    if (panel !== 'pipeline' || !session || !stockId) return
    let cancelled = false
    setStages([])
    session
      .stages(stockId, edit.medium)
      .then((next) => {
        if (!cancelled) setStages(next)
      })
      .catch((e) => {
        if (!cancelled) setError(e.message)
      })
    return () => {
      cancelled = true
    }
  }, [panel, session, stockId, edit.medium])

  async function acceptFiles(incoming) {
    if (exporting) return
    const generation = ++loadGeneration.current
    importController.current?.abort()
    const controller = new AbortController()
    importController.current = controller
    const loaded = [],
      errors = []
    for (const file of Array.from(incoming || [])) {
      if (controller.signal.aborted) break
      if (isRawFile(file)) {
        try {
          const decoded = await importRaw(file, {
            signal: controller.signal,
            onProgress: (text) => {
              if (!controller.signal.aborted) setImportStatus(`${text}: ${file.name}`)
            },
          })
          loaded.push({ id: crypto.randomUUID(), name: file.name, ...decoded })
        } catch (e) {
          if (e.name !== 'AbortError') errors.push(`${file.name}: ${e.message}`)
        }
        continue
      }
      if (!file.type.startsWith('image/') && !/\.(png|jpe?g|webp|avif|gif|bmp)$/i.test(file.name)) {
        errors.push(`${file.name}: choose an image or camera RAW file.`)
        continue
      }
      const url = URL.createObjectURL(file)
      try {
        const image = new Image()
        image.src = url
        await image.decode()
        if (image.naturalWidth * image.naturalHeight > 120000000)
          throw new Error('Images above 120 megapixels are not supported.')
        loaded.push({ id: crypto.randomUUID(), name: file.name, image, url })
      } catch (e) {
        URL.revokeObjectURL(url)
        errors.push(`${file.name}: ${e.message || 'Could not decode image.'}`)
      }
    }
    if (generation !== loadGeneration.current) {
      loaded.forEach((file) => URL.revokeObjectURL(file.url))
      return
    }
    setImportStatus(null)
    importController.current = null
    if (loaded.length) {
      loaded.forEach((file) => urls.current.add(file.url))
      if (activeId) histories.current.set(activeId, history)
      setFiles((current) => [...current, ...loaded])
      setActiveId(loaded[0].id)
      dispatch({ type: 'load', edit: defaultEdit(edit.stock) })
      replaceResult(null)
      setStage(null)
      setDifference(false)
    }
    setError(errors.length ? errors.join(' ') : null)
  }
  async function openSample() {
    try {
      const canvas = document.createElement('canvas')
      canvas.width = 1600
      canvas.height = 1000
      const ctx = canvas.getContext('2d')
      ctx.fillStyle = '#202124'
      ctx.fillRect(0, 0, 1600, 1000)
      for (let row = 0; row < 4; row++)
        for (let column = 0; column < 8; column++) {
          ctx.fillStyle = `hsl(${column * 45} ${85 - row * 20}% ${65 - row * 12}%)`
          ctx.fillRect(70 + column * 185, 70 + row * 160, 165, 140)
        }
      const gradient = ctx.createLinearGradient(70, 0, 1530, 0)
      gradient.addColorStop(0, '#000')
      gradient.addColorStop(1, '#fff')
      ctx.fillStyle = gradient
      ctx.fillRect(70, 750, 1460, 180)
      await acceptFiles([
        new File([await canvasBlob(canvas)], 'Color chart.png', {
          type: 'image/png',
        }),
      ])
    } catch (e) {
      setError(e.message)
    }
  }
  function selectFile(file) {
    if (file.id === activeId || exporting) return
    histories.current.set(activeId, history)
    setActiveId(file.id)
    dispatch({
      type: 'restore',
      history: histories.current.get(file.id) || {
        ...initialHistory,
        present: defaultEdit(edit.stock),
      },
    })
    replaceResult(null)
    setStage(null)
    setDifference(false)
  }
  function removeFile(file) {
    if (exporting) return
    const remaining = files.filter((item) => item.id !== file.id)
    if (file.id === activeId) {
      const next = remaining[Math.max(0, files.indexOf(file) - 1)]
      setActiveId(next?.id || null)
      dispatch({
        type: 'restore',
        history: histories.current.get(next?.id) || {
          ...initialHistory,
          present: defaultEdit(edit.stock),
        },
      })
      replaceResult(null)
    }
    histories.current.delete(file.id)
    setFiles(remaining)
    URL.revokeObjectURL(file.url)
    urls.current.delete(file.url)
  }
  function selectStock(id) {
    if (exporting) return
    const medium = stocks.find((s) => s.id === id)?.media.some((m) => m.id === edit.medium)
      ? edit.medium
      : null
    patch({ stock: id, medium })
    setStage(null)
    setDifference(false)
  }
  function saveEdit() {
    download(
      new Blob([JSON.stringify({ version: 1, edit }, null, 2)], {
        type: 'application/json',
      }),
      `${cleanName(active?.name || 'photo')}.fotufilm-web.json`,
    )
    setDialog(null)
  }
  async function restoreEdit(file) {
    if (!file) return
    try {
      const restored = parseEdit(
        await file.text(),
        stocks.map((s) => s.id),
      )
      patch(restored)
      setStage(null)
      setDifference(false)
      setError(null)
    } catch (e) {
      setError(e.message)
    }
  }
  async function exportImage() {
    if (!active || !session || !stockId || exporting) return
    setExporting(true)
    setError(null)
    try {
      const next = await session.render({
        image: active.image,
        edit,
        stock: stockId,
        maxEdge: exportSize === 'full' ? Infinity : Number(exportSize),
        comparison: false,
        purpose: 'export',
        onProgress: setStatus,
      })
      if (!next) throw new Error('Export was cancelled.')
      setStatus(`Encoding ${exportType.split('/')[1].toUpperCase()} export`)
      const blob =
        exportType === 'image/png'
          ? next.blob
          : await canvasBlob(next.canvas, exportType, quality / 100)
      const extension = exportType === 'image/jpeg' ? 'jpg' : exportType.split('/')[1]
      download(
        blob,
        `${cleanName(active.name)}-${edit.stock || 'normal'}${edit.medium ? `-${edit.medium}` : ''}.${extension}`,
      )
      setDialog(null)
    } catch (e) {
      setError(e.message)
    } finally {
      setExporting(false)
      setStatus(null)
    }
  }
  useEffect(() => {
    function keydown(event) {
      if (isTyping(event.target) || exporting) return
      const command = event.metaKey || event.ctrlKey
      if (command && event.key.toLowerCase() === 'o') {
        event.preventDefault()
        input.current?.click()
      } else if (command && event.key.toLowerCase() === 'z') {
        event.preventDefault()
        dispatch({ type: event.shiftKey ? 'redo' : 'undo' })
      } else if (command && event.key.toLowerCase() === 's' && active) {
        event.preventDefault()
        setDialog('export')
      } else if (event.code === 'Space' && active) {
        event.preventDefault()
        setCompare(true)
      } else if (event.key === 'Escape') {
        setCompare(false)
        setZoom(1)
        if (cropMode) setPanel('film')
      } else if (event.key === 'Enter' && cropMode) {
        setPanel('film')
        endEdit()
      } else if (!command && event.key.toLowerCase() === 'h') setHistogram((v) => !v)
      else if (!command && event.key.toLowerCase() === 'c') {
        setPanel('crop')
        setCropPreview(false)
        setInspectorOpen(true)
      } else if (event.key === '0') setZoom(1)
      else if (event.key === '+' || event.key === '=') setZoom((z) => Math.min(8, z + 0.25))
      else if (event.key === '-') setZoom((z) => Math.max(1, z - 0.25))
      else if (event.key === 'Tab') return
    }
    const release = (event) => {
      if (event.code === 'Space') setCompare(false)
    }
    const blur = () => {
      setCompare(false)
      endEdit()
    }
    window.addEventListener('keydown', keydown)
    window.addEventListener('keyup', release)
    window.addEventListener('blur', blur)
    return () => {
      window.removeEventListener('keydown', keydown)
      window.removeEventListener('keyup', release)
      window.removeEventListener('blur', blur)
    }
  }, [active, exporting, cropMode, endEdit])

  const visibleStocks = stocks.filter((stock) =>
    stock.name.toLowerCase().includes(search.toLowerCase()),
  )
  const rawWidth = active?.image.naturalWidth || 0,
    rawHeight = active?.image.naturalHeight || 0
  const width = edit.rotation % 2 ? rawHeight : rawWidth,
    height = edit.rotation % 2 ? rawWidth : rawHeight
  const cropSize = outputSize(edit.crop, width, height)
  const exportScale =
    exportSize === 'full' ? 1 : Math.min(1, Number(exportSize) / Math.max(width, height))
  const shownResult = result?.fileId === activeId ? result : null
  const adjustments = (group) => (
    <Adjustments
      group={group}
      params={edit.params}
      onChange={setParam}
      onEnd={endEdit}
      disabled={exporting || !active}
    />
  )

  return (
    <div
      className={`editor ${filmOpen ? '' : 'film-collapsed'} ${inspectorOpen ? '' : 'inspector-collapsed'}`}
    >
      <header className="toolbar" aria-label="Editor toolbar">
        <div className="toolbar-leading">
          <ToolButton
            icon="sidebar"
            label="Toggle film sidebar"
            active={filmOpen}
            onClick={() => setFilmOpen((v) => !v)}
          />
          <span className="app-name">Fotufilm</span>
          <ToolButton
            icon="open"
            label="Open images (⌘O)"
            onClick={() => input.current?.click()}
            disabled={exporting}
          />
        </div>
        <div className="toolbar-zoom">
          <ToolButton
            icon="minus"
            label="Zoom out"
            onClick={() => setZoom((z) => Math.max(1, z - 0.25))}
            disabled={!active || zoom === 1 || cropMode}
          />
          <span className="zoom-readout">{zoom === 1 ? 'Fit' : `${zoomReadout}%`}</span>
          <ToolButton
            icon="plus"
            label="Zoom in"
            onClick={() => setZoom((z) => Math.min(8, z + 0.25))}
            disabled={!active || zoom === 8 || cropMode}
          />
          <ToolButton
            icon="fit"
            label="Zoom to fit (0)"
            onClick={() => setZoom(1)}
            disabled={!active || zoom === 1}
          />
          <span className="pixel-readout">
            {active?.image.raw ? 'RAW · ' : ''}
            {active ? `${((rawWidth * rawHeight) / 1000000).toFixed(1)} MP` : ''}
          </span>
        </div>
        <div className="toolbar-trailing">
          <ToolButton
            icon="histogram"
            label="Histogram (H)"
            active={histogram}
            onClick={() => setHistogram((v) => !v)}
            disabled={!active}
          />
          <span className="toolbar-divider" />
          <ToolButton
            icon="undo"
            label="Undo (⌘Z)"
            onClick={() => dispatch({ type: 'undo' })}
            disabled={!history.past.length || exporting}
          />
          <ToolButton
            icon="redo"
            label="Redo (⇧⌘Z)"
            onClick={() => dispatch({ type: 'redo' })}
            disabled={!history.future.length || exporting}
          />
          <ToolButton
            icon="reset"
            label="Reset all edits"
            onClick={() => {
              patch(defaultEdit(edit.stock))
              setStage(null)
              setDifference(false)
            }}
            disabled={!active || exporting}
          />
          <ToolButton
            icon="export"
            label="Export (⌘S)"
            onClick={() => setDialog('export')}
            disabled={!active || !stocks.length || exporting}
          />
          <ToolButton icon="more" label="More options" onClick={() => setDialog('more')} />
          <ToolButton
            icon="inspector"
            label="Toggle adjustments"
            active={inspectorOpen}
            onClick={() => setInspectorOpen((v) => !v)}
          />
        </div>
      </header>
      <aside className="film-sidebar" aria-label="Film library" inert={exporting}>
        <div className="sidebar-heading">
          <span>Film</span>
          <small>{stocks.length}</small>
        </div>
        <div className="search-field">
          <TextInput
            label="Search films"
            isLabelHidden
            role="searchbox"
            size="sm"
            placeholder="Search films"
            value={search}
            onChange={setSearch}
            startIcon={<Icon name="search" />}
            width="100%"
          />
        </div>
        <div className="stock-list">
          <button
            className={`stock-row normal-row ${edit.stock === null ? 'selected' : ''}`}
            aria-pressed={edit.stock === null}
            onClick={() => selectStock(null)}
          >
            <span className="stock-thumb">
              {active ? <img src={active.url} alt="" /> : <Icon name="film" />}
            </span>
            <span className="stock-copy">
              <span>Normal</span>
              <small>No film</small>
            </span>
            {edit.stock === null && <Icon name="check" />}
          </button>
          {visibleStocks.map((stock) => (
            <StockRow
              key={stock.id}
              stock={stock}
              active={edit.stock === stock.id}
              image={active?.image}
              session={session}
              onSelect={() => selectStock(stock.id)}
            />
          ))}
          {!visibleStocks.length && !!stocks.length && (
            <p className="empty-search">No matching films.</p>
          )}
        </div>
      </aside>
      <main
        className={`viewer ${dragOver ? 'drag-over' : ''}`}
        aria-label="Image editor"
        onDragOver={(e) => {
          e.preventDefault()
          setDragOver(true)
        }}
        onDragLeave={(e) => {
          if (!e.currentTarget.contains(e.relatedTarget)) setDragOver(false)
        }}
        onDrop={(e) => {
          e.preventDefault()
          setDragOver(false)
          acceptFiles(e.dataTransfer.files)
        }}
      >
        {active ? (
          <ImageCanvas
            result={shownResult}
            original={active.image}
            sourceKey={active.id}
            zoom={zoom}
            outputWidth={cropMode ? width : cropSize.width}
            onZoomReadout={setZoomReadout}
            setZoom={setZoom}
            compare={compare}
            setCompare={setCompare}
            cropMode={cropMode}
            crop={edit.crop}
            onCrop={(crop) => patch({ crop, ratio: 'free' }, 'crop')}
            onEnd={endEdit}
            showHistogram={histogram ? () => setHistogram(false) : null}
          />
        ) : (
          <div className="empty-canvas">
            <Icon name="open" />
            <h1>Open a photo</h1>
            <p>Drop images here or choose files.</p>
            <Button
              label="Open images"
              variant="primary"
              size="sm"
              className="primary"
              onClick={() => input.current?.click()}
            />
            <Button
              label="Open sample chart"
              variant="ghost"
              size="sm"
              className="text-button"
              onClick={openSample}
            />
            <small>RAW, JPEG, PNG, WebP, AVIF · processed on this device</small>
          </div>
        )}
        {importStatus && (
          <div className="import-status" role="status">
            <span>{importStatus}</span>
            <Button
              label="Cancel"
              variant="ghost"
              size="sm"
              onClick={() => {
                importController.current?.abort()
                setImportStatus(null)
              }}
            />
          </div>
        )}
        {dragOver && <div className="drop-label">Drop images to open</div>}
        {error && (
          <div className="error-banner" role="alert">
            <span>{error}</span>
            <Button
              label="Retry"
              variant="ghost"
              size="sm"
              onClick={() => {
                setError(null)
                setRetry((v) => v + 1)
              }}
            />
            <button aria-label="Dismiss error" onClick={() => setError(null)}>
              <Icon name="close" size={14} />
            </button>
          </div>
        )}
        <div className="viewer-status">
          <span className="document-name">{active?.name || 'No photo open'}</span>
          <span role="status">
            {status ||
              (active && shownResult?.key !== previewKey
                ? error
                  ? 'Preview unavailable'
                  : interacting
                    ? 'Waiting for adjustments to settle before full-detail preview'
                    : 'Waiting for the next display frame'
                : null) ||
              (shownResult
                ? `${shownResult.width} × ${shownResult.height} · ${shownResult.elapsed.toFixed(0)} ms`
                : '')}
          </span>
          {active && (
            <Button
              label="Compare"
              variant="ghost"
              size="sm"
              className={`compare-button ${compare ? 'active' : ''}`}
              onPointerDown={(e) => {
                e.currentTarget.setPointerCapture(e.pointerId)
                setCompare(true)
              }}
              onPointerUp={() => setCompare(false)}
              onPointerCancel={() => setCompare(false)}
              onKeyDown={(e) => {
                if (e.key === ' ' || e.key === 'Enter') {
                  e.preventDefault()
                  setCompare(true)
                }
              }}
              onKeyUp={() => setCompare(false)}
              onBlur={() => setCompare(false)}
              aria-label="Hold to compare with original"
              icon={<Icon name="compare" />}
            />
          )}
          <span className="backend-label">
            {shownResult?.backend === 'webgpu' ? 'WebGPU' : shownResult ? 'CPU' : ''}
          </span>
        </div>
        {files.length > 1 && (
          <div className="filmstrip" aria-label="Open photos">
            {files.map((file) => (
              <div
                className={`filmstrip-item ${file.id === activeId ? 'selected' : ''}`}
                key={file.id}
              >
                <button aria-label={`Select ${file.name}`} onClick={() => selectFile(file)}>
                  <img src={file.url} alt={file.name} />
                </button>
                <button
                  className="close-photo"
                  aria-label={`Close ${file.name}`}
                  onClick={() => removeFile(file)}
                >
                  <Icon name="close" size={14} />
                </button>
              </div>
            ))}
          </div>
        )}
      </main>
      <aside className="inspector" aria-label="Adjustments">
        <TabList
          role="tablist"
          className="inspector-tabs"
          aria-label="Adjustment panels"
          value={panel}
          onChange={setInspector}
          layout="fill"
          size="sm"
          hasDivider={false}
        >
          {[
            ['film', 'film', 'Film'],
            ['light', 'adjustments', 'Light & Color'],
            ['crop', 'crop', 'Crop'],
          ].map(([id, icon, title]) => (
            <Tab
              key={id}
              value={id}
              label={title}
              icon={<Icon name={icon} />}
              panelId="inspector-content"
            />
          ))}
        </TabList>
        <div
          id="inspector-content"
          className="inspector-content"
          role="tabpanel"
          aria-label={
            panel === 'light'
              ? 'Light & Color'
              : panel === 'crop'
                ? 'Crop'
                : panel === 'pipeline'
                  ? 'Pipeline'
                  : 'Film'
          }
        >
          <fieldset disabled={exporting || !active}>
            {panel === 'film' && (
              <>
                <div className="inspector-title">
                  <h2>{selectedStock?.name || 'Normal'}</h2>
                  <p>{selectedStock ? 'Film settings' : 'No film selected'}</p>
                </div>
                {edit.stock && (
                  <Section title="Character">
                    {adjustments('Character')}
                    <Button
                      label="New Grain Pattern"
                      variant="secondary"
                      size="sm"
                      className="secondary full-width"
                      onClick={() =>
                        patch({
                          seed: crypto.getRandomValues(new Uint32Array(1))[0],
                        })
                      }
                    />
                  </Section>
                )}
                <Section title="Output">
                  <Selector
                    label="Output medium"
                    size="sm"
                    width="100%"
                    isDisabled={exporting || !active || !edit.stock}
                    value={edit.medium || selectedStock?.defaultMedium || 'screen'}
                    options={(
                      selectedStock?.media || [{ id: 'screen', name: 'Digital Reference' }]
                    ).map((medium) => ({ value: medium.id, label: medium.name }))}
                    onChange={(medium) => {
                      endEdit()
                      patch({ medium })
                      setStage(null)
                      setDifference(false)
                    }}
                  />
                  {selectedStock && (
                    <p className="medium-detail">
                      {(edit.medium || selectedStock.defaultMedium) === 'screen'
                        ? 'Direct display rendering without paper or scanning. Export is 8-bit sRGB.'
                        : selectedStock.media.find(
                            (m) => m.id === (edit.medium || selectedStock.defaultMedium),
                          )?.detail}
                    </p>
                  )}
                  <div className="info-row">
                    <span>Color space</span>
                    <span>sRGB</span>
                  </div>
                </Section>
                <p className="inspector-hint">
                  Click and hold the photo to compare with the original.
                </p>
              </>
            )}
            {panel === 'light' && (
              <>
                <Section title="Light">
                  {adjustments('Light')}
                  <Switch
                    label="Regional"
                    value={edit.localTone}
                    onChange={(value) => patch({ localTone: value })}
                    isDisabled={exporting || !active}
                    labelPosition="start"
                    labelSpacing="spread"
                    size="sm"
                  />
                </Section>
                <Section title="White Balance">{adjustments('White Balance')}</Section>
                <Section title="Color">{adjustments('Color')}</Section>
                <Section title="Grade">
                  <Switch
                    label="Encoded Grade"
                    value={edit.gradeSpace}
                    onChange={(value) => patch({ gradeSpace: value })}
                    isDisabled={exporting || !active}
                    labelPosition="start"
                    labelSpacing="spread"
                    size="sm"
                  />
                  {['Shadows', 'Midtones', 'Highlights'].map((band) => (
                    <div className="grade-band" key={band} role="group" aria-label={band}>
                      <h3>{band}</h3>
                      {adjustments(band)}
                    </div>
                  ))}
                </Section>
              </>
            )}
            {panel === 'crop' && (
              <>
                <div className="inspector-title">
                  <h2>Crop</h2>
                  <p>Drag the corners to set the frame.</p>
                </div>
                <Section title="Frame">
                  <div className="crop-actions">
                    <Button
                      label="Edit corners"
                      variant="secondary"
                      size="sm"
                      className="secondary"
                      aria-pressed={!cropPreview}
                      onClick={() => setCropPreview(false)}
                    />
                    <Button
                      label="Preview crop"
                      variant="secondary"
                      size="sm"
                      className="secondary"
                      aria-pressed={cropPreview}
                      onClick={() => {
                        endEdit()
                        setCropPreview(true)
                      }}
                    />
                  </div>
                  <Selector
                    label="Aspect ratio"
                    size="sm"
                    width="100%"
                    isDisabled={exporting || !active}
                    value={edit.ratio}
                    options={ratios.map((ratio) => ({
                      value: ratio,
                      label: ratio === 'free' ? 'Free' : ratio === 'original' ? 'Original' : ratio,
                    }))}
                    onChange={(ratio) => patch({ ratio, crop: cropForRatio(ratio, width, height) })}
                  />
                  <div className="crop-actions">
                    <Button
                      label="Rotate Left"
                      variant="secondary"
                      size="sm"
                      className="secondary"
                      onClick={() =>
                        patch({
                          rotation: (edit.rotation + 1) % 4,
                          crop: rotatedCrop(edit.crop, edit.flip),
                        })
                      }
                      icon={<Icon name="rotate" />}
                    />
                    <Button
                      label="Flip"
                      variant="secondary"
                      size="sm"
                      className="secondary"
                      onClick={() =>
                        patch({
                          flip: !edit.flip,
                          crop: flippedCrop(edit.crop),
                        })
                      }
                      icon={<Icon name="flip" />}
                    />
                  </div>
                  <Adjustment
                    slider={{
                      key: 'straighten',
                      label: 'Straighten',
                      min: -15,
                      max: 15,
                      step: 0.1,
                      def: 0,
                      unit: '°',
                    }}
                    value={edit.straighten}
                    onChange={(straighten) => {
                      setCropPreview(true)
                      patch({ straighten }, 'straighten')
                    }}
                    onEnd={endEdit}
                    disabled={exporting || !active}
                  />
                  <div className="info-row">
                    <span>Crop size</span>
                    <span>
                      {cropSize.width} × {cropSize.height}
                    </span>
                  </div>
                  <Button
                    label="Reset Crop"
                    variant="secondary"
                    size="sm"
                    className="secondary full-width"
                    onClick={() => patch({ crop: fullCrop(), ratio: 'free', straighten: 0 })}
                  />
                  <Button
                    label="Done"
                    variant="primary"
                    size="sm"
                    className="primary full-width"
                    onClick={() => {
                      endEdit()
                      setPanel('film')
                    }}
                  />
                </Section>
              </>
            )}
            {panel === 'pipeline' && (
              <>
                <div className="inspector-title">
                  <h2>Pipeline</h2>
                </div>
                <div className="pipeline-list">
                  <Button
                    label="Finished print"
                    variant="ghost"
                    size="sm"
                    className={stage === null ? 'selected' : ''}
                    onClick={() => {
                      setStage(null)
                      setDifference(false)
                    }}
                  />
                  {stages.map((item, i) => (
                    <button
                      key={item.id}
                      className={stage === i ? 'selected' : ''}
                      onClick={() => setStage(i)}
                      disabled={!edit.stock}
                    >
                      <span>{String(i + 1).padStart(2, '0')}</span>
                      {stageNames[i] || item.label}
                    </button>
                  ))}
                </div>
                <label className="toggle-row">
                  <span>Show stage difference</span>
                  <input
                    type="checkbox"
                    checked={difference}
                    onChange={(e) => setDifference(e.target.checked)}
                    disabled={stage === null || stage === 0}
                  />
                </label>
                {result?.delta && (
                  <p className="inspector-hint">
                    {result.delta.gain.toFixed(1)}× gain · {result.delta.peak}
                    /255 peak
                  </p>
                )}
              </>
            )}
          </fieldset>
        </div>
      </aside>
      <input
        ref={input}
        type="file"
        accept={IMAGE_ACCEPT}
        multiple
        hidden
        onChange={(e) => {
          acceptFiles(e.target.files)
          e.target.value = ''
        }}
      />
      <input
        ref={editInput}
        type="file"
        accept=".json"
        hidden
        onChange={(e) => {
          restoreEdit(e.target.files?.[0])
          e.target.value = ''
        }}
      />
      {dialog === 'export' && (
        <Modal
          title="Export image"
          onClose={() => {
            if (!exporting) setDialog(null)
          }}
        >
          <fieldset disabled={exporting}>
            <label className="select-row">
              Format
              <select
                aria-label="Format"
                value={exportType}
                onChange={(e) => setExportType(e.target.value)}
              >
                <option value="image/png">PNG</option>
                <option value="image/jpeg">JPEG</option>
                <option value="image/webp">WebP</option>
              </select>
            </label>
            <label className="select-row">
              Size
              <select
                aria-label="Size"
                value={exportSize}
                onChange={(e) => setExportSize(e.target.value)}
              >
                <option value="full">Full resolution</option>
                <option value="3840">3840 px long edge</option>
                <option value="2048">2048 px long edge</option>
                <option value="1600">1600 px long edge</option>
              </select>
            </label>
            {exportType !== 'image/png' && (
              <Adjustment
                slider={{
                  key: 'quality',
                  label: 'Quality',
                  min: 1,
                  max: 100,
                  step: 1,
                  def: 95,
                  unit: '%',
                }}
                disabled={exporting}
                value={quality}
                onChange={setQuality}
              />
            )}
            <p className="export-detail">
              {Math.max(1, Math.round(cropSize.width * exportScale))} ×{' '}
              {Math.max(1, Math.round(cropSize.height * exportScale))} pixels · sRGB · 8-bit
            </p>
            <p className="export-detail">
              Exports the finished image with the current crop and adjustments.
            </p>
          </fieldset>
          {exporting && <p role="status">{status || 'Preparing export'}</p>}
          <div className="dialog-actions">
            <Button
              label="Cancel"
              variant="secondary"
              size="sm"
              className="secondary"
              onClick={() => setDialog(null)}
              isDisabled={exporting}
            />
            <Button
              label={exporting ? 'Exporting…' : 'Export'}
              variant="primary"
              size="sm"
              onClick={exportImage}
              isDisabled={exporting}
            />
          </div>
        </Modal>
      )}
      {dialog === 'more' && (
        <Modal title="Options" onClose={() => setDialog(null)}>
          <div className="menu-options">
            <Button
              label="Save edits…"
              variant="secondary"
              size="sm"
              onClick={saveEdit}
              isDisabled={!active}
            />
            <Button
              label="Load edits…"
              variant="ghost"
              size="sm"
              onClick={() => {
                setDialog(null)
                editInput.current?.click()
              }}
              isDisabled={!active}
            />
            <Button
              label="Inspect pipeline"
              variant="ghost"
              size="sm"
              onClick={() => {
                setInspector('pipeline')
                setDialog(null)
              }}
            />
            <Button
              label="Keyboard shortcuts"
              variant="ghost"
              size="sm"
              onClick={() => setDialog('shortcuts')}
            />
            <Button
              label="Browser support"
              variant="ghost"
              size="sm"
              onClick={() => setDialog('support')}
            />
          </div>
        </Modal>
      )}
      {dialog === 'shortcuts' && (
        <Modal title="Keyboard shortcuts" onClose={() => setDialog(null)}>
          <dl className="shortcuts">
            {[
              ['Open images', '⌘ / Ctrl O'],
              ['Export', '⌘ / Ctrl S'],
              ['Undo', '⌘ / Ctrl Z'],
              ['Redo', '⇧ ⌘ / Ctrl Z'],
              ['Compare', 'Hold Space'],
              ['Histogram', 'H'],
              ['Crop', 'C'],
              ['Apply crop', 'Return'],
              ['Zoom', '+ / −'],
              ['Fit', '0'],
              ['Reset adjustment', 'Double-click slider'],
            ].map(([action, keys]) => (
              <div key={action}>
                <dt>{action}</dt>
                <dd>{keys}</dd>
              </div>
            ))}
          </dl>
        </Modal>
      )}
      {dialog === 'support' && (
        <Modal title="Browser support" onClose={() => setDialog(null)}>
          <div className="support-copy">
            <p>
              Photos are processed on this device. WebGPU is used when available, with WebAssembly
              CPU fallback.
            </p>
            <p>
              Fit preview uses up to 1600 pixels on the long edge; zooming requests more detail.
              Export develops the original at the selected size.
            </p>
            <p>
              The browser supports film selection, grain, light and color adjustments, three-way
              grading, crop, rotation and flip. Camera RAW files decode locally with LibRaw, using
              as-shot white balance and 16-bit linear data. Other images use the browser decoder.
            </p>
            <p>
              Video processing, scanned-negative conversion, spectral film and lens controls,
              selective adjustments, custom packs, and HDR / 16-bit export are available in the Mac
              app.
            </p>
          </div>
        </Modal>
      )}
    </div>
  )
}
