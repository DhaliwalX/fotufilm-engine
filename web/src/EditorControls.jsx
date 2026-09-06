import { useEffect, useRef, useState } from 'react'
import { SLIDERS, validCrop } from './editor-state.js'
import { clamp } from './color-controls.js'

const paths = {
  film: 'M4 3h16v18H4z M8 3v18 M16 3v18 M4 8h4 M4 16h4 M16 8h4 M16 16h4',
  open: 'M12 5v14 M5 12h14',
  minus: 'M5 12h14',
  plus: 'M12 5v14 M5 12h14',
  fit: 'M8 3H3v5 M16 3h5v5 M3 16v5h5 M21 16v5h-5',
  undo: 'M8 4 3 9l5 5 M3 9h10a7 7 0 0 1 7 7v3',
  redo: 'm16 4 5 5-5 5 M21 9H11a7 7 0 0 0-7 7v3',
  reset: 'M4 4v6h6 M4 10a8 8 0 1 1 0 5',
  export: 'M12 15V3 m-4 4 4-4 4 4 M5 12v8h14v-8',
  histogram: 'M3 19h18 M5 16v-4 M9 16V5 M13 16V9 M17 16V3 M21 16v-5',
  adjustments: 'M3 6h7 m4 0h7 M3 12h12 m4 0h2 M3 18h3 m4 0h11 M10 3v6 M15 9v6 M6 15v6',
  crop: 'M6 3v15h15 M3 6h15v15',
  compare: 'M12 3v18 M9 4H4v16h5 M15 4h5v16h-5',
  sidebar: 'M3 4h18v16H3z M9 4v16',
  inspector: 'M3 4h18v16H3z M15 4v16',
  more: 'M5 12h.01 M12 12h.01 M19 12h.01',
  close: 'm6 6 12 12 M6 18 18 6',
  search: 'M16 16l5 5 M18 10a8 8 0 1 1-16 0 8 8 0 0 1 16 0',
  rotate: 'M4 7h11a5 5 0 0 1 5 5v5 M8 3 4 7l4 4 M5 15v6h6v-6z',
  flip: 'M12 3v18 M9 6 3 18h6z M15 6l6 12h-6z',
  check: 'm5 12 4 4L19 6',
}
export function Icon({ name }) {
  return (
    <svg
      width="18"
      height="18"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d={paths[name] || paths.film} />
    </svg>
  )
}
export function ToolButton({ icon, label, active, children, ...props }) {
  return (
    <button
      type="button"
      className={`tool-button ${active ? 'active' : ''}`}
      title={label}
      aria-label={label}
      aria-pressed={active}
      {...props}
    >
      <Icon name={icon} />
      {children}
    </button>
  )
}
export function Section({ title, children, open = true }) {
  return (
    <details className="inspector-section" open={open}>
      <summary>{title}</summary>
      <div className="section-content">{children}</div>
    </details>
  )
}
export function Adjustment({ slider, value, onChange, onEnd }) {
  const accessibleLabel = slider.key.startsWith('grade')
    ? `${slider.group} ${slider.label}`
    : slider.label
  const temperature = slider.key === 'temperature'
  const rangeValue = temperature ? 1e6 / value : value
  const id = `control-${slider.key}`
  return (
    <div className="adjustment">
      <div className="adjustment-label">
        <label htmlFor={id}>{slider.label}</label>
        <div className="number-field">
          <input
            aria-label={`${accessibleLabel} value`}
            type="number"
            value={Number(value.toFixed(3))}
            min={slider.min}
            max={slider.max}
            step={slider.step}
            onChange={(e) => {
              if (e.target.value !== '' && Number.isFinite(e.target.valueAsNumber))
                onChange(clamp(e.target.valueAsNumber, slider.min, slider.max))
            }}
            onBlur={onEnd}
          />
          {slider.unit && <span>{slider.unit}</span>}
        </div>
      </div>
      <input
        id={id}
        aria-label={accessibleLabel}
        type="range"
        min={temperature ? 1e6 / slider.max : slider.min}
        max={temperature ? 1e6 / slider.min : slider.max}
        step={temperature ? 0.1 : slider.step}
        value={rangeValue}
        aria-valuetext={temperature ? `${Math.round(value)} K` : undefined}
        onChange={(e) =>
          onChange(temperature ? Math.round(1e6 / Number(e.target.value)) : Number(e.target.value))
        }
        onPointerUp={onEnd}
        onPointerCancel={onEnd}
        onKeyUp={onEnd}
        onBlur={onEnd}
        onDoubleClick={() => {
          onChange(slider.def)
          onEnd?.()
        }}
      />
    </div>
  )
}
export function Adjustments({ group, params, onChange, onEnd }) {
  return SLIDERS.filter((s) => s.group === group).map((slider) => (
    <Adjustment
      key={slider.key}
      slider={slider}
      value={params[slider.key]}
      onChange={(value) => onChange(slider.key, value)}
      onEnd={onEnd}
    />
  ))
}
export function Modal({ title, children, onClose }) {
  const ref = useRef(null)
  useEffect(() => {
    const dialog = ref.current,
      before = document.activeElement
    dialog.showModal()
    return () => {
      dialog.close()
      before?.focus()
    }
  }, [])
  return (
    <dialog
      ref={ref}
      aria-label={title}
      onCancel={(e) => {
        e.preventDefault()
        onClose()
      }}
      onClick={(e) => {
        if (e.target === e.currentTarget) onClose()
      }}
    >
      <div className="dialog-header">
        <h2>{title}</h2>
        <ToolButton icon="close" label="Close" onClick={onClose} />
      </div>
      {children}
    </dialog>
  )
}

