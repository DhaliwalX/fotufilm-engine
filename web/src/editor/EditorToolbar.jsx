import EditToolbar from "./EditToolbar.jsx";
import ViewToolbar from "./ViewToolbar.jsx";
import FileToolbar from "./FileToolbar.jsx";
export default function EditorToolbar() {
  return (
    <header className="toolbar" aria-label="Editor toolbar">
      <FileToolbar />
      <ViewToolbar />
      <EditToolbar />
    </header>
  );
}
