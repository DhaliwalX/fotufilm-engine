import test from "node:test";
import assert from "node:assert/strict";
import { launchOffer, pluginsToOffer } from "../../src/editor/usePlugins.js";

const plugin = (id, state, extra = {}) => ({
  id,
  state,
  bundledVersion: "7",
  hostInstalled: true,
  ...extra,
});

test("launch offers this build's plug-ins for the editors on this computer", () => {
  const list = [
    plugin("resolve", "notInstalled"),
    plugin("finalCut", "outdated", { hostInstalled: false }),
  ];
  assert.deepEqual(
    pluginsToOffer(list).map(({ id }) => id),
    ["resolve"],
  );
  assert.deepEqual(launchOffer(list, null), {
    ids: ["resolve"],
    version: "7",
    updating: false,
  });
  // Nothing is offered for a plug-in already this build's or one the build lacks.
  assert.equal(
    launchOffer(
      [plugin("resolve", "installed"), plugin("finalCut", "notBundled", { bundledVersion: undefined })],
      null,
    ),
    null,
  );
});

test("an update is worded as one, and a declined build is not asked again", () => {
  const list = [plugin("resolve", "outdated"), plugin("finalCut", "outdated")];
  assert.equal(launchOffer(list, null).updating, true);
  assert.equal(launchOffer(list, "7"), null);
  // A later build is a different question.
  assert.equal(launchOffer(list, "6").version, "7");
});
