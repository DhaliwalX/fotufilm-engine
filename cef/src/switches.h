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

// Passed to renderers: the extra origin that may use the transport.
inline constexpr char kDevOrigin[] = "fotufilm-dev-origin";
// Passed to renderers: the window property the transport is installed as.
inline constexpr char kTransportGlobal[] = "fotufilm-transport-global";

// Until the engine answers the editor's methods, the transport is installed under a name the
// editor does not look for, and the editor keeps its browser engine.
inline constexpr char kDefaultTransportGlobal[] = "fotufilmDesktop";

}  // namespace fotufilm::switches
