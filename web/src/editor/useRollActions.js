import { useCallback, useRef, useState } from "react";
import { rollBalance, rollDocuments } from "../negative-document.js";
import { THUMBNAIL_EDGE } from "../photo-library/thumbnails.js";
import { thumbnailEdit } from "./useThumbnail.js";

// What the frames of a roll share (the Roll panel): the roll is the strip's scanned negatives from
// the shown frame's directory (rollDocuments). Measure Roll develops each frame small, as its
// thumbnail is, for its own densest end (`negativeMeasure` of a render), and keeps the roll's
// colour (rollBalance) with every frame's edit: the one shown as an undoable change, the others'
// in their histories and kept edits, so each opens on it.
export default function useRollActions(editor) {
  const latest = useRef(editor);
  latest.current = editor;
  const [measuring, setMeasuring] = useState(null);
  const run = useRef(null);

  const { files, active } = editor;
  const frames =
    active?.image?.negative || editor.edit.negative
      ? rollDocuments(files, active)
      : [];

  // Develops `doc` under `edit` for its measurement: the scan the editor holds, or one decoded
  // for the purpose and released after. Resolves its densest end, or null.
  async function measureFrame(doc, edit, signal) {
    const { backend, session } = latest.current;
    if (!session) throw new Error("The renderer is not ready yet.");
    let decoded = null,
      image = doc.image;
    if (!image) {
      const file = doc.source?.file;
      const options = { negative: true, signal };
      decoded = await (file?.hostPath && backend.importPath
        ? backend.importPath(file.hostPath, options)
        : doc.source?.path
          ? backend.importPath(doc.source.path, options)
          : backend.importMedia(file, options));
      image = decoded.image;
    }
    try {
      const result = await session.render({
        image,
        stock: edit.stock,
        edit: thumbnailEdit(edit),
        maxEdge: THUMBNAIL_EDGE,
        background: true,
        stale: () => signal.aborted,
      });
      return result?.negativeMeasure?.denseEnd ?? null;
    } finally {
      if (decoded) {
        backend.releaseImage(decoded.image);
        URL.revokeObjectURL(decoded.url);
      }
    }
  }

  // Sets the roll's colour, or none, on every frame of `docs`, whose edits are `edits`.
  function applyRoll(docs, edits, roll) {
    const now = latest.current;
    docs.forEach((doc, index) => {
      const before = doc.id === now.activeId ? now.edit : edits[index];
      if (!before?.negative) return;
      const after = { ...before, negative: { ...before.negative, roll } };
      if (doc.id === now.activeId) {
        now.endEdit();
        now.patch({ negative: after.negative });
        now.endEdit();
        return;
      }
      const history = now.histories.current.get(doc.id);
      if (history)
        now.histories.current.set(doc.id, {
          past: [...history.past, history.present],
          present: after,
          future: [],
        });
      if (doc.editKey)
        now
          .keepEdit(doc.editKey, after)
          .catch(() =>
            now.setError(
              "The roll could not be kept with every frame on this device.",
            ),
          );
    });
  }

  const measureRoll = useCallback(async () => {
    const now = latest.current;
    const docs = rollDocuments(now.files, now.active);
    if (docs.length < 2 || run.current) return;
    const controller = new AbortController();
    run.current = controller;
    setMeasuring({ done: 0, total: docs.length });
    try {
      const edits = await now.documentEdits(docs);
      const ends = [];
      let failure = null;
      for (const [index, doc] of docs.entries()) {
        if (controller.signal.aborted) return;
        const edit = edits[index];
        if (edit?.negative)
          ends.push(
            await measureFrame(doc, edit, controller.signal).catch((error) => {
              failure ??= `${doc.name}: ${error.message || "it could not be developed."}`;
              return null;
            }),
          );
        setMeasuring({ done: index + 1, total: docs.length });
      }
      if (controller.signal.aborted) return;
      const roll = rollBalance(ends);
      if (!roll) {
        // A frame that could not be developed says why; otherwise the frames were too thin.
        latest.current.setError(
          failure
            ? `The roll could not be measured. ${failure}`
            : "Fewer than two frames of this roll show highlights to balance on. Crop away the holder, or measure a roll with more frames.",
        );
        return;
      }
      applyRoll(docs, edits, roll);
    } catch (error) {
      if (!controller.signal.aborted)
        latest.current.setError(
          error.message || "The roll could not be measured.",
        );
    } finally {
      if (run.current === controller) run.current = null;
      setMeasuring(null);
    }
  }, []);

  const cancelRollMeasure = useCallback(() => run.current?.abort(), []);

  // Takes every frame of the roll back to its own balance.
  const clearRoll = useCallback(async () => {
    const now = latest.current;
    const docs = rollDocuments(now.files, now.active);
    if (!docs.length) return;
    applyRoll(docs, await now.documentEdits(docs), null);
  }, []);

  // Takes the shown frame alone back to its own balance.
  const unrollFrame = useCallback(() => {
    const now = latest.current;
    if (!now.edit.negative?.roll) return;
    now.endEdit();
    now.patch({ negative: { ...now.edit.negative, roll: null } });
    now.endEdit();
  }, []);

  return {
    rollFrames: frames,
    rollMeasuring: measuring,
    measureRoll,
    cancelRollMeasure,
    clearRoll,
    unrollFrame,
  };
}
