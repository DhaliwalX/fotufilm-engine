import { AnimatePresence, motion } from "motion/react";
import { ActionButton } from "@react-spectrum/s2/ActionButton";
import { PickerItem, Picker } from "@react-spectrum/s2/Picker";
import { useLayoutEffect, useRef, useState } from "react";
import { HISTOGRAM as labels } from "./generated/controls.js";
import { Icon } from "./icons.jsx";
import { useHistogram } from "./use-histogram.js";
import { useFloatingPanel } from "./use-floating-panel.js";
import HistogramPlot from "./HistogramPlot.jsx";
import "./histogram.css";
export default function HistogramPanel({ result, open, onClose, container }) {
  const [scale, setScale] = useState("log");
  const [view, setView] = useState("rgb");
  const { analysis, error } = useHistogram(result, open);
  const { rect, move, resize } = useFloatingPanel(container, open);
  const [compact, setCompact] = useState(false);
  const header = useRef(null),
    plot = useRef(null);
  useLayoutEffect(() => {
    // A small dead band keeps the controls from flickering at the boundary.
    setCompact((small) =>
      small
        ? rect.width < 340 || rect.height < 200
        : rect.width < 320 || rect.height < 180,
    );
  }, [rect.width, rect.height]);
  useLayoutEffect(() => {
    if (compact && header.current?.contains(document.activeElement))
      plot.current?.focus();
  }, [compact]);

  return (
    <AnimatePresence initial={false}>
      {open && (
        <motion.section
          initial={{ opacity: 0, scale: 0.98 }}
          animate={{ opacity: 1, scale: 1 }}
          exit={{ opacity: 0, scale: 0.98 }}
          className="histogram"
          data-compact={compact}
          role="region"
          aria-label={labels.title}
          aria-busy={!analysis && !error}
          style={{
            left: rect.x,
            top: rect.y,
            width: rect.width,
            height: rect.height,
          }}
          onPointerUp={(e) => e.stopPropagation()}
          onDoubleClick={(e) => e.stopPropagation()}
        >
          <div
            ref={header}
            className="histogram-header"
            inert={compact}
            {...move}
          >
            <button
              type="button"
              className="histogram-drag"
              aria-label={labels.move}
              title="Drag to move; arrow keys move when focused"
              onKeyDown={move.onKeyDown}
            >
              <span>{labels.title}</span>
            </button>
            <Picker
              aria-label={labels.view}
              value={view}
              onChange={(e) => setView(e)}
              size={"S"}
            >
              {labels.views.map((item) => (
                <PickerItem key={item.id} id={item.id}>
                  {item.label}
                </PickerItem>
              ))}
            </Picker>
            <Picker
              aria-label={labels.mode}
              value={scale}
              onChange={(e) => setScale(e)}
              size={"S"}
            >
              {labels.modes.map((mode) => (
                <PickerItem key={mode.id} id={mode.id}>
                  {mode.label}
                </PickerItem>
              ))}
            </Picker>
            <ActionButton
              type="button"
              UNSAFE_className="histogram-close"
              aria-label={labels.close}
              onPress={onClose}
              size={"S"}
            >
              <Icon name="close" size={16} />
            </ActionButton>
          </div>
          <HistogramPlot
            analysis={analysis}
            scale={scale}
            view={view}
            compact={compact}
            move={compact ? move : undefined}
            moveLabel={labels.move}
            containerRef={plot}
          />
          {error && (
            <p className="histogram-error" role="alert">
              {error}
            </p>
          )}
          <button
            type="button"
            className="histogram-resize"
            aria-label={labels.resize}
            title="Drag to resize; arrow keys resize when focused"
            {...resize}
          >
            <span aria-hidden="true" />
          </button>
        </motion.section>
      )}
    </AnimatePresence>
  );
}
