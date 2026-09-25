import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../config/env.dart';
import '../../config/flavor.dart';
import '../../core/services.dart';
import '../theme/neu.dart';
import 'neu_box.dart';
import 'neu_widgets.dart';

/// The credit, at the foot of the screens shown before anyone signs in.
///
/// Low contrast on purpose. It is an attribution, not a control anybody is
/// looking for — findable by someone who wants it, invisible to an operator who
/// does not. Pressed, it opens a sheet, which is the only reason it reads as a
/// button at all.
class PoweredBy extends StatelessWidget {
  const PoweredBy({super.key, this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    return Opacity(
      opacity: 0.6,
      child: NeuBox(
        style: NeuStyle.flat,
        radius: 22,
        onTap: onTap,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Powered by', style: NeuText.label(c.inkMuted, size: 12)),
            const SizedBox(width: 9),
            // Height, never width: the mark is wider than it is tall and letting
            // the row size it squashes it on a narrow phone.
            Image.asset(
              'assets/brand/albatross.png',
              height: 15,
              filterQuality: FilterQuality.medium,
              semanticLabel: 'Albatross',
            ),
          ],
        ),
      ),
    );
  }
}

/// What the credit opens: who built it, and what this handset is talking to.
///
/// The second half is the useful part. "It will not connect" is the commonest
/// thing a worker reports, and the answer is nearly always the server address —
/// which is otherwise only visible to somebody willing to sign out.
Future<void> showPoweredBySheet(BuildContext context, WidgetRef ref) async {
  final c = NeuTheme.of(context);
  String version = '';
  try {
    final device = await ref.read(servicesProvider).device.current();
    version = device.appVersion;
  } catch (_) {
    // The sheet is worth showing without it.
  }
  if (!context.mounted) return;

  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: c.ground,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (sheetContext) => NeuTheme(
      colors: c,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Image.asset('assets/brand/albatross.png', height: 28),
                  const SizedBox(width: 13),
                  Text('Albatross', style: NeuText.title(c.ink, size: 21)),
                ],
              ),
              const SizedBox(height: 7),
              Text('Built ${sudiFlavor.title}.', style: NeuText.body_(c.inkMuted, size: 13)),
              const SizedBox(height: 22),
              Text('THIS HANDSET', style: NeuText.label(c.inkFaint, size: 11)),
              const SizedBox(height: 10),
              NeuBox(
                style: NeuStyle.inset,
                radius: 18,
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (version.isNotEmpty) ...[
                      Text('Version $version', style: NeuText.body_(c.inkMuted, size: 13)),
                      const SizedBox(height: 8),
                    ],
                    Text(Env.baseUrl, style: NeuText.data(c.ink, size: 12)),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              NeuButton(
                label: 'Close',
                onPressed: () => Navigator.of(sheetContext).pop(),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
