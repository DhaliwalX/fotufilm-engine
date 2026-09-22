import DevelopInspector from "./DevelopInspector.jsx";
import ProfileFields from "./ProfileFields.jsx";
import {
  SegmentedControl,
  SegmentedControlItem,
} from "@react-spectrum/s2/SegmentedControl";
import {
  Disclosure,
  DisclosureTitle,
  DisclosurePanel,
} from "@react-spectrum/s2/Disclosure";
import InspectorHeading from "./InspectorHeading.jsx";
import { inspectorPanels } from "../editor-catalogue.js";
import InspectorPanel from "../InspectorPanel.jsx";
import FilmInspector from "./FilmInspector.jsx";
import PrintInspector from "./PrintInspector.jsx";
import LightInspector from "./LightInspector.jsx";
import LensFilters from "../LensFilters.jsx";
import LensInspector from "./LensInspector.jsx";
import SourceInspector from "./SourceInspector.jsx";
import SelectiveInspector from "./SelectiveInspector.jsx";
import CropInspector from "./CropInspector.jsx";
import PipelineInspector from "./PipelineInspector.jsx";
import { useEditor } from "./EditorContext.jsx";
export default function EditorInspector() {
  const {
    inspectorOpen,
    panel,
    setInspector,
    exporting,
    active,
    edit,
    fixedSettings,
    patch,
    selectedStock,
    endEdit,
    setStage,
    setDifference,
  } = useEditor();
  return (
    <aside
      className="inspector"
      aria-label="Adjustments"
      inert={!inspectorOpen}
      aria-hidden={!inspectorOpen}
    >
      <InspectorHeading />
      <SegmentedControl
        UNSAFE_style={{
          width: "calc(100% - 24px)",
          margin: "10px 12px 8px",
        }}
        aria-label="Adjustment panels"
        selectedKey={panel}
        onSelectionChange={setInspector}
        isJustified
      >
        {inspectorPanels.map(({ id, title }) => (
          <SegmentedControlItem
            key={id}
            id={id}
            UNSAFE_style={{ paddingInline: 6 }}
          >
            {title}
          </SegmentedControlItem>
        ))}
      </SegmentedControl>
      <InspectorPanel
        panel={panel}
        contentKey={`${panel}:${edit.stock}`}
        disabled={exporting || !active}
        label={
          inspectorPanels.find((p) => p.id === panel)?.title ||
          (panel === "crop"
            ? "Crop"
            : panel === "selective"
              ? "Selective"
              : "Pipeline")
        }
      >
        {panel === "film" && <FilmInspector />}
        {panel === "develop" && <DevelopInspector />}
        {panel === "print" && <PrintInspector />}
        {panel === "light" && <LightInspector />}
        {panel === "light" && selectedStock?.available.includes("shutter") && (
          <Disclosure
            defaultExpanded={true}
            size={"S"}
            isQuiet
            UNSAFE_className={"inspector-section"}
          >
            <DisclosureTitle>{"Long Exposure"}</DisclosureTitle>
            <DisclosurePanel>
              <div className="control-stack">
                {<ProfileFields fields={["shutter"]} />}
              </div>
            </DisclosurePanel>
          </Disclosure>
        )}
        {panel === "light" && !fixedSettings && (
          <LensFilters
            edit={edit}
            stock={selectedStock}
            disabled={exporting || !active || edit.halationModel === "layered"}
            onChange={(value) => {
              endEdit();
              patch(value);
              setStage(null);
              setDifference(false);
            }}
          />
        )}
        {panel === "light" && <LensInspector />}
        {panel === "light" && <SourceInspector />}
        {panel === "selective" && <SelectiveInspector />}
        {panel === "crop" && <CropInspector />}
        {panel === "pipeline" && <PipelineInspector />}
      </InspectorPanel>
    </aside>
  );
}
