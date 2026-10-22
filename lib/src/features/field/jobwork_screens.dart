import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Ref;
import 'package:go_router/go_router.dart';

import '../../core/api/api_error.dart';
import '../../core/clock/odoo_time.dart';
import '../../core/drafts/draft_store.dart';
import '../../core/notices/notices.dart';
import '../../core/outbox/outbox.dart';
import '../../core/projection.dart';
import '../../core/services.dart';
import '../../core/session.dart';
import '../../core/sync_status.dart';
import '../../models/docs.dart';
import '../../ui/theme/neu.dart';
import '../../ui/widgets/item_table.dart';
import '../../ui/widgets/neu_box.dart';
import '../../ui/widgets/neu_widgets.dart';
import '../../ui/widgets/status_strip.dart';
import '../../ui/widgets/v2_widgets.dart';
import 'sign_in_screens.dart';
import '../shared/catalog.dart';
import 'pickups_screens.dart';

final jobWorkProvider = FutureProvider.autoDispose<List<JobWorkDoc>>((ref) {
  ref.watch(dataRevisionProvider);
  return ref.read(servicesProvider).records.jobWork();
});

final jobWorkOneProvider = FutureProvider.autoDispose.family<JobWorkDoc?, int>((ref, id) {
  ref.watch(dataRevisionProvider);
  return ref.read(servicesProvider).records.jobWorkOne(id);
});

Future<void> _queued(WidgetRef ref) async {
  await ref.read(syncProvider.notifier).refreshCounters();
  unawaited(ref.read(syncProvider.notifier).syncNow(flushFirst: true));
}

/// Start or stop the receipt timer, booked against [jobTypeId] (the
/// department it is in, unless the person picked a service).
Future<void> toggleTimer(WidgetRef ref, JobWorkDoc doc, TimerInfo timer, {int? jobTypeId}) async {
  await ref
      .read(servicesProvider)
      .field
      .timer(
        id: doc.id,
        label: doc.name,
        start: !timer.running,
        jobTypeId: timer.running ? null : (jobTypeId ?? doc.currentDepartment?.id),
      );
  await _queued(ref);
}

/// The services a receipt is about: what was asked for, else what the lines say.
List<Ref> servicesOf(JobWorkDoc doc) {
  final seen = <int>{};
  return [
    for (final s in doc.services)
      if (s.jobType != null && seen.add(s.jobType!.id)) s.jobType!,
    for (final l in doc.items)
      if (l.jobType != null && seen.add(l.jobType!.id)) l.jobType!,
  ];
}

class JobWorkScreen extends ConsumerStatefulWidget {
  const JobWorkScreen({super.key});

  @override
  ConsumerState<JobWorkScreen> createState() => _JobWorkScreenState();
}

class _JobWorkScreenState extends ConsumerState<JobWorkScreen> {
  Timer? _tick;
  late int _filter = ref.read(servicesProvider).resume.segment('jobwork_department');

