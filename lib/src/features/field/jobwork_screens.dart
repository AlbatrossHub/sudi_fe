import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_error.dart';
import '../../core/clock/odoo_time.dart';
import '../../core/outbox/outbox.dart';
import '../../core/services.dart';
import '../../core/session.dart';
import '../../core/sync_status.dart';
import '../../models/docs.dart';
import '../../ui/theme/neu.dart';
import '../../ui/widgets/neu_box.dart';
import '../../ui/widgets/neu_widgets.dart';
import '../../ui/widgets/status_strip.dart';
import 'pickups_screens.dart';
import 'sign_in_screens.dart';

final jobWorkProvider = FutureProvider.autoDispose<List<JobWorkDoc>>((ref) {
  ref.watch(dataRevisionProvider);
  return ref.read(servicesProvider).records.jobWork();
});

final jobWorkOneProvider = FutureProvider.autoDispose.family<JobWorkDoc?, int>((ref, id) {
  ref.watch(dataRevisionProvider);
  return ref.read(servicesProvider).records.jobWorkOne(id);
});

class JobWorkScreen extends ConsumerStatefulWidget {
  const JobWorkScreen({super.key});

  @override
  ConsumerState<JobWorkScreen> createState() => _JobWorkScreenState();
}

class _JobWorkScreenState extends ConsumerState<JobWorkScreen> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Only while this screen is on top, and only once a second.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final all = ref.watch(jobWorkProvider).value ?? const <JobWorkDoc>[];
    final pending = ref.watch(pendingByRecordProvider).value ?? const {};
    final running = all.where((j) => j.timer.running).toList();
    final rest = all.where((j) => !j.timer.running).toList();

    return NeuScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ScreenHeader(
            title: 'Job work',
            subtitle: '${all.length} receipts in progress',
            trailing: NeuIconButton(
              icon: Icons.person_outline_rounded,
              onPressed: () => showAccountSheet(context, ref),
              tooltip: 'Account',
            ),
          ),
          const SizedBox(height: 14),
          StatusStrip(onQueueTap: () => context.push('/queue')),
          const SizedBox(height: 14),
          Expanded(
            child: RefreshIndicator(
              color: c.accentInk,
              backgroundColor: c.ground,
              onRefresh: () => ref.read(syncProvider.notifier).syncNow(),
              child: all.isEmpty
                  ? const EmptyState(message: 'No receipts in progress')
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 16),
                      children: [
                        for (final doc in running) ...[
                          _RunningCard(doc: doc),
                          const SizedBox(height: 13),
                        ],
                        for (final doc in rest) ...[
                          _JobCard(doc: doc, pending: pending[doc.id] ?? const []),
                          const SizedBox(height: 12),
                        ],
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RunningCard extends ConsumerWidget {
  const _RunningCard({required this.doc});
  final JobWorkDoc doc;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = NeuTheme.of(context);
    final started = doc.timer.startedAt;
    final elapsed = started == null ? Duration.zero : DateTime.now().difference(started);

    return NeuBox(
      style: NeuStyle.raised,
      radius: 24,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: c.syncedInk, shape: BoxShape.circle),
              ),
              const SizedBox(width: 9),
              Text('RUNNING', style: NeuText.label(c.syncedInk, size: 12)),
              const Spacer(),
              Text(doc.name, style: NeuText.data(c.accentInk, size: 12)),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              NeuBox(
                style: NeuStyle.inset,
                radius: 64,
                width: 122,
                height: 122,
                child: Center(
                  child: Text(
                    OdooTime.duration(elapsed),
                    style: NeuText.data(c.ink, size: 19),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(doc.customer?.name ?? 'Receipt', style: NeuText.strong(c.ink, size: 17)),
                    const SizedBox(height: 7),
                    Row(
                      children: [
                        Icon(Icons.apartment_rounded, size: 14, color: c.inkFaint),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            doc.currentDepartment?.name ?? 'No department',
                            style: NeuText.body_(c.inkMuted, size: 13, w: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '${doc.totalHours.toStringAsFixed(2)} h booked',
                      style: NeuText.data(c.inkMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: NeuButton(
                  label: 'Stop timer',
                  kind: NeuButtonKind.destructive,
                  icon: Icons.stop_rounded,
                  height: 50,
                  onPressed: () async {
                    await ref.read(servicesProvider).field
                        .timer(id: doc.id, label: doc.name, start: false);
                    await ref.read(syncProvider.notifier).refreshCounters();
                    unawaited(ref.read(syncProvider.notifier).syncNow(flushFirst: true));
                  },
                ),
              ),
              const SizedBox(width: 10),
              NeuIconButton(
                icon: Icons.chevron_right_rounded,
                onPressed: () => context.push('/jobwork/${doc.id}'),
                tooltip: 'Open receipt',
                color: c.accentInk,
                size: 50,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _JobCard extends ConsumerWidget {
  const _JobCard({required this.doc, required this.pending});
  final JobWorkDoc doc;
  final List<OutboxItem> pending;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = NeuTheme.of(context);
    final queued = pending.where((p) => p.isWaiting).toList();

    return NeuBox(
      style: NeuStyle.raised,
      radius: 22,
      padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
      onTap: () => context.push('/jobwork/${doc.id}'),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(doc.name, style: NeuText.data(c.accentInk, size: 12)),
                    const Spacer(),
                    if (queued.isNotEmpty)
                      StateChip(
                        queued.first.kind == IntentKind.department ? 'Move queued' : 'Queued',
                        kind: ChipKind.queued,
                      )
                    else if (doc.currentDepartment != null)
                      StateChip(doc.currentDepartment!.name, kind: ChipKind.blocked),
                  ],
                ),
                const SizedBox(height: 6),
                Text(doc.customer?.name ?? 'Receipt', style: NeuText.strong(c.ink, size: 16)),
                const SizedBox(height: 6),
                Text(
                  '${doc.totalHours.toStringAsFixed(2)} h'
                  '${doc.items.isEmpty ? '' : ' · ${doc.totalPcs.toStringAsFixed(0)} pcs · ${doc.totalCarats.toStringAsFixed(2)} ct'}',
                  style: NeuText.data(c.inkMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 13),
          GestureDetector(
            onTap: () async {
              await ref.read(servicesProvider).field
                  .timer(id: doc.id, label: doc.name, start: true);
              await ref.read(syncProvider.notifier).refreshCounters();
              unawaited(ref.read(syncProvider.notifier).syncNow(flushFirst: true));
            },
            child: NeuBox(
              style: NeuStyle.raisedSm,
              radius: 16,
              width: 46,
              height: 46,
              child: Center(child: Icon(Icons.play_arrow_rounded, size: 24, color: c.accentInk)),
            ),
          ),
        ],
      ),
    );
  }
}

class JobWorkDetailScreen extends ConsumerStatefulWidget {
  const JobWorkDetailScreen({super.key, required this.id});
  final int id;

  @override
  ConsumerState<JobWorkDetailScreen> createState() => _JobWorkDetailScreenState();
}

class _JobWorkDetailScreenState extends ConsumerState<JobWorkDetailScreen> {
  bool _finishing = false;
  String? _finishError;

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final doc = ref.watch(jobWorkOneProvider(widget.id)).value;
    final online = ref.watch(syncProvider).online;
    if (doc == null) return const SizedBox.shrink();

    return NeuScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ScreenHeader(
            title: doc.name,
            mono: true,
            subtitle: '${doc.customer?.name ?? ''} · ${doc.currentDepartment?.name ?? 'No department'}',
            onBack: () => context.pop(),
            trailing: NeuIconButton(
              icon: Icons.arrow_forward_rounded,
              onPressed: () => context.push('/jobwork/${doc.id}/department'),
              tooltip: 'Move department',
              color: c.accentInk,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(child: _stat(context, 'Booked', '${doc.totalHours.toStringAsFixed(2)} h')),
              const SizedBox(width: 11),
              Expanded(
                child: _stat(
                  context,
                  'Total',
                  doc.items.isEmpty
                      ? '—'
                      : '${doc.totalPcs.toStringAsFixed(0)} / ${doc.totalCarats.toStringAsFixed(2)}',
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Expanded(
            child: NeuBox(
              style: NeuStyle.raised,
              radius: 22,
              padding: const EdgeInsets.fromLTRB(17, 16, 17, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('Items', style: NeuText.label(c.ink, size: 13)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text('entered by the office',
                            style: NeuText.body_(c.inkFaint, size: 12)),
                      ),
                      const StateChip('READ ONLY', kind: ChipKind.blocked),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: doc.items.isEmpty
                        ? Center(
                            child: Text('Being processed',
                                style: NeuText.body_(c.inkMuted, size: 13)),
                          )
                        : ListView(
                            children: [
                              Row(
                                children: [
                                  SizedBox(width: 24, child: Text('SR', style: NeuText.data(c.inkFaint, size: 10))),
                                  Expanded(child: Text('SIZE', style: NeuText.data(c.inkFaint, size: 10))),
                                  SizedBox(width: 46, child: Text('PCS', textAlign: TextAlign.right, style: NeuText.data(c.inkFaint, size: 10))),
                                  SizedBox(width: 58, child: Text('CTS', textAlign: TextAlign.right, style: NeuText.data(c.inkFaint, size: 10))),
                                ],
                              ),
                              Divider(color: c.hairline, height: 18),
                              for (final line in doc.items) ...[
                                Row(
                                  children: [
                                    SizedBox(width: 24, child: Text('${line.sr}', style: NeuText.data(c.inkFaint))),
                                    Expanded(
                                      child: Text(
                                        line.size.isEmpty ? line.product : line.size,
                                        style: NeuText.body_(c.ink, size: 13, w: FontWeight.w600),
                                      ),
                                    ),
                                    SizedBox(
                                      width: 46,
                                      child: Text(
                                        line.pcs == null ? '—' : line.pcs!.toStringAsFixed(0),
                                        textAlign: TextAlign.right,
                                        style: NeuText.data(c.ink),
                                      ),
                                    ),
                                    SizedBox(
                                      width: 58,
                                      child: Text(
                                        line.carats == null ? '—' : line.carats!.toStringAsFixed(2),
                                        textAlign: TextAlign.right,
                                        style: NeuText.data(c.ink),
                                      ),
                                    ),
                                  ],
                                ),
                                if (line.remarks != null && line.remarks!.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(left: 24, top: 2),
                                    child: Text(line.remarks!,
                                        style: NeuText.body_(c.inkFaint, size: 11)),
                                  ),
                                Divider(color: c.hairline, height: 18),
                              ],
                            ],
                          ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 13),
          if (_finishError != null) ...[
            NeuNote(text: _finishError!, kind: ChipKind.attention, icon: Icons.warning_amber_rounded),
            const SizedBox(height: 11),
          ],
          if (!online)
            const NeuNote(
              title: 'Finishing needs a connection',
              text: 'It runs the stock checks in the office system, and those cannot be answered on the phone.',
              icon: Icons.lock_outline_rounded,
            ),
          const SizedBox(height: 11),
          NeuButton(
            label: 'Finish job work',
            kind: NeuButtonKind.primary,
            icon: online ? Icons.check_rounded : Icons.lock_outline_rounded,
            busy: _finishing,
            disabledReason: online ? null : 'Needs a connection',
            onPressed: online ? () => _finish(doc) : null,
          ),
          const SizedBox(height: 11),
          Row(
            children: [
              Expanded(
                child: NeuButton(
                  label: doc.timer.running ? 'Stop timer' : 'Start timer',
                  height: 52,
                  icon: doc.timer.running ? Icons.stop_rounded : Icons.play_arrow_rounded,
                  onPressed: () async {
                    await ref.read(servicesProvider).field.timer(
                          id: doc.id,
                          label: doc.name,
                          start: !doc.timer.running,
                        );
                    await ref.read(syncProvider.notifier).refreshCounters();
                    unawaited(ref.read(syncProvider.notifier).syncNow(flushFirst: true));
                  },
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: NeuButton(
                  label: 'Move',
                  height: 52,
                  onPressed: () => context.push('/jobwork/${doc.id}/department'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
        ],
      ),
    );
  }

  Future<void> _finish(JobWorkDoc doc) async {
    setState(() {
      _finishing = true;
      _finishError = null;
    });
    try {
      await ref.read(servicesProvider).field.finishJobWork(
            id: doc.id,
            idemKey: ref.read(sessionProvider.notifier).newIdempotencyKey(),
          );
      await ref.read(syncProvider.notifier).syncNow();
      if (mounted) context.go('/jobwork');
    } on ApiError catch (e) {
      if (mounted) {
        setState(() {
          _finishing = false;
          _finishError = e.message;
        });
      }
    }
  }

  Widget _stat(BuildContext context, String label, String value) {
    final c = NeuTheme.of(context);
    return NeuBox(
      style: NeuStyle.raised,
      radius: 19,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(), style: NeuText.label(c.inkFaint, size: 11)),
          const SizedBox(height: 6),
          Text(value, style: NeuText.data(c.ink, size: 18)),
        ],
      ),
    );
  }
}

class DepartmentScreen extends ConsumerStatefulWidget {
  const DepartmentScreen({super.key, required this.id});
  final int id;

  @override
  ConsumerState<DepartmentScreen> createState() => _DepartmentScreenState();
}

class _DepartmentScreenState extends ConsumerState<DepartmentScreen> {
  int? _selected;

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final doc = ref.watch(jobWorkOneProvider(widget.id)).value;
    if (doc == null) return const SizedBox.shrink();

    final options = doc.involvedDepartments;
    final target = options.where((d) => d.id == _selected).firstOrNull;

    return NeuScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ScreenHeader(
            title: 'Move department',
            subtitle: '${doc.name} · ${doc.customer?.name ?? ''}',
            onBack: () => context.pop(),
          ),
          const SizedBox(height: 22),
          NeuBox(
            style: NeuStyle.inset,
            radius: 22,
            padding: const EdgeInsets.all(18),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('NOW IN', style: NeuText.label(c.inkFaint, size: 11)),
                      const SizedBox(height: 5),
                      Text(doc.currentDepartment?.name ?? '—',
                          style: NeuText.strong(c.ink, size: 17)),
                    ],
                  ),
                ),
                Icon(Icons.arrow_forward_rounded, size: 22, color: c.inkFaint),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('MOVING TO', style: NeuText.label(c.inkFaint, size: 11)),
                      const SizedBox(height: 5),
                      Text(
                        target?.name ?? 'Pick one',
                        style: NeuText.strong(target == null ? c.inkFaint : c.accentInk, size: 17),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          Text('Departments', style: NeuText.label(c.ink, size: 13)),
          const SizedBox(height: 12),
          Expanded(
            child: options.isEmpty
                ? const EmptyState(
                    message: 'No departments on this receipt',
                    hint: 'They arrive with the next sync',
                    icon: Icons.apartment_rounded,
                  )
                : ListView.separated(
                    itemCount: options.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (_, i) {
                      final dept = options[i];
                      final current = dept.id == doc.currentDepartment?.id;
                      final picked = dept.id == _selected;
                      return NeuBox(
                        style: picked ? NeuStyle.insetSm : NeuStyle.raised,
                        radius: 18,
                        padding: const EdgeInsets.fromLTRB(17, 15, 17, 15),
                        onTap: current ? null : () => setState(() => _selected = dept.id),
                        child: Row(
                          children: [
                            Container(
                              width: 22,
                              height: 22,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: picked ? c.accent : c.ground,
                                boxShadow: picked
                                    ? null
                                    : [
                                        BoxShadow(color: c.shadowDark, offset: const Offset(2, 2), blurRadius: 4),
                                        BoxShadow(color: c.shadowLight, offset: const Offset(-2, -2), blurRadius: 4),
                                      ],
                              ),
                              child: picked
                                  ? Icon(Icons.check_rounded, size: 13, color: c.onAccent)
                                  : null,
                            ),
                            const SizedBox(width: 13),
                            Expanded(
                              child: Text(
                                dept.name,
                                style: picked
                                    ? NeuText.strong(c.ink, size: 15)
                                    : NeuText.body_(c.inkMuted, size: 15, w: FontWeight.w600),
                              ),
                            ),
                            if (current) Text('now', style: NeuText.data(c.inkFaint, size: 11)),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 14),
          NeuNote(
            text: 'A running timer is banked against ${doc.currentDepartment?.name ?? 'the current department'} before the move.',
            icon: Icons.schedule_rounded,
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.check_rounded, size: 14, color: c.syncedInk),
              const SizedBox(width: 7),
              Text('Works offline', style: NeuText.label(c.syncedInk, size: 12)),
            ],
          ),
          const SizedBox(height: 11),
          NeuButton(
            label: target == null ? 'Pick a department' : 'Move to ${target.name}',
            kind: NeuButtonKind.primary,
            onPressed: target == null
                ? null
                : () async {
                    await ref.read(servicesProvider).field.moveDepartment(
                          id: doc.id,
                          label: doc.name,
                          departmentId: target.id,
                        );
                    await ref.read(syncProvider.notifier).refreshCounters();
                    unawaited(ref.read(syncProvider.notifier).syncNow(flushFirst: true));
                    if (context.mounted) context.pop();
                  },
          ),
          const SizedBox(height: 18),
        ],
      ),
    );
  }
}
