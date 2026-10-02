import { useState } from "react";
import { Button } from "@react-spectrum/s2/Button";
import { Content, Dialog, Heading } from "@react-spectrum/s2/Dialog";
import { TextField } from "@react-spectrum/s2/TextField";

// A name the folder can hold and the library will list: one visible file name.
export function nameProblem(name) {
  if (!name) return "Enter a name.";
  if (/[/\\:]/.test(name)) return "A name can’t contain “/” or “:”.";
  if (name.startsWith(".")) return "A name starting with a dot is hidden.";
  return null;
}

// Renames one photo. The name field opens with the name before the extension
// selected, so typing replaces it and keeps the extension.
export default function RenameDialog({ photo, onRename }) {
  const [name, setName] = useState(photo.name);
  const trimmed = name.trim();
  const problem = nameProblem(trimmed);
  return (
    <Dialog size="S">
      {({ close }) => (
        <>
          <Heading>Rename Photo</Heading>
          <Content>
            <form
              className="library-rename"
              onSubmit={(event) => {
                event.preventDefault();
                if (problem) return;
                if (trimmed !== photo.name) onRename(trimmed);
                close();
              }}
            >
              <TextField
                label="Name"
                aria-label="Name"
                autoFocus
                value={name}
                onChange={setName}
                isInvalid={!!problem}
                errorMessage={problem}
                onFocus={(event) => {
                  const dot = name.lastIndexOf(".");
                  event.target.setSelectionRange(
                    0,
                    dot > 0 ? dot : name.length,
                  );
                }}
              />
              <div className="dialog-actions">
                <Button size="S" variant="secondary" onPress={close}>
                  Cancel
                </Button>
                <Button
                  size="S"
                  variant="accent"
                  type="submit"
                  isDisabled={!!problem}
                >
                  Rename
                </Button>
              </div>
            </form>
          </Content>
        </>
      )}
    </Dialog>
  );
}
