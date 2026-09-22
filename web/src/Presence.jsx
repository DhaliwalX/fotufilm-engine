import { AnimatePresence, motion } from "motion/react";

// Keep transient editor surfaces in the tree until their exit completes.
export default function Presence({ show, children, className, ...props }) {
  return (
    <AnimatePresence initial={false}>
      {show && (
        <motion.div
          className={className}
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          exit={{ opacity: 0 }}
          {...props}
        >
          {children}
        </motion.div>
      )}
    </AnimatePresence>
  );
}
