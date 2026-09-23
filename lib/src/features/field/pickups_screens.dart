import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config/env.dart';
import '../../core/clock/odoo_time.dart';
import '../../core/outbox/outbox.dart';
import '../../core/services.dart';
import '../../core/sync_status.dart';
import '../../core/uploads/image_pipeline.dart';
import '../../models/docs.dart';
import '../../ui/theme/neu.dart';
import '../../ui/widgets/neu_box.dart';
import '../../ui/widgets/neu_widgets.dart';
import '../../ui/widgets/signature_pad.dart';
import '../../ui/widgets/status_strip.dart';
import 'sign_in_screens.dart';

/// `cached record + pending intents for that record`, read as one view. A
/// screen never mutates the cache directly.
final pendingByRecordProvider = FutureProvider.autoDispose<Map<int, List<OutboxItem>>>((ref) {
  ref.watch(dataRevisionProvider);
  return ref.read(servicesProvider).outbox.pendingByRecord();
});

final pickupsProvider = FutureProvider.autoDispose<List<PickupDoc>>((ref) {
  ref.watch(dataRevisionProvider);
  return ref.read(servicesProvider).records.pickups();
});

final pickupProvider =
    FutureProvider.autoDispose.family<PickupDoc?, int>((ref, id) {
  ref.watch(dataRevisionProvider);
  return ref.read(servicesProvider).records.pickup(id);
});

class PickupsScreen extends ConsumerStatefulWidget {
  const PickupsScreen({super.key});

  @override
  ConsumerState<PickupsScreen> createState() => _PickupsScreenState();
}

