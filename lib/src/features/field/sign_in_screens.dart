import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config/flavor.dart';
import '../../core/services.dart';
import '../../core/session.dart';
import '../../ui/theme/neu.dart';
import '../../ui/widgets/neu_box.dart';
import '../../ui/widgets/neu_widgets.dart';

class BootScreen extends StatelessWidget {
  const BootScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    return Scaffold(
      backgroundColor: c.ground,
      body: Center(
        child: NeuBox(
          style: NeuStyle.raised,
          radius: 28,
          width: 84,
          height: 84,
          child: Center(child: Icon(Icons.diamond_outlined, size: 38, color: c.accentInk)),
        ),
      ),
    );
  }
}

class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _login = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _login.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final session = ref.watch(sessionProvider);

    return NeuScaffold(
      padding: const EdgeInsets.fromLTRB(28, 40, 28, 24),
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
            Text('Sudi Field', textAlign: TextAlign.center, style: NeuText.title(c.ink, size: 27)),
            const SizedBox(height: 6),
            Text(
              'Pickups, deliveries and job work',
              textAlign: TextAlign.center,
              style: NeuText.body_(c.inkMuted, size: 14),
            ),
            const SizedBox(height: 40),
            NeuField(
              controller: _login,
              label: 'Login',
              hint: 'your Odoo login',
              icon: Icons.person_outline_rounded,
            ),
            const SizedBox(height: 18),
            NeuField(
              controller: _password,
              label: 'Password',
              icon: Icons.lock_outline_rounded,
              obscure: true,
            ),
            if (session.error != null) ...[
              const SizedBox(height: 16),
              NeuNote(
                text: session.error!,
                icon: Icons.warning_amber_rounded,
                kind: ChipKind.attention,
              ),
            ],
            const SizedBox(height: 22),
            NeuButton(
              label: 'Sign in',
              kind: NeuButtonKind.primary,
              busy: session.busy,
              onPressed: () => ref.read(sessionProvider.notifier).signIn(
                    login: _login.text.trim(),
                    password: _password.text,
                  ),
            ),
            const SizedBox(height: 26),
            const NeuNote(
              title: 'The first sign in needs a connection',
              text: 'After that the app opens, unlocks and records work with no signal at all.',
              icon: Icons.wifi_off_rounded,
            ),
            const SizedBox(height: 26),
            Text(
              'Accounts are created by your administrator.',
              textAlign: TextAlign.center,
              style: NeuText.body_(c.inkMuted, size: 12),
            ),
          ],
        ),
      ),
    );
  }
}

/// Local unlock over the encrypted database. The server never sees this.
class UnlockScreen extends ConsumerStatefulWidget {
  const UnlockScreen({super.key});

