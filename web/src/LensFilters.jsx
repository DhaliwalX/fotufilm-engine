import { Icon } from "./icons.jsx";
import {
  Disclosure,
  DisclosureTitle,
  DisclosurePanel,
} from "@react-spectrum/s2/Disclosure";
import { Tooltip, TooltipTrigger } from "@react-spectrum/s2/Tooltip";
import { ActionButton } from "@react-spectrum/s2/ActionButton";
import { Picker, PickerItem } from "@react-spectrum/s2/Picker";
import "./LensFilters.css";
import "./motion.css";
import FilterSwatch from "./FilterSwatch.jsx";
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
    onChange({
      filters: next,
    });
  };
  const options = LENS_FILTERS.choices.map((c) => ({
    value: c.id,
    label: c.name,
  }));
  return (
    <Disclosure
      defaultExpanded={true}
      size={"S"}
      isQuiet
      UNSAFE_className={"inspector-section"}
    >
      <DisclosureTitle>{"Filters"}</DisclosureTitle>
      <DisclosurePanel>
        <div className="control-stack">
          {filters.map((id, index) => (
            <div
              className="fitted-filter motion-fade-in"
              key={`${id}:${filters.slice(0, index).filter((value) => value === id).length}`}
              role="group"
              aria-label={`Filter ${index + 1}`}
            >
              <FilterSwatch id={id} stock={stock} />
              <div className="fitted-filter-choice">
                <Picker
                  aria-label={`Filter ${index + 1}`}
                  size="S"
                  value={id}
                  isDisabled={disabled}
                  onChange={(next) => replace(index, next)}
                  UNSAFE_style={{
                    width: "100%",
                  }}
                >
                  {[
                    {
                      value: "none",
                      label: "None",
                    },
                    ...options,
                    ...(!filterChoice(id)
                      ? [
                          {
                            value: id,
                            label: LENS_FILTERS.names[id] || id,
                          },
                        ]
                      : []),
                  ].map((option) => (
                    <PickerItem
                      id={option.value}
                      key={option.value}
                      isDisabled={option.disabled}
                    >
                      {option.label}
                    </PickerItem>
                  ))}
                </Picker>
                <span className="filter-kind">
                  {isDiffusion(id) ? "Scatters" : "Absorbs"}
                </span>
              </div>
              <div className="filter-actions">
                <TooltipTrigger>
                  <ActionButton
                    UNSAFE_className="filter-up"
                    isDisabled={disabled || index === 0}
                    onPress={() => move(index, -1)}
                    aria-label={"Move filter nearer the lens"}
                    size={"S"}
                    isQuiet
                  >
                    <Icon name={"chevronDown"} />
                  </ActionButton>
                  <Tooltip>{"Move filter nearer the lens"}</Tooltip>
                </TooltipTrigger>
                <TooltipTrigger>
                  <ActionButton
                    isDisabled={disabled || index === filters.length - 1}
                    onPress={() => move(index, 1)}
                    aria-label={"Move filter further from the lens"}
                    size={"S"}
                    isQuiet
                  >
                    <Icon name={"chevronDown"} />
                  </ActionButton>
                  <Tooltip>{"Move filter further from the lens"}</Tooltip>
                </TooltipTrigger>
                <TooltipTrigger>
                  <ActionButton
                    isDisabled={disabled}
                    onPress={() => replace(index, "none")}
                    aria-label={"Take this filter off"}
                    size={"S"}
                    isQuiet
                  >
                    <Icon name={"minus"} />
                  </ActionButton>
                  <Tooltip>{"Take this filter off"}</Tooltip>
                </TooltipTrigger>
              </div>
            </div>
          ))}
          <Picker
            label="Add Filter"
            size="S"
            value="none"
            isDisabled={disabled}
            onChange={(id) => {
              if (id !== "none")
                onChange({
                  filters: [...filters, id],
                });
            }}
            UNSAFE_style={{
              width: "100%",
            }}
          >
            {[
              {
                value: "none",
                label: "Add Filter…",
              },
              ...options,
            ].map((option) => (
              <PickerItem
                id={option.value}
                key={option.value}
                isDisabled={option.disabled}
              >
                {option.label}
              </PickerItem>
            ))}
          </Picker>
          {filters.some((id) => !isDiffusion(id)) && (
            <Picker
              label="Metering"
              size="S"
              value={edit.filterMetering || "throughTheLens"}
              isDisabled={disabled}
              onChange={(filterMetering) =>
                onChange({
                  filterMetering,
                })
              }
              UNSAFE_style={{
                width: "100%",
              }}
            >
              {LENS_FILTERS.meterings
                .map((c) => ({
                  value: c.id,
                  label: c.name,
                }))
                .map((option) => (
                  <PickerItem
                    id={option.value}
                    key={option.value}
                    isDisabled={option.disabled}
                  >
                    {option.label}
                  </PickerItem>
                ))}
            </Picker>
          )}
          {!!filters.length && (
            <ActionButton
              size="S"
              isDisabled={disabled}
              onPress={() =>
                onChange({
                  filters: [],
                })
              }
              isQuiet
            >
              {"Take Them All Off"}
            </ActionButton>
          )}
          <p className="medium-detail filter-note">{filterNote(edit)}</p>
        </div>
      </DisclosurePanel>
    </Disclosure>
  );
}
