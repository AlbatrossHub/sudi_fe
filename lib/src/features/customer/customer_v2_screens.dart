import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_error.dart';
import '../../core/drafts/draft_store.dart';
import '../../core/outbox/outbox.dart';
import '../../core/services.dart';
import '../../core/session.dart';
import '../../core/sync_status.dart';
import '../../core/uploads/image_pipeline.dart';
import '../../models/docs.dart';
import '../../ui/theme/neu.dart';
import '../../ui/widgets/neu_box.dart';
import '../../ui/widgets/neu_widgets.dart';
import '../../ui/widgets/v2_widgets.dart';
import '../field/sign_in_screens.dart';
import '../shared/catalog.dart';

// ------------------------------------------------------------ the request

/// The customer's request being built: services first (phase 1), then the
/// jangad pages and where to collect from (phase 2). One submission is both.
/// Kept as a draft on the phone's disk at every tap.
class JangadDraftState {
  const JangadDraftState({
    this.services = const [],
    this.pages = const [],
    this.savedAddress,
    this.manualAddress,
    this.loaded = false,
    this.restoredAt,
  });

  final List<ServiceRequest> services;
  final List<UploadItem> pages;
  final AddressSuggestion? savedAddress;
  final String? manualAddress;
  final bool loaded;
  final DateTime? restoredAt;

  bool get hasAddress => savedAddress != null || (manualAddress?.isNotEmpty ?? false);
  String get addressLabel => savedAddress?.label ?? manualAddress ?? 'Choose where to collect from';
  ServiceRequest? service(int jobTypeId) => services.where((s) => s.jobTypeId == jobTypeId).firstOrNull;

  JangadDraftState copyWith({
    List<ServiceRequest>? services,
    List<UploadItem>? pages,
    AddressSuggestion? savedAddress,
    String? manualAddress,
    bool clearAddress = false,
    bool? loaded,
    DateTime? restoredAt,
    bool clearRestored = false,
  }) => JangadDraftState(
    services: services ?? this.services,
    pages: pages ?? this.pages,
    savedAddress: clearAddress ? null : (savedAddress ?? this.savedAddress),
    manualAddress: clearAddress ? null : (manualAddress ?? this.manualAddress),
    loaded: loaded ?? this.loaded,
    restoredAt: clearRestored ? null : (restoredAt ?? this.restoredAt),
  );

  Map<String, dynamic> toDraft() => {
    'services': [for (final s in services) s.toDraft()],
    'pages': [for (final p in pages) p.localId],
    'saved_address': savedAddress?.toJson(),
    'manual_address': manualAddress,
  };
}

class JangadDraft extends Notifier<JangadDraftState> {
  Services get _s => ref.read(servicesProvider);

  @override
  JangadDraftState build() {
    scheduleMicrotask(_load);
    return const JangadDraftState();
  }

  Future<void> _load() async {
    final draft = await _s.drafts.load(DraftStore.customerJangad);
    if (draft == null) {
      state = state.copyWith(loaded: true);
      return;
    }
    final d = draft.data;
    final pages = await _s.uploads.byIds([for (final p in (d['pages'] as List? ?? const [])) '$p']);
    final restored = JangadDraftState(
      services: ServiceRequest.listFromDraft(d['services']),
      pages: pages,
      savedAddress: d['saved_address'] is Map
          ? AddressSuggestion.fromJson(Map<String, dynamic>.from(d['saved_address'] as Map))
          : null,
      manualAddress: d['manual_address'] as String?,
      loaded: true,
    );
    final something = restored.services.isNotEmpty || restored.pages.isNotEmpty;
    state = restored.copyWith(
      restoredAt: something && draft.savedAt.isBefore(DraftStore.launchedAt) ? draft.savedAt : null,
    );
  }

  void _save(JangadDraftState next) {
    state = next;
    _s.drafts.save(DraftStore.customerJangad, next.toDraft());
  }

  void dismissBanner() => state = state.copyWith(clearRestored: true);

  void putService(ServiceRequest service) {
    final list = [...state.services];
    final i = list.indexWhere((s) => s.jobTypeId == service.jobTypeId);
    if (i >= 0) {
      list[i] = service;
    } else {
      list.add(service);
    }
    _save(state.copyWith(services: list));
  }

  void removeService(int jobTypeId) => _save(
    state.copyWith(
      services: [
        for (final s in state.services)
          if (s.jobTypeId != jobTypeId) s,
      ],
    ),
  );

