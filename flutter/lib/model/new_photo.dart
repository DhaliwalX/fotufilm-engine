// Settings › Film Model: the settings a newly opened photograph's film model starts from
// (SettingsDialog.jsx). The new photograph's edit itself is saved_edits.dart `newPhotoEdit`.
import 'editor.dart';

/// Settings › Film Model's settings (SettingsDialog.jsx `FILM_MODEL`).
const filmModelSettings = [
  'grainModel',
  'halationModel',
  'estimatedHalation',
  'couplerReach',
  'couplerRedGreen',
  'couplerGreenBlue',
  'couplerSelf',
];

/// Whether Settings › Film Model differs from its defaults (Restore Film Model's state).
bool filmModelAdjusted(AppSettings settings) =>
    filmModelSettings.any((key) => settings.get<Object>(key) != AppSettings.defaults[key]);
