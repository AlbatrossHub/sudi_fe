import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Ref;
import 'package:go_router/go_router.dart';

import '../../core/api/api_error.dart';
import '../../core/clock/odoo_time.dart';
import '../../core/drafts/draft_store.dart';
import '../../core/services.dart';
import '../../core/session.dart';
import '../../core/sync_status.dart';
import '../../models/docs.dart';
import '../../ui/theme/neu.dart';
import '../../ui/widgets/item_table.dart';
import '../../ui/widgets/neu_box.dart';
import '../../ui/widgets/neu_widgets.dart';
import '../../ui/widgets/signature_pad.dart';
import '../../ui/widgets/status_strip.dart';
import '../../ui/widgets/v2_widgets.dart';
import 'sign_in_screens.dart';
import '../shared/catalog.dart';
import 'pickups_screens.dart';

final officeListProvider = FutureProvider.autoDispose<List<OfficeDoc>>((ref) {
  ref.watch(dataRevisionProvider);
  return ref.read(servicesProvider).records.office();
});

final officeOneProvider = FutureProvider.autoDispose.family<OfficeDoc?, int>((ref, id) {
  ref.watch(dataRevisionProvider);
  return ref.read(servicesProvider).records.officeOne(id);
});

/// Which receipts have an item table drafted on this phone.
final officeDraftIdsProvider = FutureProvider.autoDispose<Set<int>>((ref) async {
  ref.watch(dataRevisionProvider);
  final keys = await ref.read(servicesProvider).drafts.keys();
  return {
    for (final k in keys)
      if (k.startsWith('office_lines:')) ?int.tryParse(k.substring('office_lines:'.length)),
  };
});

// ------------------------------------------------------------- the table

/// A server refusal pinned to rows of the table.
class LineProblems {
  const LineProblems({this.rows = const {}, this.messages = const []});
  final Set<int> rows;
  final List<String> messages;

  bool get isEmpty => messages.isEmpty;

  /// `detail.problems`: `[{row, field, message}]` from saving the lines (row is
  /// the position in what was sent), `[{move_id, sr, field, message}]` from
  /// Mark READY (sr is the 1-based line number).
  static LineProblems from(ApiError e, List<OfficeLine> lines) {
    final raw = e.detail['problems'];
    if (raw is! List || raw.isEmpty) return LineProblems(messages: [e.message]);
    final rows = <int>{};
    final messages = <String>[];
    for (final p in raw.whereType<Map>()) {
      final row = (p['row'] as num?)?.toInt();
      final sr = (p['sr'] as num?)?.toInt();
      final moveId = (p['move_id'] as num?)?.toInt();
      int? index;
      if (moveId != null) {
        final i = lines.indexWhere((l) => l.moveId == moveId);
        if (i >= 0) index = i;
      }
      index ??= sr != null ? sr - 1 : row;
      if (index != null && index >= 0 && index < lines.length) rows.add(index);
      final message = '${p['message'] ?? ''}';
      if (message.isNotEmpty) messages.add(message);
    }
    return LineProblems(rows: rows, messages: messages.isEmpty ? [e.message] : messages);
  }
}

class OfficeTableState {
  const OfficeTableState({
    this.loaded = false,
    this.lines = const [],
    this.baseRev = 0,
    this.hasDraft = false,
    this.savedAt,
    this.restoredAt,
    this.addedOnPhone = 0,
    this.problems = const LineProblems(),
    this.busy = false,
  });

  final bool loaded;
  final List<OfficeLine> lines;

  /// The office copy's revision when this draft was started.
  final int baseRev;

  /// The table differs from the office copy and is kept on the phone.
  final bool hasDraft;
  final DateTime? savedAt;
  final DateTime? restoredAt;

  /// Entries made from the requested services with no signal.
  final int addedOnPhone;
  final LineProblems problems;
  final bool busy;

  double get pcs => lines.fold(0, (a, l) => a + l.pcs);
  double get carats => lines.fold(0, (a, l) => a + l.carats);
  List<ItemRow> get rows => [for (var i = 0; i < lines.length; i++) ItemRow.fromOffice(lines[i], i)];

  OfficeTableState copyWith({
    bool? loaded,
    List<OfficeLine>? lines,
    int? baseRev,
    bool? hasDraft,
    DateTime? savedAt,
    DateTime? restoredAt,
    bool clearRestored = false,
    int? addedOnPhone,
    LineProblems? problems,
    bool? busy,
  }) =>
      OfficeTableState(
        loaded: loaded ?? this.loaded,
        lines: lines ?? this.lines,
        baseRev: baseRev ?? this.baseRev,
        hasDraft: hasDraft ?? this.hasDraft,
        savedAt: savedAt ?? this.savedAt,
        restoredAt: clearRestored ? null : (restoredAt ?? this.restoredAt),
        addedOnPhone: addedOnPhone ?? this.addedOnPhone,
        problems: problems ?? this.problems,
        busy: busy ?? this.busy,
      );
}