  @override
  ConsumerState<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends ConsumerState<UnlockScreen> {
  String _entered = '';
  String? _error;

  Future<void> _press(String digit) async {
    if (_entered.length >= 4) return;
    setState(() {
      _entered += digit;
      _error = null;
    });
    if (_entered.length == 4) {
      final ok = await ref.read(sessionProvider.notifier).unlock(_entered);
      if (!ok && mounted) {
        setState(() {
          _entered = '';
          _error = 'That PIN is not right.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final name = ref.watch(sessionProvider).me?.name;

    return NeuScaffold(
      padding: const EdgeInsets.fromLTRB(34, 40, 34, 24),
      child: Column(
        children: [
          Text(
            name == null ? 'Welcome back' : 'Welcome back, ${name.split(' ').first}',
            textAlign: TextAlign.center,
            style: NeuText.title(c.ink, size: 25),
          ),
          const SizedBox(height: 8),
          Text('Enter your PIN to unlock', style: NeuText.body_(c.inkMuted, size: 14)),
          const SizedBox(height: 26),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < 4; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: NeuBox(
                    style: i < _entered.length ? NeuStyle.insetSm : NeuStyle.inset,
                    radius: 9,
                    width: 17,
                    height: 17,
                    color: i < _entered.length ? c.accent : c.ground,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 18),
          if (_error != null)
            StateChip(_error!, kind: ChipKind.attention, icon: Icons.warning_amber_rounded)
          else
            StateChip('Works without a connection', kind: ChipKind.synced, icon: Icons.check_rounded),
          const SizedBox(height: 28),
          Expanded(
            child: GridView.count(
              crossAxisCount: 3,
              mainAxisSpacing: 16,
              crossAxisSpacing: 16,
              childAspectRatio: 1.35,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                for (var n = 1; n <= 9; n++) _key(context, '$n'),
                const SizedBox.shrink(),
                _key(context, '0'),
                NeuBox(
                  style: NeuStyle.raised,
                  radius: 24,
                  onTap: () => setState(() {
                    if (_entered.isNotEmpty) {
                      _entered = _entered.substring(0, _entered.length - 1);
                    }
                  }),
                  child: Center(
                    child: Icon(Icons.backspace_outlined, size: 24, color: c.inkMuted),
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => confirmSignOut(context, ref),
            child: Text(
              // The customer app has no password to fall back to -- portal
              // accounts sign in by OTP and their passwords are discarded --
              // so naming one here sends them looking for something that does
              // not exist.
              sudiFlavor.isField
                  ? 'Sign in with password instead'
                  : 'Sign in with your phone number instead',
              style: NeuText.label(c.accentInk, size: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _key(BuildContext context, String digit) {
    final c = NeuTheme.of(context);
    return NeuBox(
      style: NeuStyle.raised,
      radius: 24,
      onTap: () => _press(digit),
      child: Center(
        child: Text(
          digit,
          style: TextStyle(
            fontFamily: NeuText.display,
            fontSize: 25,
            fontWeight: FontWeight.w600,
            color: c.ink,
          ),
        ),
      ),
    );
  }
}

/// The remote-wipe screen. Anything on this phone was diamond logistics data.
/// Signing out wipes the encrypted database, and the outbox lives in it.
/// Unconfirmed, this link sits one stray tap from a morning of collections
/// that never reached the office and cannot be recovered -- so it says how
/// much is at stake, and offline it says that signing back in needs signal.
Future<void> confirmSignOut(BuildContext context, WidgetRef ref) async {
  final c = NeuTheme.of(context);
  // Counted off the outbox and the radio, not off `syncProvider`: that
  // controller only starts once the session reaches `ready`, so at the lock
  // screen it still holds its defaults -- zero queued, online -- and the
  // warning would stay silent in exactly the case it exists for.
  final services = ref.read(servicesProvider);
  final queued = await services.outbox.openCount();
  final online = services.net.isOnline;
  if (!context.mounted) return;

  final lines = <String>[
    if (queued > 0)
      queued == 1
          ? 'One capture has not reached the office yet. Signing out erases '
              'it for good.'
          : '$queued captures have not reached the office yet. Signing out '
              'erases them for good.',
    if (!online) 'You have no connection, and signing back in needs one.',
    if (queued == 0 && online) 'You will need to sign in again.',
  ];

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      // Same ground as every other surface; dialogs do not go white here.
      backgroundColor: c.ground,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: Text('Sign out?', style: NeuText.title(c.ink, size: 20)),
      content: Text(lines.join('\n\n'), style: NeuText.body_(c.inkMuted, size: 14)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text('Stay signed in', style: NeuText.label(c.inkMuted, size: 13)),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(
            queued > 0 ? 'Erase and sign out' : 'Sign out',
            style: NeuText.label(c.attentionInk, size: 13),
          ),
        ),
      ],
    ),
  );

  if (confirmed ?? false) {
    await ref.read(sessionProvider.notifier).signOut();
  }
}

class RevokedScreen extends ConsumerWidget {
  const RevokedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = NeuTheme.of(context);
    return NeuScaffold(
      padding: const EdgeInsets.fromLTRB(28, 48, 28, 24),
      child: Column(
        children: [
          NeuBox(
            style: NeuStyle.inset,
            radius: 34,
            width: 104,
            height: 104,
            child: Center(child: Icon(Icons.lock_outline_rounded, size: 44, color: c.attentionInk)),
          ),
          const SizedBox(height: 30),
          Text(
            'This phone was signed out by the office',
            textAlign: TextAlign.center,
            style: NeuText.title(c.ink, size: 25),
          ),
          const SizedBox(height: 14),
          Text(
            'Everything stored on it has been cleared. Work that had already been sent is safe.',
            textAlign: TextAlign.center,
            style: NeuText.body_(c.inkMuted, size: 14),
          ),
          const SizedBox(height: 24),
          const NeuNote(
            title: 'Anything still queued did not arrive',
            text: 'Tell the office what you captured since your last sync so it can be entered by hand.',
            icon: Icons.warning_amber_rounded,
            kind: ChipKind.attention,
          ),
          const Spacer(),
          NeuButton(
            label: 'Sign in again',
            kind: NeuButtonKind.primary,
            onPressed: () => ref.read(sessionProvider.notifier).backToSignIn(),
          ),
        ],
      ),
    );
  }
}

/// Bottom tab bar. `roles` decides which tabs to draw before the first network
/// call — and the server still enforces membership on every route.
class FieldShell extends ConsumerWidget {
  const FieldShell({super.key, required this.shell});

  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = NeuTheme.of(context);
    final session = ref.watch(sessionProvider);

    final tabs = <({IconData icon, String label, int branch})>[
      if (session.hasPickupDelivery || session.roles.isEmpty)
        (icon: Icons.inventory_2_outlined, label: 'Pickups', branch: 0),
      if (session.hasPickupDelivery || session.roles.isEmpty)
        (icon: Icons.local_shipping_outlined, label: 'Deliveries', branch: 1),
      if (session.hasJobWork || session.roles.isEmpty)
        (icon: Icons.timer_outlined, label: 'Job work', branch: 2),
    ];

    return Scaffold(
      backgroundColor: c.ground,
      body: shell,
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
          child: NeuBox(
            style: NeuStyle.raised,
            radius: 24,
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                for (final tab in tabs)
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => shell.goBranch(tab.branch,
                          initialLocation: tab.branch == shell.currentIndex),
                      child: shell.currentIndex == tab.branch
                          ? NeuBox(
                              style: NeuStyle.insetSm,
                              radius: 18,
                              padding: const EdgeInsets.symmetric(vertical: 11),
                              child: _tabBody(tab.icon, tab.label, c.accentInk, true),
                            )
                          : Padding(
                              padding: const EdgeInsets.symmetric(vertical: 11),
                              child: _tabBody(tab.icon, tab.label, c.inkMuted, false),
                            ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _tabBody(IconData icon, String label, Color ink, bool active) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 21, color: ink),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontFamily: NeuText.body,
              fontSize: 11,
              fontWeight: active ? FontWeight.w800 : FontWeight.w700,
              color: ink,
            ),
          ),
        ],
      );
}

/// Shared by both flavors: the account / device sheet.
Future<void> showAccountSheet(BuildContext context, WidgetRef ref) async {
  final c = NeuTheme.of(context);
  final session = ref.read(sessionProvider);
  final services = ref.read(servicesProvider);
  final device = await services.device.current();
  if (!context.mounted) return;

  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: c.ground,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (sheetContext) => NeuTheme(
      colors: c,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 22, 24, 30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(session.me?.name ?? 'This phone', style: NeuText.title(c.ink, size: 21)),
            const SizedBox(height: 6),
            Text(
              session.me?.login ?? session.me?.phone ?? sudiFlavor.title,
              style: NeuText.body_(c.inkMuted, size: 13),
            ),
            const SizedBox(height: 18),
            NeuBox(
              style: NeuStyle.inset,
              radius: 18,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('This device', style: NeuText.label(c.inkMuted, size: 12)),
                  const SizedBox(height: 6),
                  Text(
                    '${device.deviceUid.substring(0, 8)}… · v${device.appVersion}',
                    style: NeuText.data(c.ink, size: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            NeuButton(
              label: 'Your phones',
              icon: Icons.smartphone_outlined,
              onPressed: () {
                Navigator.of(sheetContext).pop();
                context.push('/devices');
              },
            ),
            const SizedBox(height: 12),
            NeuButton(
              label: 'Sign out of this phone',
              kind: NeuButtonKind.destructive,
              // Through the same confirmation as the lock screen: this button
              // wipes the encrypted database, and the outbox is in it.
              onPressed: () {
                Navigator.of(sheetContext).pop();
                confirmSignOut(context, ref);
              },
            ),
          ],
        ),
      ),
    ),
  );
}

/// Offered once after a fresh sign-in. Skippable: a PIN protects the phone, it
/// does not protect the account, and forcing one on a busy operator at a
/// warehouse door is how an app gets abandoned.
class SetPinScreen extends ConsumerStatefulWidget {
  const SetPinScreen({super.key});

  @override
  ConsumerState<SetPinScreen> createState() => _SetPinScreenState();
}

class _SetPinScreenState extends ConsumerState<SetPinScreen> {
  String _first = '';
  String _second = '';
  String? _error;

  bool get _confirming => _first.length == 4;
  String get _entered => _confirming ? _second : _first;

  Future<void> _press(String digit) async {
    if (_entered.length >= 4) return;
    setState(() {
      _error = null;
      if (_confirming) {
        _second += digit;
      } else {
        _first += digit;
      }
    });
    if (_confirming && _second.length == 4) {
      if (_first == _second) {
        await ref.read(sessionProvider.notifier).setPin(_first);
      } else {
        setState(() {
          _first = '';
          _second = '';
          _error = 'Those did not match. Start again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    return NeuScaffold(
      padding: const EdgeInsets.fromLTRB(34, 30, 34, 24),
      child: Column(
        children: [
          Text(
            _confirming ? 'Enter it again' : 'Set an unlock PIN',
            textAlign: TextAlign.center,
            style: NeuText.title(c.ink, size: 25),
          ),
          const SizedBox(height: 8),
          Text(
            'Four digits, so the app opens without a signal.',
            textAlign: TextAlign.center,
            style: NeuText.body_(c.inkMuted, size: 14),
          ),
          const SizedBox(height: 26),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < 4; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: NeuBox(
                    style: i < _entered.length ? NeuStyle.insetSm : NeuStyle.inset,
                    radius: 9,
                    width: 17,
                    height: 17,
                    color: i < _entered.length ? c.accent : c.ground,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 18),
          if (_error != null)
            StateChip(_error!, kind: ChipKind.attention, icon: Icons.warning_amber_rounded)
          else
            StateChip(
              'The office never sees this PIN',
              kind: ChipKind.synced,
              icon: Icons.lock_outline_rounded,
            ),
          const SizedBox(height: 24),
          Expanded(
            child: GridView.count(
              crossAxisCount: 3,
              mainAxisSpacing: 16,
              crossAxisSpacing: 16,
              childAspectRatio: 1.45,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                for (var n = 1; n <= 9; n++) _pinKey(context, '$n', () => _press('$n')),
                const SizedBox.shrink(),
                _pinKey(context, '0', () => _press('0')),
                NeuBox(
                  style: NeuStyle.raised,
                  radius: 24,
                  onTap: () => setState(() {
                    if (_confirming && _second.isNotEmpty) {
                      _second = _second.substring(0, _second.length - 1);
                    } else if (!_confirming && _first.isNotEmpty) {
                      _first = _first.substring(0, _first.length - 1);
                    }
                  }),
                  child: Center(
                    child: Icon(Icons.backspace_outlined, size: 24, color: c.inkMuted),
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => ref.read(sessionProvider.notifier).declinePin(),
            child: Text('Not now', style: NeuText.label(c.inkMuted, size: 13)),
          ),
        ],
      ),
    );
  }

  Widget _pinKey(BuildContext context, String digit, VoidCallback onTap) {
    final c = NeuTheme.of(context);
    return NeuBox(
      style: NeuStyle.raised,
      radius: 24,
      onTap: onTap,
      child: Center(
        child: Text(
          digit,
          style: TextStyle(
            fontFamily: NeuText.display,
            fontSize: 25,
            fontWeight: FontWeight.w600,
            color: c.ink,
          ),
        ),
      ),
    );
  }
}
