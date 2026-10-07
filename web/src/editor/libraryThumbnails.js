import { defaultEdit } from "../editor-state.js";
import { newNegative } from "../negative-document.js";
import { restoreEdit } from "../saved-edits.js";
import { THUMBNAIL_EDGE } from "../photo-library/thumbnails.js";
import { thumbnailEdit } from "./useThumbnail.js";

// The photo library's pictures of photos drawn as they are edited (createThumbnails `render`):
// a photo with a kept edit develops with it, and a scanned negative with none reads without a
// film, as the editor shows it. The photo is decoded for the purpose and released after.
// Resolves the picture, or null for a photo the editor draws no differently.
export function libraryThumbnailRenderer({ backend, session, stocks }) {
  if (!session || !stocks?.length) return null;
  return async ({ photo, file, look }) => {
    let edit = null;
    if (look?.edit)
      try {
        edit = restoreEdit(look.edit, stocks);
      } catch {
        edit = null;
      }
    const negative = !!backend.negativeScans && !!(edit ? edit.negative : photo.negative);
    if (!edit && !negative) return null;
    edit ??= { ...defaultEdit(null), negative: newNegative() };
    const options = { negative };
    const decoded = await (file.hostPath && backend.importPath
      ? backend.importPath(file.hostPath, options)
      : backend.importMedia(file, options));
    try {
      const result = await session.render({
        image: decoded.image,
        stock: edit.stock,
        edit: thumbnailEdit(edit),
        maxEdge: THUMBNAIL_EDGE,
        background: true,
        stale: () => false,
      });
      return result?.blob ?? null;
    } finally {
      backend.releaseImage(decoded.image);
      URL.revokeObjectURL(decoded.url);
    }
  };
}
