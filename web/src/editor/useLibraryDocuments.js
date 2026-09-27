import { useCallback, useState } from "react";

// Connects the photo library to the editor: a photo opens under its library key, from which
// useSavedEdits restores its kept edit and keeps later changes, and a photo already open is
// shown rather than opened twice.
export default function useLibraryDocuments({
  files,
  exporting,
  acceptFiles,
  selectFile,
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
      const fresh = items
        .filter((item) => !open.has(item.key))
        .map((item) => ({ file: item.file, editKey: item.key }));
      if (origin && items[0]) setHandoff({ ...origin, key: items[0].key });
      if (fresh.length) await acceptFiles(fresh);
      else if (open.has(items[0]?.key)) selectFile(open.get(items[0].key));
      if (problems.length)
        setError((current) => [current, ...problems].filter(Boolean).join(" "));
    },
    [exporting, files, acceptFiles, selectFile, setError, setLibraryOpen],
  );

  return {
    openFromLibrary,
    libraryHandoff: handoff,
    endLibraryHandoff: useCallback(() => setHandoff(null), []),
  };
}