class _PickupsScreenState extends ConsumerState<PickupsScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final all = ref.watch(pickupsProvider).value ?? const <PickupDoc>[];
    final pending = ref.watch(pendingByRecordProvider).value ?? const {};

    final toCollect = all.where((p) => !p.isCollected).toList();
    final collected = all.where((p) => p.isCollected).toList();
    final shown = _tab == 0 ? toCollect : collected;

    return NeuScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ScreenHeader(
            title: 'Pickups',
            subtitle: _today(),
            trailing: NeuIconButton(
              icon: Icons.person_outline_rounded,
              onPressed: () => showAccountSheet(context, ref),
              tooltip: 'Account',
            ),
          ),
          const SizedBox(height: 14),
          StatusStrip(onQueueTap: () => context.push('/queue')),
          const SizedBox(height: 14),
          NeuSegmented(
            labels: ['To collect · ${toCollect.length}', 'Collected today · ${collected.length}'],
            index: _tab,
            onChanged: (i) => setState(() => _tab = i),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: RefreshIndicator(
              color: c.accentInk,
              backgroundColor: c.ground,
              onRefresh: () => ref.read(syncProvider.notifier).syncNow(),
              child: shown.isEmpty
                  ? EmptyState(
                      message: _tab == 0
                          ? 'Nothing to collect'
                          : 'Nothing collected yet today',
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.only(bottom: 16),
                      itemCount: shown.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 13),
                      itemBuilder: (_, i) => _PickupCard(
                        doc: shown[i],
                        pending: pending[shown[i].id] ?? const [],
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  static String _today() {
    final now = DateTime.now();
    const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    return '${days[now.weekday - 1]}, ${now.day} ${months[now.month - 1]}';
  }
}

class _PickupCard extends StatelessWidget {
  const _PickupCard({required this.doc, required this.pending});

  final PickupDoc doc;
  final List<OutboxItem> pending;

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final queued = pending.where((p) => p.isWaiting).toList();
    final blocked = pending.where((p) => p.state == OutboxState.needsAttention).toList();

    return NeuBox(
      style: NeuStyle.raised,
      radius: 22,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      onTap: () => context.push('/pickup/${doc.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(doc.name, style: NeuText.data(c.accentInk, size: 13)),
              const Spacer(),
              if (blocked.isNotEmpty)
                StateChip(
                  blocked.first.lastErrorCode == 'ALREADY_CONFIRMED' ? 'Someone else' : 'Needs you',
                  kind: blocked.first.lastErrorCode == 'ALREADY_CONFIRMED'
                      ? ChipKind.other
                      : ChipKind.attention,
                  icon: Icons.warning_amber_rounded,
                )
              else if (queued.isNotEmpty)
                const StateChip('Queued', kind: ChipKind.queued, icon: Icons.schedule_rounded)
              else if (doc.isCollected)
                const StateChip('Synced', kind: ChipKind.synced, icon: Icons.check_rounded)
              else if (doc.jangadPages == 0)
                const StateChip('No jangad yet', kind: ChipKind.blocked)
              else
                StateChip(
                  doc.jangadPages == 1 ? '1 page' : '${doc.jangadPages} pages',
                  kind: ChipKind.blocked,
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            doc.customerLabel,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: NeuText.strong(doc.customer == null ? c.blockedInk : c.ink, size: 17),
          ),
          const SizedBox(height: 7),
          if (doc.isCollected)
            Row(
              children: [
                Icon(Icons.check_rounded, size: 15, color: c.syncedInk),
                const SizedBox(width: 8),
                Text(
                  'Collected ${OdooTime.hm(doc.collectedAt)} · ${doc.jangadPages} pages',
                  style: NeuText.body_(c.inkMuted, size: 13, w: FontWeight.w600),
                ),
              ],
            )
          else ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.place_outlined, size: 15, color: c.inkFaint),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    doc.pickupAddress == null || doc.pickupAddress!.trim().isEmpty
                        ? 'No address on the receipt'
                        : oneLineAddress(doc.pickupAddress!),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: NeuText.body_(c.inkMuted, size: 13),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.schedule_rounded, size: 14, color: c.inkFaint),
                const SizedBox(width: 7),
                Text(OdooTime.hm(doc.scheduledDate), style: NeuText.data(c.inkMuted)),
                const Spacer(),
                Icon(Icons.chevron_right_rounded, size: 20, color: c.accentInk),
              ],
            ),
          ],
          if (queued.isNotEmpty) ...[
            const SizedBox(height: 12),
            NeuBox(
              style: NeuStyle.insetSm,
              radius: 13,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Sends when you are back online',
                      style: NeuText.label(c.queuedInk, size: 12),
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, size: 15, color: c.queuedInk),
                ],
              ),
            ),
          ],
          if (blocked.isNotEmpty) ...[
            const SizedBox(height: 12),
            NeuBox(
              style: NeuStyle.insetSm,
              radius: 13,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Text(
                blocked.first.lastErrorMessage ?? 'This did not go through.',
                style: NeuText.body_(c.attentionInk, size: 12, w: FontWeight.w600),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class PickupDetailScreen extends ConsumerStatefulWidget {
  const PickupDetailScreen({super.key, required this.id});
  final int id;

  @override
  ConsumerState<PickupDetailScreen> createState() => _PickupDetailScreenState();
}

class _PickupDetailScreenState extends ConsumerState<PickupDetailScreen> {
  int _page = 0;
  final _pages = <int, Uint8List?>{};
  bool _loading = false;

  Future<void> _load(int page) async {
    if (_pages.containsKey(page) || _loading) return;
    setState(() => _loading = true);
    try {
      final bytes = await ref.read(servicesProvider).field.jangadPage(widget.id, page);
      if (mounted) setState(() => _pages[page] = bytes);
    } catch (_) {
      if (mounted) setState(() => _pages[page] = null);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final doc = ref.watch(pickupProvider(widget.id)).value;

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

    if (doc.jangadPages > 0) _load(_page);

    return NeuScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ScreenHeader(
            title: doc.name,
            mono: true,
            subtitle: doc.isCollected
                ? 'Collected ${OdooTime.hm(doc.collectedAt)}'
                : 'To collect · ${OdooTime.hm(doc.scheduledDate)}',
            onBack: () => context.pop(),
            trailing: doc.contactPhone == null
                ? null
                : NeuIconButton(
                    icon: Icons.call_outlined,
                    onPressed: () {},
                    tooltip: 'Call the customer',
                    color: c.accentInk,
                  ),
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
                            child: _loading && !_pages.containsKey(_page)
                                ? CircularProgressIndicator(color: c.accentInk)
                                : JangadImage(bytes: _pages[_page], height: 250),
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
                            Text(
                              'Page ${_page + 1} of ${doc.jangadPages}',
                              style: NeuText.label(c.inkMuted, size: 12),
                            ),
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
                      _row(context, Icons.person_outline_rounded, doc.customerLabel,
                          doc.contactPhone ?? ''),
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
                const SizedBox(height: 13),
              ],
            ),
          ),
          if (!doc.isCollected) ...[
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
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: NeuText.strong(c.ink, size: 15),
              ),
              if (sub.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  sub,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: NeuText.data(c.inkMuted),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Capture, then confirm. The pages go up before the intent that quotes them.
class ConfirmPickupScreen extends ConsumerStatefulWidget {
  const ConfirmPickupScreen({super.key, required this.id});
  final int id;

  @override
  ConsumerState<ConfirmPickupScreen> createState() => _ConfirmPickupScreenState();
}

class _ConfirmPickupScreenState extends ConsumerState<ConfirmPickupScreen> {
  final _note = TextEditingController();
  final _pages = <UploadItem>[];
  Map<String, dynamic> _location = const {};
  bool _busy = false;
  String? _warning;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _addPage() async {
    final services = ref.read(servicesProvider);
    if (!await ImagePipeline.hasRoom()) {
      setState(() => _warning =
          'This phone is nearly out of room for photos. Send what is queued before taking more.');
      return;
    }
    final file = await services.images.capture();
    if (file == null) return;
    final staged = await services.uploads.stage(file, pageIndex: _pages.length);
    if (!mounted) return;
    setState(() {
      _pages.add(staged);
      _warning = null;
    });
    // Asked for in context — at the first page, not at launch.
    if (_location.isEmpty) {
      final fix = await services.location.capture();
      if (mounted) setState(() => _location = fix);
    }
  }

  Future<void> _confirm(PickupDoc doc) async {
    setState(() => _busy = true);
    final services = ref.read(servicesProvider);
    await services.field.confirmPickup(
      id: doc.id,
      label: doc.name,
      uploadLocalIds: [for (final p in _pages) p.localId],
      note: _note.text.trim().isEmpty ? null : _note.text.trim(),
      location: _location,
    );
    await ref.read(syncProvider.notifier).refreshCounters();
    unawaited(ref.read(syncProvider.notifier).syncNow(flushFirst: true));
    if (!mounted) return;
    context.go('/pickups');
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
          ScreenHeader(
            title: 'Confirm pickup',
            subtitle: '${doc.name} · ${doc.customerLabel}',
            onBack: () => context.pop(),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: ListView(
              children: [
                Text('Jangad pages', style: NeuText.label(c.ink, size: 13)),
                const SizedBox(height: 3),
                Text(
                  'in the order you photograph them',
                  style: NeuText.body_(c.inkMuted, size: 12),
                ),
                const SizedBox(height: 11),
                SizedBox(
                  height: 148,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _pages.length + 1,
                    separatorBuilder: (_, _) => const SizedBox(width: 12),
                    itemBuilder: (_, i) {
                      if (i == _pages.length) {
                        return NeuBox(
                          style: NeuStyle.raised,
                          radius: 18,
                          width: 96,
                          height: 124,
                          onTap: _addPage,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.photo_camera_outlined, size: 26, color: c.accentInk),
                              const SizedBox(height: 9),
                              Text('Add page', style: NeuText.label(c.accentInk, size: 12)),
                            ],
                          ),
                        );
                      }
                      final page = _pages[i];
                      return Column(
                        children: [
                          NeuBox(
                            style: NeuStyle.inset,
                            radius: 18,
                            width: 96,
                            height: 124,
                            padding: const EdgeInsets.all(8),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: Image.file(File(page.filePath), fit: BoxFit.cover),
                            ),
                          ),
                          const SizedBox(height: 7),
                          Text(
                            '${i + 1} · ${(page.bytes / 1024).round()} KB',
                            style: NeuText.data(c.inkMuted, size: 11),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                const SizedBox(height: 9),
                Text(
                  '${Env.imageLongEdge} px long edge · q${Env.imageQuality} · kept until the office has it',
                  style: NeuText.data(c.inkFaint, size: 11),
                ),
                if (_warning != null) ...[
                  const SizedBox(height: 14),
                  NeuNote(text: _warning!, kind: ChipKind.attention, icon: Icons.warning_amber_rounded),
                ],
                const SizedBox(height: 16),
                NeuBox(
                  style: NeuStyle.raised,
                  radius: 18,
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                  child: Row(
                    children: [
                      NeuBox(
                        style: NeuStyle.insetSm,
                        radius: 13,
                        width: 38,
                        height: 38,
                        child: Center(
                          child: Icon(
                            Icons.place_outlined,
                            size: 18,
                            color: _location.isEmpty ? c.inkFaint : c.syncedInk,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _location.isEmpty ? 'No location' : 'Location attached',
                              style: NeuText.strong(c.ink, size: 14),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              _location.isEmpty
                                  ? 'Never required — basements have no fix'
                                  : '±${(_location['accuracy_m'] as num).round()} m',
                              style: NeuText.data(c.inkMuted, size: 11),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                NeuField(
                  controller: _note,
                  label: 'Note',
                  hint: 'Anything the office should know',
                  maxLines: 2,
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
          NeuBox(
            style: NeuStyle.inset,
            radius: 16,
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
            child: Row(
              children: [
                Icon(Icons.schedule_rounded, size: 16, color: c.inkMuted),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Recorded at ${OdooTime.hm(ref.read(servicesProvider).clock.now())}, not when it sends',
                    style: NeuText.body_(c.inkMuted, size: 12),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          NeuButton(
            label: _pages.isEmpty ? 'Photograph the jangad first' : 'Confirm pickup',
            kind: NeuButtonKind.primary,
            icon: Icons.check_rounded,
            busy: _busy,
            onPressed: _pages.isEmpty ? null : () => _confirm(doc),
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

  @override
  void dispose() {
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
                  NeuBox(
                    style: i == _selected ? NeuStyle.insetSm : NeuStyle.raised,
                    radius: 18,
                    padding: const EdgeInsets.fromLTRB(17, 16, 17, 16),
                    onTap: () => setState(() => _selected = i),
                    child: Row(
                      children: [
                        Container(
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: i == _selected ? c.accent : c.ground,
                            boxShadow: i == _selected
                                ? null
                                : [
                                    BoxShadow(color: c.shadowDark, offset: const Offset(2, 2), blurRadius: 4),
                                    BoxShadow(color: c.shadowLight, offset: const Offset(-2, -2), blurRadius: 4),
                                  ],
                          ),
                          child: i == _selected
                              ? Icon(Icons.check_rounded, size: 14, color: c.onAccent)
                              : null,
                        ),
                        const SizedBox(width: 13),
                        Expanded(
                          child: Text(
                            _reasons[i],
                            style: i == _selected
                                ? NeuText.strong(c.ink, size: 15)
                                : NeuText.body_(c.inkMuted, size: 15, w: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 11),
                ],
                const SizedBox(height: 10),
                NeuField(
                  controller: _detail,
                  label: 'Detail',
                  hint: 'Shop shut, neighbour says back at 4',
                  maxLines: 3,
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
              await ref.read(servicesProvider).field.cancelPickup(
                    id: doc.id,
                    label: doc.name,
                    reason: detail.isEmpty ? _reasons[_selected] : '${_reasons[_selected]} — $detail',
                  );
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
