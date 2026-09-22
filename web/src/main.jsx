import React from "react";
import { createRoot } from "react-dom/client";
import { Provider } from "@react-spectrum/s2/Provider";
import { MotionConfig } from "motion/react";
import "./spectrum.css";
import "./typography.css";
import App from "./App.jsx";
import "./app.css";
createRoot(document.getElementById("root")).render(
  <React.StrictMode>
    <Provider locale="en-US" UNSAFE_className="spectrum-editor">
      <MotionConfig
        reducedMotion="user"
        transition={{
          duration: 0.18,
          ease: [0.2, 0.8, 0.2, 1],
        }}
      >
        <App />
      </MotionConfig>
    </Provider>
  </React.StrictMode>,
);