export function Histogram({ canvas, onClose }) {
  const ref = useRef(null)
  const [offset, setOffset] = useState([0, 0])
  const drag = useRef(null)
  useEffect(() => {
    if (!canvas) return
    const reduced = document.createElement('canvas')
    reduced.width = 128
    reduced.height = 128
    const ctx = reduced.getContext('2d', { willReadFrequently: true })
    ctx.drawImage(canvas, 0, 0, 128, 128)
    const pixels = ctx.getImageData(0, 0, 128, 128).data
    const bins = Array.from({ length: 3 }, () => Array(64).fill(0))
    for (let i = 0; i < pixels.length; i += 4)
      for (let c = 0; c < 3; c++) bins[c][pixels[i + c] >> 2]++
    const plot = ref.current.getContext('2d'),
      width = 192,
      height = 72
    plot.clearRect(0, 0, width, height)
    const peak = Math.max(1, ...bins.flat())
    bins.forEach((channel, c) => {
      plot.beginPath()
      plot.moveTo(0, height)
      channel.forEach((n, x) => plot.lineTo((x * width) / 63, height - (n / peak) * (height - 3)))
      plot.lineTo(width, height)
      plot.closePath()
      plot.fillStyle = ['#f1787890', '#78c99b90', '#79a7ed90'][c]
      plot.fill()
    })
  }, [canvas])
  return (
    <div className="histogram" style={{ transform: `translate(${offset[0]}px, ${offset[1]}px)` }}>
      <div
        className="histogram-header"
        onPointerDown={(e) => {
          if (e.target.closest('button')) return
          e.currentTarget.setPointerCapture(e.pointerId)
          drag.current = [e.clientX, e.clientY, ...offset]
        }}
        onPointerMove={(e) => {
          if (drag.current) {
            const room = e.currentTarget.closest('.canvas-area').getBoundingClientRect()
            setOffset([
              clamp(
                drag.current[2] + e.clientX - drag.current[0],
                0,
                Math.max(0, room.width - 224),
              ),
              clamp(
                drag.current[3] + e.clientY - drag.current[1],
                0,
                Math.max(0, room.height - 150),
              ),
            ])
          }
        }}
        onPointerUp={() => {
          drag.current = null
        }}
        onPointerCancel={() => {
          drag.current = null
        }}
      >
        <span>RGB histogram</span>
        <button aria-label="Close histogram" onClick={onClose}>
          ×
        </button>
      </div>
      <canvas
        ref={ref}
        width="192"
        height="72"
        aria-label="Red, green and blue tonal distribution"
      />
      <div className="histogram-scale">
        <span>0</span>
        <span>255</span>
      </div>
    </div>
  )
}

