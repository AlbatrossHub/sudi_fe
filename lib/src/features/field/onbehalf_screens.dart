import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config/env.dart';
import '../../core/drafts/draft_store.dart';
import '../../core/outbox/outbox.dart';
import '../../core/outbox/outbox_flusher.dart';
import '../../core/services.dart';
import '../../core/sync_status.dart';
import '../../core/uploads/image_pipeline.dart';
import '../../models/docs.dart';
import '../../ui/theme/neu.dart';
import '../../ui/widgets/neu_box.dart';
import '../../ui/widgets/neu_widgets.dart';
import '../../ui/widgets/status_strip.dart';
import '../../ui/widgets/v2_widgets.dart';
import '../shared/catalog.dart';

/// A jangad being built for a customer: the same request the customer would
/// make -- who, which services, the pages, where to collect from -- kept as a
/// draft on the phone's disk at every step.
class OnBehalfState {
  const OnBehalfState({
    this.customer,
    this.newPhone = '',
    this.newName = '',
    this.services = const [],
    this.pages = const [],
    this.addressId,
    this.addressLabel,
    this.manualMode = false,
    this.manual = '',
    this.note = '',
    this.loaded = false,
    this.restoredAt,
  });

  final CustomerEntry? customer;
  final String newPhone;
  final String newName;
  final List<ServiceRequest> services;
  final List<UploadItem> pages;
  final int? addressId;
  final String? addressLabel;
  final bool manualMode;
  final String manual;
  final String note;
  final bool loaded;

  /// Set when the draft was left behind by an app that went away.
  final DateTime? restoredAt;

  String get phoneDigits => newPhone.replaceAll(RegExp(r'\D'), '');
  bool get hasNewCustomer => customer == null && phoneDigits.length >= 10;
  bool get hasCustomer => customer != null || hasNewCustomer;
  String get customerName =>
      customer?.displayName ??
      (newName.trim().isNotEmpty ? newName.trim() : (hasNewCustomer ? 'New customer' : 'Customer'));
  bool get hasAddress => manualMode ? manual.trim().isNotEmpty : addressId != null;
  bool get isEmpty => customer == null && newPhone.isEmpty && services.isEmpty && pages.isEmpty;

  OnBehalfState copyWith({
    CustomerEntry? customer,
    bool clearCustomer = false,
    String? newPhone,
    String? newName,
    List<ServiceRequest>? services,
    List<UploadItem>? pages,
    int? addressId,
    String? addressLabel,
    bool clearAddress = false,
    bool? manualMode,
    String? manual,
    String? note,
    bool? loaded,
    DateTime? restoredAt,
    bool clearRestored = false,
  }) => OnBehalfState(
    customer: clearCustomer ? null : (customer ?? this.customer),
    newPhone: newPhone ?? this.newPhone,
    newName: newName ?? this.newName,
    services: services ?? this.services,
    pages: pages ?? this.pages,
    addressId: clearAddress ? null : (addressId ?? this.addressId),
    addressLabel: clearAddress ? null : (addressLabel ?? this.addressLabel),
    manualMode: manualMode ?? this.manualMode,
    manual: manual ?? this.manual,
    note: note ?? this.note,
    loaded: loaded ?? this.loaded,
    restoredAt: clearRestored ? null : (restoredAt ?? this.restoredAt),
  );

  Map<String, dynamic> toDraft() => {
    'customer': customer?.toJson(),
    'new_phone': newPhone,
    'new_name': newName,
    'services': [for (final s in services) s.toDraft()],
    'pages': [for (final p in pages) p.localId],
    'address_id': addressId,
    'address_label': addressLabel,
    'manual_mode': manualMode,
    'manual': manual,
    'note': note,
  };
}

class OnBehalfController extends Notifier<OnBehalfState> {
  Services get _s => ref.read(servicesProvider);

  @override
  OnBehalfState build() {
    scheduleMicrotask(_load);
    return const OnBehalfState();
  }

