
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_error.dart';
import '../../core/clock/odoo_time.dart';
import '../../core/outbox/outbox.dart';
import '../../core/services.dart';
import '../../core/sync_status.dart';
import '../../ui/theme/neu.dart';
import '../../ui/widgets/neu_box.dart';
import '../../ui/widgets/neu_widgets.dart';

final outboxProvider = FutureProvider.autoDispose<List<OutboxItem>>((ref) {
  ref.watch(dataRevisionProvider);
  return ref.read(servicesProvider).outbox.open();
});

/// The single most valuable support feature in the app. It turns "the app is
/// broken" into "three items queued, the oldest four hours old, last error a
/// network timeout" — a sentence somebody can act on.
class QueueScreen extends ConsumerWidget {
  const QueueScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = NeuTheme.of(context);
    final items = ref.watch(outboxProvider).value ?? const <OutboxItem>[];
    final status = ref.watch(syncProvider);
    final waiting = items.where((i) => i.isWaiting).toList();
    final attention = items.where((i) => i.state == OutboxState.needsAttention).toList();
    final oldest = items.isEmpty ? null : items.first.occurredAt;

    return NeuScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              NeuIconButton(
                icon: Icons.arrow_back_rounded,
                onPressed: () => context.pop(),
                tooltip: 'Back',
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Waiting to send', style: NeuText.title(c.ink, size: 21)),
                    const SizedBox(height: 3),
                    Text(
                      items.isEmpty
                          ? 'Nothing queued'
                          : '${items.length} items · oldest ${OdooTime.hm(oldest)}',
                      style: NeuText.body_(c.inkMuted, size: 12.5),
                    ),
                  ],
                ),
              ),
              if (attention.isNotEmpty)
                NeuIconButton(
                  icon: Icons.warning_amber_rounded,
                  onPressed: () => context.push('/attention'),
                  tooltip: 'Items needing attention',
                  color: c.attentionInk,
                ),
            ],
          ),
          const SizedBox(height: 14),
          NeuBox(
            style: NeuStyle.inset,
            radius: 16,
            padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
            child: Row(
              children: [
                Icon(
                  status.online ? Icons.cloud_done_outlined : Icons.wifi_off_rounded,
                  size: 15,
                  color: status.online ? c.syncedInk : c.blockedInk,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    status.online
                        ? 'Connected. The queue is flushing.'
                        : 'Nothing is lost. It sends itself.',
                    style: NeuText.body_(c.inkMuted, size: 12),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: items.isEmpty
                ? const EmptyState(
                    message: 'Everything has been sent',
                    hint: 'Captures show up here until the office has them',
                    icon: Icons.cloud_done_outlined,
                  )
                : ListView.separated(
                    padding: const EdgeInsets.only(bottom: 16),
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (_, i) => QueueCard(item: items[i]),
                  ),
          ),
          NeuButton(
            label: status.online ? 'Send now' : 'Send now',
            icon: Icons.refresh_rounded,
            kind: NeuButtonKind.primary,
            busy: status.syncing,
            disabledReason: status.online ? null : 'Needs a connection',
            height: 54,
            onPressed: status.online && waiting.isNotEmpty
                ? () => ref.read(syncProvider.notifier).syncNow(flushFirst: true)
                : null,
          ),
          const SizedBox(height: 18),
        ],
      ),
    );
  }
}

class QueueCard extends ConsumerWidget {
  const QueueCard({super.key, required this.item, this.showActions = false});

  final OutboxItem item;
  final bool showActions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = NeuTheme.of(context);
    final clock = ref.read(servicesProvider).clock;
    final remaining = clock.remainingFor(item.occurredAt);
    final urgent = remaining < const Duration(hours: 24);

    final (label, kind) = switch (item.state) {
      OutboxState.sending => ('Sending', ChipKind.accent),
      OutboxState.retrying => ('Retrying', ChipKind.queued),
      OutboxState.needsAttention => _attentionChip(item),
      _ => ('Queued', ChipKind.queued),
    };

