// Decode before replacing the visible tile, so updating a blob URL never flashes. A host that
// draws the photograph itself (`present`) shows the tile in its own layer: nothing to decode.
export async function renderViewportImage(session, request, viewport, stale, present = false) {
  const result = await session.render({
    ...request,
    viewport,
    purpose: "visible detail",
    present: present ? "detail" : undefined,
    stale,
  });
  if (!result || stale()) return null;
  if (result.presented)
    return {
      presented: result.presented,
      viewport,
      request,
      backend: result.backend,
      dispose() {},
    };
  const url = URL.createObjectURL(result.blob);
  const originalUrl = URL.createObjectURL(result.original);
  const dispose = () => {
    URL.revokeObjectURL(url);
    URL.revokeObjectURL(originalUrl);
  };
  try {
    await Promise.all(
      [url, originalUrl].map(async (src) => {
        const image = new Image();
        image.src = src;
        await image.decode();
      }),
    );
    if (stale()) {
      dispose();
      return null;
    }
    return {
      url,
      originalUrl,
      viewport,
      request,
      backend: result.backend,
      dispose,
    };
  } catch (error) {
    dispose();
    throw error;
  }
}
