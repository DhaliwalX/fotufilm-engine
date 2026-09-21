import test from "node:test";
import assert from "node:assert/strict";
import { defaultEdit, parseEdit } from "../../src/editor-state.js";
import {
  PROFILE_CONTROLS,
  hasProfileSettings,
  profileControlAvailable,
  profileRequestControls,
} from "../../src/profile-settings.js";

const stock = {
  available: PROFILE_CONTROLS.map((c) => c.field),
  defaultMedium: "screen",
  profile: {
    scales: { push: { neutral: 0, stops: [0, 2] } },
    choices: { shutter: [{ id: "off" }, { id: "30" }] },
    media: {
      screen: {
        screenConversion: true,
        screenGrade: true,
        viewingLights: [{ id: "reference" }],
      },
      paper: {
        enlarger: true,
        correction: true,
        viewingLights: [{ id: "reference" }, { id: "tungsten" }],
      },
      negative: {
        negative: true,
        viewingLights: [{ id: "reference" }, { id: "d50" }],
      },
    },
  },
};

test("explicit zero return stays an override and deleting it restores the native film default", () => {
  const edit = defaultEdit("gold200");
  assert.equal(hasProfileSettings(edit), false);
  edit.profile = { halationReturn: 0 };
  assert.equal(hasProfileSettings(edit), true);
  assert.deepEqual(profileRequestControls(edit, stock), { halationReturn: 0 });
  delete edit.profile.halationReturn;
  edit.profile.halationSpectrum = [0, 0, 0, 0, 0, 0, 0];
  assert.equal(hasProfileSettings(edit), false);
});

test("saved edits preserve native curves, printer toggles and all medium-specific viewing choices", () => {
  const edit = {
    ...defaultEdit("gold200"),
    profile: {
      halationSpectrum: [0, 0.2, 0.3, 0, -0.2, 0.5, 1],
      halationReturn: 0,
      printerEnabled: true,
      printerLamp: 3400,
      printLight: "d50",
      shutter: "30",
    },
  };
  const read = (profile) =>
    parseEdit(JSON.stringify({ version: 1, edit: { ...edit, profile } }), [
      "gold200",
    ]);
  assert.deepEqual(read(edit.profile).profile, edit.profile);
  for (const invalid of [
    { halationSpectrum: [0, 0] },
    { halationSpectrum: [0, 0, 0, 0, 0, 0, 100] },
    { printerEnabled: 1 },
    { printerLamp: 100 },
    { printLight: "missing" },
    { shutter: "31" },
    { halationReturn: -1 },
  ])
    assert.throws(() => read(invalid));
});

test("retained controls follow the selected stock and medium without losing saved values", () => {
  const edit = {
    ...defaultEdit("gold200"),
    profile: {
      push: 1,
      shutter: "60",
      printerEnabled: true,
      printerExposure: 1,
      negativeViewing: "scanner",
      screenGrade: 3,
      screenExposure: 1,
      printLight: "tungsten",
    },
  };
  assert.deepEqual(profileRequestControls(edit, stock), {
    push: 0,
    shutter: "off",
    screenGrade: 3,
    screenExposure: 1,
  });
  const paper = profileRequestControls({ ...edit, medium: "paper" }, stock);
  assert.equal(paper.printerEnabled, true);
  assert.equal(paper.printerExposure, 1);
  assert.equal(paper.printLight, "tungsten");
  assert.equal(paper.negativeViewing, undefined);
  assert.equal(paper.screenGrade, undefined);
  const negative = profileRequestControls(
    { ...edit, medium: "negative" },
    stock,
  );
  assert.equal(negative.negativeViewing, "scanner");
  assert.equal(negative.printLight, "reference");
  assert.equal(negative.printerEnabled, undefined);
  assert.equal(edit.profile.push, 1);
  assert.equal(edit.profile.shutter, "60");
  const grade = PROFILE_CONTROLS.find((c) => c.field === "screenGrade");
  assert.equal(
    profileControlAvailable(
      grade,
      { ...edit, digitalReference: "reference-exposure" },
      stock,
    ),
    false,
  );
});
