import { AlertDialog } from "@react-spectrum/s2/AlertDialog";
import { Button } from "@react-spectrum/s2/Button";
import { ButtonGroup } from "@react-spectrum/s2/ButtonGroup";
import { Content, Dialog, Heading } from "@react-spectrum/s2/Dialog";
import { ProgressBar } from "@react-spectrum/s2/ProgressBar";
import { useEditor } from "./EditorContext.jsx";
import { formatBytes } from "./useUpdates.js";

// Check for Updates' answers, as the Mac app's alerts give them (useUpdates.js).
export default function UpdateDialog() {
  const {
    update,
    setDialog,
    installUpdate,
    cancelUpdate,
    skipUpdate,
    openReleaseNotes,
  } = useEditor();
  if (!update) return null;
  if (update.kind === "notice")
    return (
      <AlertDialog
        title={update.title}
        variant={update.warning ? "warning" : "confirmation"}
        primaryActionLabel="OK"
      >
        {update.message}
      </AlertDialog>
    );
  if (update.kind === "downloading")
    return (
      <Dialog aria-label="Downloading update" size="S" isDismissible={false}>
        <Heading>{`Downloading Fotufilm ${update.version}…`}</Heading>
        <Content>
          <p>
            The installer opens once the download matches the checksum its release published.
          </p>
          <ProgressBar
            aria-label="Download progress"
            isIndeterminate={!(update.total > 0)}
            value={update.total > 0 ? (100 * update.bytes) / update.total : 0}
            UNSAFE_style={{ width: "100%" }}
          />
          <p className="update-bytes">
            {update.total > 0
              ? `${formatBytes(update.bytes)} of ${formatBytes(update.total)}`
              : "Connecting…"}
          </p>
        </Content>
        <ButtonGroup>
          <Button variant="secondary" onPress={cancelUpdate}>
            Cancel
          </Button>
        </ButtonGroup>
      </Dialog>
    );
  return (
    <Dialog aria-label="Update available" size="L" isDismissible={false}>
      <Heading>{`Fotufilm ${update.version} is available`}</Heading>
      <Content>
        {`You have Fotufilm ${update.current}. The update arrives as a signed installer, like the one this copy was installed from. Installing may ask for your administrator password.`}
      </Content>
      <ButtonGroup>
        {update.notes && (
          <Button variant="secondary" onPress={openReleaseNotes}>
            Release Notes
          </Button>
        )}
        {update.allowSkip && (
          <Button variant="secondary" onPress={skipUpdate}>
            Skip This Version
          </Button>
        )}
        <Button variant="secondary" onPress={() => setDialog(null)}>
          Not Now
        </Button>
        <Button variant="accent" onPress={installUpdate}>
          Download and Install…
        </Button>
      </ButtonGroup>
    </Dialog>
  );
}
