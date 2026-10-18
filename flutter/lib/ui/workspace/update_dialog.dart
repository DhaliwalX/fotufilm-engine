// Check for Updates' answers, as the Mac app's alerts give them: a notice, a release on offer, or
// its download with progress.
import 'package:flutter/widgets.dart';

import '../../model/editor.dart';
import '../../model/updates.dart';
import '../kit/kit.dart';
import '../theme/theme.dart';
import 'app_dialogs.dart';

class UpdateDialog extends StatelessWidget {
  const UpdateDialog({super.key, required this.editor, required this.onClose});
  final EditorModel editor;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: editor.updates,
        builder: (context, _) => switch (editor.updates.update) {
          null => const SizedBox.shrink(),
          final UpdateNotice notice => AlertCard(
              title: notice.title,
              message: notice.message,
              warning: notice.warning,
              primary: 'OK',
              onPrimary: onClose,
            ),
          final UpdateDownloading download => _downloading(context, download),
          final UpdateAvailable offer => _offer(offer),
        },
      );

  Widget _downloading(BuildContext context, UpdateDownloading download) {
    final known = download.total > 0;
    return AppDialogCard(
      title: 'Downloading Fotufilm ${download.version}…',
      width: 400,
      actions: [PillButton('Cancel', onPressed: editor.updates.cancel)],
      children: [
        const Text('The installer opens once the download matches the checksum its release '
            'published.'),
        const SizedBox(height: 14),
        ProgressBar(value: known ? download.bytes / download.total : null),
        const SizedBox(height: 6),
        Text(
          known
              ? '${formatBytes(download.bytes)} of ${formatBytes(download.total)}'
              : 'Connecting…',
          style: editorText(context, size: TextSizes.label, color: Palette.of(context).muted),
        ),
      ],
    );
  }

  Widget _offer(UpdateAvailable offer) => AppDialogCard(
        title: 'Fotufilm ${offer.version} is available',
        width: 640,
        actions: [
          if (offer.notes != null) PillButton('Release Notes', onPressed: editor.updates.openNotes),
          if (offer.allowSkip) PillButton('Skip This Version', onPressed: editor.updates.skip),
          PillButton('Not Now', onPressed: onClose),
          PillButton('Download and Install…',
              variant: ButtonVariant.accent, onPressed: editor.updates.install),
        ],
        children: [
          Text('You have Fotufilm ${offer.current}. The update arrives as a signed installer, like '
              'the one this copy was installed from. Installing may ask for your administrator '
              'password.'),
        ],
      );
}
