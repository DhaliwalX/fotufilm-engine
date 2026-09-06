// Finish the visible frame, then take only the newest edit. Continuous input must
// not keep cancelling every render or build a queue of obsolete slider positions.
export class PreviewQueue {
  constructor() {
    this.pending = null
    this.running = false
    this.closed = false
  }
  submit(run) {
    if (this.closed) return Promise.resolve(null)
    this.pending?.resolve(null)
    return new Promise((resolve, reject) => {
      this.pending = { run, resolve, reject }
      this.drain()
    })
  }
  async drain() {
    if (this.running) return
    this.running = true
    while (this.pending && !this.closed) {
      const next = this.pending
      this.pending = null
      try {
        next.resolve(await next.run())
      } catch (error) {
        next.reject(error)
      }
    }
    this.running = false
  }
  close() {
    this.closed = true
    this.pending?.resolve(null)
    this.pending = null
  }
}
