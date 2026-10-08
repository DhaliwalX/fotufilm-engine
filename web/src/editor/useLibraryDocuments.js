import { useCallback, useState } from "react";

// Connects the photo library to the editor: a photo opens under its library key, from which
// useSavedEdits restores its kept edit and keeps later changes, and a photo already open is
// shown rather than opened twice. An open photo renamed in the library keeps its edit under
// the new key and is read from its new name; one moved to the trash is closed.
export default function useLibraryDocuments({
  files,
  exporting,
  acceptFiles,
  selectFile,
  removeFiles,
  setFiles,
  setError,
  setLibraryOpen,
}) {
  const [handoff, setHandoff] = useState(null);

  const openFromLibrary = useCallback(
    async ({ items, missing, origin }) => {
      if (exporting || (!items.length && !missing.length)) return;
      setLibraryOpen(false);
      const problems = missing.map(
        (name) => `${name} is no longer in its folder.`,
      );
      const open = new Map(
        files
          .filter((file) => file.editKey)
          .map((file) => [file.editKey, file]),
      );
      // The photo chosen, shown first; a roll opened with it fills the strip around it.
      const shown = items.find((item) => item.shown) ?? items[0];
      const fresh = items.filter((item) => !open.has(item.key));
      if (origin && shown) setHandoff({ ...origin, key: shown.key });
      if (fresh.length)
        await acceptFiles(
          items.map((item) => ({
            file: item.file,
            editKey: item.key,
            negative: !!item.negative,
            roll: item.roll ?? null,
            shown: item === shown,
          })),
        );
      else if (open.has(shown?.key)) selectFile(open.get(shown.key));
      if (problems.length)
        setError((current) => [current, ...problems].filter(Boolean).join(" "));
    },
    [exporting, files, acceptFiles, selectFile, setError, setLibraryOpen],
  );

  const libraryPhotoRenamed = useCallback(
    ({ from, to, name }) =>
      setFiles((current) =>
        current.map((doc) => {
          if (doc.editKey !== from) return doc;
          const { file } = doc.source;
          const renamed = file
            ? Object.assign(
                new File([file], name, {
                  type: file.type,
                  lastModified: file.lastModified,
                }),
                file.hostPath
                  ? { hostPath: file.hostPath.replace(/[^/]*$/, name) }
                  : {},
              )
            : file;
          return {
            ...doc,
            name,
            editKey: to,
            source: { ...doc.source, file: renamed, name, editKey: to },
          };
        }),
      ),
    [setFiles],
  );
  const libraryPhotosTrashed = useCallback(
    (keys) => {
      const gone = new Set(keys);
      const closing = files.filter((doc) => gone.has(doc.editKey));
      if (closing.length) removeFiles(closing);
    },
    [files, removeFiles],
  );

  return {
    openFromLibrary,
    libraryPhotoRenamed,
    libraryPhotosTrashed,
    libraryHandoff: handoff,
    endLibraryHandoff: useCallback(() => setHandoff(null), []),
  };
}
