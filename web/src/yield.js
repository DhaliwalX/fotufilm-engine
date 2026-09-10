// Timers nested across rows acquire the browser's 4 ms minimum delay. Yield to
// input without imposing that delay on every strip of a realtime preview.
export function yieldToBrowser() {
  if (globalThis.scheduler?.yield) return globalThis.scheduler.yield()
  return new Promise((resolve) => {
    const channel = new MessageChannel()
    channel.port1.onmessage = () => {
      channel.port1.close()
      channel.port2.close()
      resolve()
    }
    channel.port2.postMessage(null)
  })
}