export function ImageCanvas({
  result,
  original,
  sourceKey,
  zoom,
  setZoom,
  compare,
  setCompare,
  cropMode,
  crop,
  onCrop,
  onEnd,
  showHistogram,
  outputWidth,
  onZoomReadout,
}) {
  const container = useRef(null),
    drag = useRef(null)
  const [offset, setOffset] = useState([0, 0]),
    [room, setRoom] = useState([1, 1])
  useEffect(() => {
    const observer = new ResizeObserver(([entry]) =>
      setRoom([entry.contentRect.width, entry.contentRect.height]),
    )
    observer.observe(container.current)
    return () => observer.disconnect()
  }, [])
  useEffect(() => {
    setOffset([0, 0])
    setZoom(1)
  }, [sourceKey, setZoom])
  useEffect(() => {
    if (zoom === 1) setOffset([0, 0])
  }, [zoom])
  const width = result?.width || original?.naturalWidth || 1,
    height = result?.height || original?.naturalHeight || 1
  const fit = Math.min((room[0] - 48) / width, (room[1] - 48) / height, 1)
  const displayWidth = Math.max(1, width * fit),
    displayHeight = Math.max(1, height * fit)
  const displayUrl = compare ? result?.originalUrl || original?.src : result?.url || original?.src
  const nativeScale = displayWidth / Math.max(1, outputWidth || width)
  useEffect(() => {
    onZoomReadout?.(Math.round(nativeScale * (cropMode ? 1 : zoom) * 100))
  }, [nativeScale, cropMode, zoom, onZoomReadout])
  useEffect(() => {
    const surface = container.current
    const wheel = (event) => {
      if (cropMode || event.target.closest('.histogram')) return
      event.preventDefault()
      setZoom((z) => clamp(z * (event.deltaY > 0 ? 0.9 : 1.1), 1, 8))
    }
    surface.addEventListener('wheel', wheel, { passive: false })
    return () => surface.removeEventListener('wheel', wheel)
  }, [cropMode, setZoom])
  function begin(e) {
    if (e.button !== 0 || cropMode || e.target.closest('.histogram')) return
    e.currentTarget.setPointerCapture(e.pointerId)
    if (zoom === 1) setCompare(true)
    else drag.current = [e.clientX, e.clientY, ...offset]
  }
  function end() {
    drag.current = null
    setCompare(false)
  }
  return (
    <div
      ref={container}
      className={`canvas-area ${cropMode ? 'cropping' : ''}`}
      tabIndex={0}
      aria-label="Photo preview"
      onDoubleClick={(event) => {
        if (!cropMode && !event.target.closest('.histogram'))
          setZoom((z) => (z === 1 ? clamp(1 / nativeScale, 1, 8) : 1))
      }}
      onPointerDown={begin}
      onPointerMove={(e) => {
        if (drag.current)
          setOffset([
            clamp(
              drag.current[2] + e.clientX - drag.current[0],
              (-displayWidth * (zoom - 1)) / 2,
              (displayWidth * (zoom - 1)) / 2,
            ),
            clamp(
              drag.current[3] + e.clientY - drag.current[1],
              (-displayHeight * (zoom - 1)) / 2,
              (displayHeight * (zoom - 1)) / 2,
            ),
          ])
      }}
      onPointerUp={end}
      onPointerCancel={end}
      onLostPointerCapture={end}
    >
      {displayUrl && (
        <div
          className="photo-plane"
          style={{
            width: displayWidth,
            height: displayHeight,
            transform: `translate(${offset[0]}px, ${offset[1]}px) scale(${cropMode ? 1 : zoom})`,
          }}
        >
          <img
            src={displayUrl}
            alt={compare ? 'Original photo' : 'Developed photo'}
            draggable="false"
          />
          {cropMode && (
            <svg
              className="crop-overlay"
              viewBox="0 0 1000 1000"
              preserveAspectRatio="none"
              aria-label="Crop selection"
            >
              <path
                d={`M0 0H1000V1000H0Z M${crop.map((p) => p.map((v) => v * 1000).join(' ')).join(' L')}Z`}
                fillRule="evenodd"
                fill="#0008"
              />
              <polygon
                points={crop.map((p) => p.map((v) => v * 1000).join(',')).join(' ')}
                fill="none"
                stroke="white"
                strokeWidth="1.5"
                vectorEffect="non-scaling-stroke"
              />
            </svg>
          )}
          {cropMode &&
            crop.map(([x, y], i) => (
              <button
                key={i}
                className="crop-handle"
                aria-label={
                  [
                    'Top left crop corner',
                    'Top right crop corner',
                    'Bottom right crop corner',
                    'Bottom left crop corner',
                  ][i]
                }
                style={{ left: `${x * 100}%`, top: `${y * 100}%` }}
                onPointerDown={(e) => {
                  e.stopPropagation()
                  e.currentTarget.setPointerCapture(e.pointerId)
                }}
                onPointerMove={(e) => {
                  if (!e.currentTarget.hasPointerCapture(e.pointerId)) return
                  const rect = e.currentTarget.parentElement.getBoundingClientRect()
                  const next = crop.map((p) => [...p])
                  next[i] = [
                    clamp((e.clientX - rect.left) / rect.width, 0, 1),
                    clamp((e.clientY - rect.top) / rect.height, 0, 1),
                  ]
                  if (validCrop(next)) onCrop(next)
                }}
                onPointerUp={onEnd}
                onPointerCancel={onEnd}
                onKeyDown={(e) => {
                  const delta = {
                    ArrowLeft: [-0.005, 0],
                    ArrowRight: [0.005, 0],
                    ArrowUp: [0, -0.005],
                    ArrowDown: [0, 0.005],
                  }[e.key]
                  if (!delta) return
                  e.preventDefault()
                  const next = crop.map((p) => [...p])
                  next[i] = [clamp(x + delta[0], 0, 1), clamp(y + delta[1], 0, 1)]
                  if (validCrop(next)) onCrop(next)
                }}
                onKeyUp={onEnd}
              />
            ))}
        </div>
      )}
      {compare && <span className="original-badge">Original</span>}
      {showHistogram && result && <Histogram canvas={result.canvas} onClose={showHistogram} />}
    </div>
  )
}
