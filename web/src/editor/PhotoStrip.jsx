import { ActionButton } from "@react-spectrum/s2/ActionButton";
import { Icon } from "../icons.jsx";
import { useEditor } from "./EditorContext.jsx";
import { stripPath } from "./opened-folder.js";
// The open photos, under the path of the one shown. A click shows one; Shift-click and
// Command-click choose more for Paste Settings and presets to apply to, with the one shown
// (useStripSelection.js).
export default function PhotoStrip() {
  const { files, activeId, selectedFiles, pressPhoto, removeFile } =
    useEditor();
  const several = selectedFiles.length > 1;
  const shown = files.find((file) => file.id === activeId);
  const place = shown ? stripPath(shown) : "";
  return (
    <div className="filmstrip" aria-label="Open photos">
      {place && (
        // Clipped at its start, so the file name stays in view; the whole path on hover.
        <div className="filmstrip-path" title={place}>
          <bdi>{place}</bdi>
        </div>
      )}
      <div className="filmstrip-items">
        {files.map((file) => {
          const chosen = several && selectedFiles.includes(file);
          return (
            <div
              className={`filmstrip-item ${file.id === activeId ? "selected" : ""} ${chosen ? "chosen" : ""}`}
              key={file.id}
            >
              <ActionButton
                aria-label={`Select ${file.name}`}
                aria-current={file.id === activeId ? "true" : undefined}
                aria-pressed={several ? chosen : undefined}
                onPress={(e) => pressPhoto(file, e)}
                isQuiet
                UNSAFE_style={{ width: "100%", height: "100%", padding: 0 }}
                size={"S"}
              >
                <span className="filmstrip-preview">
                  {file.url ? (
                    <img src={file.url} alt="" />
                  ) : (
                    <span className="filmstrip-name">{file.name}</span>
                  )}
                </span>
              </ActionButton>
              <span className="filmstrip-close">
                <ActionButton
                  aria-label={`Close ${file.name}`}
                  onPress={() => removeFile(file)}
                  size={"S"}
                  UNSAFE_style={{
                    width: 24,
                    minWidth: 24,
                    height: 24,
                    padding: 0,
                    borderRadius: "50%",
                  }}
                >
                  <Icon name="close" size={14} />
                </ActionButton>
              </span>
            </div>
          );
        })}
      </div>
    </div>
  );
}
