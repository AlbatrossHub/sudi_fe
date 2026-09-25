import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_error.dart';
import '../../core/clock/odoo_time.dart';
import '../../core/outbox/outbox.dart';
import '../../core/services.dart';
import '../../core/session.dart';
import '../../core/sync_status.dart';
import '../../core/uploads/image_pipeline.dart';
import '../../models/docs.dart';
import '../../ui/theme/neu.dart';
import '../../ui/widgets/neu_box.dart';
import '../../ui/widgets/neu_widgets.dart';
import '../../ui/widgets/powered_by.dart';
import '../field/sign_in_screens.dart';
import '../../ui/widgets/status_strip.dart';

/// Pages staged for the jangad being built, and the address chosen for it.
class JangadDraft extends Notifier<JangadDraftState> {
  @override
  JangadDraftState build() => const JangadDraftState();

  void addPage(UploadItem page) =>
      state = state.copyWith(pages: [...state.pages, page]);

  void removePage(String localId) =>
      state = state.copyWith(pages: state.pages.where((p) => p.localId != localId).toList());

  void chooseSaved(AddressSuggestion address) =>
      state = JangadDraftState(pages: state.pages, savedAddress: address);

  void chooseManual(String text) =>
      state = JangadDraftState(pages: state.pages, manualAddress: text);

  void clear() => state = const JangadDraftState();
}

class JangadDraftState {
  const JangadDraftState({this.pages = const [], this.savedAddress, this.manualAddress});

  final List<UploadItem> pages;
  final AddressSuggestion? savedAddress;
  final String? manualAddress;

  bool get hasAddress => savedAddress != null || (manualAddress?.isNotEmpty ?? false);
  String get addressLabel => savedAddress?.label ?? manualAddress ?? 'Choose where to collect from';

  JangadDraftState copyWith({List<UploadItem>? pages}) => JangadDraftState(
        pages: pages ?? this.pages,
        savedAddress: savedAddress,
        manualAddress: manualAddress,
      );
}

final jangadDraftProvider =
    NotifierProvider<JangadDraft, JangadDraftState>(JangadDraft.new);

final addressesProvider = FutureProvider.autoDispose<List<AddressSuggestion>>((ref) async {
  try {
    return await ref.read(servicesProvider).auth.addresses();
  } on ApiError {
    // Degrades offline: the list may be missing, and an address can always be
    // typed instead.
    return const [];
  }
});

final submissionsProvider = FutureProvider.autoDispose<List<Map<String, Object?>>>((ref) {
  ref.watch(dataRevisionProvider);
  return ref.read(servicesProvider).customer.submissions();
});

// ---------------------------------------------------------------------------

class PhoneScreen extends ConsumerStatefulWidget {
  const PhoneScreen({super.key});

  @override
  ConsumerState<PhoneScreen> createState() => _PhoneScreenState();
}

