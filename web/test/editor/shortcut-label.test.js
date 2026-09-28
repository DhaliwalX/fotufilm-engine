import test from "node:test";
import assert from "node:assert/strict";
import { isApplePlatform, shortcutLabel } from "../../src/shortcut-label.js";

test("shortcuts read as the platform writes them", () => {
  assert.equal(shortcutLabel("⇧⌘Z", true), "⇧⌘Z");
  assert.equal(shortcutLabel("⇧⌘Z", false), "Ctrl+Shift+Z");
  assert.equal(shortcutLabel("⌥⌘N", false), "Ctrl+Alt+N");
  assert.equal(shortcutLabel("⌘S", false), "Ctrl+S");
  assert.equal(isApplePlatform({ platform: "MacIntel" }), true);
  assert.equal(isApplePlatform({ userAgentData: { platform: "Windows" } }), false);
  assert.equal(isApplePlatform({ platform: "Linux x86_64" }), false);
});
