// Decode before replacing the visible tile, so updating a blob URL never flashes.
export async function renderViewportImage(session, request, viewport, stale) {
  const result = await session.render({
    ...request,
    viewport,
    purpose: "visible detail",
    stale,
  });
  if (!result || stale()) return null;
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
