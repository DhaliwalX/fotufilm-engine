import { AnimatePresence, motion } from "motion/react";
import { useLayoutEffect, useRef } from "react";

export default function InspectorPanel({
  panel,
  contentKey = panel,
  label,
  disabled,
  children,
}) {
  const container = useRef(null);
  const positions = useRef(new Map());
  useLayoutEffect(() => {
    container.current.scrollTop = positions.current.get(panel) || 0;
  }, [panel]);
  return (
    <div
      id="inspector-content"
      className="inspector-content"
      role="region"
      aria-label={label}
      ref={container}
      onScroll={(event) =>
        positions.current.set(panel, event.currentTarget.scrollTop)
      }
    >
      <AnimatePresence initial={false} mode="wait">
        <motion.fieldset
          key={contentKey}
          disabled={disabled}
          initial={{ opacity: 0, y: 3 }}
          animate={{ opacity: 1, y: 0 }}
          exit={{ opacity: 0, y: -3 }}
          transition={{ duration: 0.12 }}
        >
          {children}
        </motion.fieldset>
      </AnimatePresence>
    </div>
  );
}
