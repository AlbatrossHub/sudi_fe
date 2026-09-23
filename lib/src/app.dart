import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'config/flavor.dart';
import 'core/services.dart';
import 'core/session.dart';
import 'core/sync_status.dart';
import 'features/customer/customer_screens.dart';
import 'features/field/deliveries_screens.dart';
import 'features/field/jobwork_screens.dart';
import 'features/field/pickups_screens.dart';
import 'features/shared/devices_screen.dart';
import 'features/field/queue_screens.dart';
import 'features/field/sign_in_screens.dart';
import 'ui/theme/neu.dart';

class SudiApp extends ConsumerStatefulWidget {
  const SudiApp({super.key});

  @override
  ConsumerState<SudiApp> createState() => _SudiAppState();
}

class _SudiAppState extends ConsumerState<SudiApp> {
  late final GoRouter _router;
  late final _RouterRefresh _refresh;

  @override
  void initState() {
    super.initState();
    _refresh = _RouterRefresh(ref);
    _router = sudiFlavor.isField ? _fieldRouter(_refresh) : _customerRouter(_refresh);
  }

  @override
  void dispose() {
    _refresh.dispose();
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(sessionProvider, (previous, next) {
      if (previous?.stage != SessionStage.ready && next.stage == SessionStage.ready) {
        ref.read(syncProvider.notifier).start();
        // Housekeeping, once the session is usable: tells the server what this
        // handset is running, which is otherwise only recorded at login and so
        // goes stale the first time the app is updated in place.
        unawaited(ref.read(servicesProvider).auth.reportThisDevice());
      }
    });

    // Light only, on purpose. Neumorphism carries depth in a few percent of
    // luminance, and on a dark ground that difference is close to invisible —
    // the surfaces stop reading as raised or sunk at all. This app is also used
    // outdoors, where the light ground is the legible one.
    final colors = NeuColors.light(
      sudiFlavor.accent,
      sudiFlavor.accentInk,
      sudiFlavor.accentShadow,
      sudiFlavor.onAccent,
    );

    // Dark glyphs in the status bar: the app ground is light whatever the
    // phone's own theme is set to.
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Color(0x00000000),
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
        systemNavigationBarColor: Color(0xFFE3E8F0),
        systemNavigationBarIconBrightness: Brightness.dark,
      ),
    );

    return NeuTheme(
      colors: colors,
      child: MaterialApp.router(
        title: sudiFlavor.title,
        debugShowCheckedModeBanner: false,
        routerConfig: _router,
        themeMode: ThemeMode.light,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.light,
          fontFamily: NeuText.body,
          scaffoldBackgroundColor: colors.ground,
          colorScheme: ColorScheme.fromSeed(
            seedColor: colors.accent,
            brightness: Brightness.light,
            surface: colors.ground,
          ),
          splashFactory: InkSparkle.splashFactory,
        ),
        builder: (context, child) => NeuTheme(
          colors: colors,
          // The screens are drawn at 390x844. A phone with Display Size
          // turned up reports a 360-wide canvas, and Samsung's font slider
          // goes to 1.3 on top of that — together they overflow layouts that
          // are fine at either alone. 1.15 still honours someone who wants
          // bigger text without breaking the screen they need to read.
          child: MediaQuery.withClampedTextScaling(
            minScaleFactor: 0.9,
            maxScaleFactor: 1.15,
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}

/// Bridges the session notifier into go_router's refresh mechanism.
class _RouterRefresh extends ChangeNotifier {
  _RouterRefresh(WidgetRef ref) {
    _sub = ref.listenManual<SessionState>(
      sessionProvider,
      (previous, next) {
        if (previous?.stage != next.stage ||
            previous?.mustOfferPin != next.mustOfferPin) {
          notifyListeners();
        }
      },
    );
  }

  late final ProviderSubscription<SessionState> _sub;

  @override
  void dispose() {
    _sub.close();
    super.dispose();
  }
}

String? _gate(SessionStage stage, String location, {bool mustOfferPin = false}) {
  switch (stage) {
    case SessionStage.booting:
      return location == '/boot' ? null : '/boot';
    case SessionStage.signedOut:
      return location.startsWith('/signin') || location.startsWith('/phone') ||
              location.startsWith('/otp') || location.startsWith('/register')
          ? null
          : (sudiFlavor.isField ? '/signin' : '/phone');
    case SessionStage.locked:
      return location == '/unlock' ? null : '/unlock';
    case SessionStage.revoked:
      return location == '/revoked' ? null : '/revoked';
    case SessionStage.ready:
      if (mustOfferPin) return location == '/setpin' ? null : '/setpin';
      const entry = <String>{
        '/boot', '/signin', '/unlock', '/revoked', '/setpin', '/phone', '/otp', '/register'
      };
      if (entry.contains(location)) {
        return sudiFlavor.isField ? '/pickups' : '/jangad';
      }
      return null;
  }
}

GoRouter _fieldRouter(Listenable refresh) => GoRouter(
      initialLocation: '/boot',
      refreshListenable: refresh,
      redirect: (context, state) {
        final session = ProviderScope.containerOf(context).read(sessionProvider);
        return _gate(session.stage, state.matchedLocation,
            mustOfferPin: session.mustOfferPin);
      },
      routes: [
        GoRoute(path: '/boot', builder: (_, _) => const BootScreen()),
        GoRoute(path: '/signin', builder: (_, _) => const SignInScreen()),
        GoRoute(path: '/setpin', builder: (_, _) => const SetPinScreen()),
        GoRoute(path: '/unlock', builder: (_, _) => const UnlockScreen()),
        GoRoute(path: '/revoked', builder: (_, _) => const RevokedScreen()),
        StatefulShellRoute.indexedStack(
          builder: (_, _, shell) => FieldShell(shell: shell),
          branches: [
            StatefulShellBranch(routes: [
              GoRoute(path: '/pickups', builder: (_, _) => const PickupsScreen()),
            ]),
            StatefulShellBranch(routes: [
              GoRoute(path: '/deliveries', builder: (_, _) => const DeliveriesScreen()),
            ]),
            StatefulShellBranch(routes: [
              GoRoute(path: '/jobwork', builder: (_, _) => const JobWorkScreen()),
            ]),
          ],
        ),
        GoRoute(
          path: '/pickup/:id',
          builder: (_, s) => PickupDetailScreen(id: int.parse(s.pathParameters['id']!)),
        ),
        GoRoute(
          path: '/pickup/:id/confirm',
          builder: (_, s) => ConfirmPickupScreen(id: int.parse(s.pathParameters['id']!)),
        ),
        GoRoute(
          path: '/pickup/:id/cancel',
          builder: (_, s) => CancelPickupScreen(id: int.parse(s.pathParameters['id']!)),
        ),
        GoRoute(
          path: '/delivery/:id/deliver',
          builder: (_, s) => DeliverScreen(id: int.parse(s.pathParameters['id']!)),
        ),
        GoRoute(
          path: '/jobwork/:id',
          builder: (_, s) => JobWorkDetailScreen(id: int.parse(s.pathParameters['id']!)),
        ),
        GoRoute(
          path: '/jobwork/:id/department',
          builder: (_, s) => DepartmentScreen(id: int.parse(s.pathParameters['id']!)),
        ),
        GoRoute(path: '/queue', builder: (_, _) => const QueueScreen()),
        GoRoute(path: '/attention', builder: (_, _) => const AttentionScreen()),
        GoRoute(path: '/devices', builder: (_, _) => const DevicesScreen()),
      ],
    );

GoRouter _customerRouter(Listenable refresh) => GoRouter(
      initialLocation: '/boot',
      refreshListenable: refresh,
      redirect: (context, state) {
        final session = ProviderScope.containerOf(context).read(sessionProvider);
        return _gate(session.stage, state.matchedLocation,
            mustOfferPin: session.mustOfferPin);
      },
      routes: [
        GoRoute(path: '/boot', builder: (_, _) => const BootScreen()),
        GoRoute(path: '/setpin', builder: (_, _) => const SetPinScreen()),
        GoRoute(path: '/phone', builder: (_, _) => const PhoneScreen()),
        GoRoute(
          path: '/otp',
          builder: (_, s) => OtpScreen(phone: s.uri.queryParameters['phone'] ?? ''),
        ),
        GoRoute(
          path: '/register',
          builder: (_, s) => RegisterScreen(token: s.uri.queryParameters['token'] ?? ''),
        ),
        GoRoute(path: '/jangad', builder: (_, _) => const JangadScreen()),
        GoRoute(path: '/jangad/address', builder: (_, _) => const AddressScreen()),
        GoRoute(path: '/submitted', builder: (_, _) => const SubmittedScreen()),
        GoRoute(path: '/devices', builder: (_, _) => const DevicesScreen()),
        GoRoute(path: '/revoked', builder: (_, _) => const RevokedScreen()),
        GoRoute(path: '/unlock', builder: (_, _) => const UnlockScreen()),
      ],
    );
