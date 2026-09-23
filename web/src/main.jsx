import { installWindowChrome } from "./backend/macos/window-chrome.js";
import React from "react";
import { createRoot } from "react-dom/client";
import { Provider } from "@react-spectrum/s2/Provider";
import { MotionConfig } from "motion/react";
import "./spectrum.css";
import "./typography.css";
import App from "./App.jsx";
import { BackendContext } from "./backend/BackendContext.jsx";
import { createBackend } from "./backend/create.js";
import "./app.css";
import { BackendBoundary, BackendFailure } from "./backend/BackendBoundary.jsx";
if (window.fotufilmNativeTransport) document.documentElement.dataset.nativeHost = "macos";
const root = createRoot(document.getElementById("root"));
createBackend(window.fotufilmNative, window.fotufilmNativeTransport)
  .then((backend) =>
    root.render(
      <BackendBoundary>
        <React.StrictMode>
          <Provider locale="en-US" UNSAFE_className="spectrum-editor">
            <MotionConfig
              reducedMotion="user"
              transition={{
                duration: 0.18,
                ease: [0.2, 0.8, 0.2, 1],
              }}
            >
              <BackendContext.Provider value={backend}>
                <App />
              </BackendContext.Provider>
            </MotionConfig>
          </Provider>
        </React.StrictMode>
      </BackendBoundary>,
    ),
  )
  .catch((error) => root.render(<BackendFailure error={error} />));

const disposeChrome = installWindowChrome(window.fotufilmNativeTransport);
if (import.meta.hot) import.meta.hot.dispose(() => disposeChrome?.());
