import { ActionButton } from "@react-spectrum/s2/ActionButton";
import { Icon } from "../icons.jsx";
import { useEditor } from "./EditorContext.jsx";
export default function PhotoStrip() {
  const { files, activeId, selectFile, removeFile } = useEditor();
  return (
    <div className="filmstrip" aria-label="Open photos">
      {files.map((file) => (
        <div
          className={`filmstrip-item ${file.id === activeId ? "selected" : ""}`}
          key={file.id}
        >
          <ActionButton
            aria-label={`Select ${file.name}`}
            aria-current={file.id === activeId ? "true" : undefined}
            onPress={() => selectFile(file)}
            isQuiet
            UNSAFE_style={{ width: "100%", height: "100%", padding: 0 }}
            size={"S"}
          >
            <span className="filmstrip-preview">
              <img src={file.url} alt="" />
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
      ))}
    </div>
  );
}
