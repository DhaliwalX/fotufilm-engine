// Only the native host uses these rectangles. AppKit handles the actual mouse drag.
export function installWindowChrome(transport) {
  if (!transport) return;
  let toolbar, frame;
  const resize = new ResizeObserver(schedule);
  const interactive = 'button,input,select,textarea,a,[role="button"],[role="slider"],[role="combobox"],[role="menuitem"]';
  function schedule() {
    cancelAnimationFrame(frame);
    frame = requestAnimationFrame(() => {
      const next = document.querySelector('.toolbar');
      if (next !== toolbar) {
        resize.disconnect(); toolbar = next;
        if (toolbar) resize.observe(toolbar);
      }
      const rect = (element) => {
        const { x, y, width, height } = element.getBoundingClientRect();
        return [x, y, width, height];
      };
      transport.postMessage({
        id: crypto.randomUUID(), method: 'windowChrome',
        params: { toolbar: toolbar ? rect(toolbar) : [0, 0, 0, 0],
          controls: toolbar ? [...toolbar.querySelectorAll(interactive)].map(rect) : [] },
      }).catch(console.error);
    });
  }
  const mutations = new MutationObserver(schedule);
  mutations.observe(document.body, { childList: true, subtree: true, attributes: true,
    attributeFilter: ['class', 'style', 'hidden'] });
  window.addEventListener('resize', schedule);
  schedule();
  return () => {
    cancelAnimationFrame(frame); resize.disconnect(); mutations.disconnect();
    window.removeEventListener('resize', schedule);
  };
}
