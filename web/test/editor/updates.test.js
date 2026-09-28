import test from "node:test";
import assert from "node:assert/strict";
import { checkOutcome, formatBytes } from "../../src/editor/useUpdates.js";

const available = {
  state: "available",
  current: "1.10 (build 12)",
  version: "1.11",
  release: "1.11 (build 3)",
  notes: "https://fotufilm.com/releases",
};

test("the menu command always answers, as the Mac app's does", () => {
  assert.deepEqual(checkOutcome({ state: "current", current: "1.10 (build 12)" }, { manual: true }), {
    kind: "notice",
    title: "You're up to date",
    message: "Fotufilm 1.10 (build 12) is the newest release.",
  });
  const failed = checkOutcome({ state: "failed", message: "The update feed answered with status 404." }, { manual: true });
  assert.equal(failed.title, "Fotufilm could not check for updates");
  assert.equal(failed.warning, true);
  const offer = checkOutcome(available, { manual: true, skipped: "1.11 (build 3)" });
  assert.equal(offer.kind, "available");
  assert.equal(offer.allowSkip, false);
});

test("an automatic check speaks only of a release not skipped", () => {
  assert.equal(checkOutcome({ state: "current" }, { manual: false }), null);
  assert.equal(checkOutcome({ state: "failed" }, { manual: false }), null);
  assert.equal(checkOutcome(available, { manual: false, skipped: "1.11 (build 3)" }), null);
  const offer = checkOutcome(available, { manual: false, skipped: "1.11 (build 2)" });
  assert.equal(offer.allowSkip, true);
  assert.equal(offer.notes, "https://fotufilm.com/releases");
});

test("download sizes read as the Mac's file-size formatter", () => {
  assert.equal(formatBytes(12_345_678), "12.3 MB");
  assert.equal(formatBytes(1_500_000_000), "1.5 GB");
  assert.equal(formatBytes(512_000), "512 KB");
});
