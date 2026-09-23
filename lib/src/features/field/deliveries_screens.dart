import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/clock/odoo_time.dart';
import '../../core/outbox/outbox.dart';
import '../../core/services.dart';
import '../../core/sync_status.dart';
import '../../models/docs.dart';
import '../../ui/theme/neu.dart';
import '../../ui/widgets/neu_box.dart';
import '../../ui/widgets/neu_widgets.dart';
import '../../ui/widgets/signature_pad.dart';
import '../../ui/widgets/status_strip.dart';
import 'pickups_screens.dart';

final deliveriesProvider = FutureProvider.autoDispose<List<DeliveryDoc>>((ref) {
  ref.watch(dataRevisionProvider);
  return ref.read(servicesProvider).records.deliveries();
});

final deliveryProvider = FutureProvider.autoDispose.family<DeliveryDoc?, int>((ref, id) {
  ref.watch(dataRevisionProvider);
  return ref.read(servicesProvider).records.delivery(id);
});

class DeliveriesScreen extends ConsumerStatefulWidget {
  const DeliveriesScreen({super.key});

  @override
  ConsumerState<DeliveriesScreen> createState() => _DeliveriesScreenState();
}

class _DeliveriesScreenState extends ConsumerState<DeliveriesScreen> {
  int _tab = 0;
  final _selected = <int>{};

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final all = ref.watch(deliveriesProvider).value ?? const <DeliveryDoc>[];
    final pending = ref.watch(pendingByRecordProvider).value ?? const {};

    final awaiting = all.where((d) => d.stage == 'awaiting').toList();
    final out = all.where((d) => d.stage == 'out').toList();
    final done = all.where((d) => d.stage == 'delivered').toList();
    final shown = switch (_tab) { 0 => awaiting, 1 => out, _ => done };

