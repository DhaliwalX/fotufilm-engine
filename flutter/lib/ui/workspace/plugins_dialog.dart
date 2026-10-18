// The plug-ins for other editors the engine installs (web/src/editor/PluginsDialog.jsx): what is
// installed, from which build, and the Mac app's Plugins menu actions for each. Opened from the
// More menu, the Plugins menu, or at launch when this build's plug-ins are not in place.
import 'package:flutter/widgets.dart';

import '../../model/editor.dart';
import '../../model/plugins.dart';
import '../kit/kit.dart';
import '../theme/theme.dart';
import 'app_dialogs.dart';

class PluginsDialog extends StatefulWidget {
  const PluginsDialog({super.key, required this.editor, required this.onClose});
  final EditorModel editor;
  final VoidCallback onClose;

  @override
  State<PluginsDialog> createState() => _PluginsDialogState();
}

class _PluginsDialogState extends State<PluginsDialog> {
  Plugins get model => widget.editor.plugins;

  @override
  void initState() {
    super.initState();
    // Read afresh on opening: a plug-in may have been installed or removed since.
    if (model.offer == null) model.refresh().ignore();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: model,
        builder: (context, _) => model.offer != null ? _offer(model.offer!) : _list(),
      );

  /// The launch offer, worded as the Mac app's: install for a plug-in never there, update for
  /// one from another build.
  Widget _offer(PluginOffer offer) {
    final names = [for (final id in offer.ids) model.status(id)?['name'] as String? ?? id];
    final notes = [
      for (final id in offer.ids)
        if (model.status(id)?['note'] case final String note) note,
    ];
    final verb = offer.updating ? 'Update' : 'Install';
    return AppDialogCard(
      title: '$verb the Fotufilm plug-ins for ${joinedNames(names)}?',
      actions: [
        PillButton('Not Now', onPressed: () {
          model.decline();
          widget.onClose();
        }),
        PillButton(verb, variant: ButtonVariant.accent, onPressed: model.acceptOffer),
      ],
      children: [
        PaneNote(offer.updating
            ? 'The installed plug-ins are from another version of Fotufilm. Updating them keeps '
                'them developing the same film this app does.'
            : 'Fotufilm can develop film inside ${joinedNames(names)} using the same engine this '
                'app uses.'),
        for (final note in notes) PaneNote(note),
      ],
    );
  }

  Widget _list() {
    final catalogue = model.catalogue;
    return AppDialogCard(
      title: 'Plug-ins',
      onDismiss: widget.onClose,
      children: [
        PaneNote('Fotufilm can develop film inside '
            '${joinedNames([for (final p in catalogue) p['name'] as String])} using the same '
            'engine this app uses. Restart an editor after installing to load its plug-in.'),
        const SizedBox(height: 8),
        for (final (i, plugin) in catalogue.indexed) ...[
          if (i > 0) Container(height: 1, color: Palette.of(context).border),
          _PluginRow(plugin: plugin, model: model),
        ],
      ],
    );
  }
}

class _PluginRow extends StatelessWidget {
  const _PluginRow({required this.plugin, required this.model});
  final Json plugin;
  final Plugins model;

  @override
  Widget build(BuildContext context) {
    final id = plugin['id'] as String;
    final status = model.status(id);
    final busy = model.busy == id;
    final result = model.result?.id == id ? model.result : null;
    final installed = status != null &&
        (status['state'] == 'installed' || status['state'] == 'outdated');
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PaneHeading(plugin['name'] as String),
        PaneNote(pluginStatusText(status)),
        if (status?['bundledVersion'] != null && !installed && status?['note'] != null)
          PaneNote(status!['note'] as String),
        const SizedBox(height: 8),
        Row(children: [
          PillButton(
            busy ? 'Installing…' : installLabel(status),
            variant:
                status?['state'] == 'installed' ? ButtonVariant.secondary : ButtonVariant.accent,
            onPressed: status?['bundledVersion'] == null || model.busy != null
                ? null
                : () => model.install(id),
          ),
          const SizedBox(width: 8),
          PillButton('Show Installed Plug-in', onPressed: installed ? () => model.reveal(id) : null),
        ]),
        if (result?.message != null) PaneNote(result!.message!),
        if (result?.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(result!.error!, style: editorText(context, size: TextSizes.label)),
          ),
      ]),
    );
  }
}
