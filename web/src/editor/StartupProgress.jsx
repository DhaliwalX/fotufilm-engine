import { useEffect, useState } from "react";
import { AnimatePresence, motion, useReducedMotion } from "motion/react";
import { ProgressBar } from "@react-spectrum/s2/ProgressBar";
import FotufilmBrand from "./FotufilmBrand.jsx";
import "./startup-progress.css";

export default function StartupProgress({ progress }) {
  const [visible, setVisible] = useState(true);
  const reducedMotion = useReducedMotion();
  useEffect(() => {
    if (!progress.done) {
      setVisible(true);
      return;
    }
    // Let the bar reach its final value before fading the loader away.
    const timer = setTimeout(() => setVisible(false), reducedMotion ? 0 : 300);
    return () => clearTimeout(timer);
  }, [progress.done, reducedMotion]);
  return (
    <AnimatePresence>
      {visible && (
        <motion.div
          className="startup-progress"
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          exit={{ opacity: 0 }}
          transition={{ duration: reducedMotion ? 0 : 0.35 }}
        >
          <FotufilmBrand />
          <ProgressBar
            aria-label="Preparing editor"
            isIndeterminate={!progress.done}
            label={
              <AnimatePresence mode="wait" initial={false}>
                <motion.span
                  key={progress.label}
                  initial={{ opacity: 0 }}
                  animate={{ opacity: 1 }}
                  exit={{ opacity: 0 }}
                  transition={{ duration: reducedMotion ? 0 : 0.12 }}
                >
                  {progress.label}
                </motion.span>
              </AnimatePresence>
            }
            value={progress.value}
            size="S"
          />
        </motion.div>
      )}
    </AnimatePresence>
  );
}