    return NeuScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ScreenHeader(
            title: 'Deliveries',
            subtitle: _selected.isEmpty
                ? '${out.length} out with you'
                : '${_selected.length} selected',
            trailing: NeuIconButton(
              icon: Icons.refresh_rounded,
              onPressed: () => ref.read(syncProvider.notifier).syncNow(),
              tooltip: 'Refresh',
            ),
          ),
          const SizedBox(height: 14),
          StatusStrip(onQueueTap: () => context.push('/queue')),
          const SizedBox(height: 14),
          NeuSegmented(
            labels: ['Awaiting ${awaiting.length}', 'Out ${out.length}', 'Done ${done.length}'],
            index: _tab,
            onChanged: (i) => setState(() {
              _tab = i;
              _selected.clear();
            }),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: RefreshIndicator(
              color: c.accentInk,
              backgroundColor: c.ground,
              onRefresh: () => ref.read(syncProvider.notifier).syncNow(),
              child: shown.isEmpty
                  ? EmptyState(
                      message: switch (_tab) {
                        0 => 'Nothing awaiting collection',
                        1 => 'Nothing out with you',
                        _ => 'Nothing delivered yet today',
                      },
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.only(bottom: 16),
                      itemCount: shown.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 12),
                      itemBuilder: (_, i) => _DeliveryCard(
                        doc: shown[i],
                        pending: pending[shown[i].id] ?? const [],
                        selectable: _tab == 0,
                        selected: _selected.contains(shown[i].id),
                        onToggle: () => setState(() {
                          _selected.contains(shown[i].id)
                              ? _selected.remove(shown[i].id)
                              : _selected.add(shown[i].id);
                        }),
                      ),
                    ),
            ),
          ),
          if (_selected.isNotEmpty) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.schedule_rounded, size: 14, color: c.queuedInk),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    'Someone else may take these first',
                    style: NeuText.label(c.queuedInk, size: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                SizedBox(
                  width: 96,
                  child: NeuButton(
                    label: 'Clear',
                    onPressed: () => setState(_selected.clear),
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: NeuButton(
                    label: 'Take ${_selected.length} out',
                    kind: NeuButtonKind.primary,
                    icon: Icons.local_shipping_outlined,
                    onPressed: () async {
                      final ids = _selected.toList();
                      await ref.read(servicesProvider).field.takeDeliveries(ids);
                      setState(_selected.clear);
                      await ref.read(syncProvider.notifier).refreshCounters();
                      unawaited(ref.read(syncProvider.notifier).syncNow(flushFirst: true));
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

class _DeliveryCard extends ConsumerWidget {
  const _DeliveryCard({
    required this.doc,
    required this.pending,
    required this.selectable,
    required this.selected,
    required this.onToggle,
  });

  final DeliveryDoc doc;
  final List<OutboxItem> pending;
  final bool selectable;
  final bool selected;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = NeuTheme.of(context);
    final lost = pending
        .where((p) => p.state == OutboxState.needsAttention && p.lastErrorCode == 'ALREADY_TAKEN')
        .toList();
    final queued = pending.where((p) => p.isWaiting).toList();

    return NeuBox(
      style: selected ? NeuStyle.insetSm : NeuStyle.raised,
      radius: 22,
      padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
      onTap: selectable ? onToggle : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (selectable) ...[
                Container(
                  width: 25,
                  height: 25,
                  margin: const EdgeInsets.only(top: 2),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(9),
                    color: selected ? c.accent : c.ground,
                    boxShadow: selected
                        ? null
                        : [
                            BoxShadow(color: c.shadowDark, offset: const Offset(2, 2), blurRadius: 5),
                            BoxShadow(color: c.shadowLight, offset: const Offset(-2, -2), blurRadius: 5),
                          ],
                  ),
                  child: selected ? Icon(Icons.check_rounded, size: 15, color: c.onAccent) : null,
                ),
                const SizedBox(width: 13),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            doc.name,
                            overflow: TextOverflow.ellipsis,
                            style: NeuText.data(lost.isEmpty ? c.accentInk : c.otherInk, size: 12),
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (lost.isNotEmpty)
                          const StateChip('Someone else', kind: ChipKind.other)
                        else if (queued.isNotEmpty)
                          const StateChip('Queued', kind: ChipKind.queued, icon: Icons.schedule_rounded)
                        else if (doc.stage == 'out')
                          const StateChip('Out with you', kind: ChipKind.synced)
                        else if (doc.stage == 'delivered')
                          const StateChip('Delivered', kind: ChipKind.synced, icon: Icons.check_rounded),
                      ],
                    ),
                    // The origin receipt gets its own line: real references are
                    // long enough that sharing a row with the delivery's own
                    // reference left them touching.
                    if (doc.originReceipt != null) ...[
                      const SizedBox(height: 4),
                      Text('from ${doc.originReceipt!.name}',
                          overflow: TextOverflow.ellipsis,
                          style: NeuText.data(c.inkFaint, size: 11)),
                    ],
                    const SizedBox(height: 6),
                    Text(
                      doc.customer?.name ?? 'Customer',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: NeuText.strong(c.ink, size: 16),
                    ),
                    if (doc.address != null && doc.address!.trim().isNotEmpty) ...[
                      const SizedBox(height: 5),
                      Text(
                        oneLineAddress(doc.address!),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: NeuText.body_(c.inkMuted, size: 13),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      doc.stage == 'out'
                          ? 'Since ${OdooTime.hm(doc.outSince)} · ${_figures(doc)}'
                          : _figures(doc),
                      style: NeuText.data(c.ink, size: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (lost.isNotEmpty) ...[
            const SizedBox(height: 12),
            NeuBox(
              style: NeuStyle.insetSm,
              radius: 17,
              color: Color.lerp(c.otherFill, c.ground, 0.25),
              padding: const EdgeInsets.fromLTRB(15, 14, 15, 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: c.otherInk,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Center(
                      child: Icon(Icons.person_rounded, size: 18, color: c.ground),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          lost.first.lastErrorMessage ?? 'Someone else took this.',
                          style: NeuText.strong(c.otherInk, size: 14),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Nothing else in your queue was held up.',
                          style: NeuText.body_(c.otherInk, size: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 11),
            NeuButton(
              label: 'Got it',
              height: 44,
              onPressed: () async {
                final services = ref.read(servicesProvider);
                for (final item in lost) {
                  await services.outbox.remove(item.localId);
                }
                await ref.read(syncProvider.notifier).refreshCounters();
              },
            ),
          ],
          if (doc.stage == 'out' && lost.isEmpty && queued.isEmpty) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: NeuButton(
                    label: 'Hand back',
                    height: 46,
                    onPressed: () async {
                      await ref.read(servicesProvider).field
                          .releaseDelivery(id: doc.id, label: doc.name);
                      await ref.read(syncProvider.notifier).refreshCounters();
                      unawaited(ref.read(syncProvider.notifier).syncNow(flushFirst: true));
                    },
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: NeuButton(
                    label: 'Delivered',
                    kind: NeuButtonKind.primary,
                    height: 46,
                    onPressed: () => context.push('/delivery/${doc.id}/deliver'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  static String _figures(DeliveryDoc doc) {
    if (doc.items.isEmpty) return 'Being processed';
    return '${_trim(doc.totalPcs)} pcs · ${doc.totalCarats.toStringAsFixed(2)} ct';
  }

  static String _trim(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
}

/// Mark Delivered is a capture step, not a button. The receiver's name and a
/// drawn signature are required; without either the server answers 422 and the
/// parcel stays out for delivery.
class DeliverScreen extends ConsumerStatefulWidget {
  const DeliverScreen({super.key, required this.id});
  final int id;

  @override
  ConsumerState<DeliverScreen> createState() => _DeliverScreenState();
}

class _DeliverScreenState extends ConsumerState<DeliverScreen> {
  final _receiver = TextEditingController();
  final _signature = SignatureController();
  Map<String, dynamic> _location = const {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _signature.addListener(_onDraw);
    scheduleMicrotask(() async {
      final fix = await ref.read(servicesProvider).location.capture();
      if (mounted) setState(() => _location = fix);
    });
  }

  void _onDraw() => setState(() {});

  @override
  void dispose() {
    _signature.removeListener(_onDraw);
    _signature.dispose();
    _receiver.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final doc = ref.watch(deliveryProvider(widget.id)).value;
    if (doc == null) return const SizedBox.shrink();

    final ready = _receiver.text.trim().isNotEmpty && !_signature.isEmpty;

    return NeuScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ScreenHeader(
            title: 'Proof of delivery',
            subtitle: '${doc.name} · ${doc.customer?.name ?? ''}',
            onBack: () => context.pop(),
          ),
          const SizedBox(height: 15),
          Expanded(
            child: ListView(
              children: [
                NeuField(
                  controller: _receiver,
                  label: 'Who received it',
                  required_: true,
                  hint: 'Full name',
                  icon: Icons.person_outline_rounded,
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Text('Signature', style: NeuText.label(c.ink, size: 13)),
                    const SizedBox(width: 7),
                    Text('required', style: NeuText.label(c.attentionInk, size: 11)),
                    const Spacer(),
                    GestureDetector(
                      onTap: _signature.clear,
                      child: NeuBox(
                        style: NeuStyle.raisedSm,
                        radius: 12,
                        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
                        child: Text('Clear', style: NeuText.label(c.inkMuted, size: 12)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SignaturePad(controller: _signature),
                const SizedBox(height: 18),
                NeuBox(
                  style: NeuStyle.raised,
                  radius: 18,
                  padding: const EdgeInsets.fromLTRB(16, 13, 16, 13),
                  child: Row(
                    children: [
                      Icon(
                        Icons.place_outlined,
                        size: 18,
                        color: _location.isEmpty ? c.inkFaint : c.syncedInk,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _location.isEmpty ? 'No location — that is fine' : 'Location attached',
                          style: NeuText.body_(c.ink, size: 13, w: FontWeight.w600),
                        ),
                      ),
                      if (_location.isNotEmpty)
                        Text('±${(_location['accuracy_m'] as num).round()} m',
                            style: NeuText.data(c.inkMuted, size: 11)),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                const NeuNote(
                  text: 'Offline the signature goes up first, then the delivery. '
                      'Both stay queued until they do.',
                  icon: Icons.schedule_rounded,
                  kind: ChipKind.queued,
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
          NeuButton(
            label: ready ? 'Mark delivered' : 'Name and signature are required',
            kind: NeuButtonKind.primary,
            icon: Icons.check_rounded,
            busy: _busy,
            onPressed: ready ? () => _submit(doc) : null,
          ),
          const SizedBox(height: 18),
        ],
      ),
    );
  }

  Future<void> _submit(DeliveryDoc doc) async {
    setState(() => _busy = true);
    final services = ref.read(servicesProvider);
    final file = await _signature.render(ink: NeuTheme.of(context).ink);
    if (file == null) {
      setState(() => _busy = false);
      return;
    }
    // Page index -1 marks the signature so the flusher can tell it from the
    // optional photos when it patches references into the intent.
    final staged = await services.uploads.stage(file, pageIndex: -1);
    await services.field.markDelivered(
      id: doc.id,
      label: doc.name,
      receiverName: _receiver.text.trim(),
      signatureUploadLocalId: staged.localId,
      location: _location,
    );
    await ref.read(syncProvider.notifier).refreshCounters();
    unawaited(ref.read(syncProvider.notifier).syncNow(flushFirst: true));
    if (!mounted) return;
    context.go('/deliveries');
  }
}
