import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/projection.dart';
import '../../core/services.dart';
import '../../core/session.dart';
import '../../models/docs.dart';
import '../../ui/theme/neu.dart';
import '../../ui/widgets/neu_box.dart';
import '../../ui/widgets/neu_widgets.dart';
import '../../ui/widgets/v2_widgets.dart';
import '../shared/catalog.dart';
import 'jobwork_screens.dart';
import 'pickups_screens.dart';

/// `GET /me/productivity` for a range: the saved copy, then the server's.
final productivityProvider =
    StreamProvider.autoDispose.family<Productivity, (DateTime, DateTime)>((ref, range) {
  final v2 = ref.read(servicesProvider).v2;
  return savedThenFresh(
    () => v2.savedProductivity(range.$1, range.$2),
    () => v2.productivity(range.$1, range.$2),
  );
});

DateTime _day(DateTime t) => DateTime(t.year, t.month, t.day);

/// My work: hours booked today or this week, per day and per service, and the
/// entries behind them -- with the manual ones still on this phone.
class MyWorkScreen extends ConsumerStatefulWidget {
  const MyWorkScreen({super.key});

  @override
  ConsumerState<MyWorkScreen> createState() => _MyWorkScreenState();
}

class _MyWorkScreenState extends ConsumerState<MyWorkScreen> {
  late bool _week = ref.read(servicesProvider).resume.segment('mywork') == 0;

  (DateTime, DateTime) get _range {
    final today = _day(DateTime.now());
    if (!_week) return (today, today);
    final monday = today.subtract(Duration(days: today.weekday - 1));
    return (monday, monday.add(const Duration(days: 6)));
  }

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final range = _range;
    final data = ref.watch(productivityProvider(range));
    final open = ref.watch(openOutboxProvider).value ?? const [];
    final jobs = ref.watch(jobWorkProvider).value ?? const <JobWorkDoc>[];
    final name = ref.watch(sessionProvider.select((s) => s.me?.name)) ?? '';
    final today = _day(DateTime.now());

    final queued = [
      for (final e in Projection.queuedTimeLogs(open))
        if (e.date != null && !_day(e.date!).isBefore(range.$1) && !_day(e.date!).isAfter(range.$2)) e,
    ];
    final p = data.value;
    final queuedHours = queued.fold<double>(0, (a, e) => a + e.hours);
    final customers = {for (final j in jobs) j.id: j.customer?.name};
    final entries = [
      ...queued,
      for (final e in p?.entries ?? const <TimeEntry>[])
        if (!_week || (e.date != null && _day(e.date!) == today)) e,
    ];

