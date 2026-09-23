import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../config/flavor.dart';
import '../../core/clock/odoo_time.dart';
import '../../core/sync_status.dart';
import '../theme/neu.dart';
import 'neu_box.dart';
import 'neu_widgets.dart';

/// The four things, in one inset strip. Never a modal, never a full-width
/// red banner: an operator in a basement knows they are in a basement.
class StatusStrip extends ConsumerWidget {
  const StatusStrip({super.key, this.onQueueTap});

  final VoidCallback? onQueueTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = NeuTheme.of(context);
    final status = ref.watch(syncProvider);

    final online = status.online;
    final stateInk = online ? c.syncedInk : c.blockedInk;

    return NeuBox(
      style: NeuStyle.inset,
      radius: 16,
      padding: const EdgeInsets.fromLTRB(14, 11, 11, 11),
      child: Row(
        children: [
          if (online)
            Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: c.syncedInk,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(color: c.syncedInk.withValues(alpha: 0.22), blurRadius: 0, spreadRadius: 3),
                ],
              ),
            )
          else
            Icon(Icons.wifi_off_rounded, size: 15, color: stateInk),
          const SizedBox(width: 8),
          Text(online ? 'Online' : 'Offline', style: NeuText.label(stateInk, size: 12)),
          const SizedBox(width: 8),
          Container(width: 1, height: 13, color: c.hairline),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              // No "Synced" prefix: at a large system font scale the three
              // parts of this strip do not fit, and the *time* is the part
              // that matters.
              status.syncing
                  ? 'Syncing…'
                  // The customer app pulls nothing, so "synced 3 min ago" — and
                  // worse, "never" — says nothing true about it.
                  : sudiFlavor.isField
                      ? OdooTime.ago(status.lastSyncedAt)
                      : (status.queued > 0 ? 'Waiting to send' : 'Ready'),
              overflow: TextOverflow.ellipsis,
              style: NeuText.body_(c.inkMuted, size: 12),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: onQueueTap,
            child: NeuBox(
              style: NeuStyle.raisedSm,
              radius: 12,
              color: status.needsAttention > 0
                  ? c.attentionFill
                  : status.queued > 0
                      ? c.queuedFill
                      : c.syncedFill,
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    status.needsAttention > 0
                        ? Icons.warning_amber_rounded
                        : status.queued > 0
                            ? Icons.schedule_rounded
                            : Icons.check_rounded,
                    size: 13,
                    color: status.needsAttention > 0
                        ? c.attentionInk
                        : status.queued > 0
                            ? c.queuedInk
                            : c.syncedInk,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    status.needsAttention > 0
                        ? '${status.needsAttention} needs you'
                        : status.queued > 0
                            ? '${status.queued} queued'
                            : 'All sent',
                    style: NeuText.label(
                      status.needsAttention > 0
                          ? c.attentionInk
                          : status.queued > 0
                              ? c.queuedInk
                              : c.syncedInk,
                      size: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Header used on every list screen.
class ScreenHeader extends StatelessWidget {
  const ScreenHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.onBack,
    this.trailing,
    this.mono = false,
  });

  final String title;
  final String? subtitle;
  final VoidCallback? onBack;
  final Widget? trailing;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    return Row(
      children: [
        if (onBack != null) ...[
          NeuIconButton(
            icon: Icons.arrow_back_rounded,
            onPressed: onBack,
            tooltip: 'Back',
          ),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                overflow: TextOverflow.ellipsis,
                style: mono
                    ? NeuText.data(c.accentInk, size: 15)
                    : NeuText.title(c.ink, size: onBack != null ? 21 : 26),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 3),
                Text(
                  subtitle!,
                  overflow: TextOverflow.ellipsis,
                  style: NeuText.body_(c.inkMuted, size: 12.5),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 12), trailing!],
      ],
    );
  }
}
