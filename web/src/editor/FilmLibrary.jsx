import FilmSidebarToggle from "./FilmSidebarToggle.jsx";
import { ActionButton } from "@react-spectrum/s2/ActionButton";
import { useEffect, useRef } from "react";
import { useReducedMotion } from "motion/react";
import StockButton from "./StockButton.jsx";
import { SearchField } from "@react-spectrum/s2/SearchField";
import { Icon } from "../icons.jsx";
import { StockRow } from "./StockRow.jsx";
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
    session,
    setPanel,
    setFilmOpen,
    setInspectorOpen,
  } = useEditor();
  const list = useRef(null);
  const reducedMotion = useReducedMotion();
  const displayedStocks = compactLayout ? stocks : visibleStocks;
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
  }, [compactLayout, filmOpen, edit.stock, reducedMotion]);
  return (
    <aside
      className="film-sidebar"
      aria-label="Film library"
      inert={exporting || (compactLayout && !filmOpen)}
      aria-hidden={compactLayout && !filmOpen}
    >
      <div className="sidebar-heading">
        <span className="film-heading-label" aria-hidden={!compactLayout && !filmOpen}>
          <span>Film</span>
          <small>{stocks.length}</small>
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
            aria-label="Search films"
            size="S"
            placeholder="Search films"
            value={search}
            onChange={setSearch}
            UNSAFE_style={{
              width: "100%",
            }}
          />
        </div>
      )}
      <div className="stock-list" id="film-library-content" ref={list}>
        <StockButton
          name="Normal"
          kind="No film"
          normal
          url={active?.url}
          selected={edit.stock === null}
          onSelect={() => selectStock(null)}
        />
        {displayedStocks.map((stock) => (
          <StockRow
            key={stock.id}
            stock={stock}
            active={edit.stock === stock.id}
            image={active?.image.video ? null : active?.image}
            session={session}
            previewSize={previewSize}
            onSelect={() => selectStock(stock.id)}
          />
        ))}
        {!displayedStocks.length && !!stocks.length && (
          <p className="empty-search">No matching films.</p>
        )}
      </div>
    </aside>
  );
}
