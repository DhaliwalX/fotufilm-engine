// The app's own dialogs, which commands and the editor's services open (EditorWorkspace.jsx's
// `dialog`): Settings, Plug-ins, a film pack's notice, an update and Browser support. The model
// asks for one; the workspace's dialog host shows it.
import 'package:flutter/foundation.dart';

enum AppDialog { settings, plugins, filmPack, update, support }

class AppDialogs extends ChangeNotifier {
  /// The dialog on show, if it is one of these.
  AppDialog? open;

  /// The latest request, which the dialog host takes.
  AppDialog? requested;

  void request(AppDialog dialog) {
    requested = dialog;
    notifyListeners();
  }

  /// Closes `dialog` if it is the one on show (`setDialog(null)`).
  void close([AppDialog? dialog]) {
    if (dialog != null && open != dialog) return;
    requested = null;
    open = null;
    notifyListeners();
  }
}
