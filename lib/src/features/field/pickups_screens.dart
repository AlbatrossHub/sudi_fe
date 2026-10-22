import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config/env.dart';
import '../../core/clock/odoo_time.dart';
import '../../core/drafts/draft_store.dart';
import '../../core/outbox/outbox.dart';
import '../../core/outbox/outbox_flusher.dart';
import '../../core/projection.dart';
import '../../core/services.dart';
import '../../core/session.dart';
import '../../core/sync_status.dart';
import '../../core/uploads/image_pipeline.dart';
import '../../models/docs.dart';
import '../../ui/theme/neu.dart';
import '../../ui/widgets/neu_box.dart';
import '../../ui/widgets/neu_widgets.dart';
import '../../ui/widgets/signature_pad.dart';
import '../../ui/widgets/status_strip.dart';
import '../../ui/widgets/v2_widgets.dart';
import 'sign_in_screens.dart';

/// `cached record + pending intents for that record`, read as one view. A
/// screen never mutates the cache directly.
final pendingByRecordProvider = FutureProvider.autoDispose<Map<int, List<OutboxItem>>>((ref) {
  ref.watch(dataRevisionProvider);
  return ref.read(servicesProvider).outbox.pendingByRecord();
});

/// Every open intent, for the cards that exist only on this phone.
final openOutboxProvider = FutureProvider.autoDispose<List<OutboxItem>>((ref) {
  ref.watch(dataRevisionProvider);
  return ref.read(servicesProvider).outbox.open();
});

final pickupsProvider = FutureProvider.autoDispose<List<PickupDoc>>((ref) {
  ref.watch(dataRevisionProvider);
  return ref.read(servicesProvider).records.pickups();
});

final pickupProvider = FutureProvider.autoDispose.family<PickupDoc?, int>((ref, id) {
  ref.watch(dataRevisionProvider);
  return ref.read(servicesProvider).records.pickup(id);
});

/// The pickup list with this phone's queue played on top.
final pickupViewsProvider = Provider.autoDispose<List<PickupView>>((ref) {
  final docs = ref.watch(pickupsProvider).value ?? const <PickupDoc>[];
  final pending = ref.watch(pendingByRecordProvider).value ?? const <int, List<OutboxItem>>{};
  final open = ref.watch(openOutboxProvider).value ?? const <OutboxItem>[];
  return PickupView.build(docs, pending, open);
});

/// A jangad page: the saved copy first, then the server's.
final jangadPageProvider =
    StreamProvider.autoDispose.family<Uint8List?, (int, int)>((ref, key) async* {
  final v2 = ref.read(servicesProvider).v2;
  final saved = await v2.savedPage(key.$1, key.$2);
  if (saved != null) yield saved;
  try {
    yield await v2.jangadPage(key.$1, key.$2);
  } catch (_) {
    if (saved == null) yield null;
  }
});

class PickupsScreen extends ConsumerStatefulWidget {
  const PickupsScreen({super.key});

  @override
  ConsumerState<PickupsScreen> createState() => _PickupsScreenState();
}

class _PickupsScreenState extends ConsumerState<PickupsScreen> {
  late int _tab = ref.read(servicesProvider).resume.segment('pickups');

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final views = ref.watch(pickupViewsProvider);
    final session = ref.watch(sessionProvider);

    final toCollect = views.where((v) => !v.collected).toList();
    final collected = views.where((v) => v.collected).toList();
    final shown = _tab == 0 ? toCollect : collected;