  Future<void> addPage(UploadItem page) async {
    final next = state.copyWith(pages: [...state.pages, page]);
    state = next;
    await _s.drafts.saveNow(DraftStore.customerJangad, next.toDraft());
  }

  Future<void> removePage(String localId) async {
    final pages = [
      for (final p in state.pages)
        if (p.localId != localId) p,
    ];
    _save(state.copyWith(pages: pages));
    await _s.uploads.discard(localId);
    await _s.uploads.renumber([for (final p in pages) p.localId]);
  }

  void chooseSaved(AddressSuggestion address) =>
      _save(JangadDraftState(services: state.services, pages: state.pages, savedAddress: address, loaded: true));

  void chooseManual(String text) =>
      _save(JangadDraftState(services: state.services, pages: state.pages, manualAddress: text, loaded: true));

  Future<void> clear() async {
    await _s.drafts.clear(DraftStore.customerJangad);
    state = const JangadDraftState(loaded: true);
  }
}

final jangadDraftProvider = NotifierProvider<JangadDraft, JangadDraftState>(JangadDraft.new);

/// Add or edit one service on the request, through the sheet.
Future<void> editRequestService(
  BuildContext context,
  WidgetRef ref, {
  required int jobTypeId,
  required String name,
  required String unit,
}) async {
  final existing = ref.read(jangadDraftProvider).service(jobTypeId);
  final result = await showAddServiceSheet(context, name: name, unit: unit, existing: existing);
  if (result == null) return;
  final draft = ref.read(jangadDraftProvider.notifier);
  if (result.remove) {
    draft.removeService(jobTypeId);
  } else {
    draft.putService(
      ServiceRequest(jobTypeId: jobTypeId, name: name, unit: unit, quantity: result.quantity, remarks: result.remarks),
    );
  }
}

// -------------------------------------------------------------------- GST

/// The KYC step: the business GSTIN, or "skip for now". Runs after sign-in
/// whenever the account has none on file; a skip is never final.
class GstScreen extends ConsumerStatefulWidget {
  const GstScreen({super.key});

  @override
  ConsumerState<GstScreen> createState() => _GstScreenState();
}

class _GstScreenState extends ConsumerState<GstScreen> {
  final _vat = TextEditingController();
  bool _busy = false;
  String? _error;
  GstAnswerView? _answer;

  @override
  void dispose() {
    _vat.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final answer = await ref.read(servicesProvider).auth.submitGst(_vat.text.trim().toUpperCase());
      if (!mounted) return;
      setState(() => _answer = GstAnswerView(answer.company, answer.gstState));
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _done(String state) async {
    await ref.read(sessionProvider.notifier).gstDone(state);
    if (mounted) context.go('/home');
  }

  Future<void> _skip() async {
    setState(() => _busy = true);
    try {
      await ref.read(servicesProvider).auth.skipGst();
    } on ApiError {
      // No signal: skip on the phone; the server asks again next time.
    }
    await _done('skipped');
  }

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final online = ref.watch(syncProvider.select((s) => s.online));
    final valid = RegExp(r'^[0-9A-Z]{15}$').hasMatch(_vat.text.trim().toUpperCase());

    return NeuScaffold(
      padding: const EdgeInsets.fromLTRB(24, 30, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView(
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: NeuBox(
                    style: NeuStyle.raised,
                    radius: 22,
                    width: 64,
                    height: 64,
                    child: Icon(Icons.badge_outlined, size: 28, color: c.accentInk),
                  ),
                ),
                const SizedBox(height: 18),
                Text('Your business GSTIN', style: NeuText.title(c.ink, size: 25)),
                const SizedBox(height: 8),
                Text(
                  'We put it on your invoices. We check it and fill in your business name and '
                  'address for you.',
                  style: NeuText.body_(c.inkMuted, size: 14.5),
                ),
                const SizedBox(height: 18),
                LabeledInput(
                  fieldKey: const Key('gstin'),
                  label: 'GSTIN',
                  controller: _vat,
                  hint: '27AABCK1234F1Z5',
                  mono: true,
                  size: 17,
                  onChanged: (_) => setState(() {
                    _answer = null;
                    _error = null;
                  }),
                ),
                if (_answer != null) ...[
                  const SizedBox(height: 14),
                  NeuBox(
                    style: NeuStyle.raised,
                    radius: 20,
                    padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(color: c.syncedFill, shape: BoxShape.circle),
                          child: Icon(Icons.check_rounded, size: 14, color: c.syncedInk),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                (_answer!.company ?? 'GSTIN saved').toUpperCase(),
                                style: NeuText.label(c.ink, size: 14.5),
                              ),
                              const SizedBox(height: 2),
                              Text('On file for your invoices', style: NeuText.body_(c.inkMuted, size: 12.5)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  NeuNote(text: _error!, kind: ChipKind.attention, icon: Icons.warning_amber_rounded),
                ],
                const SizedBox(height: 16),
              ],
            ),
          ),
          if (_answer != null)
            NeuButton(
              label: 'Continue',
              kind: NeuButtonKind.primary,
              height: 54,
              onPressed: () => _done(_answer!.state),
            )
          else
            NeuButton(
              label: 'Save and continue',
              kind: NeuButtonKind.primary,
              height: 54,
              busy: _busy,
              disabledReason: online ? null : 'Checking a GSTIN needs a connection',
              onPressed: online && valid ? _save : null,
            ),
          const SizedBox(height: 12),
          if (_answer == null) ...[
            NeuButton(label: 'Skip for now', height: 50, onPressed: _busy ? null : _skip),
            const SizedBox(height: 8),
            Text(
              'You can still send a jangad; we will ask again later.',
              textAlign: TextAlign.center,
              style: NeuText.body_(c.inkFaint, size: 12),
            ),
          ],
          const SizedBox(height: 22),
        ],
      ),
    );
  }
}