class _PhoneScreenState extends ConsumerState<PhoneScreen> {
  final _phone = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final phone = _phone.text.replaceAll(RegExp(r'\s+'), '');
    try {
      await ref.read(servicesProvider).auth.requestOtp(phone);
      if (mounted) context.push('/otp?phone=$phone');
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    return NeuScaffold(
      padding: const EdgeInsets.fromLTRB(28, 48, 28, 24),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: NeuBox(
                style: NeuStyle.raised,
                radius: 28,
                width: 84,
                height: 84,
                child: Center(child: Icon(Icons.diamond_outlined, size: 40, color: c.accentInk)),
              ),
            ),
            const SizedBox(height: 18),
            Text('Send your jangad', textAlign: TextAlign.center, style: NeuText.title(c.ink, size: 27)),
            const SizedBox(height: 7),
            Text(
              'Photograph the slip, pick a pickup address,\nand we collect it.',
              textAlign: TextAlign.center,
              style: NeuText.body_(c.inkMuted, size: 14),
            ),
            const SizedBox(height: 40),
            Text('Mobile number', style: NeuText.label(c.inkMuted, size: 12)),
            const SizedBox(height: 9),
            NeuBox(
              style: NeuStyle.inset,
              radius: 18,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Row(
                children: [
                  Text('+91', style: NeuText.data(c.inkMuted, size: 15)),
                  const SizedBox(width: 12),
                  Container(width: 1, height: 20, color: c.hairline),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      // Without this the Send button reads a stale
                      // `_phone.text` and stays disabled however much you type.
                      onChanged: (_) => setState(() {}),
                      cursorColor: c.accentInk,
                      style: NeuText.data(c.ink, size: 16),
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(vertical: 16),
                        hintText: '98765 43210',
                        hintStyle: NeuText.data(c.inkFaint, size: 16),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              NeuNote(text: _error!, kind: ChipKind.attention, icon: Icons.warning_amber_rounded),
            ],
            const SizedBox(height: 20),
            NeuButton(
              label: 'Send code on WhatsApp',
              kind: NeuButtonKind.primary,
              icon: Icons.chat_bubble_outline_rounded,
              busy: _busy,
              onPressed: _phone.text.length >= 10 ? _send : null,
            ),
            const SizedBox(height: 24),
            const NeuNote(
              title: 'The code comes on WhatsApp',
              text: 'Not by SMS. Check that the number you type has WhatsApp on it.',
              icon: Icons.chat_bubble_outline_rounded,
              kind: ChipKind.accent,
            ),
            const SizedBox(height: 24),
            Text(
              'New here? The same number signs you up.',
              textAlign: TextAlign.center,
              style: NeuText.body_(c.inkMuted, size: 12),
            ),
            const SizedBox(height: 22),
            Center(child: PoweredBy(onTap: () => showPoweredBySheet(context, ref))),
          ],
        ),
      ),
    );
  }
}

class OtpScreen extends ConsumerStatefulWidget {
  const OtpScreen({super.key, required this.phone});
  final String phone;