    return NeuScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ScreenHeader(
            title: 'Pickups',
            subtitle: '${toCollect.length} to collect · ${collected.length} collected today',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const NoticeBell(),
                const SizedBox(width: 10),
                NeuIconButton(
                  icon: Icons.person_outline_rounded,
                  onPressed: () => showAccountSheet(context, ref),
                  tooltip: 'Account',
                ),
              ],
            ),
          ),
          const SizedBox(height: 13),
          StatusStrip(onQueueTap: () => context.push('/queue')),
          const SizedBox(height: 13),
          NeuSegmented(
            labels: ['To collect · ${toCollect.length}', 'Collected today · ${collected.length}'],
            index: _tab,
            onChanged: (i) {
              setState(() => _tab = i);
              ref.read(servicesProvider).resume.setSegment('pickups', i);
            },
          ),
          const SizedBox(height: 13),
          Expanded(
            child: RefreshIndicator(
              color: c.accentInk,
              backgroundColor: c.ground,
              onRefresh: () => ref.read(syncProvider.notifier).syncNow(flushFirst: true),
              child: shown.isEmpty
                  ? EmptyState(
                      message: _tab == 0 ? 'Nothing to collect' : 'Nothing collected yet today',
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.only(bottom: 16),
                      itemCount: shown.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 12),
                      itemBuilder: (_, i) => PickupCard(view: shown[i]),
                    ),
            ),
          ),
          if (session.canPostOnBehalf) ...[
            const SizedBox(height: 8),
            NeuButton(
              key: const Key('post-on-behalf'),
              label: 'Jangad for a customer',
              kind: NeuButtonKind.primary,
              icon: Icons.post_add_rounded,
              height: 54,
              onPressed: () => context.push('/onbehalf'),
            ),
            const SizedBox(height: 4),
          ],
        ],
      ),
    );
  }
}

class PickupCard extends ConsumerWidget {
  const PickupCard({super.key, required this.view});

  final PickupView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = NeuTheme.of(context);
    final doc = view.doc;
    final refused = view.refused;
    final waiting = view.pending.any((p) => p.isWaiting) ||
        (view.posted?.isWaiting ?? false);
    final online = ref.watch(syncProvider.select((s) => s.online));

    final (String chip, ChipKind kind) = refused.isNotEmpty
        ? (
            refused.first.lastErrorCode == 'ALREADY_CONFIRMED' ? 'Someone else' : 'Needs you',
            refused.first.lastErrorCode == 'ALREADY_CONFIRMED' ? ChipKind.other : ChipKind.attention,
          )
        : view.onThisPhone
            ? ('On this phone', ChipKind.queued)
            : view.queuedConfirm != null
                ? ('Collect queued', ChipKind.queued)
                : view.queuedCancel != null
                    ? ('Cancel queued', ChipKind.queued)
                    : doc!.isCollected
                        ? ('Synced', ChipKind.synced)
                        : doc.jangadPages == 0
                            ? ('No jangad yet', ChipKind.blocked)
                            : (doc.jangadPages == 1 ? '1 page' : '${doc.jangadPages} pages', ChipKind.blocked);

    final String line;
    if (view.onThisPhone) {
      line = view.queuedConfirm != null
          ? 'Posted and collected by you · ${OdooTime.hm(view.postedAt)}'
          : 'Posted by you for the customer · ${OdooTime.hm(view.postedAt)}';
    } else if (doc!.isCollected) {
      line = 'Collected ${OdooTime.hm(doc.collectedAt)} · ${_pages(doc.jangadPages)}';
    } else if (view.queuedConfirm != null) {
      line = 'Collected ${OdooTime.hm(view.collectedAt)} on this phone · '
          'synced when it lands';
    } else {
      final address = doc.pickupAddress == null || doc.pickupAddress!.trim().isEmpty
          ? 'No address on the receipt'
          : oneLineAddress(doc.pickupAddress!);
      final services = doc.services.isEmpty
          ? ''
          : ' · ${doc.services.length} service${doc.services.length == 1 ? '' : 's'}';
      line = '$address · ${_pages(doc.jangadPages)}$services';
    }

    final tags = [
      if (view.onThisPhone) ...view.serviceChips,
      if (view.onThisPhone) _pages(view.pages),
    ];