class GstAnswerView {
  const GstAnswerView(this.company, this.state);
  final String? company;
  final String state;
}

// -------------------------------------------------------------- dashboard

/// Home: the services the workshop offers, picked one at a time.
class CustomerDashboardScreen extends ConsumerStatefulWidget {
  const CustomerDashboardScreen({super.key});

  @override
  ConsumerState<CustomerDashboardScreen> createState() => _CustomerDashboardScreenState();
}

class _CustomerDashboardScreenState extends ConsumerState<CustomerDashboardScreen> {
  bool _all = false;

  static String _greeting(DateTime now) => now.hour < 12
      ? 'Good morning'
      : now.hour < 17
      ? 'Good afternoon'
      : 'Good evening';

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final me = ref.watch(sessionProvider.select((s) => s.me));
    final catalog = ref.watch(serviceCatalogProvider);
    final draft = ref.watch(jangadDraftProvider);
    final online = ref.watch(syncProvider.select((s) => s.online));
    final services = catalog.value ?? const <ServiceInfo>[];
    final shown = _all || services.length <= 6 ? services : services.take(6).toList();
    final gst = me?.gstState;

    return NeuScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Greeting and buttons on one row, the name on its own below: sharing
          // the row with the GST chip and two buttons cut it to "Test …".
          Row(
            children: [
              Expanded(child: Text(_greeting(DateTime.now()), style: NeuText.body_(c.inkMuted, size: 13))),
              NeuIconButton(
                icon: Icons.receipt_long_outlined,
                onPressed: () => context.push('/submitted'),
                tooltip: 'What you have sent',
              ),
              const SizedBox(width: 8),
              NeuIconButton(
                icon: Icons.person_outline_rounded,
                onPressed: () => showAccountSheet(context, ref),
                tooltip: 'Account',
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(me?.name ?? 'Welcome', maxLines: 1, softWrap: false, style: NeuText.title(c.ink, size: 24)),
                ),
              ),
              const SizedBox(width: 10),
              if (gst == 'present')
                const StateChip('GST on file', kind: ChipKind.synced, icon: Icons.check_rounded)
              else if (gst != null)
                GestureDetector(
                  onTap: () => context.push('/gst'),
                  child: const StateChip('Add GSTIN', kind: ChipKind.accent, icon: Icons.add_rounded),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: ListView(
              children: [
                if (draft.restoredAt != null) ...[
                  ResumeBanner(
                    closedAt: draft.restoredAt!,
                    what: 'Your services and photos',
                    onDismiss: ref.read(jangadDraftProvider.notifier).dismissBanner,
                  ),
                  const SizedBox(height: 14),
                ],
                Text('What should we do?', style: NeuText.title(c.ink, size: 18)),
                const SizedBox(height: 3),
                Text('Tap a service, say how many, add it. One at a time.', style: NeuText.body_(c.inkMuted, size: 13)),
                if (!online && services.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    'No signal — this is the list saved on your phone.',
                    style: NeuText.label(c.queuedInk, size: 12),
                  ),
                ],
                const SizedBox(height: 14),
                if (catalog is AsyncError && catalog.value == null)
                  NeuNote(
                    title: 'The services list needs a connection the first time',
                    text: 'You can still send the jangad now; tell us what to do when we collect it.',
                    icon: Icons.wifi_off_rounded,
                    kind: ChipKind.queued,
                  )
                else if (catalog.value == null)
                  Padding(
                    padding: const EdgeInsets.all(30),
                    child: Center(child: CircularProgressIndicator(color: c.accentInk)),
                  )
                else
                  GridView.count(
                    crossAxisCount: 2,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 1.45,
                    padding: const EdgeInsets.all(2),
                    children: [for (final s in shown) _ServiceTile(service: s, picked: draft.service(s.id))],
                  ),
                if (services.length > 6) ...[
                  const SizedBox(height: 12),
                  NeuBox(
                    style: NeuStyle.raisedSm,
                    radius: 15,
                    height: 44,
                    onTap: () => setState(() => _all = !_all),
                    child: Center(
                      child: Text(
                        _all ? 'Fewer services' : 'All ${services.length} services',
                        style: NeuText.label(c.accentInk, size: 13.5),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
              ],
            ),
          ),
          if (draft.services.isNotEmpty)
            _RequestBar(services: draft.services)
          else if (catalog is AsyncError && catalog.value == null)
            NeuButton(
              label: 'Send the jangad without services',
              kind: NeuButtonKind.primary,
              icon: Icons.photo_camera_outlined,
              height: 54,
              onPressed: () => context.push('/request/jangad'),
            ),
          const SizedBox(height: 18),
        ],
      ),
    );
  }
}