  @override
  void initState() {
    super.initState();
    // A running timer shows minutes; there is no need to repaint every second.
    _tick = Timer.periodic(const Duration(seconds: 20), (_) {
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
    final pending = ref.watch(pendingByRecordProvider).value ?? const <int, List<OutboxItem>>{};
    final fresh = ref.watch(noticesProvider.select((s) => s.unreadPickings));

    final departments = <int, (String, int)>{};
    for (final doc in all) {
      final dept = Projection.department(doc, pending[doc.id] ?? const []);
      if (dept == null) continue;
      final seen = departments[dept.id];
      departments[dept.id] = (dept.name, (seen?.$2 ?? 0) + 1);
    }
    if (_filter != 0 && !departments.containsKey(_filter)) _filter = 0;
    final shown = [
      for (final doc in all)
        if (_filter == 0 || Projection.department(doc, pending[doc.id] ?? const [])?.id == _filter) doc,
    ];
    final running = [
      for (final doc in all)
        if (Projection.timer(doc, pending[doc.id] ?? const []).running) doc,
    ];

    return NeuScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ScreenHeader(
            title: 'Job work',
            subtitle: '${all.length} ready · validated by the office',
            trailing: const TabHeaderActions(),
          ),
          const SizedBox(height: 13),
          StatusStrip(onQueueTap: () => context.push('/queue')),
          const SizedBox(height: 13),
          if (departments.isNotEmpty) ...[
            SizedBox(
              height: 46,
              child: ListView(
                scrollDirection: Axis.horizontal,
                clipBehavior: Clip.none,
                children: [
                  PickChip(label: 'All · ${all.length}', selected: _filter == 0, onTap: () => _setFilter(0)),
                  for (final entry in departments.entries) ...[
                    const SizedBox(width: 8),
                    PickChip(
                      label: '${entry.value.$1} · ${entry.value.$2}',
                      selected: _filter == entry.key,
                      onTap: () => _setFilter(entry.key),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 10),
          ],
          for (final doc in running) ...[
            _RunningStrip(doc: doc, timer: Projection.timer(doc, pending[doc.id] ?? const [])),
            const SizedBox(height: 12),
          ],
          Expanded(
            child: RefreshIndicator(
              color: c.accentInk,
              backgroundColor: c.ground,
              onRefresh: () => ref.read(syncProvider.notifier).syncNow(flushFirst: true),
              child: shown.isEmpty
                  ? const EmptyState(
                      message: 'Nothing ready for job work',
                      hint: 'The office marks receipts READY; they appear here',
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.only(bottom: 16),
                      itemCount: shown.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 12),
                      itemBuilder: (_, i) => _JobCard(
                        doc: shown[i],
                        pending: pending[shown[i].id] ?? const [],
                        fresh: fresh.contains(shown[i].id),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  void _setFilter(int id) {
    setState(() => _filter = id);
    ref.read(servicesProvider).resume.setSegment('jobwork_department', id);
  }
}

class _RunningStrip extends StatelessWidget {
  const _RunningStrip({required this.doc, required this.timer});
  final JobWorkDoc doc;
  final TimerInfo timer;

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final started = timer.startedAt;
    final elapsed = started == null ? Duration.zero : DateTime.now().difference(started);
    return NeuBox(
      style: NeuStyle.raised,
      radius: 20,
      padding: const EdgeInsets.fromLTRB(15, 13, 15, 13),
      onTap: () => context.push('/jobwork/${doc.id}'),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: c.syncedInk, shape: BoxShape.circle),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'RUNNING · ${doc.name}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NeuText.label(c.syncedInk, size: 12).copyWith(letterSpacing: 0.5),
                ),
                const SizedBox(height: 2),
                Text(
                  '${doc.customer?.name ?? 'Receipt'} · ${doc.currentDepartment?.name ?? 'No department'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NeuText.strong(c.ink, size: 14),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(OdooTime.duration(elapsed).substring(0, 5), style: NeuText.data(c.ink, size: 20)),
        ],
      ),
    );
  }
}

class _JobCard extends StatelessWidget {
  const _JobCard({required this.doc, required this.pending, required this.fresh});
  final JobWorkDoc doc;
  final List<OutboxItem> pending;
  final bool fresh;

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final queued = pending.where((p) => p.isWaiting).toList();
    final dept = Projection.department(doc, pending);
    final (String chip, ChipKind kind) = queued.isNotEmpty
        ? (
            switch (queued.last.kind) {
              IntentKind.department => 'Move queued',
              IntentKind.timer => 'Timer queued',
              IntentKind.logTime => 'Time queued',
              _ => 'Queued',
            },
            ChipKind.queued,
          )
        : fresh
        // A notice brought it in: say where it is now, if anywhere.
        ? (dept != null ? 'In ${dept.name} · new' : 'READY · new', ChipKind.synced)
        : dept != null
        ? ('In ${dept.name}', ChipKind.blocked)
        : ('READY', ChipKind.synced);
    final figures = [
      if (doc.items.isNotEmpty) '${doc.items.length} line${doc.items.length == 1 ? '' : 's'}',
      if (doc.items.isNotEmpty) '${Fig.pcs(doc.totalPcs)} pcs',
      if (doc.items.isNotEmpty) '${Fig.ct(doc.totalCarats)} ct',
      if (doc.myHours > 0) '${Fig.hours(doc.myHours)} yours',
    ].join(' · ');
    final services = servicesOf(doc);

    return NeuBox(
      style: NeuStyle.raised,
      radius: 22,
      padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
      onTap: () => context.push('/jobwork/${doc.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(doc.name, overflow: TextOverflow.ellipsis, style: NeuText.data(c.accentInk, size: 12)),
              ),
              const SizedBox(width: 8),
              Flexible(child: StateChip(chip, kind: kind)),
            ],
          ),
          const SizedBox(height: 6),
          Text(doc.customer?.name ?? 'Receipt', style: NeuText.strong(c.ink, size: 16)),
          if (figures.isNotEmpty) ...[
            const SizedBox(height: 5),
            Text(figures, style: NeuText.data(c.inkMuted, size: 12)),
          ],
          if (services.isNotEmpty) ...[
            const SizedBox(height: 9),
            Wrap(spacing: 6, runSpacing: 6, children: [for (final s in services) InsetTag(s.name)]),
          ],
        ],
      ),
    );
  }
}

// ------------------------------------------------------------ the receipt

class JobWorkDetailScreen extends ConsumerStatefulWidget {
  const JobWorkDetailScreen({super.key, required this.id});
  final int id;