    return NeuBox(
      style: NeuStyle.raised,
      radius: 22,
      padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
      onTap: () => view.onThisPhone
          ? context.push('/onbehalf/posted/${view.posted!.localId}')
          : context.push('/pickup/${doc!.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  doc?.name ?? 'No number yet',
                  overflow: TextOverflow.ellipsis,
                  style: NeuText.data(doc == null ? c.inkFaint : c.accentInk, size: 12),
                ),
              ),
              const SizedBox(width: 8),
              StateChip(chip, kind: kind),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            view.customerName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: NeuText.strong(doc != null && doc.customer == null ? c.blockedInk : c.ink, size: 16),
          ),
          const SizedBox(height: 4),
          Text(line, maxLines: 2, overflow: TextOverflow.ellipsis, style: NeuText.body_(c.inkMuted, size: 13)),
          if (tags.isNotEmpty) ...[
            const SizedBox(height: 9),
            Wrap(spacing: 6, runSpacing: 6, children: [for (final t in tags) InsetTag(t)]),
          ],
          if (waiting && !online) ...[
            const SizedBox(height: 11),
            NeuBox(
              style: NeuStyle.insetSm,
              radius: 13,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(
                children: [
                  Icon(Icons.schedule_rounded, size: 14, color: c.queuedInk),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('Sends by itself when online',
                        style: NeuText.label(c.queuedInk, size: 12)),
                  ),
                ],
              ),
            ),
          ],
          if (refused.isNotEmpty) ...[
            const SizedBox(height: 11),
            NeuBox(
              style: NeuStyle.insetSm,
              radius: 13,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Text(
                refused.first.lastErrorMessage ?? 'This did not go through.',
                style: NeuText.body_(c.attentionInk, size: 12, w: FontWeight.w600),
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _pages(int n) => n == 1 ? '1 page' : '$n pages';
}

class PickupDetailScreen extends ConsumerStatefulWidget {
  const PickupDetailScreen({super.key, required this.id});
  final int id;

  @override
  ConsumerState<PickupDetailScreen> createState() => _PickupDetailScreenState();
}

class _PickupDetailScreenState extends ConsumerState<PickupDetailScreen> {
  int _page = 0;

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final doc = ref.watch(pickupProvider(widget.id)).value;
    final pending = (ref.watch(pendingByRecordProvider).value ?? const {})[widget.id] ?? const [];

    if (doc == null) {
      return NeuScaffold(
        child: Column(
          children: [
            ScreenHeader(title: 'Receipt', onBack: () => context.pop()),
            const Spacer(),
            Text('This receipt is no longer on this phone.',
                style: NeuText.body_(c.inkMuted, size: 14)),
            const Spacer(),
          ],
        ),
      );
    }

    final view = PickupView.server(doc, pending);
    final page = doc.jangadPages > 0 ? ref.watch(jangadPageProvider((doc.id, _page))) : null;

    return NeuScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ScreenHeader(
            title: doc.name,
            mono: true,
            subtitle: view.collected
                ? 'Collected ${OdooTime.hm(view.collectedAt)}'
                : 'To collect · ${OdooTime.hm(doc.scheduledDate)}',
            onBack: () => context.pop(),
          ),
          const SizedBox(height: 13),
          Expanded(
            child: ListView(
              children: [
                if (doc.jangadPages == 0)
                  NeuBox(
                    style: NeuStyle.inset,
                    radius: 22,
                    padding: const EdgeInsets.symmetric(vertical: 34, horizontal: 20),
                    child: Column(
                      children: [
                        Icon(Icons.image_not_supported_outlined, size: 34, color: c.inkFaint),
                        const SizedBox(height: 12),
                        Text('No jangad on this receipt yet',
                            style: NeuText.body_(c.inkMuted, size: 13)),
                        const SizedBox(height: 4),
                        Text('You photograph it when you collect',
                            textAlign: TextAlign.center,
                            style: NeuText.body_(c.inkFaint, size: 12)),
                      ],
                    ),
                  )
                else
                  NeuBox(
                    style: NeuStyle.inset,
                    radius: 22,
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      children: [
                        SizedBox(
                          height: 260,
                          child: Center(
                            child: switch (page) {
                              AsyncData(:final value) => JangadImage(bytes: value, height: 250),
                              AsyncError() => const JangadImage(bytes: null, height: 250),
                              _ => CircularProgressIndicator(color: c.accentInk),
                            },
                          ),
                        ),
                        const SizedBox(height: 11),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            for (var i = 0; i < doc.jangadPages; i++)
                              GestureDetector(
                                onTap: () => setState(() => _page = i),
                                child: Container(
                                  margin: const EdgeInsets.symmetric(horizontal: 6),
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: i == _page ? c.accent : c.hairline,
                                  ),
                                ),
                              ),
                            const SizedBox(width: 6),
                            Text('Page ${_page + 1} of ${doc.jangadPages}',
                                style: NeuText.label(c.inkMuted, size: 12)),
                          ],
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 13),
                NeuBox(
                  style: NeuStyle.raised,
                  radius: 20,
                  padding: const EdgeInsets.all(17),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _row(context, Icons.person_outline_rounded, doc.customerLabel, doc.contactPhone ?? ''),
                      Divider(color: c.hairline, height: 26),
                      _row(
                        context,
                        Icons.place_outlined,
                        doc.pickupAddress == null || doc.pickupAddress!.trim().isEmpty
                            ? 'No address on the receipt'
                            : oneLineAddress(doc.pickupAddress!),
                        '',
                      ),
                    ],
                  ),
                ),
                if (doc.services.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const SectionLabel('Services asked for'),
                  const SizedBox(height: 9),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final s in doc.services) InsetTag('${s.name} · ${s.quantityLabel}'),
                    ],
                  ),
                ],
                const SizedBox(height: 13),
              ],
            ),
          ),
          if (view.queuedConfirm != null || view.queuedCancel != null)
            NeuNote(
              title: view.queuedConfirm != null ? 'Collected on this phone' : 'Cancel on this phone',
              text: 'It reaches the office by itself, with the time you tapped it.',
              icon: Icons.schedule_rounded,
              kind: ChipKind.queued,
            )
          else if (!doc.isCollected) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.check_rounded, size: 14, color: c.syncedInk),
                const SizedBox(width: 7),
                Text('Both actions work offline', style: NeuText.label(c.syncedInk, size: 12)),
              ],
            ),
            const SizedBox(height: 11),
            NeuButton(
              label: 'Confirm pickup',
              kind: NeuButtonKind.primary,
              icon: Icons.photo_camera_outlined,
              onPressed: () => context.push('/pickup/${doc.id}/confirm'),
            ),
            const SizedBox(height: 11),
            NeuButton(
              label: 'Cannot collect',
              kind: NeuButtonKind.destructive,
              onPressed: () => context.push('/pickup/${doc.id}/cancel'),
            ),
          ],
          const SizedBox(height: 18),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, IconData icon, String title, String sub) {
    final c = NeuTheme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NeuBox(
          style: NeuStyle.insetSm,
          radius: 13,
          width: 38,
          height: 38,
          child: Center(child: Icon(icon, size: 18, color: c.accentInk)),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: NeuText.strong(c.ink, size: 15)),
              if (sub.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: NeuText.data(c.inkMuted)),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Capture, then confirm. The pages go up before the intent that quotes them.
///
/// Also "Collect it now" straight after posting a jangad for a customer
/// ([postedLocalId]): the receipt may not exist yet, so the confirm is chained
/// behind the jangad and the pages already taken go with it (more are
/// optional).
///
/// Everything typed and photographed is a draft on the phone's disk until the
/// confirm is queued: a killed app comes back to it, with the banner saying so.
class ConfirmPickupScreen extends ConsumerStatefulWidget {
  const ConfirmPickupScreen({super.key, this.id, this.postedLocalId})
      : assert(id != null || postedLocalId != null);

  final int? id;
  final String? postedLocalId;

  @override
  ConsumerState<ConfirmPickupScreen> createState() => _ConfirmPickupScreenState();
}

class _ConfirmPickupScreenState extends ConsumerState<ConfirmPickupScreen> {
  final _note = TextEditingController();
  final _pages = <UploadItem>[];
  Map<String, dynamic> _location = const {};
  DateTime? _locatedAt;
  bool _busy = false;
  String? _warning;
  DateTime? _restoredAt;
  OutboxItem? _posted;
  int? _postedPickingId;
  Map<String, dynamic> _postedMeta = const {};

  // Read once: `ref` is off limits in dispose, where the draft is saved.
  late final Services _s = ref.read(servicesProvider);

  String get _draftKey => widget.id != null
      ? DraftStore.confirmPickup(widget.id!)
      : DraftStore.confirmPosted(widget.postedLocalId!);

  bool get _pagesOptional => widget.postedLocalId != null;

  @override
  void initState() {
    super.initState();
    unawaited(_restore());
  }

  Future<void> _restore() async {
    if (widget.postedLocalId != null) {
      _posted = await _s.outbox.byId(widget.postedLocalId!);
      final landed = await _s.kv.readJson(OutboxFlusher.postedKey(widget.postedLocalId!));
      _postedPickingId = (landed?['picking_id'] as num?)?.toInt();
      final meta = _posted?.meta ?? landed?['meta'];
      if (meta is Map) _postedMeta = Map<String, dynamic>.from(meta);
    }
    final draft = await _s.drafts.load(_draftKey);
    if (draft != null) {
      final ids = [for (final p in (draft.data['pages'] as List? ?? const [])) '$p'];
      final pages = await _s.uploads.byIds(ids);
      _pages
        ..clear()
        ..addAll(pages);
      _note.text = '${draft.data['note'] ?? ''}';
      final loc = draft.data['location'];
      if (loc is Map) _location = Map<String, dynamic>.from(loc);
      _locatedAt = DateTime.tryParse('${draft.data['located_at'] ?? ''}');
      if (draft.savedAt.isBefore(DraftStore.launchedAt) && (pages.isNotEmpty || _note.text.isNotEmpty)) {
        _restoredAt = draft.savedAt;
      }
    }
    if (mounted) setState(() {});
  }

  void _persist() => _s.drafts.save(_draftKey, {
        'pages': [for (final p in _pages) p.localId],
        'note': _note.text,
        'location': _location,
        'located_at': _locatedAt?.toIso8601String(),
      });

  @override
  void dispose() {
    unawaited(_s.drafts.saveNow(_draftKey));
    _note.dispose();
    super.dispose();
  }

  Future<void> _addPage() async {
    if (!await ImagePipeline.hasRoom()) {
      setState(() => _warning =
          'This phone is nearly out of room for photos. Send what is queued before taking more.');
      return;
    }
    final file = await _s.images.capture();
    if (file == null) return;
    final staged = await _s.uploads.stage(file, pageIndex: _pages.length);
    if (!mounted) return;
    setState(() {
      _pages.add(staged);
      _warning = null;
    });
    await _s.drafts.saveNow(_draftKey, {
      'pages': [for (final p in _pages) p.localId],
      'note': _note.text,
      'location': _location,
    });
    // Asked for in context — at the first page, not at launch.
    if (_location.isEmpty) {
      final fix = await _s.location.capture();
      if (mounted && fix.isNotEmpty) {
        setState(() {
          _location = fix;
          _locatedAt = _s.clock.now();
        });
        _persist();
      }
    }
  }

  Future<void> _removePage(UploadItem page) async {
    setState(() => _pages.remove(page));
    await _s.uploads.discard(page.localId);
    await _s.uploads.renumber([for (final p in _pages) p.localId]);
    _persist();
  }

  Future<void> _confirm(String label) async {
    setState(() => _busy = true);
    final note = _note.text.trim().isEmpty ? null : _note.text.trim();
    final pages = [for (final p in _pages) p.localId];
    if (widget.id != null || _postedPickingId != null) {
      await _s.field.confirmPickup(
        id: widget.id ?? _postedPickingId!,
        label: label,
        uploadLocalIds: pages,
        note: note,
        location: _location,
      );
    } else if (_posted != null) {
      await _s.field.confirmAfterPosting(
        jangad: _posted!,
        label: label,
        uploadLocalIds: pages,
        note: note,
        location: _location,
      );
    }
    await _s.drafts.clear(_draftKey);
    await ref.read(syncProvider.notifier).refreshCounters();
    unawaited(ref.read(syncProvider.notifier).syncNow(flushFirst: true));
    if (!mounted) return;
    context.go('/pickups');
  }

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final docId = widget.id ?? _postedPickingId;
    final doc = docId == null ? null : ref.watch(pickupProvider(docId)).value;
    final online = ref.watch(syncProvider.select((s) => s.online));
    if (widget.id != null && doc == null) return const SizedBox.shrink();

    final reference = doc?.name ?? 'Posted on this phone';
    final customer = doc?.customerLabel ?? '${_postedMeta['customer_name'] ?? 'Customer'}';
    final address = doc?.pickupAddress ?? '${_postedMeta['address'] ?? ''}';
    final now = ref.read(servicesProvider).clock.now();
    final ready = _pages.isNotEmpty || _pagesOptional;

    return NeuScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_restoredAt != null) ...[
            ResumeBanner(
              closedAt: _restoredAt!,
              what: 'Your photos, note and location',
              onDismiss: () => setState(() => _restoredAt = null),
            ),
            const SizedBox(height: 13),
          ],
          StepHeader(step: reference, title: 'Confirm pickup'),
          const SizedBox(height: 14),
          Expanded(
            child: ListView(
              children: [
                NeuBox(
                  style: NeuStyle.raised,
                  radius: 22,
                  padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(customer, style: NeuText.strong(c.ink, size: 16)),
                      if (address.trim().isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(oneLineAddress(address),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: NeuText.body_(c.inkMuted, size: 13)),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Text(_pagesOptional ? 'More jangad pages (optional)' : 'Jangad pages',
                    style: NeuText.label(c.ink, size: 13)),
                const SizedBox(height: 3),
                Text(
                  _pagesOptional
                      ? 'The pages you just took already go with the jangad'
                      : 'in the order you photograph them',
                  style: NeuText.body_(c.inkMuted, size: 12),
                ),
                const SizedBox(height: 11),
                SizedBox(
                  height: 138,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _pages.length + 1,
                    separatorBuilder: (_, _) => const SizedBox(width: 12),
                    itemBuilder: (_, i) {
                      if (i == _pages.length) {
                        return NeuBox(
                          style: NeuStyle.inset,
                          radius: 14,
                          width: 96,
                          height: 120,
                          onTap: _addPage,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.photo_camera_outlined, size: 24, color: c.accentInk),
                              const SizedBox(height: 6),
                              Text(_pages.isEmpty ? 'Add page' : 'Page ${_pages.length + 1}',
                                  style: NeuText.label(c.accentInk, size: 12)),
                            ],
                          ),
                        );
                      }
                      final page = _pages[i];
                      return Column(
                        children: [
                          Stack(
                            children: [
                              NeuBox(
                                style: NeuStyle.raisedSm,
                                radius: 14,
                                width: 96,
                                height: 120,
                                padding: const EdgeInsets.all(6),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child: Image.file(File(page.filePath),
                                      fit: BoxFit.cover, width: 84, height: 108),
                                ),
                              ),
                              Positioned(
                                right: 4,
                                top: 4,
                                child: GestureDetector(
                                  onTap: () => _removePage(page),
                                  child: NeuBox(
                                    style: NeuStyle.raisedSm,
                                    radius: 12,
                                    width: 24,
                                    height: 24,
                                    child: Icon(Icons.close_rounded, size: 14, color: c.inkMuted),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 5),
                          Text('${i + 1} · ${(page.bytes / 1024).round()} KB',
                              style: NeuText.data(c.inkMuted, size: 10.5)),
                        ],
                      );
                    },
                  ),
                ),
                Text(
                  '${Env.imageLongEdge} px long edge · kept until the office has it',
                  style: NeuText.data(c.inkFaint, size: 11),
                ),
                if (_warning != null) ...[
                  const SizedBox(height: 14),
                  NeuNote(text: _warning!, kind: ChipKind.attention, icon: Icons.warning_amber_rounded),
                ],
                const SizedBox(height: 16),
                LabeledInput(
                  label: 'Note',
                  controller: _note,
                  hint: 'Anything the office should know',
                  maxLines: 2,
                  onChanged: (_) => _persist(),
                ),
                const SizedBox(height: 14),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    children: [
                      Icon(Icons.place_outlined,
                          size: 17, color: _location.isEmpty ? c.inkFaint : c.syncedInk),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          _location.isEmpty
                              ? 'No location — never required'
                              : 'Location captured · ±${(_location['accuracy_m'] as num? ?? 0).round()} m',
                          style: NeuText.label(_location.isEmpty ? c.inkMuted : c.syncedInk, size: 13)
                              .copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      if (_locatedAt != null)
                        Text(OdooTime.hm(_locatedAt), style: NeuText.data(c.inkFaint, size: 12)),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
          NeuBox(
            style: NeuStyle.inset,
            radius: 16,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Text(
              online
                  ? 'Recorded at ${OdooTime.hm(now)}, not when it sends.'
                  : 'Once it lands, the office sees “collected ${OdooTime.hm(now)}, '
                      'recorded offline, synced …” with the time it arrives.',
              style: NeuText.body_(c.inkMuted, size: 12.5),
            ),
          ),
          const SizedBox(height: 12),
          NeuButton(
            key: const Key('confirm-collected'),
            label: ready ? 'Confirm collected' : 'Photograph the jangad first',
            kind: NeuButtonKind.primary,
            icon: Icons.check_rounded,
            busy: _busy,
            onPressed: ready ? () => _confirm(doc?.name ?? customer) : null,
          ),
          const SizedBox(height: 18),
        ],
      ),
    );
  }
}

class CancelPickupScreen extends ConsumerStatefulWidget {
  const CancelPickupScreen({super.key, required this.id});
  final int id;

  @override
  ConsumerState<CancelPickupScreen> createState() => _CancelPickupScreenState();
}

class _CancelPickupScreenState extends ConsumerState<CancelPickupScreen> {
  static const _reasons = [
    'Customer not available',
    'Parcel not ready',
    'Address wrong or unreachable',
    'Something else',
  ];

  int _selected = 0;
  final _detail = TextEditingController();
  bool _busy = false;
  DateTime? _restoredAt;

  // Read once: `ref` is off limits in dispose, where the draft is saved.
  late final Services _s = ref.read(servicesProvider);
  String get _key => DraftStore.cancelPickup(widget.id);

  @override
  void initState() {
    super.initState();
    unawaited(() async {
      final draft = await _s.drafts.load(_key);
      if (draft == null || !mounted) return;
      setState(() {
        _selected = ((draft.data['reason'] as num?)?.toInt() ?? 0).clamp(0, _reasons.length - 1);
        _detail.text = '${draft.data['detail'] ?? ''}';
        if (draft.savedAt.isBefore(DraftStore.launchedAt)) _restoredAt = draft.savedAt;
      });
    }());
  }

  void _persist() => _s.drafts.save(_key, {'reason': _selected, 'detail': _detail.text});

  @override
  void dispose() {
    unawaited(_s.drafts.saveNow(_key));
    _detail.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final doc = ref.watch(pickupProvider(widget.id)).value;
    if (doc == null) return const SizedBox.shrink();

    return NeuScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_restoredAt != null) ...[
            ResumeBanner(
              closedAt: _restoredAt!,
              what: 'Your reason and detail',
              onDismiss: () => setState(() => _restoredAt = null),
            ),
            const SizedBox(height: 13),
          ],
          ScreenHeader(
            title: 'Cannot collect',
            subtitle: '${doc.name} · ${doc.customerLabel}',
            onBack: () => context.pop(),
          ),
          const SizedBox(height: 22),
          Row(
            children: [
              Text('Reason', style: NeuText.label(c.ink, size: 13)),
              const SizedBox(width: 7),
              Text('required', style: NeuText.label(c.attentionInk, size: 11)),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ListView(
              children: [
                for (var i = 0; i < _reasons.length; i++) ...[
                  ChoiceRow(
                    title: _reasons[i],
                    selected: i == _selected,
                    onTap: () {
                      setState(() => _selected = i);
                      _persist();
                    },
                  ),
                  const SizedBox(height: 11),
                ],
                const SizedBox(height: 10),
                NeuField(
                  controller: _detail,
                  label: 'Detail',
                  hint: 'Shop shut, neighbour says back at 4',
                  maxLines: 3,
                  onChanged: (_) => _persist(),
                ),
                const SizedBox(height: 18),
                const NeuNote(
                  text: 'Cancelling closes the receipt. The office is told, and the customer has to book again.',
                  icon: Icons.warning_amber_rounded,
                  kind: ChipKind.attention,
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
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
            label: 'Cancel this pickup',
            kind: NeuButtonKind.destructive,
            busy: _busy,
            onPressed: () async {
              setState(() => _busy = true);
              final detail = _detail.text.trim();
              await _s.field.cancelPickup(
                id: doc.id,
                label: doc.name,
                reason: detail.isEmpty ? _reasons[_selected] : '${_reasons[_selected]} — $detail',
              );
              await _s.drafts.clear(_key);
              await ref.read(syncProvider.notifier).refreshCounters();
              unawaited(ref.read(syncProvider.notifier).syncNow(flushFirst: true));
              if (context.mounted) context.go('/pickups');
            },
          ),
          const SizedBox(height: 11),
          NeuButton(label: 'Go back', onPressed: () => context.pop(), height: 52),
          const SizedBox(height: 18),
        ],
      ),
    );
  }
}
