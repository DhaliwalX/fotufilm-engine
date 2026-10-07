import { ActionButton } from "@react-spectrum/s2/ActionButton";
import { Text } from "@react-spectrum/s2/Text";
import {
  Menu,
  MenuItem,
  MenuSection,
  MenuTrigger,
  SubmenuTrigger,
} from "@react-spectrum/s2/Menu";
import { Icon } from "../icons.jsx";
import { editorControl } from "../editor-catalogue.js";
import { LEGAL_MENU } from "../generated/controls.js";
import { useEditor } from "./EditorContext.jsx";
import { editHistory, filmNamer } from "../edit-history.js";
import { shortcutLabel } from "../shortcut-label.js";

export default function OptionsMenu() {
  const {
    setDialog,
    exporting,
    auto,
    saveEdit,
    active,
    editInput,
    setInspector,
    plugins,
    history,
    dispatch,
    stocks,
    filmPacks,
    openFilmPacks,
    editSettings,
    pasteSettings,
    applyPreset,
    importNegatives,
  } = useEditor();
  const noPhoto = !active || exporting;
  const imageOnlyDisabled = !active || !!active.image.video || exporting;
  // The Edit History, as the Mac app's Edit menu lists it: every step, the one shown ticked.
  const steps = editHistory(history, filmNamer(stocks));
  return (
    <MenuTrigger align="end">
      <ActionButton aria-label="More options" size="S" isQuiet>
        <Icon name="more" />
      </ActionButton>
      <Menu aria-label="Options">
        <MenuSection aria-label="Import">
          {importNegatives && (
            <MenuItem
              id="negative"
              isDisabled={exporting}
              onAction={importNegatives}
            >
              <Icon slot="icon" name="negative" />
              <Text>Import Scanned Negative…</Text>
            </MenuItem>
          )}
          {filmPacks && (
            <MenuItem id="filmPack" isDisabled={exporting} onAction={openFilmPacks}>
              <Icon slot="icon" name="film" />
              <Text>Import Film Pack…</Text>
            </MenuItem>
          )}
        </MenuSection>
        <MenuSection
          aria-label="Automatic adjustments"
          selectionMode="multiple"
          selectedKeys={auto.active ? ["auto"] : []}
          onSelectionChange={() => auto.toggle()}
        >
          <MenuItem id="auto" isDisabled={!auto.available}>
            <Icon slot="icon" name={auto.busy ? "close" : "autoAdjust"} />
            <Text>
              {auto.busy
                ? "Cancel Auto Adjust"
                : editorControl("autoAdjustment").title}
            </Text>
          </MenuItem>
        </MenuSection>
        <MenuSection aria-label="Edit history">
          <SubmenuTrigger>
            <MenuItem id="history" isDisabled={!active || exporting}>
              <Icon slot="icon" name="undo" />
              <Text>Edit History</Text>
            </MenuItem>
            <Menu
              aria-label="Edit History"
              selectionMode="single"
              disallowEmptySelection
              selectedKeys={[`step-${steps.index}`]}
              onSelectionChange={(keys) => {
                const [key] = keys;
                if (key)
                  dispatch({ type: "goTo", index: Number(String(key).replace("step-", "")) });
              }}
            >
              {steps.titles.map((title, index) => (
                <MenuItem key={index} id={`step-${index}`} textValue={title}>
                  <Text>{title}</Text>
                </MenuItem>
              ))}
            </Menu>
          </SubmenuTrigger>
        </MenuSection>
        <MenuSection aria-label="Settings">
          <MenuItem
            id="copySettings"
            textValue="Copy Settings…"
            isDisabled={noPhoto}
            onAction={() => setDialog("copySettings")}
          >
            <Icon slot="icon" name="copySettings" />
            <Text>Copy Settings…</Text>
            <Text slot="description">{shortcutLabel("⌥⌘C")}</Text>
          </MenuItem>
          <MenuItem
            id="pasteSettings"
            textValue="Paste Settings"
            isDisabled={noPhoto || !editSettings.copied}
            onAction={pasteSettings}
          >
            <Icon slot="icon" name="pasteSettings" />
            <Text>Paste Settings</Text>
            <Text slot="description">{shortcutLabel("⌥⌘V")}</Text>
          </MenuItem>
          <SubmenuTrigger>
            <MenuItem id="presets" textValue="Presets">
              <Icon slot="icon" name="presets" />
              <Text>Presets</Text>
            </MenuItem>
            <Menu aria-label="Presets">
              <MenuSection aria-label="Apply preset">
                {editSettings.presets.map((preset) => (
                  <MenuItem
                    key={preset.id}
                    id={`preset-${preset.id}`}
                    textValue={preset.name}
                    isDisabled={noPhoto}
                    onAction={() => applyPreset(preset.id)}
                  >
                    <Text>{preset.name}</Text>
                  </MenuItem>
                ))}
              </MenuSection>
              <MenuSection aria-label="Manage presets">
                <MenuItem
                  id="savePreset"
                  isDisabled={noPhoto}
                  onAction={() => setDialog("savePreset")}
                >
                  <Text>Save Preset…</Text>
                </MenuItem>
                <MenuItem
                  id="managePresets"
                  isDisabled={!editSettings.presets.length}
                  onAction={() => setDialog("presets")}
                >
                  <Text>Manage Presets…</Text>
                </MenuItem>
              </MenuSection>
            </Menu>
          </SubmenuTrigger>
        </MenuSection>
        <MenuSection aria-label="Saved edits">
          <MenuItem
            id="save"
            isDisabled={!active || exporting}
            onAction={saveEdit}
          >
            <Icon slot="icon" name="saveEdits" />
            <Text>Save edits…</Text>
          </MenuItem>
          <MenuItem
            id="load"
            isDisabled={!active || exporting}
            onAction={() => editInput.current?.click()}
          >
            <Icon slot="icon" name="loadEdits" />
            <Text>Load edits…</Text>
          </MenuItem>
        </MenuSection>
        <MenuSection aria-label="Tools">
          <MenuItem
            id="selective"
            isDisabled={imageOnlyDisabled}
            onAction={() => setInspector("selective")}
          >
            <Icon slot="icon" name="selective" />
            <Text>Selective</Text>
          </MenuItem>
          <MenuItem
            id="crop"
            isDisabled={imageOnlyDisabled}
            onAction={() => setInspector("crop")}
          >
            <Icon slot="icon" name="crop" />
            <Text>Crop</Text>
          </MenuItem>
          <MenuItem id="pipeline" onAction={() => setInspector("pipeline")}>
            <Icon slot="icon" name="pipeline" />
            <Text>Inspect pipeline</Text>
          </MenuItem>
        </MenuSection>
        <MenuSection aria-label="Help">
          <MenuItem id="settings" onAction={() => setDialog("settings")}>
            <Icon slot="icon" name="adjustments" />
            <Text>Settings…</Text>
          </MenuItem>
          {plugins && (
            <MenuItem
              id="plugins"
              isDisabled={exporting}
              onAction={() => setDialog("plugins")}
            >
              <Icon slot="icon" name="export" />
              <Text>Plug-ins…</Text>
            </MenuItem>
          )}
          <MenuItem id="shortcuts" onAction={() => setDialog("shortcuts")}>
            <Icon slot="icon" name="shortcuts" />
            <Text>Keyboard shortcuts</Text>
          </MenuItem>
          <MenuItem id="support" onAction={() => setDialog("support")}>
            <Icon slot="icon" name="help" />
            <Text>Browser support</Text>
          </MenuItem>
        </MenuSection>
        <MenuSection aria-label={LEGAL_MENU.title}>
          {LEGAL_MENU.links.map(({ id, title, icon, href }) => (
            <MenuItem
              key={id}
              id={id}
              href={href}
              target="_blank"
              rel="noopener noreferrer"
            >
              <Icon slot="icon" name={icon} />
              <Text>{title}</Text>
            </MenuItem>
          ))}
        </MenuSection>
      </Menu>
    </MenuTrigger>
  );
}
