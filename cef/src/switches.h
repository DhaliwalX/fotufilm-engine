// Command-line switches the host understands, and those it hands to its child processes.
#pragma once

namespace fotufilm::switches {

// Load the editor from a development server (for example Vite on http://127.0.0.1:5173) instead
// of the bundled build, keeping hot reload. Its origin is trusted with the transport.
inline constexpr char kDevUrl[] = "fotufilm-dev-url";
// Serve the editor from this directory instead of the bundle's web build.
inline constexpr char kWebRoot[] = "fotufilm-web-root";
// Open the bridge diagnostics page instead of the editor.
inline constexpr char kDiagnostics[] = "fotufilm-diagnostics";
// Keep the browser profile (library, settings) in this directory, so a second copy of the app can
// run beside the first rather than hand its launch over to it.
inline constexpr char kProfile[] = "fotufilm-profile";

// Passed to renderers: the extra origin that may use the transport.
inline constexpr char kDevOrigin[] = "fotufilm-dev-origin";
// Passed to renderers: the window property the transport is installed as.
inline constexpr char kTransportGlobal[] = "fotufilm-transport-global";
// Passed to renderers: the engine's capabilities JSON, exposed as the transport's
// `capabilities`.
inline constexpr char kCapabilities[] = "fotufilm-capabilities";

// With the engine linked the transport is the one the editor looks for
// (web/src/backend/macos/host.js). Without it the transport is installed under a name the editor
// does not look for, and the editor keeps its browser engine.
#if defined(FOTUFILM_WITH_ENGINE)
inline constexpr char kDefaultTransportGlobal[] = "fotufilmNativeTransport";
#else
inline constexpr char kDefaultTransportGlobal[] = "fotufilmDesktop";
#endif

}  // namespace fotufilm::switches
