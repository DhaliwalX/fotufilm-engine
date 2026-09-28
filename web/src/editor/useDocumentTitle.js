import { useEffect } from "react";

// The window is named after the photo open in it, as the Mac app's is; with none, after the app.
// A native host shows the page's title as its window's (Window menu, Mission Control, the Dock).
export default function useDocumentTitle({ active, backend }) {
  const name = active?.name;
  useEffect(() => {
    if (typeof document === "undefined") return;
    if (!document.documentElement.dataset.startTitle)
      document.documentElement.dataset.startTitle = document.title;
    document.title =
      name ?? (backend.kind === "native" ? "Fotufilm" : document.documentElement.dataset.startTitle);
  }, [name, backend]);
}
