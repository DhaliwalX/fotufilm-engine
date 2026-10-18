// The app's own dialogs: the host that shows the one the editor asks for (Settings, Plug-ins, a
// film pack's notice, an update, Browser support), and the card and alert they are drawn in
// (Spectrum's Dialog and AlertDialog).
import 'package:flutter/widgets.dart';

import '../../model/app_dialogs.dart';
import '../../model/editor.dart';
import '../kit/kit.dart';
import '../theme/theme.dart';
import 'film_pack_notice.dart';
import 'plugins_dialog.dart';
import 'settings_dialog.dart';
import 'shortcuts_dialog.dart';
import 'support_dialog.dart';
import 'update_dialog.dart';

/// Shows the dialog `editor.dialogs` asks for over the window, and refreshes the film packs and
/// plug-ins when the window comes back to the front: either may have changed behind it. It takes
/// no room of its own.
class AppDialogHost extends StatefulWidget {
  const AppDialogHost({super.key, required this.editor});
  final EditorModel editor;

  @override
  State<AppDialogHost> createState() => _AppDialogHostState();
}

class _AppDialogHostState extends State<AppDialogHost> {
  AppDialogs get dialogs => widget.editor.dialogs;
  AnchoredOverlay? _shown;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    dialogs.addListener(_changed);
    _lifecycle = AppLifecycleListener(onResume: () {
      final editor = widget.editor;
      if (editor.engine == null || editor.exporting) return;
      editor.filmPacks.refresh().ignore();
      editor.plugins.refresh().ignore();
    });
  }

  @override
  void dispose() {
    dialogs.removeListener(_changed);
    _lifecycle.dispose();
    super.dispose();
  }

  void _changed() {
    final requested = dialogs.requested;
    if (requested != null && requested != dialogs.open) {
      _shown?.close();
      dialogs
        ..open = requested
        ..requested = null;
      _shown = showModal(context, (close) => _dialog(requested),
          dismissible: requested != AppDialog.update);
      _watch(_shown!, requested);
    } else if (dialogs.open == null && _shown != null) {
      final shown = _shown!;
      _shown = null;
      shown.close();
    }
  }

  /// The overlay may also close by a click on its backdrop: the editor hears of it.
  void _watch(AnchoredOverlay shown, AppDialog dialog) {
    shown.onClose = () {
      if (_shown != shown) return;
      _shown = null;
      if (dialog == AppDialog.plugins) widget.editor.plugins.dialogClosed();
      if (dialog == AppDialog.filmPack) widget.editor.filmPacks.notice = null;
      if (dialogs.open == dialog) dialogs.close();
    };
  }

  Widget _dialog(AppDialog dialog) {
    final editor = widget.editor;
    void close() => dialogs.close(dialog);
    return switch (dialog) {
      AppDialog.settings => SettingsDialog(editor: editor, onClose: close),
      AppDialog.plugins => PluginsDialog(editor: editor, onClose: close),
      AppDialog.filmPack => FilmPackNotice(editor: editor, onClose: close),
      AppDialog.update => UpdateDialog(editor: editor, onClose: close),
      AppDialog.support => SupportDialog(onClose: close),
      AppDialog.shortcuts => ShortcutsDialog(editor: editor, onClose: close),
    };
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Spectrum's Dialog: a heading, a close button where it may be dismissed, the content (scrolled
/// where the window is short) and its buttons on the right.
class AppDialogCard extends StatelessWidget {
  const AppDialogCard({
    super.key,
    required this.title,
    required this.children,
    this.actions = const [],
    this.onDismiss,
    this.width = 480,
  });

  final String title;
  final List<Widget> children, actions;

  /// The close button's action; none where the dialog asks for an answer.
  final VoidCallback? onDismiss;
  final double width;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    final room = MediaQuery.sizeOf(context);
    return Container(
      width: width.clamp(0, room.width - 32).toDouble(),
      constraints: BoxConstraints(maxHeight: room.height - 48),
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      decoration: BoxDecoration(
        color: palette.dark ? const Color(0xFF222222) : const Color(0xFFFFFFFF),
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 40, offset: Offset(0, 10))],
      ),
      child: DefaultTextStyle(
        style: editorText(context),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(title,
                      style: editorText(context, size: TextSizes.dialog, weight: FontWeight.w700)),
                ),
              ),
              if (onDismiss != null)
                QuietButton(icon: 'close', tooltip: 'Dismiss', onPressed: onDismiss),
            ]),
            const SizedBox(height: 14),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
              ),
            ),
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 24),
              Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: actions),
            ],
          ],
        ),
      ),
    );
  }
}

/// Spectrum's AlertDialog: a title, its message and the answers, the primary one last.
class AlertCard extends StatelessWidget {
  const AlertCard({
    super.key,
    required this.title,
    required this.message,
    required this.primary,
    required this.onPrimary,
    this.cancel,
    this.onCancel,
    this.variant = ButtonVariant.accent,
    this.warning = false,
  });

  final String title, message, primary;
  final VoidCallback onPrimary;
  final String? cancel;
  final VoidCallback? onCancel;
  final ButtonVariant variant;

  /// A warning's title carries the alert icon.
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final palette = Palette.of(context);
    return AppDialogCard(
      title: title,
      width: 400,
      actions: [
        if (cancel != null) PillButton(cancel!, onPressed: onCancel),
        PillButton(primary, variant: variant, onPressed: onPrimary),
      ],
      children: [
        if (warning)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: AppIcon('warning', size: 20, color: palette.dark ? const Color(0xFFF5A623) : const Color(0xFFC77D00)),
            ),
          ),
        Text(message, style: editorText(context, height: 1.5)),
      ],
    );
  }
}

/// A heading inside a dialog's pane (`.settings-pane h3`).
class PaneHeading extends StatelessWidget {
  const PaneHeading(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(text, style: editorText(context, weight: FontWeight.w700)),
      );
}

/// A pane's muted note (`.medium-detail`).
class PaneNote extends StatelessWidget {
  const PaneNote(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.only(top: 6), child: Note(text));
}