/// The office's item table for one receipt: a draft on the phone until it is
/// saved, which needs a signal. Nothing here is queued -- the office edits a
/// table, it does not fire intents at it.
class OfficeTableController extends Notifier<OfficeTableState> {
  OfficeTableController(this.id);
  final int id;

  Services get _s => ref.read(servicesProvider);
  String get _key => DraftStore.officeLines(id);

  @override
  OfficeTableState build() {
    scheduleMicrotask(_load);
    return const OfficeTableState();
  }

  Future<void> _load() async {
    final doc = await _s.records.officeOne(id);
    final draft = await _s.drafts.load(_key);
    if (!ref.mounted) return;
    if (draft != null) {
      state = OfficeTableState(
        loaded: true,
        lines: [
          for (final m in ((draft.data['lines'] as List?) ?? const []).whereType<Map>())
            OfficeLine.fromDraft(Map<String, dynamic>.from(m)),
        ],
        baseRev: (draft.data['base_rev'] as num?)?.toInt() ?? doc?.rev ?? 0,
        hasDraft: true,
        savedAt: draft.savedAt,
        restoredAt: draft.savedAt.isBefore(DraftStore.launchedAt) ? draft.savedAt : null,
        addedOnPhone: (draft.data['added_on_phone'] as num?)?.toInt() ?? 0,
      );
    } else {
      state = OfficeTableState(
        loaded: true,
        lines: [for (final l in doc?.items ?? const <ItemLine>[]) OfficeLine.fromItem(l)],
        baseRev: doc?.rev ?? 0,
      );
    }
  }

  void dismissBanner() => state = state.copyWith(clearRestored: true);

  void _edit(List<OfficeLine> lines, {int? addedOnPhone}) {
    state = state.copyWith(
      lines: lines,
      hasDraft: true,
      savedAt: DateTime.now(),
      addedOnPhone: addedOnPhone,
      problems: const LineProblems(),
    );
    _s.drafts.save(_key, {
      'lines': [for (final l in lines) l.toDraft()],
      'base_rev': state.baseRev,
      'added_on_phone': state.addedOnPhone,
    });
  }

  void put(int? index, OfficeLine line) {
    final lines = [...state.lines];
    if (index == null || index >= lines.length) {
      lines.add(line);
    } else {
      lines[index] = line;
    }
    _edit(lines);
  }

  void remove(int index) => _edit([...state.lines]..removeAt(index));

  void _adopt(OfficeDoc doc) {
    state = OfficeTableState(
      loaded: true,
      lines: [for (final l in doc.items) OfficeLine.fromItem(l)],
      baseRev: doc.rev,
    );
  }

  /// One tap: an entry per requested service. Online the server makes them
  /// (and links them to the requests); with no signal the phone makes the same
  /// entries into the draft, and they go with the table when it is saved.
  Future<void> addFromRequests(OfficeDoc doc) async {
    state = state.copyWith(busy: true);
    try {
      final fresh = await _s.v2.officeLinesFromRequests(id);
      await _s.drafts.clear(_key);
      _adopt(fresh);
      ref.read(dataRevisionProvider.notifier).bump();
    } on ApiError catch (e) {
      if (e.code != ApiError.network) {
        state = state.copyWith(busy: false, problems: LineProblems.from(e, state.lines));
        return;
      }
      final linked = {for (final l in state.lines) ?l.requestId};
      final made = [
        for (final r in doc.services)
          if (r.moveId == null && !linked.contains(r.id)) OfficeLine.fromRequest(r),
      ];
      state = state.copyWith(busy: false);
      _edit([...state.lines, ...made], addedOnPhone: state.addedOnPhone + made.length);
    }
  }

  /// Send the table. Returns whether it is now the office's copy.
  Future<bool> save() async {
    state = state.copyWith(busy: true, problems: const LineProblems());
    try {
      final fresh = await _s.v2.saveOfficeLines(id, state.lines);
      await _s.drafts.clear(_key);
      _adopt(fresh);
      ref.read(dataRevisionProvider.notifier).bump();
      return true;
    } on ApiError catch (e) {
      state = state.copyWith(busy: false, problems: LineProblems.from(e, state.lines));
      return false;
    }
  }