  @override
  ConsumerState<JobWorkDetailScreen> createState() => _JobWorkDetailScreenState();
}

class _JobWorkDetailScreenState extends ConsumerState<JobWorkDetailScreen> {
  bool _finishing = false;
  String? _finishError;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
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
    final doc = ref.watch(jobWorkOneProvider(widget.id)).value;
    final online = ref.watch(syncProvider.select((s) => s.online));
    final pending = (ref.watch(pendingByRecordProvider).value ?? const {})[widget.id] ?? const [];
    if (doc == null) {
      return NeuScaffold(
        child: Column(
          children: [
            ScreenHeader(title: 'Receipt', onBack: () => context.pop()),
            const Spacer(),
            Text('This receipt is no longer in job work.', style: NeuText.body_(c.inkMuted, size: 14)),
            const Spacer(),
          ],
        ),
      );
    }
    final timer = Projection.timer(doc, pending);
    final elapsed = timer.running && timer.startedAt != null
        ? DateTime.now().difference(timer.startedAt!)
        : Duration.zero;
    final rows = [for (final l in doc.items) ItemRow.fromLine(l)];

    return NeuScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StepHeader(step: '${doc.name} · READY', title: doc.customer?.name ?? 'Receipt'),
          const SizedBox(height: 13),
          Expanded(
            child: ListView(
              children: [
                if (doc.services.isNotEmpty) ...[
                  NeuBox(
                    style: NeuStyle.inset,
                    radius: 16,
                    padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
                    child: Text.rich(
                      TextSpan(
                        style: NeuText.body_(c.inkSoft, size: 12.5),
                        children: [
                          TextSpan(text: 'Customer asked for', style: NeuText.label(c.ink, size: 12.5)),
                          for (final s in doc.services)
                            TextSpan(
                              text:
                                  ' · ${s.name} ${s.quantityLabel}'
                                  '${s.remarks == null ? '' : ' “${s.remarks}”'}',
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 13),
                ],
                ItemTable(
                  rows: rows,
                  emptyText: 'The office has not entered the lines yet',
                  onRowTap: (i) => showLineSheet(context, doc, i),
                ),
                const SizedBox(height: 8),
                Text(
                  'Sr stays put while the rest scrolls. Tap a row to see it in full.',
                  style: NeuText.body_(c.inkMuted, size: 12),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
          Row(
            children: [
              Expanded(
                child: ActionTile(
                  icon: Icons.more_time_rounded,
                  label: 'Log time',
                  onTap: () => context.push('/jobwork/${doc.id}/log'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ActionTile(
                  icon: Icons.arrow_forward_rounded,
                  label: 'Move',
                  onTap: () => context.push('/jobwork/${doc.id}/department'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ActionTile(
                  icon: timer.running ? Icons.stop_rounded : Icons.play_arrow_rounded,
                  label: timer.running ? 'Stop ${OdooTime.duration(elapsed).substring(0, 5)}' : 'Start timer',
                  ink: timer.running ? c.attentionInk : null,
                  onTap: () => toggleTimer(ref, doc, timer),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_finishError != null) ...[
            NeuNote(text: _finishError!, kind: ChipKind.attention, icon: Icons.warning_amber_rounded),
            const SizedBox(height: 11),
          ],
          if (!online) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.lock_outline_rounded, size: 14, color: c.blockedInk),
                const SizedBox(width: 7),
                Text('Finishing needs a connection', style: NeuText.body_(c.blockedInk, size: 12, w: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 10),
          ],
          NeuBox(
            key: const Key('finish-job-work'),
            style: online ? NeuStyle.raised : NeuStyle.flat,
            color: online ? null : c.disabledFill,
            radius: 18,
            height: 54,
            onTap: online && !_finishing ? () => _finish(doc) : null,
            child: Center(
              child: _finishing
                  ? SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.4, color: c.syncedInk),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          online ? Icons.check_circle_outline_rounded : Icons.lock_outline_rounded,
                          size: 19,
                          color: online ? c.syncedInk : c.disabledInk,
                        ),
                        const SizedBox(width: 9),
                        Text('Finish job work', style: NeuText.strong(online ? c.syncedInk : c.disabledInk, size: 15)),
                      ],
                    ),
            ),
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
      await ref
          .read(servicesProvider)
          .field
          .finishJobWork(id: doc.id, idemKey: ref.read(sessionProvider.notifier).newIdempotencyKey());
      await ref.read(syncProvider.notifier).syncNow();
      // The delivery order it creates reaches Deliveries after the visibility lag.
      ref.read(syncProvider.notifier).followUpOwnChange();
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
}

/// One line, in full, with the line before and after a tap away.
Future<void> showLineSheet(BuildContext context, JobWorkDoc doc, int index) {
  return showNeuSheet<void>(
    context,
    builder: (sheetContext) => _LineSheet(doc: doc, initial: index),
  );
}

class _LineSheet extends StatefulWidget {
  const _LineSheet({required this.doc, required this.initial});
  final JobWorkDoc doc;
  final int initial;

  @override
  State<_LineSheet> createState() => _LineSheetState();
}

class _LineSheetState extends State<_LineSheet> {
  late int _i = widget.initial;

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final items = widget.doc.items;
    final line = items[_i];
    final request =
        widget.doc.services.where((s) => s.moveId == line.moveId && line.moveId != null).firstOrNull ??
        widget.doc.services.where((s) => s.jobType?.id == line.jobType?.id).firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            NeuBox(
              style: NeuStyle.insetSm,
              radius: 14,
              width: 44,
              height: 44,
              color: c.ground,
              child: Center(child: Text('${line.sr}', style: NeuText.data(c.accentInk, size: 17))),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'LINE ${_i + 1} OF ${items.length}',
                    style: NeuText.label(c.inkMuted, size: 12).copyWith(letterSpacing: 0.6),
                  ),
                  Text(line.jobType?.name ?? 'No service', style: NeuText.title(c.ink, size: 19)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 15),
        Row(
          children: [
            Expanded(
              child: ValueWell(label: 'Size', value: line.size.isEmpty ? '—' : line.size),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ValueWell(label: 'Pcs', value: Fig.pcs(line.pcs)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ValueWell(label: 'Carats', value: Fig.ct(line.carats)),
            ),
          ],
        ),
        const SizedBox(height: 12),
        ValueWell(label: 'Remarks', value: (line.remarks ?? '').isEmpty ? '—' : line.remarks!, mono: false),
        const SizedBox(height: 14),
        if (request != null) ...[
          SummaryRow(label: "From the customer's request", value: '${request.name} · ${request.quantityLabel}'),
          const SizedBox(height: 8),
        ],
        if (line.product.isNotEmpty) SummaryRow(label: 'Item', value: line.product),
        const SizedBox(height: 12),
        Text(
          'Lines are entered by the office. Something wrong? Note it on the receipt.',
          style: NeuText.body_(c.inkFaint, size: 12),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: NeuButton(
                label: _i > 0 ? 'Line $_i' : 'First line',
                icon: Icons.chevron_left_rounded,
                height: 50,
                onPressed: _i > 0 ? () => setState(() => _i--) : null,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: NeuButton(
                label: _i < items.length - 1 ? 'Line ${_i + 2}' : 'Last line',
                icon: Icons.chevron_right_rounded,
                height: 50,
                onPressed: _i < items.length - 1 ? () => setState(() => _i++) : null,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// --------------------------------------------------------------- log time

class LogTimeScreen extends ConsumerStatefulWidget {
  const LogTimeScreen({super.key, required this.id});
  final int id;

  @override
  ConsumerState<LogTimeScreen> createState() => _LogTimeScreenState();
}

class _LogTimeScreenState extends ConsumerState<LogTimeScreen> {
  int? _jobTypeId;
  int _hours = 1;
  int _minutes = 0;
  DateTime _day = DateTime.now();
  final _note = TextEditingController();
  bool _busy = false;
  DateTime? _restoredAt;
  Timer? _tick;

  late final Services _s = ref.read(servicesProvider);
  String get _key => DraftStore.timeLog(widget.id);

  @override
  void initState() {
    super.initState();
    final s = _s;
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    unawaited(() async {
      final draft = await s.drafts.load(_key);
      if (draft == null || !mounted) return;
      setState(() {
        _jobTypeId = (draft.data['job_type_id'] as num?)?.toInt();
        _hours = (draft.data['hours'] as num?)?.toInt() ?? 1;
        _minutes = (draft.data['minutes'] as num?)?.toInt() ?? 0;
        _day = DateTime.tryParse('${draft.data['day']}') ?? DateTime.now();
        _note.text = '${draft.data['note'] ?? ''}';
        if (draft.savedAt.isBefore(DraftStore.launchedAt)) _restoredAt = draft.savedAt;
      });
    }());
  }

  void _persist() => _s.drafts.save(_key, {
    'job_type_id': _jobTypeId,
    'hours': _hours,
    'minutes': _minutes,
    'day': TimeLogRequest.isoDate(_day),
    'note': _note.text,
  });

  @override
  void dispose() {
    _tick?.cancel();
    unawaited(_s.drafts.saveNow(_key));
    _note.dispose();
    super.dispose();
  }

  double get _total => _hours + _minutes / 60;

  Future<void> _pickDay() async {
    final today = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: today.subtract(const Duration(days: 31)),
      lastDate: today,
    );
    if (picked != null) {
      setState(() => _day = picked);
      _persist();
    }
  }

  Future<void> _save(JobWorkDoc doc, String serviceName) async {
    setState(() => _busy = true);
    await _s.field.logTime(
      id: doc.id,
      label: doc.name,
      request: TimeLogRequest(
        jobTypeId: _jobTypeId!,
        hours: double.parse(_total.toStringAsFixed(4)),
        description: _note.text,
        date: _day,
      ),
      jobTypeName: serviceName,
    );
    await _s.drafts.clear(_key);
    await _queued(ref);
    if (mounted) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final doc = ref.watch(jobWorkOneProvider(widget.id)).value;
    final pending = (ref.watch(pendingByRecordProvider).value ?? const {})[widget.id] ?? const [];
    if (doc == null) return const NeuScaffold(child: SizedBox.shrink());
    final services = servicesOf(doc);
    final options = services.isNotEmpty ? services : [if (doc.currentDepartment != null) doc.currentDepartment!];
    _jobTypeId ??= options.isNotEmpty ? options.first.id : null;
    final chosen = options.where((o) => o.id == _jobTypeId).firstOrNull;
    final timer = Projection.timer(doc, pending);
    final elapsed = timer.running && timer.startedAt != null
        ? DateTime.now().difference(timer.startedAt!)
        : Duration.zero;
    final now = DateTime.now();
    final isToday = _day.year == now.year && _day.month == now.month && _day.day == now.day;
    final ready = _total > 0 && chosen != null;

    return NeuScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_restoredAt != null) ...[
            ResumeBanner(
              closedAt: _restoredAt!,
              what: 'The service, hours and note',
              onDismiss: () => setState(() => _restoredAt = null),
            ),
            const SizedBox(height: 12),
          ],
          StepHeader(step: '${doc.name} · ${doc.customer?.name ?? ''}', title: 'Log time'),
          const SizedBox(height: 15),
          Expanded(
            child: ListView(
              children: [
                NeuBox(
                  style: NeuStyle.raised,
                  radius: 22,
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                  child: Row(
                    children: [
                      NeuBox(
                        style: NeuStyle.inset,
                        radius: 37,
                        width: 74,
                        height: 74,
                        child: Center(
                          child: Text(OdooTime.duration(elapsed).substring(0, 5), style: NeuText.data(c.ink, size: 17)),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              timer.running ? 'Timer running' : 'Use the timer',
                              style: NeuText.label(c.ink, size: 14),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              timer.running
                                  ? 'Stop it when you put the parcel down.'
                                  : 'Start now, stop when you put it down.',
                              style: NeuText.body_(c.inkMuted, size: 12.5),
                            ),
                          ],
                        ),
                      ),
                      NeuIconButton(
                        icon: timer.running ? Icons.stop_rounded : Icons.play_arrow_rounded,
                        size: 46,
                        color: timer.running ? c.attentionInk : c.accentInk,
                        tooltip: timer.running ? 'Stop timer' : 'Start timer',
                        onPressed: () => toggleTimer(ref, doc, timer, jobTypeId: _jobTypeId),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 15),
                Row(
                  children: [
                    Expanded(child: Divider(color: c.hairline)),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Text(
                        'OR ENTER IT',
                        style: NeuText.label(c.inkFaint, size: 12).copyWith(letterSpacing: 0.7),
                      ),
                    ),
                    Expanded(child: Divider(color: c.hairline)),
                  ],
                ),
                const SizedBox(height: 15),
                Text('Service', style: NeuText.label(c.inkMuted, size: 12)),
                const SizedBox(height: 7),
                if (options.isEmpty)
                  Text('This receipt has no service on it yet.', style: NeuText.body_(c.inkMuted, size: 13))
                else
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final o in options)
                        PickChip(
                          label: o.name,
                          selected: o.id == _jobTypeId,
                          onTap: () {
                            setState(() => _jobTypeId = o.id);
                            _persist();
                          },
                        ),
                    ],
                  ),
                const SizedBox(height: 15),
                Text('How long', style: NeuText.label(c.inkMuted, size: 12)),
                const SizedBox(height: 7),
                Row(
                  children: [
                    Expanded(
                      child: QtyStepper(
                        key: const Key('hours-stepper'),
                        big: false,
                        value: _hours.toDouble(),
                        unit: 'h',
                        step: 1,
                        max: 24,
                        lessLabel: 'One hour less',
                        moreLabel: 'One hour more',
                        onChanged: (v) {
                          setState(() => _hours = v.round());
                          _persist();
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: QtyStepper(
                        key: const Key('minutes-stepper'),
                        big: false,
                        value: _minutes.toDouble(),
                        unit: 'min',
                        step: 15,
                        max: 45,
                        lessLabel: '15 minutes less',
                        moreLabel: '15 minutes more',
                        onChanged: (v) {
                          setState(() => _minutes = v.round());
                          _persist();
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 15),
                Row(
                  children: [
                    Expanded(
                      flex: 10, // 10 : 14 against the note, as designed
                      child: NeuBox(
                        style: NeuStyle.insetSm,
                        radius: 15,
                        color: c.ground,
                        onTap: _pickDay,
                        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Day',
                              style: NeuText.label(c.inkMuted, size: 11).copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${isToday ? 'Today' : weekdayShort[_day.weekday - 1]}, ${_day.day} ${monthShort[_day.month - 1]}',
                              style: NeuText.strong(c.ink, size: 14.5),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 14,
                      child: LabeledInput(
                        label: 'Note (optional)',
                        controller: _note,
                        hint: 'Lines 1–2 done',
                        size: 14.5,
                        onChanged: (_) => _persist(),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
          const OfflineHint('Works offline · saved with the time you entered it'),
          const SizedBox(height: 10),
          NeuButton(
            key: const Key('save-time'),
            label: ready ? 'Save ${Fig.hours(_total)}' : (chosen == null ? 'Pick a service' : 'Enter how long'),
            kind: NeuButtonKind.primary,
            height: 54,
            busy: _busy,
            onPressed: ready ? () => _save(doc, chosen.name) : null,
          ),
          const SizedBox(height: 18),
        ],
      ),
    );
  }
}

// -------------------------------------------------------------- move

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
    final catalog = ref.watch(jobTypesProvider).value;
    final pending = (ref.watch(pendingByRecordProvider).value ?? const {})[widget.id] ?? const [];
    if (doc == null) return const NeuScaffold(child: SizedBox.shrink());

    final current = Projection.department(doc, pending);
    final onJangad = {for (final s in servicesOf(doc)) s.id};
    final all = <Ref>[
      ...servicesOf(doc),
      for (final j in catalog ?? const <JobTypeInfo>[]) Ref(id: j.id, name: j.name),
      ...doc.involvedDepartments,
    ];
    final seen = <int>{};
    final options = [
      for (final o in all)
        if (o.id != current?.id && seen.add(o.id)) o,
    ];
    _selected ??= options.where((o) => onJangad.contains(o.id)).firstOrNull?.id;
    final target = options.where((d) => d.id == _selected).firstOrNull;
    final history = [
      for (final d in doc.involvedDepartments)
        if (d.id != current?.id) d,
    ];

    return NeuScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StepHeader(step: '${doc.name} · ${doc.customer?.name ?? ''}', title: 'Move to department'),
          const SizedBox(height: 15),
          NeuBox(
            style: NeuStyle.inset,
            radius: 18,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Where it has been', style: NeuText.label(c.inkMuted, size: 12)),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final d in history) ...[
                      StateChip(d.name, kind: ChipKind.blocked),
                      Icon(Icons.arrow_forward_rounded, size: 14, color: c.inkFaint),
                    ],
                    StateChip(
                      current == null ? 'No department yet' : '${current.name} · now',
                      kind: current == null ? ChipKind.blocked : ChipKind.synced,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 15),
          const SectionLabel('Move it to'),
          const SizedBox(height: 10),
          Expanded(
            child: options.isEmpty
                ? const EmptyState(
                    message: 'No other departments known yet',
                    hint: 'The list comes with the next sync',
                    icon: Icons.apartment_rounded,
                  )
                : NeuBox(
                    style: NeuStyle.inset,
                    radius: 20,
                    padding: const EdgeInsets.all(6),
                    child: ListView.builder(
                      itemCount: options.length,
                      itemBuilder: (_, i) {
                        final dept = options[i];
                        final picked = dept.id == _selected;
                        final row = Row(
                          children: [
                            RadioDot(selected: picked),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                dept.name,
                                style: picked
                                    ? NeuText.label(c.ink, size: 14.5)
                                    : NeuText.body_(c.ink, size: 14.5, w: FontWeight.w600),
                              ),
                            ),
                            if (onJangad.contains(dept.id))
                              Text('on the jangad', style: NeuText.body_(c.inkMuted, size: 12)),
                          ],
                        );
                        return picked
                            ? NeuBox(
                                style: NeuStyle.raisedSm,
                                radius: 15,
                                padding: const EdgeInsets.fromLTRB(12, 13, 12, 13),
                                onTap: () => setState(() => _selected = dept.id),
                                child: row,
                              )
                            : InkWell(
                                onTap: () => setState(() => _selected = dept.id),
                                child: Container(
                                  padding: const EdgeInsets.fromLTRB(12, 13, 12, 13),
                                  decoration: i == options.length - 1
                                      ? null
                                      : BoxDecoration(
                                          border: Border(bottom: BorderSide(color: c.hairline)),
                                        ),
                                  child: row,
                                ),
                              );
                      },
                    ),
                  ),
          ),
          const SizedBox(height: 8),
          Text(
            'Services on this jangad are listed first. The job workers there get a notification.',
            style: NeuText.body_(c.inkMuted, size: 12),
          ),
          const SizedBox(height: 12),
          const OfflineHint('Works offline · moves when it reaches the office'),
          const SizedBox(height: 10),
          NeuButton(
            label: target == null ? 'Pick a department' : 'Move to ${target.name}',
            kind: NeuButtonKind.primary,
            height: 54,
            onPressed: target == null
                ? null
                : () async {
                    await ref
                        .read(servicesProvider)
                        .field
                        .moveDepartment(
                          id: doc.id,
                          label: doc.name,
                          departmentId: target.id,
                          departmentName: target.name,
                        );
                    await _queued(ref);
                    if (context.mounted) context.pop();
                  },
          ),
          const SizedBox(height: 18),
        ],
      ),
    );
  }
}