  @override
  ConsumerState<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends ConsumerState<OtpScreen> {
  final _code = TextEditingController();
  Timer? _tick;
  int _resendIn = 60;
  int _expiresIn = 300;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        if (_resendIn > 0) _resendIn--;
        if (_expiresIn > 0) _expiresIn--;
      });
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _code.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final verdict = await ref.read(servicesProvider).auth.verifyOtp(
            phone: widget.phone,
            code: _code.text.trim(),
          );
      if (!mounted) return;
      if (verdict.registrationRequired) {
        context.push('/register?token=${verdict.registrationToken}');
      } else {
        await ref.read(sessionProvider.notifier).afterCustomerAuth();
      }
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resend() async {
    try {
      final challenge = await ref.read(servicesProvider).auth.requestOtp(widget.phone);
      if (mounted) {
        setState(() {
          _resendIn = challenge.resendAfter;
          _expiresIn = challenge.expiresIn;
          _error = null;
        });
      }
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    return NeuScaffold(
      padding: const EdgeInsets.fromLTRB(28, 20, 28, 24),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: NeuIconButton(
                icon: Icons.arrow_back_rounded,
                onPressed: () => context.pop(),
                tooltip: 'Back',
              ),
            ),
            const SizedBox(height: 30),
            Text('Enter the code', style: NeuText.title(c.ink, size: 26)),
            const SizedBox(height: 10),
            Text.rich(
              TextSpan(
                style: NeuText.body_(c.inkMuted, size: 14),
                children: [
                  const TextSpan(text: 'Sent on WhatsApp to '),
                  TextSpan(text: '+91 ${widget.phone}', style: NeuText.data(c.ink, size: 14)),
                ],
              ),
            ),
            const SizedBox(height: 26),
            NeuBox(
              style: NeuStyle.inset,
              radius: 18,
              padding: const EdgeInsets.symmetric(horizontal: 22),
              child: TextField(
                controller: _code,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(6),
                ],
                textAlign: TextAlign.center,
                cursorColor: c.accentInk,
                onChanged: (v) {
                  setState(() {});
                  if (v.length == 6) _verify();
                },
                style: NeuText.data(c.ink, size: 26).copyWith(letterSpacing: 10),
                decoration: InputDecoration(
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 18),
                  hintText: '······',
                  hintStyle: NeuText.data(c.inkFaint, size: 26).copyWith(letterSpacing: 10),
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              NeuNote(text: _error!, kind: ChipKind.attention, icon: Icons.warning_amber_rounded),
            ],
            const SizedBox(height: 18),
            NeuBox(
              style: NeuStyle.inset,
              radius: 17,
              padding: const EdgeInsets.fromLTRB(17, 14, 17, 14),
              child: Row(
                children: [
                  Icon(Icons.schedule_rounded, size: 17, color: c.inkMuted),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Text(
                      _expiresIn > 0
                          ? 'The code expires in ${_mmss(_expiresIn)}'
                          : 'That code has expired — send a new one',
                      style: NeuText.body_(c.inkMuted, size: 13),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            NeuButton(
              label: 'Verify',
              kind: NeuButtonKind.primary,
              busy: _busy,
              onPressed: _code.text.length == 6 ? _verify : null,
            ),
            const SizedBox(height: 12),
            NeuButton(
              label: _resendIn > 0 ? 'Send again in ${_mmss(_resendIn)}' : 'Send the code again',
              icon: Icons.refresh_rounded,
              height: 52,
              onPressed: _resendIn > 0 ? null : _resend,
            ),
            const SizedBox(height: 22),
            const NeuNote(
              text: 'No message? It may be a WhatsApp problem at our end rather than a wrong '
                  'number — we say so plainly if the send failed.',
              icon: Icons.warning_amber_rounded,
              kind: ChipKind.queued,
            ),
          ],
        ),
      ),
    );
  }

  static String _mmss(int seconds) =>
      '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key, required this.token});
  final String token;

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _name = TextEditingController();
  final _gst = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _gst.dispose();
    super.dispose();
  }

  Future<void> _submit({required bool withGst}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final vat = _gst.text.trim();
      await ref.read(servicesProvider).auth.register(
            registrationToken: widget.token,
            name: _name.text.trim(),
            vat: withGst && vat.isNotEmpty ? vat : null,
          );
      await ref.read(sessionProvider.notifier).afterCustomerAuth();
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    return NeuScaffold(
      padding: const EdgeInsets.fromLTRB(28, 20, 28, 24),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: NeuIconButton(
                icon: Icons.arrow_back_rounded,
                onPressed: () => context.pop(),
                tooltip: 'Back',
              ),
            ),
            const SizedBox(height: 26),
            Text('Who are we collecting from?', style: NeuText.title(c.ink, size: 25)),
            const SizedBox(height: 9),
            Text(
              'The number is verified. We need a name for the receipt.',
              style: NeuText.body_(c.inkMuted, size: 14),
            ),
            const SizedBox(height: 26),
            NeuField(
              controller: _name,
              label: 'Name or firm',
              required_: true,
              hint: 'Kiran Gems',
              icon: Icons.apartment_rounded,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 20),
            NeuField(
              controller: _gst,
              label: 'GST number',
              hint: '24AAACK1234M1ZP',
              icon: Icons.badge_outlined,
              textStyle: NeuText.data(c.ink, size: 14),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              NeuNote(text: _error!, kind: ChipKind.attention, icon: Icons.warning_amber_rounded),
            ],
            const SizedBox(height: 18),
            const NeuNote(
              text: 'Your company details are filled in from the GST number. You can leave it '
                  'out and add it whenever you like.',
              icon: Icons.info_outline_rounded,
              kind: ChipKind.accent,
            ),
            const SizedBox(height: 22),
            NeuButton(
              label: 'Continue',
              kind: NeuButtonKind.primary,
              busy: _busy,
              onPressed: _name.text.trim().isEmpty ? null : () => _submit(withGst: true),
            ),
            const SizedBox(height: 12),
            NeuButton(
              label: 'Skip the GST number',
              height: 52,
              onPressed: _name.text.trim().isEmpty ? null : () => _submit(withGst: false),
            ),
          ],
        ),
      ),
    );
  }
}

class JangadScreen extends ConsumerStatefulWidget {
  const JangadScreen({super.key});

  @override
  ConsumerState<JangadScreen> createState() => _JangadScreenState();
}