  /// Save if there is anything to save, then Mark READY.
  Future<OfficeReadyResult?> markReady(String idemKey) async {
    if (state.hasDraft && !await save()) return null;
    state = state.copyWith(busy: true);
    try {
      final result = await _s.v2.markReady(id, idemKey: idemKey);
      await _s.drafts.clear(_key);
      ref.read(dataRevisionProvider.notifier).bump();
      // It moves to the Job work list: fetch it there once the server serves it.
      ref.read(syncProvider.notifier).followUpOwnChange();
      state = state.copyWith(busy: false);
      return result;
    } on ApiError catch (e) {
      state = state.copyWith(busy: false, problems: LineProblems.from(e, state.lines));
      return null;
    }
  }
}

final officeTableProvider =
    NotifierProvider.autoDispose.family<OfficeTableController, OfficeTableState, int>(OfficeTableController.new);

// ------------------------------------------------------------------ list

class OfficeScreen extends ConsumerWidget {
  const OfficeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = NeuTheme.of(context);
    final docs = ref.watch(officeListProvider).value ?? const <OfficeDoc>[];
    final drafts = ref.watch(officeDraftIdsProvider).value ?? const <int>{};

    return NeuScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ScreenHeader(
            title: 'Office',
            subtitle: '${docs.length} collected jangad${docs.length == 1 ? '' : 's'} to validate',
            trailing: const TabHeaderActions(),
          ),
          const SizedBox(height: 13),
          StatusStrip(onQueueTap: () => context.push('/queue')),
          const SizedBox(height: 13),
          Expanded(
            child: RefreshIndicator(
              color: c.accentInk,
              backgroundColor: c.ground,
              onRefresh: () => ref.read(syncProvider.notifier).syncNow(flushFirst: true),
              child: docs.isEmpty
                  ? const EmptyState(
                      message: 'Nothing waiting to be validated',
                      hint: 'Collected jangads arrive here',
                      icon: Icons.fact_check_outlined,
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.only(bottom: 16),
                      itemCount: docs.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 12),
                      itemBuilder: (_, i) => _OfficeCard(doc: docs[i], draft: drafts.contains(docs[i].id)),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The source chip: who started the receipt.
Widget sourceChip(OfficeDoc doc) => StateChip(
      doc.sourceLabel,
      kind: switch (doc.jangadSource) {
        'on_behalf' => ChipKind.other,
        'customer_app' => ChipKind.synced,
        _ => ChipKind.blocked,
      },
    );

class _OfficeCard extends StatelessWidget {
  const _OfficeCard({required this.doc, required this.draft});
  final OfficeDoc doc;
  final bool draft;

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final requested = ServiceRequest.summary([
      for (final s in doc.services) ServiceRequest(jobTypeId: s.jobType?.id ?? 0, name: s.name, unit: s.unit, quantity: s.quantity),
    ]);
    final linked = doc.services.where((s) => s.moveId != null).length;
    return NeuBox(
      style: NeuStyle.raised,
      radius: 22,
      padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
      onTap: () => context.push(doc.items.isEmpty && !draft ? '/office/${doc.id}' : '/office/${doc.id}/entries'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(doc.name, style: NeuText.data(c.accentInk, size: 12))),
              if (draft)
                const StateChip('Draft on this phone', kind: ChipKind.queued)
              else
                Text('collected ${OdooTime.hm(doc.collectedAt)}', style: NeuText.data(c.inkMuted, size: 11.5)),
            ],
          ),
          const SizedBox(height: 6),
          Text(doc.customerLabel, style: NeuText.strong(c.ink, size: 16)),
          const SizedBox(height: 7),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              sourceChip(doc),
              if (doc.items.isNotEmpty && doc.services.isNotEmpty)
                InsetTag('$linked of ${doc.services.length} entries made')
              else if (doc.services.isNotEmpty)
                InsetTag(requested),
              if (doc.items.isNotEmpty && doc.services.isEmpty)
                InsetTag('${doc.items.length} line${doc.items.length == 1 ? '' : 's'}'),
              InsetTag(doc.jangadPages == 1 ? '1 page' : '${doc.jangadPages} pages'),
            ],
          ),
        ],
      ),
    );
  }
}

// --------------------------------------------------------------- receipt

class OfficeReceiptScreen extends ConsumerStatefulWidget {
  const OfficeReceiptScreen({super.key, required this.id});
  final int id;

  @override
  ConsumerState<OfficeReceiptScreen> createState() => _OfficeReceiptScreenState();
}