  Future<void> _load() async {
    final draft = await _s.drafts.load(DraftStore.onBehalf);
    if (draft == null) {
      state = state.copyWith(loaded: true);
      return;
    }
    final d = draft.data;
    final pages = await _s.uploads.byIds([for (final p in (d['pages'] as List? ?? const [])) '$p']);
    final customer = d['customer'] is Map
        ? CustomerEntry.fromJson(Map<String, dynamic>.from(d['customer'] as Map))
        : null;
    final restored = OnBehalfState(
      customer: customer,
      newPhone: '${d['new_phone'] ?? ''}',
      newName: '${d['new_name'] ?? ''}',
      services: ServiceRequest.listFromDraft(d['services']),
      pages: pages,
      addressId: (d['address_id'] as num?)?.toInt(),
      addressLabel: d['address_label'] as String?,
      manualMode: d['manual_mode'] == true,
      manual: '${d['manual'] ?? ''}',
      note: '${d['note'] ?? ''}',
      loaded: true,
    );
    state = restored.copyWith(
      restoredAt: draft.savedAt.isBefore(DraftStore.launchedAt) && !restored.isEmpty ? draft.savedAt : null,
    );
  }

  void _save(OnBehalfState next) {
    state = next;
    _s.drafts.save(DraftStore.onBehalf, next.toDraft());
  }

  void dismissBanner() => state = state.copyWith(clearRestored: true);

  void pickCustomer(CustomerEntry entry) {
    final changed = state.customer?.id != entry.id;
    // A new customer starts on their default address (else their first), as the
    // design shows; the operator can still pick another or type one.
    final preset = !changed || entry.addresses.isEmpty
        ? null
        : entry.addresses.firstWhere((a) => a.isDefault, orElse: () => entry.addresses.first).id;
    _save(
      state.copyWith(
        customer: entry,
        newPhone: '',
        newName: '',
        addressId: preset,
        clearAddress: changed && preset == null,
        manualMode: changed ? false : state.manualMode,
      ),
    );
  }

  void typeNewCustomer({String? phone, String? name}) => _save(
    state.copyWith(
      clearCustomer: true,
      newPhone: phone ?? state.newPhone,
      newName: name ?? state.newName,
      clearAddress: state.customer != null,
      manualMode: state.customer != null ? true : state.manualMode,
    ),
  );

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
    await _s.drafts.saveNow(DraftStore.onBehalf, next.toDraft());
  }

  Future<void> removePage(UploadItem page) async {
    final pages = [
      for (final p in state.pages)
        if (p.localId != page.localId) p,
    ];
    _save(state.copyWith(pages: pages));
    await _s.uploads.discard(page.localId);
    await _s.uploads.renumber([for (final p in pages) p.localId]);
  }

  void chooseAddress(CustomerAddress address) => _save(
    state.copyWith(
      addressId: address.id,
      addressLabel: address.address.isEmpty ? address.label : address.address,
      manualMode: false,
    ),
  );

  void chooseManual() => _save(state.copyWith(clearAddress: true, manualMode: true));
  void setManual(String text) => _save(state.copyWith(manual: text));
  void setNote(String text) => _save(state.copyWith(note: text));

  /// Queue it. Returns the outbox intent -- the "Posted" screen and "Collect
  /// it now" both work from it.
  Future<OutboxItem> post() async {
    final st = state;
    final request = OnBehalfRequest(
      partnerId: st.customer?.id,
      phone: st.customer == null ? st.phoneDigits : null,
      newCustomerName: st.customer == null ? st.newName : null,
      pickupAddressId: st.manualMode ? null : st.addressId,
      manualPickupAddress: st.manualMode ? st.manual.trim() : null,
      services: st.services,
      note: st.note,
    );
    final item = await _s.field.postOnBehalf(
      request: request,
      pageLocalIds: [for (final p in st.pages) p.localId],
      customerName: st.customerName,
      addressLabel: st.manualMode ? st.manual.trim() : (st.addressLabel ?? ''),
    );
    await _s.drafts.clear(DraftStore.onBehalf);
    state = const OnBehalfState(loaded: true);
    return item;
  }
}

final onBehalfProvider = NotifierProvider<OnBehalfController, OnBehalfState>(OnBehalfController.new);

// --------------------------------------------------------------- step 1

