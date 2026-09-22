import PanelDismissButton from "./PanelDismissButton.jsx";
import { ToggleButton } from "@react-spectrum/s2/ToggleButton";
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
  } = useEditor();
  return (
    <aside
      className="film-sidebar"
      aria-label="Film library"
      inert={exporting || (compactLayout && !filmOpen)}
      aria-hidden={compactLayout && !filmOpen}
    >
      <div className="sidebar-heading">
        <span>Film</span>
        <small>{stocks.length}</small>
        <PanelDismissButton panel="film" />
      </div>
      <div className="search-field">
        <SearchField
          aria-label="Search films"
          size={compactLayout ? "L" : "S"}
          placeholder="Search films"
          value={search}
          onChange={setSearch}
          UNSAFE_style={{
            width: "100%",
          }}
        />
      </div>
      <div className="stock-list">
        <ToggleButton
          isQuiet
          UNSAFE_className={`stock-row normal-row ${edit.stock === null ? "selected" : ""}`}
          onPress={() => selectStock(null)}
          size={"S"}
          isSelected={edit.stock === null}
        >
          <span className="stock-thumb">
            {active ? <img src={active.url} alt="" /> : <Icon name="film" />}
          </span>
          <span className="stock-copy">
            <span>Normal</span>
            <small>No film</small>
          </span>
          {edit.stock === null && <Icon name="check" />}
        </ToggleButton>
        {visibleStocks.map((stock) => (
          <StockRow
            key={stock.id}
            stock={stock}
            active={edit.stock === stock.id}
            image={active?.image.video ? null : active?.image}
            session={session}
            onSelect={() => selectStock(stock.id)}
          />
        ))}
        {!visibleStocks.length && !!stocks.length && (
          <p className="empty-search">No matching films.</p>
        )}
      </div>
    </aside>
  );
}