class _OfficeReceiptScreenState extends ConsumerState<OfficeReceiptScreen> {
  int _page = 0;

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final doc = ref.watch(officeOneProvider(widget.id)).value;
    final table = ref.watch(officeTableProvider(widget.id));
    if (doc == null) return _gone(context);
    final when = doc.createdAt;
    final who = doc.collectedBy?.name;
    final page = doc.jangadPages > 0 ? ref.watch(jangadPageProvider((doc.id, _page))) : null;
    final hasEntries = table.lines.isNotEmpty;

    return NeuScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StepHeader(step: '${doc.name} · collected ${OdooTime.hm(doc.collectedAt)}', title: doc.customerLabel),
          const SizedBox(height: 12),
          Expanded(
            child: ListView(
              children: [
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    sourceChip(doc),
                    Text(
                      [
                        if (doc.jangadSource == 'on_behalf') 'for the customer at ${OdooTime.hm(when)}'
                        else if (when != null) 'sent at ${OdooTime.hm(when)}',
                        if (who != null) 'collected by $who',
                      ].join(' · '),
                      style: NeuText.body_(c.inkMuted, size: 12.5),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (doc.jangadPages == 0)
                  NeuNote(text: 'This receipt has no jangad photo.', icon: Icons.image_not_supported_outlined)
                else
                  NeuBox(
                    style: NeuStyle.raised,
                    radius: 18,
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      children: [
                        SizedBox(
                          height: 220,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: InteractiveViewer(
                              maxScale: 5,
                              child: Center(
                                child: switch (page) {
                                  AsyncData(:final value) => JangadImage(bytes: value, height: 220),
                                  AsyncError() => const JangadImage(bytes: null, height: 220),
                                  _ => CircularProgressIndicator(color: c.accentInk),
                                },
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            NeuIconButton(
                              icon: Icons.chevron_left_rounded,
                              size: 36,
                              tooltip: 'Previous page',
                              onPressed: _page > 0 ? () => setState(() => _page--) : null,
                            ),
                            const SizedBox(width: 12),
                            Text('Page ${_page + 1} of ${doc.jangadPages} · pinch to zoom',
                                style: NeuText.data(c.inkMuted, size: 11)),
                            const SizedBox(width: 12),
                            NeuIconButton(
                              icon: Icons.chevron_right_rounded,
                              size: 36,
                              tooltip: 'Next page',
                              onPressed: _page < doc.jangadPages - 1 ? () => setState(() => _page++) : null,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 14),
                const SectionLabel('Requested services'),
                const SizedBox(height: 9),
                if (doc.services.isEmpty)
                  Text('The customer did not pick services. Enter the lines from the jangad.',
                      style: NeuText.body_(c.inkMuted, size: 13))
                else
                  RequestedServicesTable(services: doc.services),
                if (!table.problems.isEmpty) ...[
                  const SizedBox(height: 12),
                  NeuNote(
                    text: table.problems.messages.join('\n'),
                    icon: Icons.warning_amber_rounded,
                    kind: ChipKind.attention,
                  ),
                ],
                const SizedBox(height: 16),
              ],
            ),
          ),
          if (hasEntries)
            NeuButton(
              label: 'Open the item table',
              kind: NeuButtonKind.primary,
              icon: Icons.table_rows_outlined,
              height: 54,
              onPressed: () => context.push('/office/${doc.id}/entries'),
            )
          else if (doc.services.isNotEmpty)
            NeuButton(
              key: const Key('add-from-requests'),
              label: 'Add entries from this table',
              kind: NeuButtonKind.primary,
              icon: Icons.playlist_add_rounded,
              height: 54,
              busy: table.busy,
              onPressed: () async {
                await ref.read(officeTableProvider(doc.id).notifier).addFromRequests(doc);
                if (context.mounted && ref.read(officeTableProvider(doc.id)).problems.isEmpty) {
                  context.push('/office/${doc.id}/entries');
                }
              },
            ),
          const SizedBox(height: 12),
          NeuButton(
            label: hasEntries ? 'Add another line' : 'Enter lines by hand',
            height: 50,
            onPressed: () => context.push('/office/${doc.id}/entries?add=1'),
          ),
          const SizedBox(height: 18),
        ],
      ),
    );
  }
}

Widget _gone(BuildContext context) {
  final c = NeuTheme.of(context);
  return NeuScaffold(
    child: Column(
      children: [
        ScreenHeader(title: 'Receipt', onBack: () => context.go('/office')),
        const Spacer(),
        Text('This receipt has left the office list.', style: NeuText.body_(c.inkMuted, size: 14)),
        const SizedBox(height: 6),
        Text('It was marked READY, or the office took it back.',
            style: NeuText.body_(c.inkFaint, size: 12.5)),
        const Spacer(),
      ],
    ),
  );
}

// --------------------------------------------------------------- entries

class OfficeEntriesScreen extends ConsumerStatefulWidget {
  const OfficeEntriesScreen({super.key, required this.id, this.addOnOpen = false});
  final int id;

  /// Opened from "Enter lines by hand": the new-line sheet comes up at once.
  final bool addOnOpen;

  @override
  ConsumerState<OfficeEntriesScreen> createState() => _OfficeEntriesScreenState();
}

class _OfficeEntriesScreenState extends ConsumerState<OfficeEntriesScreen> {
  bool _added = false;

  int get id => widget.id;

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final doc = ref.watch(officeOneProvider(id)).value;
    final table = ref.watch(officeTableProvider(id));
    final ctl = ref.read(officeTableProvider(id).notifier);
    final online = ref.watch(syncProvider.select((s) => s.online));
    if (doc == null) return _gone(context);

    if (widget.addOnOpen && !_added && table.loaded) {
      _added = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) showOfficeLineSheet(context, ref, doc, null);
      });
    }
    final requested = doc.requestedPcs;
    final mismatch = requested > 0 && table.pcs != requested;
    final changedUnder = table.hasDraft && doc.rev > table.baseRev;

    return NeuScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (table.restoredAt != null) ...[
            ResumeBanner(
              closedAt: table.restoredAt!,
              what: 'Your entries',
              onDismiss: ctl.dismissBanner,
            ),
            const SizedBox(height: 12),
          ],
          StepHeader(step: '${doc.name} · ${doc.customerLabel}', title: 'Item entries'),
          const SizedBox(height: 13),
          Expanded(
            child: ListView(
              children: [
                if (table.addedOnPhone > 0 || doc.services.any((s) => s.moveId != null))
                  NeuBox(
                    style: NeuStyle.inset,
                    radius: 16,
                    padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
                    child: Row(
                      children: [
                        Icon(Icons.playlist_add_check_rounded, size: 18, color: c.accentInk),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            table.addedOnPhone > 0
                                ? '${table.addedOnPhone} entr${table.addedOnPhone == 1 ? 'y' : 'ies'} added from the requested '
                                    'services on this phone. Split or adjust them to match the jangad.'
                                : 'Entries were added from the requested services. Split or adjust them '
                                    'to match the jangad.',
                            style: NeuText.body_(c.inkSoft, size: 12.5),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (changedUnder) ...[
                  const SizedBox(height: 10),
                  const NeuNote(
                    text: 'The office copy changed since this draft was started. Saving replaces it '
                        'with the table below.',
                    icon: Icons.info_outline_rounded,
                    kind: ChipKind.other,
                  ),
                ],
                const SizedBox(height: 13),
                if (!table.loaded)
                  Center(child: CircularProgressIndicator(color: c.accentInk))
                else
                  ItemTable(
                    rows: table.rows,
                    editable: true,
                    showToggle: false,
                    problemRows: table.problems.rows,
                    emptyText: 'No lines yet. Add the first one below.',
                    onRowTap: (i) => showOfficeLineSheet(context, ref, doc, i),
                  ),
                if (!table.problems.isEmpty) ...[
                  const SizedBox(height: 12),
                  NeuNote(
                    title: 'The office could not take this table',
                    text: table.problems.messages.join('\n'),
                    icon: Icons.warning_amber_rounded,
                    kind: ChipKind.attention,
                  ),
                ],
                const SizedBox(height: 13),
                Row(
                  children: [
                    Expanded(
                      flex: 10, // 10 : 13 against the check beside it, as designed
                      child: NeuButton(
                        key: const Key('add-line'),
                        label: 'Add line',
                        icon: Icons.add_rounded,
                        height: 48,
                        onPressed: () => showOfficeLineSheet(context, ref, doc, null),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 13,
                      child: requested <= 0
                          ? const SizedBox.shrink()
                          : Container(
                              height: 48,
                              alignment: Alignment.center,
                              padding: const EdgeInsets.symmetric(horizontal: 10),
                              decoration: BoxDecoration(
                                color: mismatch ? c.queuedFill : c.syncedFill,
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Text(
                                mismatch
                                    ? '${Fig.pcs(table.pcs)} pcs vs ${Fig.pcs(requested)} requested'
                                    : 'Matches the ${Fig.pcs(requested)} pcs requested',
                                textAlign: TextAlign.center,
                                style: NeuText.label(mismatch ? c.queuedInk : c.syncedInk, size: 12),
                              ),
                            ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
          Text(
            table.hasDraft
                ? 'Draft saved on this phone · ${OdooTime.hm(table.savedAt)}'
                : 'Same as the office copy',
            textAlign: TextAlign.center,
            style: NeuText.body_(c.inkMuted, size: 12),
          ),
          const SizedBox(height: 10),
          NeuButton(
            label: 'Save and mark READY',
            kind: NeuButtonKind.primary,
            height: 54,
            onPressed: table.lines.isEmpty ? null : () => context.push('/office/$id/ready'),
          ),
          const SizedBox(height: 10),
          NeuButton(
            label: table.hasDraft ? 'Save, not ready yet' : 'Saved',
            height: 48,
            busy: table.busy,
            disabledReason: online ? null : 'Needs a connection — your entries stay saved here',
            onPressed: online && table.hasDraft
                ? () async {
                    final ok = await ctl.save();
                    if (ok && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('${doc.name}: the office has the table')),
                      );
                    }
                  }
                : null,
          ),
          const SizedBox(height: 18),
        ],
      ),
    );
  }
}

// -------------------------------------------------------------- edit row

/// Edit one entry, or add a new one ([index] null).
Future<void> showOfficeLineSheet(BuildContext context, WidgetRef ref, OfficeDoc doc, int? index) {
  return showNeuSheet<void>(
    context,
    builder: (sheetContext) => _OfficeLineSheet(doc: doc, initial: index),
  );
}

class _OfficeLineSheet extends ConsumerStatefulWidget {
  const _OfficeLineSheet({required this.doc, required this.initial});
  final OfficeDoc doc;
  final int? initial;

  @override
  ConsumerState<_OfficeLineSheet> createState() => _OfficeLineSheetState();
}

class _OfficeLineSheetState extends ConsumerState<_OfficeLineSheet> {
  int? _index;
  final _size = TextEditingController();
  final _pcs = TextEditingController();
  final _ct = TextEditingController();
  final _remarks = TextEditingController();
  int? _jobTypeId;
  String? _jobTypeName;

  @override
  void initState() {
    super.initState();
    _open(widget.initial);
  }

  void _open(int? index) {
    final lines = ref.read(officeTableProvider(widget.doc.id)).lines;
    _index = index != null && index < lines.length ? index : null;
    final line = _index == null ? null : lines[_index!];
    _size.text = line?.size ?? '';
    _pcs.text = line == null || line.pcs == 0 ? '' : Fig.pcs(line.pcs);
    _ct.text = line == null || line.carats == 0 ? '' : Fig.ct(line.carats);
    _remarks.text = line?.remarks ?? '';
    _jobTypeId = line?.jobTypeId;
    _jobTypeName = line?.jobTypeName;
  }

  @override
  void dispose() {
    _size.dispose();
    _pcs.dispose();
    _ct.dispose();
    _remarks.dispose();
    super.dispose();
  }

  OfficeLine _line(OfficeLine? base) => OfficeLine(
        moveId: base?.moveId,
        requestId: base?.requestId,
        size: _size.text.trim(),
        pcs: double.tryParse(_pcs.text.trim()) ?? 0,
        carats: double.tryParse(_ct.text.trim()) ?? 0,
        jobTypeId: _jobTypeId,
        jobTypeName: _jobTypeName,
        remarks: _remarks.text.trim().isEmpty ? null : _remarks.text.trim(),
      );

  void _store() {
    final ctl = ref.read(officeTableProvider(widget.doc.id).notifier);
    final lines = ref.read(officeTableProvider(widget.doc.id)).lines;
    ctl.put(_index, _line(_index == null ? null : lines[_index!]));
  }

  Future<void> _other() async {
    final picked = await showNeuSheet<Ref>(
      context,
      builder: (ctx) => Consumer(
        builder: (ctx, ref, _) {
          final c = NeuTheme.of(ctx);
          final all = ref.watch(jobTypesProvider).value;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Pick a service', style: NeuText.title(c.ink, size: 19)),
              const SizedBox(height: 12),
              if (all == null)
                Text('The list of services needs a connection the first time.',
                    style: NeuText.body_(c.inkMuted, size: 13))
              else
                for (final j in all) ...[
                  NeuBox(
                    style: NeuStyle.raisedSm,
                    radius: 14,
                    onTap: () => Navigator.of(ctx).pop(Ref(id: j.id, name: j.name)),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    child: Text(j.name, style: NeuText.strong(c.ink, size: 14.5)),
                  ),
                  const SizedBox(height: 8),
                ],
            ],
          );
        },
      ),
    );
    if (picked != null) {
      setState(() {
        _jobTypeId = picked.id;
        _jobTypeName = picked.name;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final table = ref.watch(officeTableProvider(widget.doc.id));
    final seen = <int>{};
    final options = <Ref>[
      for (final s in widget.doc.services)
        if (s.jobType != null && seen.add(s.jobType!.id)) s.jobType!,
      if (_jobTypeId != null && !seen.contains(_jobTypeId)) Ref(id: _jobTypeId!, name: _jobTypeName ?? 'Service'),
    ];
    final sr = (_index ?? table.lines.length) + 1;
    final hasNext = _index != null && _index! < table.lines.length - 1;

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
              child: Center(child: Text('$sr', style: NeuText.data(c.accentInk, size: 17))),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('LINE $sr', style: NeuText.label(c.inkMuted, size: 12).copyWith(letterSpacing: 0.6)),
                  Text(_index == null ? 'New entry' : 'Edit entry', style: NeuText.title(c.ink, size: 19)),
                ],
              ),
            ),
            if (_index != null)
              NeuIconButton(
                icon: Icons.delete_outline_rounded,
                size: 42,
                color: c.attentionInk,
                tooltip: 'Delete line $sr',
                onPressed: () {
                  ref.read(officeTableProvider(widget.doc.id).notifier).remove(_index!);
                  Navigator.of(context).pop();
                },
              ),
          ],
        ),
        const SizedBox(height: 14),
        Text('Service', style: NeuText.label(c.inkMuted, size: 12)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final o in options)
              PickChip(
                label: o.name,
                selected: o.id == _jobTypeId,
                onTap: () => setState(() {
                  _jobTypeId = o.id;
                  _jobTypeName = o.name;
                }),
              ),
            PickChip(label: 'Other…', selected: false, onTap: _other),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: LabeledInput(label: 'Size', controller: _size, hint: '+6.5', size: 16),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: LabeledInput(
                fieldKey: const Key('line-pcs'),
                label: 'Pcs',
                controller: _pcs,
                mono: true,
                size: 16,
                highlight: (double.tryParse(_pcs.text) ?? 0) <= 0,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: LabeledInput(
                fieldKey: const Key('line-ct'),
                label: 'Carats',
                controller: _ct,
                mono: true,
                size: 16,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        LabeledInput(label: 'Remarks', controller: _remarks, hint: 'Optional'),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: NeuButton(
                label: hasNext ? 'Next line' : 'Add another',
                height: 52,
                onPressed: () {
                  _store();
                  setState(() => _open(hasNext ? _index! + 1 : null));
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: NeuButton(
                key: const Key('line-done'),
                label: 'Done',
                kind: NeuButtonKind.primary,
                height: 52,
                onPressed: () {
                  _store();
                  Navigator.of(context).pop();
                },
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ----------------------------------------------------------------- ready

/// One line of the READY checklist.
class ReadyCheck {
  const ReadyCheck(this.text, {required this.ok, this.blocking = true});
  final String text;
  final bool ok;

  /// A failing blocking check holds the button; the rest are warnings.
  final bool blocking;
}

/// What the server checks before READY, checked here first so the button can
/// say so before anyone taps it.
List<ReadyCheck> readyChecks(OfficeDoc doc, List<OfficeLine> lines) {
  final noService = [for (var i = 0; i < lines.length; i++) if (!lines[i].hasService) i + 1];
  final noPieces = [for (var i = 0; i < lines.length; i++) if (!lines[i].hasPieces) i + 1];
  final pcs = lines.fold<double>(0, (a, l) => a + l.pcs);
  final requested = doc.requestedPcs;
  return [
    ReadyCheck(
      doc.customer == null ? 'No customer on the receipt yet' : 'Customer is set — ${doc.customer!.name}',
      ok: doc.customer != null,
    ),
    ReadyCheck(
      lines.isEmpty
          ? 'No lines yet'
          : noService.isEmpty
              ? '${lines.length} line${lines.length == 1 ? '' : 's'}, each with a service'
              : 'Line ${noService.first} needs a service${noService.length > 1 ? ' (and ${noService.length - 1} more)' : ''}',
      ok: lines.isNotEmpty && noService.isEmpty,
    ),
    ReadyCheck(
      noPieces.isEmpty
          ? 'Every line has pieces'
          : 'Line ${noPieces.first} has no pieces${noPieces.length > 1 ? ' (and ${noPieces.length - 1} more)' : ''}',
      ok: lines.isNotEmpty && noPieces.isEmpty,
    ),
    if (requested > 0)
      ReadyCheck(
        pcs == requested
            ? '${Fig.pcs(pcs)} pcs, as requested'
            : '${Fig.pcs(pcs)} pcs on the lines, ${Fig.pcs(requested)} requested',
        ok: pcs == requested,
        blocking: false,
      ),
  ];
}

class OfficeReadyScreen extends ConsumerStatefulWidget {
  const OfficeReadyScreen({super.key, required this.id});
  final int id;

  @override
  ConsumerState<OfficeReadyScreen> createState() => _OfficeReadyScreenState();
}

class _OfficeReadyScreenState extends ConsumerState<OfficeReadyScreen> {
  /// One key per visit: a retry after a lost answer replays, never repeats.
  late final String _idem = ref.read(sessionProvider.notifier).newIdempotencyKey();

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final doc = ref.watch(officeOneProvider(widget.id)).value;
    final table = ref.watch(officeTableProvider(widget.id));
    final online = ref.watch(syncProvider.select((s) => s.online));
    if (doc == null) return _gone(context);
    final checks = readyChecks(doc, table.lines);
    final blocked = checks.any((k) => k.blocking && !k.ok);
    final departments = {for (final l in table.lines) ?l.jobTypeName}.toList();

    return NeuScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StepHeader(step: '${doc.name} · ${doc.customerLabel}', title: 'Ready for job work?'),
          const SizedBox(height: 15),
          Expanded(
            child: ListView(
              children: [
                NeuBox(
                  style: NeuStyle.raised,
                  radius: 22,
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                  child: Column(
                    children: [
                      for (var i = 0; i < checks.length; i++) ...[
                        if (i > 0) const SizedBox(height: 12),
                        Row(
                          key: Key('ready-check-$i'),
                          children: [
                            Container(
                              width: 22,
                              height: 22,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: checks[i].ok
                                    ? c.syncedFill
                                    : (checks[i].blocking ? c.attentionFill : c.queuedFill),
                              ),
                              child: Center(
                                child: checks[i].ok
                                    ? Icon(Icons.check_rounded, size: 14, color: c.syncedInk)
                                    : Text(checks[i].blocking ? '×' : '!',
                                        style: NeuText.label(
                                            checks[i].blocking ? c.attentionInk : c.queuedInk,
                                            size: 13)),
                              ),
                            ),
                            const SizedBox(width: 11),
                            Expanded(child: Text(checks[i].text, style: NeuText.strong(c.ink, size: 14))),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 15),
                NeuBox(
                  style: NeuStyle.inset,
                  radius: 18,
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      for (final (value, label) in [
                        ('${table.lines.length}', 'lines'),
                        (Fig.pcs(table.pcs), 'pcs'),
                        (Fig.ct(table.carats), 'ct'),
                      ])
                        Expanded(
                          child: Column(
                            children: [
                              Text(value, style: NeuText.data(c.ink, size: 20)),
                              Text(label, style: NeuText.label(c.inkMuted, size: 11.5).copyWith(fontWeight: FontWeight.w700)),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 15),
                Text(
                  '${departments.isEmpty ? 'Job workers' : 'Job workers in ${departments.join(' and ')}'} get a '
                  "notification. Prices are worked out from ${doc.customer?.name ?? "the customer"}'s rate list as usual.",
                  style: NeuText.body_(c.inkMuted, size: 13),
                ),
                if (!table.problems.isEmpty) ...[
                  const SizedBox(height: 14),
                  NeuNote(
                    title: 'Not ready yet',
                    text: table.problems.messages.join('\n'),
                    icon: Icons.warning_amber_rounded,
                    kind: ChipKind.attention,
                  ),
                ],
                const SizedBox(height: 16),
              ],
            ),
          ),
          if (!online) ...[
            NeuBox(
              key: const Key('needs-signal'),
              style: NeuStyle.inset,
              radius: 16,
              padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
              child: Row(
                children: [
                  Container(width: 9, height: 9, decoration: BoxDecoration(color: c.inkFaint, shape: BoxShape.circle)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        style: NeuText.body_(c.inkSoft, size: 12.5),
                        children: [
                          TextSpan(text: 'Needs a signal. ', style: NeuText.label(c.inkSoft, size: 12.5)),
                          const TextSpan(text: 'Without one, your entries stay saved here and this button waits.'),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          NeuButton(
            key: const Key('mark-ready'),
            label: 'Mark READY for job work',
            kind: NeuButtonKind.primary,
            icon: Icons.check_circle_outline_rounded,
            height: 54,
            busy: table.busy,
            disabledReason: blocked ? 'Fix the lines marked × first' : null,
            onPressed: online && !blocked
                ? () async {
                    final result =
                        await ref.read(officeTableProvider(widget.id).notifier).markReady(_idem);
                    if (result == null || !context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('${result.reference.isEmpty ? doc.name : result.reference} is ready for job work')),
                    );
                    context.go('/office');
                  }
                : null,
          ),
          const SizedBox(height: 18),
        ],
      ),
    );
  }
}