    return NeuScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('My work', style: NeuText.title(c.ink, size: 26)),
                    const SizedBox(height: 3),
                    Text(
                      '${name.split(' ').first.isEmpty ? 'You' : name.split(' ').first} · '
                      '${_week ? 'week of ${range.$1.day} ${monthShort[range.$1.month - 1]}' : 'today, ${today.day} ${monthShort[today.month - 1]}'}',
                      style: NeuText.body_(c.inkMuted, size: 13),
                    ),
                  ],
                ),
              ),
              _toggle(context),
            ],
          ),
          const SizedBox(height: 14),
          Expanded(
            child: RefreshIndicator(
              color: c.accentInk,
              backgroundColor: c.ground,
              onRefresh: () async => ref.invalidate(productivityProvider(range)),
              child: ListView(
                padding: const EdgeInsets.only(bottom: 16),
                children: [
                  if (data is AsyncError && p == null)
                    const NeuNote(
                      title: 'Your hours come from the office',
                      text: 'They show here the first time this page is opened with a signal, and '
                          'stay on the phone after that.',
                      icon: Icons.wifi_off_rounded,
                      kind: ChipKind.queued,
                    )
                  else if (p == null)
                    Padding(
                      padding: const EdgeInsets.all(30),
                      child: Center(child: CircularProgressIndicator(color: c.accentInk)),
                    )
                  else ...[
                    _totalCard(context, p, queuedHours, today),
                    if (p.byJobType.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      _byService(context, p),
                    ],
                  ],
                  const SizedBox(height: 16),
                  SectionLabel(_week ? 'Today' : 'Entries'),
                  const SizedBox(height: 9),
                  if (entries.isEmpty)
                    Text('Nothing booked yet today.', style: NeuText.body_(c.inkMuted, size: 13))
                  else
                    for (final e in entries) ...[
                      _entry(context, e, customers[e.picking?.id]),
                      const SizedBox(height: 9),
                    ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _toggle(BuildContext context) {
    final c = NeuTheme.of(context);
    Widget seg(String label, bool week) {
      final on = _week == week;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          setState(() => _week = week);
          ref.read(servicesProvider).resume.setSegment('mywork', week ? 0 : 1);
        },
        child: on
            ? NeuBox(
                style: NeuStyle.raisedSm,
                radius: 11,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Text(label, style: NeuText.label(c.accentInk, size: 12.5)),
              )
            : Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Text(label, style: NeuText.label(c.inkMuted, size: 12.5).copyWith(fontWeight: FontWeight.w700)),
              ),
      );
    }

    return NeuBox(
      style: NeuStyle.inset,
      radius: 14,
      padding: const EdgeInsets.all(4),
      child: Row(mainAxisSize: MainAxisSize.min, children: [seg('Today', false), const SizedBox(width: 4), seg('Week', true)]),
    );
  }

  Widget _totalCard(BuildContext context, Productivity p, double queuedHours, DateTime today) {
    final c = NeuTheme.of(context);
    final days = p.byDay;
    final top = max(1.0, days.fold<double>(0, (a, d) => max(a, d.hours)));
    return NeuBox(
      style: NeuStyle.raised,
      radius: 24,
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(Fig.hours(p.totalHours), style: NeuText.data(c.ink, size: 36)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(_week ? 'booked this week' : 'booked today',
                    style: NeuText.body_(c.inkMuted, size: 13)),
              ),
            ],
          ),
          if (queuedHours > 0) ...[
            const SizedBox(height: 4),
            Text('+ ${Fig.hours(queuedHours)} on this phone, sent when online',
                style: NeuText.label(c.queuedInk, size: 12)),
          ],
          if (_week && days.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text('Hours per day', style: NeuText.label(c.inkMuted, size: 12)),
            const SizedBox(height: 8),
            Semantics(
              label: 'Hours per day: ${days.map((d) => '${weekdayShort[d.date.weekday - 1]} ${Fig.hours(d.hours)}').join(', ')}',
              child: Container(
                height: 110,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.hairline))),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final d in days)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 5),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              // One line, shrunk to the column if it must be: at a large font
                              // scale "1.75" wrapped to "1.7 / 5" on the M31.
                              if (_day(d.date) == today && d.hours > 0) ...[
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    Fig.pcs(d.hours),
                                    maxLines: 1,
                                    softWrap: false,
                                    style: NeuText.data(c.ink, size: 11),
                                  ),
                                ),
                                const SizedBox(height: 4),
                              ],
                              // The tallest bar leaves room for that label inside the 110 px
                              // plot, so it never runs down over the day names.
                              if (d.hours > 0)
                                Container(
                                  constraints: const BoxConstraints(maxWidth: 26),
                                  height: 78 * d.hours / top,
                                  decoration: BoxDecoration(
                                    color: c.accentInk.withValues(alpha: _day(d.date) == today ? 1 : 0.55),
                                    borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                for (final d in days)
                  Expanded(
                    child: Text(
                      weekdayShort[d.date.weekday - 1],
                      textAlign: TextAlign.center,
                      style: NeuText.label(
                        _day(d.date) == today
                            ? c.ink
                            : (_day(d.date).isAfter(today) ? c.inkFaint : c.inkMuted),
                        size: 11,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _byService(BuildContext context, Productivity p) {
    final c = NeuTheme.of(context);
    final total = max(0.0001, p.totalHours);
    return NeuBox(
      style: NeuStyle.raised,
      radius: 22,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('By service', style: NeuText.label(c.inkMuted, size: 12)),
          for (final j in p.byJobType) ...[
            const SizedBox(height: 11),
            Row(
              children: [
                Expanded(child: Text(j.jobType?.name ?? 'No service', style: NeuText.label(c.ink, size: 13))),
                Text(Fig.hours(j.hours), style: NeuText.data(c.ink, size: 13)),
              ],
            ),
            const SizedBox(height: 4),
            NeuBox(
              style: NeuStyle.insetSm,
              radius: 4,
              height: 8,
              child: LayoutBuilder(
                builder: (context, box) => Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    width: box.maxWidth * (j.hours / total).clamp(0, 1),
                    decoration: BoxDecoration(color: c.accentInk, borderRadius: BorderRadius.circular(4)),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _entry(BuildContext context, TimeEntry e, String? customer) {
    final c = NeuTheme.of(context);
    final how = e.running ? 'timer' : (e.onThisPhone ? 'entered on this phone' : 'entered');
    return NeuBox(
      style: NeuStyle.raisedSm,
      radius: 18,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  [e.picking?.name, customer].whereType<String>().where((s) => s.isNotEmpty).join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NeuText.strong(c.ink, size: 14),
                ),
                Text(
                  [e.jobType?.name, how, e.description].whereType<String>().where((s) => s.isNotEmpty).join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: NeuText.body_(c.inkMuted, size: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (e.running)
            Text('running', style: NeuText.data(c.syncedInk, size: 14))
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(Fig.hours(e.hours), style: NeuText.data(c.ink, size: 14)),
                if (e.onThisPhone) ...[
                  const SizedBox(height: 4),
                  const StateChip('On this phone', kind: ChipKind.queued),
                ],
              ],
            ),
        ],
      ),
    );
  }
}