    return NeuBox(
      style: NeuStyle.raised,
      radius: 20,
      padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  item.kind.label,
                  style: NeuText.strong(
                    item.state == OutboxState.needsAttention ? c.inkMuted : c.ink,
                    size: 15,
                  ),
                ),
              ),
              StateChip(label, kind: kind),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${item.recordLabel ?? 'New receipt'} · captured ${OdooTime.hm(item.occurredAt)}',
            style: NeuText.data(c.inkMuted),
          ),
          if (item.lastErrorMessage != null) ...[
            const SizedBox(height: 10),
            NeuBox(
              style: NeuStyle.insetSm,
              radius: 13,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(
                children: [
                  Icon(
                    item.state == OutboxState.retrying
                        ? Icons.refresh_rounded
                        : Icons.info_outline_rounded,
                    size: 14,
                    color: item.state == OutboxState.retrying ? c.queuedInk : c.otherInk,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      item.state == OutboxState.retrying && item.nextAttemptAt != null
                          ? '${item.lastErrorMessage} · next try ${OdooTime.hm(item.nextAttemptAt)}'
                          : item.lastErrorMessage!,
                      style: NeuText.body_(
                        item.state == OutboxState.retrying ? c.queuedInk : c.otherInk,
                        size: 12,
                        w: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          // The 72-hour cliff: an intent that sits for three days will never
          // succeed, so it is surfaced well before it expires.
          if (item.isWaiting && urgent) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(Icons.hourglass_bottom_rounded, size: 14, color: c.attentionInk),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    remaining == Duration.zero
                        ? 'This has expired'
                        : 'Expires in ${remaining.inHours} h — send it today',
                    style: NeuText.label(c.attentionInk, size: 12),
                  ),
                ),
              ],
            ),
          ],
          if (showActions || item.state == OutboxState.needsAttention) ...[
            const SizedBox(height: 12),
            NeuButton(
              label: 'Dismiss',
              height: 44,
              onPressed: () async {
                await ref.read(servicesProvider).outbox.remove(item.localId);
                await ref.read(syncProvider.notifier).refreshCounters();
              },
            ),
          ],
        ],
      ),
    );
  }

  static (String, ChipKind) _attentionChip(OutboxItem item) {
    return switch (item.lastErrorCode) {
      ApiError.alreadyTaken || ApiError.alreadyConfirmed => ('Someone else', ChipKind.other),
      ApiError.staleIntent => ('Expired', ChipKind.attention),
      ApiError.clockSkew => ('Clock wrong', ChipKind.attention),
      _ => ('Needs you', ChipKind.attention),
    };
  }
}

/// Nothing on this screen sends itself.
class AttentionScreen extends ConsumerWidget {
  const AttentionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = NeuTheme.of(context);
    final status = ref.watch(syncProvider);
    final items = (ref.watch(outboxProvider).value ?? const <OutboxItem>[])
        .where((i) => i.state == OutboxState.needsAttention)
        .toList();

    return NeuScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              NeuIconButton(
                icon: Icons.arrow_back_rounded,
                onPressed: () => context.pop(),
                tooltip: 'Back',
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Needs your attention', style: NeuText.title(c.ink, size: 21)),
                    const SizedBox(height: 3),
                    Text('Nothing here sends itself',
                        style: NeuText.body_(c.inkMuted, size: 12.5)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 15),
          Expanded(
            child: ListView(
              children: [
                if (status.clockSkewed) ...[
                  NeuBox(
                    style: NeuStyle.raised,
                    radius: 22,
                    padding: const EdgeInsets.all(17),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 34,
                              height: 34,
                              decoration: BoxDecoration(
                                color: c.queuedFill,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Center(
                                child: Icon(Icons.schedule_rounded, size: 18, color: c.queuedInk),
                              ),
                            ),
                            const SizedBox(width: 11),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text("This phone's clock is wrong",
                                      style: NeuText.strong(c.ink, size: 15)),
                                  const SizedBox(height: 3),
                                  Text(status.clockSkewLabel ?? '',
                                      style: NeuText.data(c.inkMuted)),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Your times are corrected before they are sent, so nothing is '
                          'mis-recorded. Fix it in the phone settings and this goes away.',
                          style: NeuText.body_(c.inkMuted, size: 12.5),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 13),
                ],
                if (items.isEmpty && !status.clockSkewed)
                  const EmptyState(
                    message: 'Nothing needs you',
                    hint: 'Refused and expired captures land here',
                    icon: Icons.check_circle_outline_rounded,
                    inline: true,
                  )
                else
                  for (final item in items) ...[
                    QueueCard(item: item, showActions: true),
                    const SizedBox(height: 13),
                  ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
