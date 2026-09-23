// Own provisional images until the dialog either closes or transfers a result to the library.
export function createImageScope(backend) {
  const images = new Set(),
    urls = new Set();
  let closed = false;
  return {
    image(image) {
      if (closed) backend.releaseImage(image);
      else images.add(image);
      return image;
    },
    preview({ image, url }) {
      // makePreview decorates the same owned image; it must not allocate a second image lease.
      if (closed) URL.revokeObjectURL(url);
      else urls.add(url);
      return image;
    },
    transfer(image, url) {
      images.delete(image);
      urls.delete(url);
    },
    dispose() {
      closed = true;
      for (const image of images) backend.releaseImage(image);
      for (const url of urls) URL.revokeObjectURL(url);
      images.clear();
      urls.clear();
    },
  };
}
