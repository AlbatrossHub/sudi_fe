import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_error.dart';
import '../../core/clock/odoo_time.dart';
import '../../core/services.dart';
import '../../core/session.dart';
import '../../core/sync_status.dart';
import '../../models/docs.dart';
import '../../ui/theme/neu.dart';
import '../../ui/widgets/neu_box.dart';
import '../../ui/widgets/neu_widgets.dart';
import '../../ui/widgets/powered_by.dart';
import '../../ui/widgets/status_strip.dart';
import '../shared/catalog.dart';
import 'customer_v2_screens.dart';

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
    final saved = ref.watch(savedAddressesProvider);
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
                      online
                          ? 'The saved list could not be loaded.'
                          : 'We cannot reach your saved list right now.',
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
              onPressed: () => context.go('/home'),
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
                        if (_services(latest) != null) ...[
                          _line(context, Icons.diamond_outlined, _services(latest)!),
                          Divider(color: c.hairline, height: 26),
                        ],
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
                        if (_services(newest) != null) ...[
                          _line(context, Icons.diamond_outlined, _services(newest)!),
                          Divider(color: c.hairline, height: 26),
                        ],
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
                    inline: true,
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
            onPressed: () => context.go('/home'),
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

  /// `2 services · 160 pcs`, from what was stored with the submission.
  static String? _services(Map<String, Object?> row) {
    try {
      final list = ServiceRequest.listFromDraft(jsonDecode('${row['services'] ?? '[]'}'));
      return list.isEmpty ? null : ServiceRequest.summary(list);
    } catch (_) {
      return null;
    }
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
