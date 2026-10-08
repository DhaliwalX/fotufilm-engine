import test from "node:test";
import assert from "node:assert/strict";
import {
  PANEL_WIDTHS,
  PICTURE_MIN,
  clampedWidth,
  keptWidths,
  shownWidths,
} from "../../src/editor/usePanelWidths.js";

test("a side panel resizes inside its bounds and leaves the picture its room", () => {
  // A wide window: only the panel's own bounds hold it.
  assert.equal(clampedWidth("film", 300, 330, 2000), 300);
  assert.equal(clampedWidth("film", 20, 330, 2000), PANEL_WIDTHS.film.min);
  assert.equal(
    clampedWidth("inspector", 9000, 236, 2000),
    PANEL_WIDTHS.inspector.max,
  );
  // The picture keeps its 420 pixels beside the other panel.
  assert.equal(
    clampedWidth("inspector", 600, 236, 1100),
    1100 - 236 - PICTURE_MIN,
  );
  // A window too narrow for all three still shows each panel at its least.
  assert.equal(clampedWidth("film", 300, 330, 600), PANEL_WIDTHS.film.min);
  assert.equal(
    clampedWidth("film", Number.NaN, 330, 2000),
    PANEL_WIDTHS.film.min,
  );
});

test("a narrow window narrows the inspector first and gives the widths back as it widens", () => {
  const preferred = { film: 300, inspector: 500 };
  assert.deepEqual(shownWidths(preferred, 1600), preferred);
  // 1100 leaves 380 for the inspector beside a 300-pixel film list.
  assert.deepEqual(shownWidths(preferred, 1100), { film: 300, inspector: 380 });
  // Narrower still, the inspector stops at its least and the film list gives way.
  assert.deepEqual(shownWidths(preferred, 950), { film: 250, inspector: 280 });
  // The preference is untouched, so a wider window shows it again.
  assert.deepEqual(shownWidths(preferred, 1600), preferred);
});

test("widths kept from the last visit are read back inside their bounds", () => {
  assert.deepEqual(keptWidths(null), { film: 236, inspector: 330 });
  assert.deepEqual(keptWidths("{"), { film: 236, inspector: 330 });
  assert.deepEqual(keptWidths(JSON.stringify({ film: 300, inspector: 9000 })), {
    film: 300,
    inspector: PANEL_WIDTHS.inspector.max,
  });
  assert.deepEqual(keptWidths(JSON.stringify({ film: "wide" })), {
    film: 236,
    inspector: 330,
  });
});