class _ServiceTile extends ConsumerWidget {
  const _ServiceTile({required this.service, required this.picked});
  final ServiceInfo service;
  final ServiceRequest? picked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = NeuTheme.of(context);
    final added = picked != null;
    return NeuBox(
      key: Key('service-tile-${service.id}'),
      style: added ? NeuStyle.inset : NeuStyle.raised,
      radius: 20,
      padding: const EdgeInsets.fromLTRB(14, 13, 12, 12),
      onTap: () => editRequestService(context, ref, jobTypeId: service.id, name: service.name, unit: service.unit),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Text(
              service.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: NeuText.label(added ? c.accentInk : c.ink, size: 14.5),
            ),
          ),
          if (added)
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(color: c.accent, borderRadius: BorderRadius.circular(9)),
                child: Text(
                  picked!.quantity > 0 ? 'Added · ${picked!.quantityLabel}' : 'Added',
                  style: NeuText.label(c.onAccent, size: 11.5),
                ),
              ),
            )
          else
            Align(
              alignment: Alignment.centerRight,
              child: NeuBox(
                style: NeuStyle.raisedSm,
                radius: 10,
                width: 30,
                height: 30,
                child: Icon(Icons.add_rounded, size: 18, color: c.accentInk),
              ),
            ),
        ],
      ),
    );
  }
}

/// The accent bar at the foot of the dashboard: the request so far, and Next.
class _RequestBar extends StatelessWidget {
  const _RequestBar({required this.services});
  final List<ServiceRequest> services;

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    return NeuBox(
      key: const Key('request-bar'),
      style: NeuStyle.accent,
      radius: 20,
      onTap: () => context.push('/request'),
      child: SizedBox(
        height: 62,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: c.onAccent.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Center(child: Text('${services.length}', style: NeuText.data(c.onAccent, size: 15))),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Your request', style: NeuText.label(c.onAccent, size: 15)),
                    Text(
                      ServiceRequest.summary(services),
                      style: NeuText.body_(c.onAccent.withValues(alpha: 0.9), size: 12),
                    ),
                  ],
                ),
              ),
              Text('Next', style: NeuText.label(c.onAccent, size: 14)),
              const SizedBox(width: 4),
              Icon(Icons.arrow_forward_rounded, size: 18, color: c.onAccent),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- request

/// Phase 1 of 2: the services picked, each editable or removable.
class RequestScreen extends ConsumerWidget {
  const RequestScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = NeuTheme.of(context);
    final draft = ref.watch(jangadDraftProvider);
    final services = draft.services;

