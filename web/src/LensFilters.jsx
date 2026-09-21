import "./LensFilters.css";
import "./motion.css";
import FilterSwatch from "./FilterSwatch.jsx";
import { Selector } from "@astryxdesign/core/Selector";
import { Button } from "@astryxdesign/core/Button";
import { Section, ToolButton } from "./EditorControls.jsx";
import { LENS_FILTERS } from "./generated/controls.js";
import { filterChoice, filterNote, isDiffusion } from "./lens-filters.js";

export default function LensFilters({ edit, stock, onChange, disabled }) {
  const filters = edit.filters || [];
  const replace = (index, id) =>
    onChange({
      filters:
        id === "none"
          ? filters.filter((_, i) => i !== index)
          : filters.map((value, i) => (i === index ? id : value)),
    });
  const move = (index, delta) => {
    const next = [...filters];
    [next[index], next[index + delta]] = [next[index + delta], next[index]];
    onChange({ filters: next });
  };
  const options = LENS_FILTERS.choices.map((c) => ({
    value: c.id,
    label: c.name,
  }));
  return (
    <Section title="Filters">
      {filters.map((id, index) => (
        <div
          className="fitted-filter motion-fade-in"
          key={`${id}:${filters.slice(0, index).filter((value) => value === id).length}`}
          role="group"
          aria-label={`Filter ${index + 1}`}
        >
          <FilterSwatch id={id} stock={stock} />
          <div className="fitted-filter-choice">
            <Selector
              label={`Filter ${index + 1}`}
              isLabelHidden
              size="sm"
              width="100%"
              value={id}
              isDisabled={disabled}
              options={[
                { value: "none", label: "None" },
                ...options,
                ...(!filterChoice(id)
                  ? [{ value: id, label: LENS_FILTERS.names[id] || id }]
                  : []),
              ]}
              onChange={(next) => replace(index, next)}
            />
            <span className="filter-kind">
              {isDiffusion(id) ? "Scatters" : "Absorbs"}
            </span>
          </div>
          <div className="filter-actions">
            <ToolButton
              icon="chevronDown"
              className="filter-up"
              label="Move filter nearer the lens"
              disabled={disabled || index === 0}
              onClick={() => move(index, -1)}
            />
            <ToolButton
              icon="chevronDown"
              label="Move filter further from the lens"
              disabled={disabled || index === filters.length - 1}
              onClick={() => move(index, 1)}
            />
            <ToolButton
              icon="minus"
              label="Take this filter off"
              disabled={disabled}
              onClick={() => replace(index, "none")}
            />
          </div>
        </div>
      ))}
      <Selector
        label="Add Filter"
        size="sm"
        width="100%"
        value="none"
        isDisabled={disabled}
        options={[{ value: "none", label: "Add Filter…" }, ...options]}
        onChange={(id) => {
          if (id !== "none") onChange({ filters: [...filters, id] });
        }}
      />
      {filters.some((id) => !isDiffusion(id)) && (
        <Selector
          label="Metering"
          size="sm"
          width="100%"
          value={edit.filterMetering || "throughTheLens"}
          isDisabled={disabled}
          options={LENS_FILTERS.meterings.map((c) => ({
            value: c.id,
            label: c.name,
          }))}
          onChange={(filterMetering) => onChange({ filterMetering })}
        />
      )}
      {!!filters.length && (
        <Button
          label="Take Them All Off"
          size="sm"
          variant="ghost"
          isDisabled={disabled}
          onClick={() => onChange({ filters: [] })}
        />
      )}
      <p className="medium-detail filter-note">{filterNote(edit)}</p>
    </Section>
  );
}