class _JangadScreenState extends ConsumerState<JangadScreen> {
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
    ref.read(jangadDraftProvider.notifier).addPage(staged);
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
    );
    ref.read(jangadDraftProvider.notifier).clear();
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
          ScreenHeader(
            title: 'New jangad',
            subtitle: ref.watch(sessionProvider).me?.name ?? 'Your receipts',
            // Two actions, because until now the customer app had no account
            // entry at all: no way to see who you are signed in as, no way to
            // reach your other phones, and no way out except a link on the
            // lock screen.
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                NeuIconButton(
                  icon: Icons.receipt_long_outlined,
                  onPressed: () => context.push('/submitted'),
                  tooltip: 'What you have sent',
                ),
                const SizedBox(width: 10),
                NeuIconButton(
                  icon: Icons.person_outline_rounded,
                  onPressed: () => showAccountSheet(context, ref),
                  tooltip: 'Account',
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          StatusStrip(onQueueTap: () => context.push('/submitted')),
          const SizedBox(height: 16),
          Expanded(
            child: ListView(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('Pages', style: NeuText.label(c.ink, size: 13)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('we keep the order you shoot them in',
                          style: NeuText.body_(c.inkMuted, size: 12)),
                    ),
                    Text('${draft.pages.length}', style: NeuText.data(c.accentInk)),
                  ],
                ),
                const SizedBox(height: 12),
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 13,
                  crossAxisSpacing: 13,
                  childAspectRatio: 0.95,
                  children: [
                    for (var i = 0; i < draft.pages.length; i++)
                      Stack(
                        children: [
                          Positioned.fill(
                            child: NeuBox(
                              style: NeuStyle.inset,
                              radius: 20,
                              padding: const EdgeInsets.all(10),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: Image.file(
                                  File(draft.pages[i].filePath),
                                  fit: BoxFit.cover,
                                  width: double.infinity,
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            left: 14,
                            top: 14,
                            child: Container(
                              width: 24,
                              height: 24,
                              decoration: BoxDecoration(
                                color: c.accentInk,
                                borderRadius: BorderRadius.circular(9),
                              ),
                              child: Center(
                                child: Text('${i + 1}', style: NeuText.label(c.onAccent, size: 12)),
                              ),
                            ),
                          ),
                          Positioned(
                            right: 12,
                            top: 12,
                            child: GestureDetector(
                              onTap: () async {
                                await ref
                                    .read(servicesProvider)
                                    .uploads
                                    .discard(draft.pages[i].localId);
                                ref
                                    .read(jangadDraftProvider.notifier)
                                    .removePage(draft.pages[i].localId);
                              },
                              child: Container(
                                width: 26,
                                height: 26,
                                decoration: BoxDecoration(
                                  color: c.ground,
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(color: c.shadowDark, offset: const Offset(2, 2), blurRadius: 5),
                                  ],
                                ),
                                child: Center(
                                  child: Icon(Icons.close_rounded, size: 15, color: c.inkMuted),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
                if (draft.pages.isNotEmpty) const SizedBox(height: 13),
                NeuButton(
                  label: draft.pages.isEmpty ? 'Photograph the jangad' : 'Photograph another page',
                  icon: Icons.photo_camera_outlined,
                  height: 62,
                  onPressed: _addPage,
                ),
                if (_warning != null) ...[
                  const SizedBox(height: 13),
                  NeuNote(text: _warning!, kind: ChipKind.attention, icon: Icons.warning_amber_rounded),
                ],
                const SizedBox(height: 14),
                NeuBox(
                  style: NeuStyle.raised,
                  radius: 20,
                  padding: const EdgeInsets.fromLTRB(17, 16, 17, 16),
                  onTap: () => context.push('/jangad/address'),
                  child: Row(
                    children: [
                      NeuBox(
                        style: NeuStyle.insetSm,
                        radius: 13,
                        width: 38,
                        height: 38,
                        child: Center(child: Icon(Icons.place_outlined, size: 18, color: c.accentInk)),
                      ),
                      const SizedBox(width: 13),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('COLLECT FROM', style: NeuText.label(c.inkFaint, size: 11)),
                            const SizedBox(height: 4),
                            Text(
                              draft.hasAddress
                                  ? oneLineAddress(draft.addressLabel)
                                  : draft.addressLabel,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: NeuText.strong(
                                draft.hasAddress ? c.ink : c.inkFaint,
                                size: 14,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right_rounded, size: 20, color: c.accentInk),
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
            padding: const EdgeInsets.fromLTRB(15, 13, 15, 13),
            child: Row(
              children: [
                Icon(Icons.check_rounded, size: 16, color: c.syncedInk),
                const SizedBox(width: 11),
                Expanded(
                  child: Text(
                    'Send it from a basement if you like. It goes when you have signal.',
                    style: NeuText.body_(c.inkMuted, size: 12),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          NeuButton(
            label: ready
                ? 'Send ${draft.pages.length} page${draft.pages.length == 1 ? '' : 's'}'
                : draft.pages.isEmpty
                    ? 'Photograph the jangad first'
                    : 'Choose where to collect from',
            kind: NeuButtonKind.primary,
            icon: Icons.arrow_forward_rounded,
            busy: _busy,
            // A button that names the next step should take you there rather
            // than sit disabled with the answer in its own label.
            onPressed: ready
                ? _submit
                : draft.pages.isEmpty
                    ? null
                    : () => context.push('/jangad/address'),
          ),
          const SizedBox(height: 18),
        ],
      ),
    );
  }
}

class AddressScreen extends ConsumerStatefulWidget {
  const AddressScreen({super.key});

  @override
  ConsumerState<AddressScreen> createState() => _AddressScreenState();
}

class _AddressScreenState extends ConsumerState<AddressScreen> {
  final _manual = TextEditingController();

  @override
  void initState() {
    super.initState();
    _manual.text = ref.read(jangadDraftProvider).manualAddress ?? '';
  }

  @override
  void dispose() {
    _manual.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final draft = ref.watch(jangadDraftProvider);
    final saved = ref.watch(addressesProvider);
    final online = ref.watch(syncProvider).online;

    return NeuScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ScreenHeader(
            title: 'Collect from',
            subtitle: 'Where should we send someone?',
            onBack: () => context.pop(),
          ),
          const SizedBox(height: 18),
          if (!online)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: NeuNote(
                text: 'Your saved list needs a connection. You can always type an address.',
                icon: Icons.wifi_off_rounded,
                kind: ChipKind.queued,
              ),
            ),
          Expanded(
            child: ListView(
              children: [
                Text('Saved addresses', style: NeuText.label(c.ink, size: 13)),
                const SizedBox(height: 12),
                switch (saved) {
                  // Offline the fetch yields nothing, which is not the same
                  // as having nothing saved. "Nothing saved yet" next to the
                  // banner above reads as "your address was deleted".
                  AsyncData(:final value) when value.isEmpty => Text(
                      online
                          ? 'Nothing saved yet.'
                          : 'We cannot reach your saved list right now.',
                      style: NeuText.body_(c.inkMuted, size: 13),
                    ),
                  AsyncData(:final value) => Column(
                      children: [
                        for (final address in value) ...[
                          _addressTile(
                            context,
                            title: address.name.isEmpty ? address.address : address.name,
                            subtitle: address.address,
                            isDefault: address.isDefault,
                            selected: draft.savedAddress?.id == address.id,
                            onTap: () {
                              ref.read(jangadDraftProvider.notifier).chooseSaved(address);
                              _manual.clear();
                            },
                          ),
                          const SizedBox(height: 11),
                        ],
                      ],
                    ),
                  AsyncError() => Text(
                      'The saved list could not be loaded.',
                      style: NeuText.body_(c.inkMuted, size: 13),
                    ),
                  _ => Center(child: CircularProgressIndicator(color: c.accentInk)),
                },
                const SizedBox(height: 22),
                Row(
                  children: [
                    Expanded(child: Divider(color: c.hairline)),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: Text('or', style: NeuText.label(c.inkFaint, size: 12)),
                    ),
                    Expanded(child: Divider(color: c.hairline)),
                  ],
                ),
                const SizedBox(height: 22),
                NeuField(
                  controller: _manual,
                  label: 'Type an address',
                  hint: 'Shop 14, Bhagal, near Chowk Bazaar, Surat',
                  maxLines: 3,
                  onChanged: (v) {
                    if (v.trim().isNotEmpty) {
                      ref.read(jangadDraftProvider.notifier).chooseManual(v.trim());
                    }
                  },
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
          NeuButton(
            label: 'Use this address',
            kind: NeuButtonKind.primary,
            onPressed: draft.hasAddress ? () => context.pop() : null,
          ),
          const SizedBox(height: 18),
        ],
      ),
    );
  }

  Widget _addressTile(
    BuildContext context, {
    required String title,
    required String subtitle,
    required bool isDefault,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final c = NeuTheme.of(context);
    return NeuBox(
      style: selected ? NeuStyle.insetSm : NeuStyle.raised,
      radius: 19,
      padding: const EdgeInsets.fromLTRB(17, 16, 17, 16),
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            margin: const EdgeInsets.only(top: 2),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected ? c.accent : c.ground,
              boxShadow: selected
                  ? null
                  : [
                      BoxShadow(color: c.shadowDark, offset: const Offset(2, 2), blurRadius: 4),
                      BoxShadow(color: c.shadowLight, offset: const Offset(-2, -2), blurRadius: 4),
                    ],
            ),
            child: selected ? Icon(Icons.check_rounded, size: 13, color: c.onAccent) : null,
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: NeuText.strong(c.ink, size: 15),
                      ),
                    ),
                    if (isDefault) ...[
                      const SizedBox(width: 8),
                      const StateChip('USUAL', kind: ChipKind.synced),
                    ],
                  ],
                ),
                if (subtitle.isNotEmpty && subtitle != title) ...[
                  const SizedBox(height: 5),
                  Text(
                    oneLineAddress(subtitle),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: NeuText.body_(c.inkMuted, size: 13),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The `reference` is the whole acknowledgement — there is no receipt list to
/// send the customer to. Offline there is no reference yet, and this screen
/// says so plainly rather than inventing a placeholder.
class SubmittedScreen extends ConsumerWidget {
  const SubmittedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = NeuTheme.of(context);
    final rows = ref.watch(submissionsProvider).value ?? const <Map<String, Object?>>[];
    // Ordered `occurred_at DESC`, so row zero is the jangad the customer just
    // sent. The hero has to be *that* row and no other: picking the newest row
    // that happens to carry a reference means that offline -- when the new one
    // has none yet -- the screen says "We have it" over the *previous*
    // jangad's number. A customer who writes that number down is holding
    // somebody else's reference, and it changes under them on the next flush.
    final newest = rows.isEmpty ? null : rows.first;
    final latest = newest != null && newest['reference'] != null ? newest : null;
    final queued = rows.skip(1).where((r) => r['reference'] == null).toList();

    return NeuScaffold(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: NeuIconButton(
              icon: Icons.arrow_back_rounded,
              onPressed: () => context.go('/jangad'),
              tooltip: 'Back',
            ),
          ),
          const SizedBox(height: 22),
          Expanded(
            child: ListView(
              children: [
                if (latest != null) ...[
                  Center(
                    child: NeuBox(
                      style: NeuStyle.raised,
                      radius: 34,
                      width: 98,
                      height: 98,
                      child: Center(
                        child: NeuBox(
                          style: NeuStyle.insetSm,
                          radius: 24,
                          width: 66,
                          height: 66,
                          color: c.accentInk,
                          child: Center(
                            child: Icon(Icons.check_rounded, size: 34, color: c.onAccent),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text('We have it', textAlign: TextAlign.center, style: NeuText.title(c.ink, size: 27)),
                  const SizedBox(height: 10),
                  Text(
                    'Keep this reference. Quote it if you call the office.',
                    textAlign: TextAlign.center,
                    style: NeuText.body_(c.inkMuted, size: 14),
                  ),
                  const SizedBox(height: 22),
                  NeuBox(
                    style: NeuStyle.inset,
                    radius: 24,
                    padding: const EdgeInsets.all(22),
                    child: Column(
                      children: [
                        Text('YOUR REFERENCE', style: NeuText.label(c.inkFaint, size: 11)),
                        const SizedBox(height: 10),
                        Text('${latest['reference']}', style: NeuText.data(c.accentInk, size: 26)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  NeuBox(
                    style: NeuStyle.raised,
                    radius: 22,
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      children: [
                        _line(context, Icons.photo_library_outlined, _pagesSent(latest)),
                        Divider(color: c.hairline, height: 26),
                                        _line(context, Icons.place_outlined,
                            oneLineAddress('${latest['address'] ?? ''}')),
                        Divider(color: c.hairline, height: 26),
                        _line(
                          context,
                          Icons.schedule_rounded,
                          'Sent at ${OdooTime.hm(DateTime.tryParse('${latest['submitted_at']}'))}',
                        ),
                      ],
                    ),
                  ),
                ] else if (newest != null) ...[
                  // Captured but not yet acknowledged. Same shape as the sent
                  // hero so the screen does not jump when the reference lands,
                  // but it never claims the office has it.
                  Center(
                    child: NeuBox(
                      style: NeuStyle.raised,
                      radius: 34,
                      width: 98,
                      height: 98,
                      child: Center(
                        child: NeuBox(
                          style: NeuStyle.insetSm,
                          radius: 24,
                          width: 66,
                          height: 66,
                          color: c.queuedFill,
                          child: Center(
                            child: Icon(Icons.schedule_rounded, size: 34, color: c.queuedInk),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text('Saved on your phone',
                      textAlign: TextAlign.center, style: NeuText.title(c.ink, size: 27)),
                  const SizedBox(height: 10),
                  Text(
                    'It sends the moment you have signal. Your reference '
                    'appears here then.',
                    textAlign: TextAlign.center,
                    style: NeuText.body_(c.inkMuted, size: 14),
                  ),
                  const SizedBox(height: 22),
                  NeuBox(
                    style: NeuStyle.raised,
                    radius: 22,
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      children: [
                        _line(context, Icons.photo_library_outlined, _pagesHeld(newest)),
                        Divider(color: c.hairline, height: 26),
                        _line(context, Icons.place_outlined,
                            oneLineAddress('${newest['address'] ?? ''}')),
                        Divider(color: c.hairline, height: 26),
                        _line(
                          context,
                          Icons.photo_camera_outlined,
                          'Photographed at '
                          '${OdooTime.hm(DateTime.tryParse('${newest['occurred_at']}'))}',
                        ),
                      ],
                    ),
                  ),
                ] else
                  const EmptyState(
                    message: 'Nothing sent yet',
                    hint: 'Photograph a jangad and it appears here',
                    icon: Icons.receipt_long_outlined,
                  ),
                if (queued.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  for (final row in queued) ...[
                    NeuBox(
                      style: NeuStyle.raised,
                      radius: 20,
                      padding: const EdgeInsets.fromLTRB(17, 16, 17, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text('Waiting to send',
                                    style: NeuText.strong(c.inkMuted, size: 14)),
                              ),
                              const StateChip('Queued', kind: ChipKind.queued),
                            ],
                          ),
                          const SizedBox(height: 9),
                          Text(
                            'Photographed at ${OdooTime.hm(DateTime.tryParse('${row['occurred_at']}'))}. '
                            'It gets its reference the moment it reaches us.',
                            style: NeuText.body_(c.inkMuted, size: 12.5),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                ],
              ],
            ),
          ),
          NeuButton(
            label: 'Send another jangad',
            kind: NeuButtonKind.primary,
            icon: Icons.add_rounded,
            onPressed: () => context.go('/jangad'),
          ),
        ],
      ),
    );
  }

  /// `pages` is stored as a JSON list, so counting commas gets it wrong the
  /// moment a page id contains one.
  static String _pagesSent(Map<String, Object?> row) {
    var count = 1;
    try {
      final decoded = jsonDecode('${row['pages'] ?? '[]'}');
      if (decoded is List) count = decoded.length;
    } catch (_) {
      count = 1;
    }
    return count == 1 ? '1 page sent' : '$count pages sent';
  }

  /// Same count, worded for a jangad that has not left the phone yet.
  static String _pagesHeld(Map<String, Object?> row) {
    final sent = _pagesSent(row);
    return sent.replaceFirst(' sent', ' ready to send');
  }

  Widget _line(BuildContext context, IconData icon, String text) {
    final c = NeuTheme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: c.inkFaint),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: NeuText.body_(c.ink, size: 14, w: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}
