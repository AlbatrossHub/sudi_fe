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
              status.syncing
                  ? 'Syncing…'
                  // The customer app pulls nothing, so "synced 3 min ago" — and
                  // worse, "never" — says nothing true about it.
                  : !sudiFlavor.isField
                      ? (online
                          ? (status.queued > 0 ? 'Sending…' : 'Ready')
                          : 'Sends by itself when online')
                      : online
                          ? (status.lastSyncedAt == null
                              ? 'Not synced yet'
                              : 'Synced ${OdooTime.ago(status.lastSyncedAt)}')
                          // Offline the list is the copy saved at the last pull:
                          // say when, as a time, so nobody mistakes it for live.
                          : (status.lastSyncedAt == null
                              ? 'Nothing saved yet'
                              : 'List saved ${OdooTime.hm(status.lastSyncedAt)}'),
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
                            ? '${status.queued} on this phone'
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
              // One line, shrunk to fit: at a large font scale a header beside
              // an action ellipsised ("For which custome…") or, allowed two
              // lines, broke a single word ("Notificatio / ns").
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  title,
                  maxLines: 1,
                  softWrap: false,
                  style: mono
                      ? NeuText.data(c.accentInk, size: 15)
                      : NeuText.title(c.ink, size: onBack != null ? 21 : 26),
                ),
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