    return NeuScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StepHeader(step: 'PHASE 1 OF 2 · SERVICES', title: 'Your request', onBack: () => context.go('/home')),
          const SizedBox(height: 14),
          const PhaseBars(done: 1),
          const SizedBox(height: 14),
          Expanded(
            child: ListView(
              children: [
                if (services.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    child: Text(
                      'No services yet. Pick them on the home screen.',
                      style: NeuText.body_(c.inkMuted, size: 13.5),
                    ),
                  ),
                for (final s in services) ...[
                  NeuBox(
                    key: Key('request-service-${s.jobTypeId}'),
                    style: NeuStyle.raised,
                    radius: 20,
                    padding: const EdgeInsets.fromLTRB(15, 14, 15, 14),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(s.name, style: NeuText.label(c.ink, size: 15)),
                              const SizedBox(height: 3),
                              Text(
                                s.quantity > 0 ? s.quantityLabel : 'Count not given',
                                style: NeuText.data(c.ink, size: 13),
                              ),
                              if (s.remarks != null) ...[
                                const SizedBox(height: 3),
                                Text('“${s.remarks}”', style: NeuText.body_(c.inkMuted, size: 12.5)),
                              ],
                            ],
                          ),
                        ),
                        NeuIconButton(
                          icon: Icons.edit_outlined,
                          size: 38,
                          tooltip: 'Edit ${s.name}',
                          onPressed: () =>
                              editRequestService(context, ref, jobTypeId: s.jobTypeId, name: s.name, unit: s.unit),
                        ),
                        const SizedBox(width: 8),
                        NeuIconButton(
                          key: Key('remove-service-${s.jobTypeId}'),
                          icon: Icons.close_rounded,
                          size: 38,
                          tooltip: 'Remove ${s.name}',
                          onPressed: () => ref.read(jangadDraftProvider.notifier).removeService(s.jobTypeId),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                NeuBox(
                  style: NeuStyle.inset,
                  radius: 18,
                  height: 52,
                  onTap: () => context.go('/home'),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.add_rounded, size: 18, color: c.accentInk),
                      const SizedBox(width: 8),
                      Text('Add another service', style: NeuText.label(c.accentInk, size: 14.5)),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
          if (services.isNotEmpty) ...[
            NeuBox(
              style: NeuStyle.inset,
              radius: 16,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Text(
                    '${services.length} service${services.length == 1 ? '' : 's'}',
                    style: NeuText.body_(c.inkMuted, size: 13.5),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      ServiceRequest.summary(services).split(' · ').skip(1).join(' · '),
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: NeuText.data(c.ink, size: 13),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          NeuButton(
            label: 'Next: jangad photo',
            kind: NeuButtonKind.primary,
            icon: Icons.arrow_forward_rounded,
            height: 54,
            onPressed: services.isEmpty ? null : () => context.push('/request/jangad'),
          ),
          const SizedBox(height: 18),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------ the jangad

/// Phase 2 of 2: photograph the jangad, say where to collect it, send.
class CustomerJangadScreen extends ConsumerStatefulWidget {
  const CustomerJangadScreen({super.key});

  @override
  ConsumerState<CustomerJangadScreen> createState() => _CustomerJangadScreenState();
}

class _CustomerJangadScreenState extends ConsumerState<CustomerJangadScreen> {
  bool _busy = false;
  String? _warning;

  Future<void> _addPage() async {
    final services = ref.read(servicesProvider);
    if (!await ImagePipeline.hasRoom()) {
      setState(() => _warning = 'This phone is nearly out of room for photos.');
      return;
    }
    final file = await services.images.capture();
    if (file == null) return;
    final draft = ref.read(jangadDraftProvider);
    final staged = await services.uploads.stage(file, pageIndex: draft.pages.length);
    await ref.read(jangadDraftProvider.notifier).addPage(staged);
    if (mounted) setState(() => _warning = null);
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    final draft = ref.read(jangadDraftProvider);
    final services = ref.read(servicesProvider);
    await services.customer.submitJangad(
      uploadLocalIds: [for (final p in draft.pages) p.localId],
      addressId: draft.savedAddress?.id,
      manualAddress: draft.savedAddress == null ? draft.manualAddress : null,
      addressLabel: draft.addressLabel,
      services: draft.services,
    );
    await ref.read(jangadDraftProvider.notifier).clear();
    await ref.read(syncProvider.notifier).refreshCounters();
    unawaited(ref.read(syncProvider.notifier).syncNow(flushFirst: true));
    if (!mounted) return;
    context.go('/submitted');
  }

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final draft = ref.watch(jangadDraftProvider);
    final ready = draft.pages.isNotEmpty && draft.hasAddress;

    return NeuScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StepHeader(step: 'PHASE 2 OF 2 · JANGAD', title: 'Photograph the jangad'),
          const SizedBox(height: 14),
          const PhaseBars(done: 2),
          const SizedBox(height: 14),
          Expanded(
            child: ListView(
              children: [
                if (draft.services.isNotEmpty) ...[
                  NeuBox(
                    style: NeuStyle.inset,
                    radius: 16,
                    padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
                    child: Text.rich(
                      TextSpan(
                        style: NeuText.body_(c.inkSoft, size: 12.5),
                        children: [
                          TextSpan(
                            text: ServiceRequest.summary(draft.services),
                            style: NeuText.label(c.inkSoft, size: 12.5),
                          ),
                          TextSpan(text: ' — ${draft.services.map((s) => s.name).join(', ')}'),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                ],
                SizedBox(
                  height: 200,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: draft.pages.length + 1,
                    separatorBuilder: (_, _) => const SizedBox(width: 12),
                    itemBuilder: (_, i) {
                      if (i == draft.pages.length) {
                        return NeuBox(
                          style: NeuStyle.inset,
                          radius: 18,
                          width: 150,
                          onTap: _addPage,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.photo_camera_outlined, size: 26, color: c.accentInk),
                              const SizedBox(height: 8),
                              Text(
                                draft.pages.isEmpty ? 'Photograph it' : 'Another page',
                                style: NeuText.label(c.accentInk, size: 13),
                              ),
                            ],
                          ),
                        );
                      }
                      final page = draft.pages[i];
                      return NeuBox(
                        style: NeuStyle.raised,
                        radius: 18,
                        width: 150,
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          children: [
                            Expanded(
                              child: Stack(
                                children: [
                                  Positioned.fill(
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(12),
                                      child: Image.file(File(page.filePath), fit: BoxFit.cover),
                                    ),
                                  ),
                                  Positioned(
                                    right: 4,
                                    top: 4,
                                    child: GestureDetector(
                                      onTap: () => ref.read(jangadDraftProvider.notifier).removePage(page.localId),
                                      child: NeuBox(
                                        style: NeuStyle.raisedSm,
                                        radius: 13,
                                        width: 26,
                                        height: 26,
                                        child: Icon(Icons.close_rounded, size: 15, color: c.inkMuted),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text('Page ${i + 1}', style: NeuText.data(c.inkMuted, size: 11)),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                if (_warning != null) ...[
                  const SizedBox(height: 12),
                  NeuNote(text: _warning!, kind: ChipKind.attention, icon: Icons.warning_amber_rounded),
                ],
                const SizedBox(height: 16),
                const SectionLabel('Collect from'),
                const SizedBox(height: 10),
                NeuBox(
                  style: draft.hasAddress ? NeuStyle.inset : NeuStyle.raised,
                  radius: 20,
                  padding: const EdgeInsets.fromLTRB(15, 13, 15, 13),
                  onTap: () => context.push('/request/address'),
                  child: Row(
                    children: [
                      RadioDot(selected: draft.hasAddress),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              draft.savedAddress != null && draft.savedAddress!.name.isNotEmpty
                                  ? draft.savedAddress!.name
                                  : (draft.hasAddress
                                        ? oneLineAddress(draft.addressLabel)
                                        : 'Choose where to collect from'),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: NeuText.strong(draft.hasAddress ? c.ink : c.inkFaint, size: 14.5),
                            ),
                            if (draft.savedAddress != null && draft.savedAddress!.name.isNotEmpty)
                              Text(
                                oneLineAddress(draft.savedAddress!.address),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: NeuText.body_(c.inkMuted, size: 12.5),
                              ),
                          ],
                        ),
                      ),
                      Text(draft.hasAddress ? 'Change' : '', style: NeuText.label(c.accentInk, size: 12.5)),
                      if (!draft.hasAddress) Icon(Icons.chevron_right_rounded, color: c.accentInk),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
          const OfflineHint('No signal? Send it anyway — it goes by itself when you are back online.'),
          const SizedBox(height: 12),
          NeuButton(
            label: ready
                ? 'Send for pickup'
                : draft.pages.isEmpty
                ? 'Photograph the jangad first'
                : 'Choose where to collect from',
            kind: NeuButtonKind.primary,
            height: 54,
            busy: _busy,
            // A button that names the next step should take you there rather
            // than sit disabled with the answer in its own label.
            onPressed: ready
                ? _submit
                : draft.pages.isEmpty
                ? null
                : () => context.push('/request/address'),
          ),
          const SizedBox(height: 18),
        ],
      ),
    );
  }
}
