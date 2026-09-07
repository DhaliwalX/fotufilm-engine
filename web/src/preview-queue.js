import { SLIDERS } from './editor-state.js'

export function previewLabel(current, previous) {
  const { edit, fileId, filename, stockName, mediumName, edge } = current
  const before = previous?.fileId === fileId ? previous.edit : null
  let action = stockName || 'Normal'
  if (!before) action = filename
  else if (edit.stock !== before.stock) action = stockName || 'Normal'
  else if (edit.medium !== before.medium) action = mediumName || 'Default output medium'
  else {
    const changes = SLIDERS.filter((slider) => edit.params[slider.key] !== before.params[slider.key])
    if (changes.length) {
      action = changes.slice(0, 2).map((slider) => {
        const value = Number(edit.params[slider.key].toFixed(2))
        const label = slider.key.startsWith('grade') ? `${slider.group} ${slider.label}` : slider.label
        return `${label} ${slider.key === 'ev' && value > 0 ? '+' : ''}${value}${slider.unit ? ` ${slider.unit}` : ''}`
      }).join(', ')
      if (changes.length > 2) action += ` + ${changes.length - 2} more`
    } else if (edit.rotation !== before.rotation) action = 'Rotate photo'
    else if (edit.flip !== before.flip) action = 'Flip photo'
    else if (edit.straighten !== before.straighten) action = `Straighten ${Number(edit.straighten.toFixed(2))}°`
    else if (JSON.stringify(edit.crop) !== JSON.stringify(before.crop)) action = 'Crop photo'
    else if (edit.seed !== before.seed) action = 'New grain pattern'
    else if (edit.localTone !== before.localTone) action = edit.localTone ? 'Enable regional tone' : 'Disable regional tone'
    else if (edit.gradeSpace !== before.gradeSpace) action = edit.gradeSpace ? 'Encoded grade' : 'Linear grade'
    else if (current.cropMode !== previous.cropMode) action = current.cropMode ? 'Crop canvas' : 'Cropped preview'
    else if (current.stage !== previous.stage || current.difference !== previous.difference)
      action = current.stageLabel || 'Film preview'
    else if (edge !== previous.edge) action = edge > previous.edge ? 'Full detail' : 'Interactive'
  }
  return `${action} · ${edge}px preview`
}

// Finish the visible frame, then take only the newest edit. Continuous input must
// not keep cancelling every render or build a queue of obsolete slider positions.
export class PreviewQueue {
  constructor(onStatus = () => {}) {
    this.pending = null
    this.running = false
    this.closed = false
    this.active = null
    this.onStatus = onStatus
  }
  publish() {
    if (this.closed) return
    this.onStatus(this.active
      ? `${this.active.stage}${this.pending ? ` · Next: ${this.pending.label}` : ''}`
      : null)
  }
  submit(run, label = 'Preview') {
    if (this.closed) return Promise.resolve(null)
    this.pending?.resolve(null)
    return new Promise((resolve, reject) => {
      this.pending = { run, label, resolve, reject }
      if (this.running) this.publish()
      this.drain()
    })
  }
  async drain() {
    if (this.running) return
    this.running = true
    while (this.pending && !this.closed) {
      const next = this.pending
      this.pending = null
      this.active = { ...next, stage: `Preparing ${next.label}` }
      const active = this.active
      this.publish()
      try {
        next.resolve(await next.run((stage) => {
          if (this.active !== active || this.closed) return
          active.stage = stage
          this.publish()
        }))
      } catch (error) {
        next.reject(error)
      }
    }
    this.active = null
    this.running = false
    this.publish()
  }
  close() {
    this.closed = true
    this.pending?.resolve(null)
    this.pending = null
  }
}
