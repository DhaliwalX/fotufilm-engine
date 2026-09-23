import { clampPlayhead } from "./time.js";

// Media clock and transport lifecycle, independent of React and the image backend.
export function createPlayback(
  video,
  {
    start,
    end,
    onState,
    onTime,
    requestFrame = requestAnimationFrame,
    cancelFrame = cancelAnimationFrame,
  },
) {
  let options = {
    start,
    end,
    disabled: false,
    loop: false,
    muted: false,
    rate: 1,
  };
  let state = { playing: false, position: start, error: null };
  let frame = null,
    disposed = false,
    generation = 0,
    pending = false,
    lastPaint = -Infinity;
  const update = (patch) => {
    state = { ...state, ...patch };
    if (!disposed) onState(state);
  };
  function publish(value, render = true) {
    const position = clampPlayhead(value, options.start, options.end);
    update({ position });
    if (render && !disposed) onTime(position);
  }
  function pause() {
    generation++;
    pending = false;
    video.pause();
    if (frame !== null) cancelFrame(frame);
    frame = null;
    update({ playing: false });
    if (!disposed) publish(video.currentTime);
  }
  function seek(value) {
    const position = clampPlayhead(value, options.start, options.end);
    // Unsupported playback codecs can still seek through the image backend.
    try {
      video.currentTime = position;
    } catch {
      /* Decoder owns the preview. */
    }
    publish(position);
  }
  async function play() {
    if (options.disabled || disposed) return;
    if (
      video.currentTime < options.start ||
      video.currentTime >= options.end - 0.002
    )
      seek(options.start);
    const attempt = ++generation;
    pending = true;
    try {
      await video.play();
      if (disposed || attempt !== generation) return;
      pending = false;
      update({ error: null });
    } catch (error) {
      if (disposed || attempt !== generation) return;
      pending = false;
      pause();
      if (error.name !== "AbortError")
        update({
          error:
            "Playback is unavailable for this codec. You can still seek and edit its frames.",
        });
    }
  }
  function boundary() {
    if (options.loop && !options.disabled) {
      seek(options.start);
      if (video.paused) void play();
    } else {
      pause();
      seek(options.end);
    }
  }
  function tick(now) {
    frame = null;
    if (disposed || video.paused) return;
    if (video.currentTime >= options.end) boundary();
    else if (now - lastPaint >= 32) {
      // The preview queue finishes its current frame and coalesces subsequent requests.
      // Keep it supplied at the display cadence instead of imposing an 8 fps ceiling.
      publish(video.currentTime);
      lastPaint = now;
    }
    if (!video.paused && !disposed) frame = requestFrame(tick);
  }
  const listeners = {
    play() {
      if (disposed || options.disabled) {
        pause();
        return;
      }
      update({ playing: true, error: null });
      if (frame === null) frame = requestFrame(tick);
    },
    pause() {
      if (frame !== null) cancelFrame(frame);
      frame = null;
      update({ playing: false });
    },
    ended: boundary,
    loadedmetadata() {
      seek(state.position);
    },
    timeupdate() {
      if (!video.paused && video.currentTime >= options.end) boundary();
      else if (video.paused && !video.ended) publish(video.currentTime);
    },
    error() {
      pause();
      update({
        error:
          "Playback is unavailable for this codec. You can still seek and edit its frames.",
      });
    },
  };
  for (const [name, listener] of Object.entries(listeners))
    video.addEventListener(name, listener);
  return {
    toggle() {
      if (!video.paused || pending) pause();
      else void play();
    },
    pause,
    seek(value) {
      if (!options.disabled) {
        pause();
        seek(value);
      }
    },
    skip(delta) {
      if (!options.disabled) {
        pause();
        seek(state.position + delta);
      }
    },
    configure(next) {
      const boundsChanged =
        options.start !== next.start || options.end !== next.end;
      options = { ...options, ...next };
      video.muted = options.muted;
      video.playbackRate = options.rate;
      if (options.disabled) pause();
      if (
        (boundsChanged &&
          (state.position < options.start || state.position >= options.end)) ||
        video.currentTime < options.start
      )
        seek(options.start);
    },
    dispose() {
      disposed = true;
      for (const [name, listener] of Object.entries(listeners))
        video.removeEventListener(name, listener);
      pause();
    },
  };
}
