// Browser support (web/src/editor/SupportDialog.jsx), as the More menu opens it, and the menu's
// Legal links (OptionsMenu.jsx, the catalogue's LEGAL_MENU), which open in the browser.
import 'package:flutter/widgets.dart';

import '../../app/host_window.dart';
import '../../model/catalogue.dart';
import '../kit/kit.dart';
import '../theme/theme.dart';
import 'app_dialogs.dart';

class SupportDialog extends StatelessWidget {
  const SupportDialog({super.key, required this.onClose});
  final VoidCallback onClose;

  static const _copy = [
    'Photos and videos are processed on this device. WebGPU is used when available, with '
        'WebAssembly CPU fallback.',
    'A smaller overview keeps movement smooth. Once movement settles, the visible image is '
        'developed at the display’s pixel resolution. Export develops the entire image at the '
        'selected size.',
    'The browser supports film selection and format, ageing, halation, grain models, push/pull, '
        'bleach bypass, colour separation, print viewing, a simulated printer, an ordered '
        'lens-filter stack, automatic and manual lens correction, Auto Adjust, photo frames, '
        'light and color adjustments, three-way grading, color and light selections, crop, '
        'rotation and flip. Camera RAW files use as-shot white balance. RAW, linear EXR and '
        'supported HDR JPEG gain maps preserve decoded highlight detail before film exposure.',
    'Scanned-negative conversion, automatic subject selections, custom packs, and HDR export are '
        'available in the Mac app. Still previews and exports use Display P3 where supported; '
        'TIFF preserves 16-bit Display P3 precision. Other browsers use sRGB for canvas output.',
  ];

  @override
  Widget build(BuildContext context) => AppDialogCard(
        title: 'Browser support',
        onDismiss: onClose,
        children: [
          for (final p in _copy)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(p,
                  style: editorText(context, color: Palette.of(context).muted, height: 1.7)),
            ),
        ],
      );
}

/// The More menu's Legal section: each link opens in the browser.
List<MenuItem> legalMenuItems(Catalogue catalogue) => [
      for (final link in ((catalogue.module['LEGAL_MENU'] as Map?)?['links'] as List? ?? const [])
          .cast<Json>())
        MenuItem(
          label: link['title'] as String,
          icon: link['icon'] as String?,
          onSelected: () => HostWindow.openUrl(link['href'] as String),
        ),
    ];
