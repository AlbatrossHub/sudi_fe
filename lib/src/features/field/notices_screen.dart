import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/notices/notices.dart';
import '../../models/docs.dart';
import '../../ui/theme/neu.dart';
import '../../ui/widgets/neu_box.dart';
import '../../ui/widgets/neu_widgets.dart';
import '../../ui/widgets/v2_widgets.dart';

/// The bell's list: new ones raised, earlier ones sunk. Tapping one opens the
/// receipt it is about and marks it read.
class NoticesScreen extends ConsumerWidget {
  const NoticesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = NeuTheme.of(context);
    final state = ref.watch(noticesProvider);
    final fresh = [for (final n in state.items) if (!n.read) n];
    final earlier = [for (final n in state.items) if (n.read) n];

    void open(NoticeInfo n) {
      ref.read(noticesProvider.notifier).markRead([n.id]);
      final route = routeForNotice(scope: n.scope, pickingId: n.pickingId);
      if (route != '/notices') context.push(route);
    }

    return NeuScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              NeuIconButton(icon: Icons.arrow_back_rounded, onPressed: () => context.pop(), tooltip: 'Back'),
              const SizedBox(width: 12),
              Expanded(child: Text('Notifications', style: NeuText.title(c.ink, size: 22))),
              if (fresh.isNotEmpty)
                NeuBox(
                  style: NeuStyle.raisedSm,
                  radius: 13,
                  onTap: () => ref.read(noticesProvider.notifier).markAllRead(),
                  padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
                  child: Text('Mark all read', style: NeuText.label(c.accentInk, size: 12.5)),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Expanded(
            child: RefreshIndicator(
              color: c.accentInk,
              backgroundColor: c.ground,
              onRefresh: () => ref.read(noticesProvider.notifier).refresh(announce: false),
              child: state.items.isEmpty
                  ? const EmptyState(
                      message: 'No notifications',
                      hint: 'New pickups, job work and jangads to validate show up here',
                      icon: Icons.notifications_none_rounded,
                    )
                  : ListView(
                      children: [
                        if (fresh.isNotEmpty) ...[
                          SectionLabel('New · ${fresh.length}'),
                          const SizedBox(height: 10),
                          for (final n in fresh) ...[
                            _NoticeCard(notice: n, onTap: () => open(n)),
                            const SizedBox(height: 11),
                          ],
                        ],
                        if (earlier.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          const SectionLabel('Earlier'),
                          const SizedBox(height: 10),
                          for (final n in earlier) ...[
                            NeuBox(
                              style: NeuStyle.insetSm,
                              radius: 18,
                              color: c.ground,
                              onTap: () => open(n),
                              padding: const EdgeInsets.fromLTRB(15, 13, 15, 13),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(n.title, style: NeuText.strong(c.inkSoft, size: 14)),
                                  const SizedBox(height: 3),
                                  Text(relativeDayTime(n.createdAt), style: NeuText.data(c.inkFaint, size: 11.5)),
                                ],
                              ),
                            ),
                            const SizedBox(height: 10),
                          ],
                        ],
                        const SizedBox(height: 12),
                        Text(
                          'Arrives while the app is open, and on the next sync after a gap. Phone '
                          'notifications when the app is closed come with push, later.',
                          textAlign: TextAlign.center,
                          style: NeuText.body_(c.inkMuted, size: 12),
                        ),
                        const SizedBox(height: 18),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({required this.notice, required this.onTap});
  final NoticeInfo notice;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final (IconData icon, Color ink, String source) = switch (notice.kind) {
      'jobwork_ready' => (Icons.inventory_2_outlined, c.syncedInk, 'job work'),
      'department_transfer' => (Icons.swap_horiz_rounded, c.accentInk, 'department move'),
      'pickup_new' => (Icons.add_location_alt_outlined, c.accentInk, 'new pickup'),
      'office_validate' => (Icons.fact_check_outlined, c.accentInk, 'to validate'),
      'delivery_ready' => (Icons.local_shipping_outlined, c.accentInk, 'delivery'),
      _ => (Icons.notifications_none_rounded, c.accentInk, 'notice'),
    };
    return NeuBox(
      style: NeuStyle.raised,
      radius: 20,
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(15, 14, 15, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          NeuBox(
            style: NeuStyle.insetSm,
            radius: 13,
            width: 40,
            height: 40,
            color: c.ground,
            child: Icon(icon, size: 19, color: ink),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(notice.title, style: NeuText.label(c.ink, size: 14.5))),
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(color: c.accentInk, shape: BoxShape.circle),
                    ),
                  ],
                ),
                if ((notice.body ?? '').isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(notice.body!, style: NeuText.body_(c.inkSoft, size: 13)),
                ],
                const SizedBox(height: 4),
                Text('${relativeDayTime(notice.createdAt)} · $source',
                    style: NeuText.data(c.inkFaint, size: 11.5)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
