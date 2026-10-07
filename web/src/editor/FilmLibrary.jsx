import FilmSidebarToggle from "./FilmSidebarToggle.jsx";
import { ActionButton } from "@react-spectrum/s2/ActionButton";
import { useEffect, useRef, useState } from "react";
import { useReducedMotion } from "motion/react";
import StockButton from "./StockButton.jsx";
import { SearchField } from "@react-spectrum/s2/SearchField";
import {
  SegmentedControl,
  SegmentedControlItem,
} from "@react-spectrum/s2/SegmentedControl";
import { Tooltip, TooltipTrigger } from "@react-spectrum/s2/Tooltip";
import { Icon } from "../icons.jsx";
import { StockRow } from "./StockRow.jsx";
import { PresetRow } from "./PresetRow.jsx";
import { useThumbnailSource } from "./useThumbnail.js";
import { useEditor } from "./EditorContext.jsx";
export default function FilmLibrary() {
  const {
    compactLayout,
    filmOpen,
    exporting,
    stocks,
    search,
    setSearch,
    edit,
    selectStock,
    active,
    visibleStocks,
    libraryStocks,
    session,
    setPanel,
    setFilmOpen,
    setInspectorOpen,
    backend,
    videoTime,
    editSettings,
    applyPreset,
    setDialog,
  } = useEditor();
  const [tab, setTab] = useState("film");
  const [presetSearch, setPresetSearch] = useState("");
  const presets = tab === "presets";
  const visiblePresets = editSettings.presets.filter((preset) =>
    preset.name.toLowerCase().includes(presetSearch.toLowerCase()),
  );
  const settled = useThumbnailSource({ active, edit, videoTime, backend });
  const list = useRef(null);
  const reducedMotion = useReducedMotion();
  const displayedStocks = compactLayout ? libraryStocks : visibleStocks;
  const previewSize = compactLayout
    ? Math.max(
        160,
        Math.min(384, Math.ceil(126 * (globalThis.devicePixelRatio || 1))),
      )
    : 160;
  useEffect(() => {
    if (!compactLayout || !filmOpen) return;
    const strip = list.current;
    const selected = strip.querySelector('[aria-pressed="true"]');
    if (!selected) return;
    const tile = selected.getBoundingClientRect(),
      bounds = strip.getBoundingClientRect();
    strip.scrollTo({
      left:
        strip.scrollLeft +
        tile.left -
        bounds.left -
        (bounds.width - tile.width) / 2,
      behavior: reducedMotion ? "instant" : "smooth",
    });
  }, [compactLayout, filmOpen, edit.stock, tab, reducedMotion]);
  return (
    <aside
      className="film-sidebar"
      aria-label="Film library"
      inert={exporting || (compactLayout && !filmOpen)}
      aria-hidden={compactLayout && !filmOpen}
    >
      <div className="sidebar-heading">
        <span
          className="film-heading-label"
          aria-hidden={!compactLayout && !filmOpen}
          inert={!compactLayout && !filmOpen}
        >
          <SegmentedControl
            aria-label="Library"
            size="S"
            selectedKey={tab}
            onSelectionChange={setTab}
            isJustified
            UNSAFE_style={{ width: "100%" }}
          >
            <SegmentedControlItem id="film">{"Films"}</SegmentedControlItem>
            <SegmentedControlItem id="presets">{"Presets"}</SegmentedControlItem>
          </SegmentedControl>
        </span>
        {compactLayout && (
          <ActionButton
            aria-label="Film settings"
            isQuiet
            size="M"
            onPress={() => {
              setPanel("film");
              setFilmOpen(false);
              setInspectorOpen(true);
            }}
          >
            <Icon name="adjustments" />
          </ActionButton>
        )}
        <FilmSidebarToggle />
      </div>
      {!compactLayout && (
        <div className="search-field" inert={!filmOpen} aria-hidden={!filmOpen}>
          <SearchField
            aria-label={presets ? "Search presets" : "Search films"}
            size="S"
            placeholder={presets ? "Search presets" : "Search films"}
            value={presets ? presetSearch : search}
            onChange={presets ? setPresetSearch : setSearch}
            UNSAFE_style={{
              width: "100%",
            }}
          />
          {presets && (
            <TooltipTrigger>
              <ActionButton
                aria-label="Save Preset"
                isQuiet
                size="S"
                isDisabled={!active}
                onPress={() => setDialog("savePreset")}
              >
                <Icon name="plus" />
              </ActionButton>
              <Tooltip>{"Save Preset…"}</Tooltip>
            </TooltipTrigger>
          )}
        </div>
      )}
      <div className="stock-list" id="film-library-content" ref={list}>
        {presets ? (
          <>
            {visiblePresets.map((preset) => (
              <PresetRow
                key={preset.id}
                preset={preset}
                stocks={stocks}
                current={edit}
                image={settled.image}
                edit={settled.edit}
                videoTime={settled.videoTime}
                session={session}
                previewSize={previewSize}
                onSelect={() => applyPreset(preset.id)}
              />
            ))}
            {!editSettings.presets.length ? (
              <p className="empty-search">No presets yet.</p>
            ) : (
              !visiblePresets.length && (
                <p className="empty-search">No matching presets.</p>
              )
            )}
          </>
        ) : (
          <>
            {edit.negative ? (
              // A negative's own picture is the scan: Normal shows its plain positive.
              <StockRow
                stock={null}
                name="Normal"
                kind="No film"
                active={edit.stock === null}
                image={settled.image}
                edit={settled.edit}
                videoTime={settled.videoTime}
                session={session}
                previewSize={previewSize}
                onSelect={() => selectStock(null)}
              />
            ) : (
              <StockButton
                name="Normal"
                kind="No film"
                normal
                url={active?.url}
                selected={edit.stock === null}
                onSelect={() => selectStock(null)}
              />
            )}
            {displayedStocks.map((stock) => (
              <StockRow
                key={stock.id}
                stock={stock}
                active={edit.stock === stock.id}
                image={settled.image}
                edit={settled.edit}
                videoTime={settled.videoTime}
                session={session}
                previewSize={previewSize}
                onSelect={() => selectStock(stock.id)}
              />
            ))}
            {!displayedStocks.length && !!stocks.length && (
              <p className="empty-search">No matching films.</p>
            )}
          </>
        )}
      </div>
    </aside>
  );
}