class OnBehalfCustomerScreen extends ConsumerStatefulWidget {
  const OnBehalfCustomerScreen({super.key});

  @override
  ConsumerState<OnBehalfCustomerScreen> createState() => _OnBehalfCustomerScreenState();
}

class _OnBehalfCustomerScreenState extends ConsumerState<OnBehalfCustomerScreen> {
  final _search = TextEditingController();
  final _phone = TextEditingController();
  final _name = TextEditingController();
  bool _seeded = false;

  @override
  void dispose() {
    _search.dispose();
    _phone.dispose();
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final st = ref.watch(onBehalfProvider);
    final ctl = ref.read(onBehalfProvider.notifier);
    final directory = ref.watch(customersProvider);
    if (st.loaded && !_seeded) {
      _seeded = true;
      _phone.text = st.newPhone;
      _name.text = st.newName;
    }
    final query = _search.text;
    final matches =
        ((directory.value ?? const <CustomerEntry>[]).where((e) => e.matches(query)).toList()
              ..sort(CustomerEntry.byName))
            .take(60)
            .toList();

    return NeuScaffold(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (st.restoredAt != null) ...[
            ResumeBanner(
              closedAt: st.restoredAt!,
              what: 'The customer, services and pages',
              onDismiss: ctl.dismissBanner,
            ),
            const SizedBox(height: 12),
          ],
          StepHeader(
            step: 'STEP 1 OF 3 · CUSTOMER',
            title: 'For which customer?',
            onBack: () => context.go('/pickups'),
          ),
          const SizedBox(height: 14),
          NeuBox(
            style: NeuStyle.inset,
            radius: 16,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                Icon(Icons.search_rounded, size: 19, color: c.inkFaint),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    key: const Key('customer-search'),
                    controller: _search,
                    onChanged: (_) => setState(() {}),
                    cursorColor: c.accentInk,
                    style: NeuText.strong(c.ink, size: 15),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 15),
                      hintText: 'Search customers',
                      hintStyle: NeuText.body_(c.inkFaint, size: 15),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Text(
              'Name or phone · list saved on this phone, works offline',
              style: NeuText.body_(c.inkMuted, size: 12),
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: ListView(
              children: [
                if (directory is AsyncError && directory.value == null)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: NeuNote(
                      text:
                          'The customer list comes from the office the first time it is opened '
                          'with a signal. You can still type a new customer below.',
                      icon: Icons.wifi_off_rounded,
                      kind: ChipKind.queued,
                    ),
                  )
                else if (directory.value == null)
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Center(child: CircularProgressIndicator(color: c.accentInk)),
                  ),
                for (final entry in matches) ...[
                  ChoiceRow(
                    title: entry.displayName,
                    subtitle: [
                      entry.isNumberOnly ? 'Unnamed contact' : entry.maskedPhone,
                      entry.addresses.isEmpty
                          ? 'no address'
                          : '${entry.addresses.length} address${entry.addresses.length == 1 ? '' : 'es'}',
                    ].join(' · '),
                    mono: !entry.isNumberOnly,
                    selected: st.customer?.id == entry.id,
                    onTap: () {
                      ctl.pickCustomer(entry);
                      _phone.clear();
                      _name.clear();
                      FocusScope.of(context).unfocus();
                    },
                    trailing: StateChip(
                      entry.hasGst ? 'GST' : 'No GST',
                      kind: entry.hasGst ? ChipKind.synced : ChipKind.blocked,
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                if (directory.value != null && matches.isEmpty && query.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text('Nobody called "$query" on the list.', style: NeuText.body_(c.inkMuted, size: 13)),
                  ),
                NeuBox(
                  style: st.hasNewCustomer ? NeuStyle.inset : NeuStyle.raised,
                  radius: 22,
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('Not in the list? New customer', style: NeuText.label(c.inkSoft, size: 13)),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            flex: 10, // 10 : 13 against the business name, as designed
                            child: LabeledInput(
                              label: 'Mobile',
                              controller: _phone,
                              hint: '10 digits',
                              mono: true,
                              size: 14,
                              keyboardType: TextInputType.phone,
                              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                              onChanged: (v) => ctl.typeNewCustomer(phone: v),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            flex: 13,
                            child: LabeledInput(
                              label: 'Business name',
                              controller: _name,
                              hint: 'As on the jangad',
                              size: 14,
                              onChanged: (v) => ctl.typeNewCustomer(name: v),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'The office links it to the right account when it arrives.',
                        style: NeuText.body_(c.inkMuted, size: 12),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
              ],
            ),
          ),
          NeuButton(
            label: st.hasCustomer ? 'Next: services' : 'Pick a customer',
            kind: NeuButtonKind.primary,
            icon: Icons.arrow_forward_rounded,
            height: 54,
            onPressed: st.hasCustomer ? () => context.push('/onbehalf/services') : null,
          ),
          const SizedBox(height: 18),
        ],
      ),
    );
  }
}

// --------------------------------------------------------------- step 2

class OnBehalfServicesScreen extends ConsumerWidget {
  const OnBehalfServicesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = NeuTheme.of(context);
    final st = ref.watch(onBehalfProvider);
    final ctl = ref.read(onBehalfProvider.notifier);
    final catalog = ref.watch(jobTypesProvider);
    final added = {for (final s in st.services) s.jobTypeId};
    final remaining = (catalog.value ?? const <JobTypeInfo>[]).where((j) => !added.contains(j.id)).toList();
    final noCatalog = catalog is AsyncError && catalog.value == null;

    Future<void> edit(String name, String unit, int jobTypeId, ServiceRequest? existing) async {
      final result = await showAddServiceSheet(context, name: name, unit: unit, existing: existing);
      if (result == null) return;
      if (result.remove) {
        ctl.removeService(jobTypeId);
      } else {
        ctl.putService(
          ServiceRequest(
            jobTypeId: jobTypeId,
            name: name,
            unit: unit,
            quantity: result.quantity,
            remarks: result.remarks,
          ),
        );
      }
    }

    return NeuScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StepHeader(step: 'STEP 2 OF 3 · ${st.customerName.toUpperCase()}', title: 'Services they want'),
          const SizedBox(height: 14),
          Expanded(
            child: ListView(
              children: [
                for (var i = 0; i < st.services.length; i++) ...[
                  NeuBox(
                    style: NeuStyle.raised,
                    radius: 20,
                    padding: const EdgeInsets.fromLTRB(15, 14, 15, 14),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        NeuBox(
                          style: NeuStyle.insetSm,
                          radius: 10,
                          width: 30,
                          height: 30,
                          color: c.ground,
                          child: Center(child: Text('${i + 1}', style: NeuText.data(c.accentInk, size: 12))),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(st.services[i].name, style: NeuText.strong(c.ink, size: 15)),
                              const SizedBox(height: 2),
                              Text(
                                st.services[i].quantity > 0 ? st.services[i].quantityLabel : 'No count yet',
                                style: NeuText.data(c.ink, size: 13),
                              ),
                              if (st.services[i].remarks != null) ...[
                                const SizedBox(height: 3),
                                Text('“${st.services[i].remarks}”', style: NeuText.body_(c.inkMuted, size: 12.5)),
                              ],
                            ],
                          ),
                        ),
                        NeuIconButton(
                          icon: Icons.edit_outlined,
                          size: 38,
                          tooltip: 'Edit ${st.services[i].name}',
                          onPressed: () =>
                              edit(st.services[i].name, st.services[i].unit, st.services[i].jobTypeId, st.services[i]),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                const SizedBox(height: 4),
                SectionLabel(st.services.isEmpty ? 'Pick what they want' : 'Add one more'),
                const SizedBox(height: 10),
                if (noCatalog)
                  const NeuNote(
                    text:
                        'The list of services comes from the office the first time, with a '
                        'signal. You can post the jangad without them; the office adds them.',
                    icon: Icons.wifi_off_rounded,
                    kind: ChipKind.queued,
                  )
                else
                  NeuBox(
                    style: NeuStyle.inset,
                    radius: 20,
                    padding: const EdgeInsets.all(6),
                    child: Column(
                      children: [
                        if (catalog.value == null)
                          Padding(
                            padding: const EdgeInsets.all(18),
                            child: CircularProgressIndicator(color: c.accentInk),
                          ),
                        for (var i = 0; i < remaining.length; i++)
                          InkWell(
                            onTap: () => edit(remaining[i].name, remaining[i].unit, remaining[i].id, null),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                              decoration: i == remaining.length - 1
                                  ? null
                                  : BoxDecoration(
                                      border: Border(bottom: BorderSide(color: c.hairline)),
                                    ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      remaining[i].name,
                                      style: NeuText.body_(c.ink, size: 14.5, w: FontWeight.w600),
                                    ),
                                  ),
                                  NeuBox(
                                    style: NeuStyle.raisedSm,
                                    radius: 12,
                                    width: 34,
                                    height: 34,
                                    child: Icon(Icons.add_rounded, size: 19, color: c.accentInk),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: 14),
              ],
            ),
          ),
          NeuButton(
            label: st.services.isEmpty && !noCatalog ? 'Pick at least one service' : 'Next: jangad photo',
            kind: NeuButtonKind.primary,
            icon: Icons.arrow_forward_rounded,
            height: 54,
            onPressed: st.services.isEmpty && !noCatalog ? null : () => context.push('/onbehalf/pages'),
          ),
          const SizedBox(height: 18),
        ],
      ),
    );
  }
}

// --------------------------------------------------------------- step 3

class OnBehalfPagesScreen extends ConsumerStatefulWidget {
  const OnBehalfPagesScreen({super.key});

  @override
  ConsumerState<OnBehalfPagesScreen> createState() => _OnBehalfPagesScreenState();
}

class _OnBehalfPagesScreenState extends ConsumerState<OnBehalfPagesScreen> {
  late final _manual = TextEditingController(text: ref.read(onBehalfProvider).manual);
  late final _note = TextEditingController(text: ref.read(onBehalfProvider).note);
  bool _busy = false;
  String? _warning;

  @override
  void dispose() {
    _manual.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _addPage() async {
    final s = ref.read(servicesProvider);
    if (!await ImagePipeline.hasRoom()) {
      setState(() => _warning = 'This phone is nearly out of room for photos.');
      return;
    }
    final file = await s.images.capture();
    if (file == null) return;
    final staged = await s.uploads.stage(file, pageIndex: ref.read(onBehalfProvider).pages.length);
    await ref.read(onBehalfProvider.notifier).addPage(staged);
    if (mounted) setState(() => _warning = null);
  }

  Future<void> _post() async {
    setState(() => _busy = true);
    final item = await ref.read(onBehalfProvider.notifier).post();
    await ref.read(syncProvider.notifier).refreshCounters();
    unawaited(ref.read(syncProvider.notifier).syncNow(flushFirst: true));
    if (!mounted) return;
    context.go('/onbehalf/posted/${item.localId}');
  }

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final st = ref.watch(onBehalfProvider);
    final ctl = ref.read(onBehalfProvider.notifier);
    final addresses = st.customer?.addresses ?? const <CustomerAddress>[];
    final ready = st.pages.isNotEmpty && st.hasAddress;

    return NeuScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StepHeader(step: 'STEP 3 OF 3 · ${st.customerName.toUpperCase()}', title: 'Jangad pages'),
          const SizedBox(height: 14),
          Expanded(
            child: ListView(
              children: [
                SizedBox(
                  height: 182,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: st.pages.length + 1,
                    separatorBuilder: (_, _) => const SizedBox(width: 12),
                    itemBuilder: (_, i) {
                      if (i == st.pages.length) {
                        return NeuBox(
                          style: NeuStyle.inset,
                          radius: 18,
                          width: 104,
                          onTap: _addPage,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.photo_camera_outlined, size: 24, color: c.accentInk),
                              const SizedBox(height: 8),
                              Text('Add page', style: NeuText.label(c.accentInk, size: 12.5)),
                            ],
                          ),
                        );
                      }
                      final page = st.pages[i];
                      return NeuBox(
                        style: NeuStyle.raised,
                        radius: 18,
                        width: 104,
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
                                      onTap: () => ctl.removePage(page),
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
                            ),
                            const SizedBox(height: 6),
                            Text('Page ${i + 1}', style: NeuText.data(c.inkMuted, size: 11)),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Kept on this phone until the office has them. Long side ${Env.imageLongEdge} px '
                  '— the handwriting stays readable.',
                  style: NeuText.body_(c.inkMuted, size: 12),
                ),
                if (_warning != null) ...[
                  const SizedBox(height: 12),
                  NeuNote(text: _warning!, kind: ChipKind.attention, icon: Icons.warning_amber_rounded),
                ],
                const SizedBox(height: 16),
                const SectionLabel('Collect from'),
                const SizedBox(height: 10),
                for (final a in addresses) ...[
                  ChoiceRow(
                    title: a.label.isEmpty ? oneLineAddress(a.address) : a.label,
                    subtitle: a.label.isEmpty ? null : oneLineAddress(a.address),
                    selected: !st.manualMode && st.addressId == a.id,
                    onTap: () => ctl.chooseAddress(a),
                  ),
                  const SizedBox(height: 10),
                ],
                ChoiceRow(
                  title: addresses.isEmpty ? 'Type the pickup address' : 'Somewhere else',
                  selected: st.manualMode,
                  onTap: ctl.chooseManual,
                ),
                if (st.manualMode) ...[
                  const SizedBox(height: 10),
                  LabeledInput(
                    label: 'Address',
                    controller: _manual,
                    hint: 'Shop 14, Bhagal, near Chowk Bazaar',
                    maxLines: 2,
                    onChanged: ctl.setManual,
                  ),
                ],
                const SizedBox(height: 14),
                LabeledInput(
                  label: 'Note for the office (optional)',
                  controller: _note,
                  hint: 'e.g. hand over at the gate',
                  onChanged: ctl.setNote,
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
          NeuButton(
            label: ready
                ? 'Post the jangad'
                : st.pages.isEmpty
                ? 'Photograph the jangad first'
                : 'Choose where to collect from',
            kind: NeuButtonKind.primary,
            height: 54,
            busy: _busy,
            onPressed: ready ? _post : null,
          ),
          const SizedBox(height: 18),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- posted

final _postedProvider = FutureProvider.autoDispose.family<(OutboxItem?, Map<String, dynamic>?), String>((
  ref,
  localId,
) async {
  ref.watch(dataRevisionProvider);
  final s = ref.read(servicesProvider);
  return (await s.outbox.byId(localId), await s.kv.readJson(OutboxFlusher.postedKey(localId)));
});

/// "Saved on this phone": what was posted, and the offer to collect it now.
class OnBehalfPostedScreen extends ConsumerWidget {
  const OnBehalfPostedScreen({super.key, required this.localId});
  final String localId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = NeuTheme.of(context);
    final data = ref.watch(_postedProvider(localId)).value;
    final online = ref.watch(syncProvider.select((s) => s.online));
    final open = ref.watch(_dependentsProvider(localId)).value ?? const <OutboxItem>[];
    if (data == null) return const NeuScaffold(child: SizedBox.shrink());
    final (item, landed) = data;
    final reference = landed?['reference'] as String?;
    final meta =
        item?.meta ??
        (landed?['meta'] is Map ? Map<String, dynamic>.from(landed!['meta'] as Map) : const <String, dynamic>{});
    final postedAt = item?.occurredAt ?? DateTime.tryParse('${landed?['occurred_at'] ?? ''}');
    final services = ServiceRequest.listFromDraft(meta['services']);
    final collectQueued = open.any((o) => o.kind == IntentKind.confirmPickup);

    if (item == null && landed == null) {
      return NeuScaffold(
        child: Column(
          children: [
            ScreenHeader(title: 'Jangad', onBack: () => context.go('/pickups')),
            const Spacer(),
            Text('This jangad is no longer on this phone.', style: NeuText.body_(c.inkMuted, size: 14)),
            const Spacer(),
          ],
        ),
      );
    }

    final atOffice = item == null;
    final customer = '${meta['customer_name'] ?? 'the customer'}';

    return NeuScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NeuBox(
            style: NeuStyle.inset,
            radius: 16,
            padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
            child: Row(
              children: [
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(color: online ? c.syncedInk : c.inkFaint, shape: BoxShape.circle),
                ),
                const SizedBox(width: 9),
                Text(
                  online ? 'Online' : 'Offline',
                  style: NeuText.label(online ? c.syncedInk : c.blockedInk, size: 12),
                ),
                const SizedBox(width: 9),
                Container(width: 1, height: 13, color: c.hairline),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    atOffice ? 'With the office' : 'Sends by itself when online',
                    style: NeuText.body_(c.inkMuted, size: 12),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                const SizedBox(height: 26),
                Center(
                  child: NeuBox(
                    style: NeuStyle.raised,
                    radius: 30,
                    width: 92,
                    height: 92,
                    child: Icon(
                      atOffice ? Icons.check_rounded : Icons.phone_android_rounded,
                      size: 38,
                      color: atOffice ? c.syncedInk : c.queuedInk,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  atOffice ? 'With the office' : 'Saved on this phone',
                  textAlign: TextAlign.center,
                  style: NeuText.title(c.ink, size: 24),
                ),
                const SizedBox(height: 10),
                Text(
                  atOffice
                      ? 'The jangad for $customer is in the pickup list, under its own number.'
                      : 'The jangad for $customer is in your Pickups. It goes to the office, with '
                            'the time you posted it, as soon as there is a signal.',
                  textAlign: TextAlign.center,
                  style: NeuText.body_(c.inkMuted, size: 14),
                ),
                const SizedBox(height: 18),
                NeuBox(
                  style: NeuStyle.raised,
                  radius: 22,
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                  child: Column(
                    children: [
                      SummaryRow(label: 'Customer', value: customer),
                      const SizedBox(height: 9),
                      SummaryRow(
                        label: 'Services',
                        value: services.isEmpty
                            ? '—'
                            : ServiceRequest.summary(services)
                                  .replaceFirst(' services', '')
                                  .replaceFirst(' service', ''),
                      ),
                      const SizedBox(height: 9),
                      SummaryRow(label: 'Pages', value: '${meta['pages'] ?? '—'}'),
                      const SizedBox(height: 9),
                      SummaryRow(label: 'Posted', value: dayAndTime(postedAt?.toLocal()), mono: true),
                      const SizedBox(height: 9),
                      SummaryRow(
                        label: 'Number',
                        child: reference != null
                            ? Text(reference, style: NeuText.data(c.accentInk, size: 13))
                            : const StateChip('Given by the office', kind: ChipKind.queued),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                if (item?.state == OutboxState.needsAttention)
                  NeuNote(
                    title: 'The office refused it',
                    text: item!.lastErrorMessage ?? 'Open the queue to see why.',
                    icon: Icons.warning_amber_rounded,
                    kind: ChipKind.attention,
                  )
                else
                  NeuNote(
                    text: collectQueued
                        ? 'Collected on this phone. Both steps go together, in order, once you are online.'
                        : atOffice
                        ? 'Taking the parcel with you? Collect it now — the pages you took go with it.'
                        : 'Taking the parcel with you? Collect it now — both steps go together, in '
                              'order, once you are online.',
                    icon: Icons.inventory_2_outlined,
                    kind: collectQueued ? ChipKind.queued : ChipKind.accent,
                  ),
                const SizedBox(height: 16),
              ],
            ),
          ),
          if (!collectQueued && item?.state != OutboxState.needsAttention) ...[
            NeuButton(
              label: 'Collect it now',
              kind: NeuButtonKind.primary,
              icon: Icons.inventory_2_outlined,
              height: 54,
              onPressed: () => context.push('/onbehalf/collect/$localId'),
            ),
            const SizedBox(height: 12),
          ],
          NeuButton(
            label: collectQueued ? 'Back to pickups' : 'Leave it in the pickup list',
            height: 52,
            onPressed: () => context.go('/pickups'),
          ),
          const SizedBox(height: 18),
        ],
      ),
    );
  }
}

final _dependentsProvider = FutureProvider.autoDispose.family<List<OutboxItem>, String>((ref, localId) {
  ref.watch(dataRevisionProvider);
  return ref.read(servicesProvider).outbox.dependentsOf(localId);
});
