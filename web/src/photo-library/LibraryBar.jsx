import { Button } from "@react-spectrum/s2/Button";
import { Picker, PickerItem } from "@react-spectrum/s2/Picker";
import { SearchField } from "@react-spectrum/s2/SearchField";
import { Slider } from "@react-spectrum/s2/Slider";
import { ToggleButton } from "@react-spectrum/s2/ToggleButton";
import { LIBRARY_SORTS } from "./library-model.js";

const count = new Intl.NumberFormat();
const RATINGS = [
  { id: 0, label: "Any rating" },
  ...[1, 2, 3, 4, 5].map((value) => ({
    id: value,
    label: value === 5 ? "★★★★★" : `${"★".repeat(value)} or more`,
  })),
];

export default function LibraryBar({
  title,
  shown,
  selected,
  filters,
  onFilters,
  tileSize,
  onTileSize,
  onOpen,
}) {
  return (
    <div className="library-bar">
      <div className="library-title">
        <h2>{title}</h2>
        <span>
          {selected > 1
            ? `${count.format(selected)} of ${count.format(shown)} selected`
            : `${count.format(shown)} ${shown === 1 ? "photo" : "photos"}`}
        </span>
      </div>
      <div className="library-controls">
        <SearchField
          aria-label="Search file names"
          placeholder="Search"
          size="S"
          value={filters.search}
          onChange={(search) => onFilters({ search })}
          UNSAFE_style={{ width: 168 }}
        />
        <Picker
          aria-label="Sort"
          size="S"
          selectedKey={filters.sort}
          onSelectionChange={(sort) => onFilters({ sort })}
          UNSAFE_style={{ width: 132 }}
        >
          {LIBRARY_SORTS.map((sort) => (
            <PickerItem key={sort.id} id={sort.id}>
              {sort.label}
            </PickerItem>
          ))}
        </Picker>
        <Picker
          aria-label="Rating"
          size="S"
          selectedKey={filters.minRating}
          onSelectionChange={(minRating) => onFilters({ minRating })}
          UNSAFE_style={{ width: 132 }}
        >
          {RATINGS.map((rating) => (
            <PickerItem key={rating.id} id={rating.id}>
              {rating.label}
            </PickerItem>
          ))}
        </Picker>
        <ToggleButton
          size="S"
          isQuiet
          isSelected={filters.editedOnly}
          onChange={(editedOnly) => onFilters({ editedOnly })}
        >
          Edited
        </ToggleButton>
        <Slider
          aria-label="Thumbnail size"
          labelPosition="side"
          UNSAFE_className="library-size"
          size="S"
          minValue={96}
          maxValue={280}
          step={4}
          value={tileSize}
          onChange={onTileSize}
          UNSAFE_style={{ width: 88 }}
        />
        <Button
          size="S"
          variant="accent"
          isDisabled={!selected}
          onPress={onOpen}
        >
          {selected > 1 ? `Open ${count.format(selected)}` : "Open"}
        </Button>
      </div>
    </div>
  );
}
