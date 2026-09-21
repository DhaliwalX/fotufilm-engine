import "./motion.css";
import { useLayoutEffect, useRef } from "react";

// A panel owns its scroll position; changing tools never moves keyboard focus.
// The keyed content animates only when changing panels, not while editing a value.
export default function InspectorPanel({ panel, label, disabled, children }) {
  const container = useRef(null);
  const positions = useRef(new Map());
  useLayoutEffect(() => {
    container.current.scrollTop = positions.current.get(panel) || 0;
  }, [panel]);
  return (
    <div
      id="inspector-content"
      className="inspector-content"
      role="tabpanel"
      aria-label={label}
      ref={container}
      onScroll={(event) =>
        positions.current.set(panel, event.currentTarget.scrollTop)
      }
    >
      <fieldset
        key={panel}
        className="inspector-panel-enter motion-panel-enter"
        disabled={disabled}
      >
        {children}
      </fieldset>
    </div>
  );
}
