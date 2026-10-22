import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'config/flavor.dart';
import 'core/notices/notices.dart';
import 'core/resume/resume_store.dart';
import 'core/services.dart';
import 'core/session.dart';
import 'core/sync_status.dart';
import 'features/customer/customer_screens.dart';
import 'features/customer/customer_v2_screens.dart';
import 'features/field/deliveries_screens.dart';
import 'features/field/jobwork_screens.dart';
import 'features/field/mywork_screen.dart';
import 'features/field/notices_screen.dart';
import 'features/field/office_screens.dart';
import 'features/field/onbehalf_screens.dart';
import 'features/field/pickups_screens.dart';
import 'features/field/queue_screens.dart';
import 'features/field/sign_in_screens.dart';
import 'features/shared/devices_screen.dart';
import 'ui/theme/neu.dart';

class SudiApp extends ConsumerStatefulWidget {
  const SudiApp({super.key});

  @override
  ConsumerState<SudiApp> createState() => _SudiAppState();
}

class _SudiAppState extends ConsumerState<SudiApp> {
  late final GoRouter _router;
  late final _RouterRefresh _refresh;

  /// Where the app was when it last went away, read before anything moved.
  late final ResumePoint _coldStart;

  /// Until the first signed-in screen is reached: the app is on its way back
  /// to [_coldStart] rather than to the plain home.
  bool _resumePending = true;

  @override
  void initState() {
    super.initState();
    _coldStart = ref.read(servicesProvider).resume.point;
    _refresh = _RouterRefresh(ref);
    _router = sudiFlavor.isField ? _fieldRouter(_refresh, _redirect) : _customerRouter(_refresh, _redirect);
    _router.routerDelegate.addListener(_onRoute);
    NoticeAlerts.instance.onOpen = (route) => _router.push(route);
  }

  @override
  void dispose() {
    _router.routerDelegate.removeListener(_onRoute);
    _refresh.dispose();
    _router.dispose();
    super.dispose();
  }

  String? _redirect(BuildContext context, GoRouterState state) {
    final session = ref.read(sessionProvider);
    return gate(session, state.matchedLocation, resumeTab: _resumePending ? _coldStart.tab : null);
  }

  /// Every page and tab change is saved; the first signed-in tab after a cold
  /// start also puts back the page that was open on top of it.
  void _onRoute() {
    final location = topLocation(_router);
    ref.read(servicesProvider).resume.location(location);
    if (!_resumePending || !isTabLocation(location)) return;
    final session = ref.read(sessionProvider);
    if (session.stage != SessionStage.ready || session.mustOfferPin || session.mustAskGst) return;
    _resumePending = false;
    if (_coldStart.hasPage && location == _coldStart.tab && isResumableLocation(_coldStart.location)) {
      // On top of the tab, so Back goes where it always went.
      WidgetsBinding.instance.addPostFrameCallback((_) => _router.push(_coldStart.location));
    }
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
      if (next.stage == SessionStage.signedOut || next.stage == SessionStage.revoked) {
        _resumePending = false;
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
        theme: sudiTheme(colors),
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

ThemeData sudiTheme(NeuColors colors) => ThemeData(
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
    );

/// The location on top, including a page pushed over a tab.
String topLocation(GoRouter router) {
  final config = router.routerDelegate.currentConfiguration;
  if (config.matches.isEmpty) return config.uri.toString();
  final last = config.matches.last;
  if (last is ImperativeRouteMatch) return last.matches.uri.toString();
  return config.uri.toString();
}

/// Bridges the session notifier into go_router's refresh mechanism.
class _RouterRefresh extends ChangeNotifier {
  _RouterRefresh(WidgetRef ref) {
    _sub = ref.listenManual<SessionState>(
      sessionProvider,
      (previous, next) {
        if (previous?.stage != next.stage ||
            previous?.mustOfferPin != next.mustOfferPin ||
            previous?.mustAskGst != next.mustAskGst ||
            previous?.roles.join() != next.roles.join()) {
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

/// The tabs a session's roles open, in tab-bar order. With no roles known yet
/// (a first launch before `/auth/me`), the v1 set.
List<String> allowedTabs(SessionState s) {
  if (!sudiFlavor.isField) return const ['/home'];
  final none = s.roles.isEmpty;
  return [
    if (s.hasPickupDelivery || none) ...['/pickups', '/deliveries'],
    if (s.hasJobWork || none) '/jobwork',
    if (s.hasJobWork) '/mywork',
    if (s.hasOffice) '/office',
  ];
}

/// Home for this person: the tab the app was left on, if their roles still
/// allow it, else their first tab.
String homeFor(SessionState s, {String? resumeTab}) {
  final tabs = allowedTabs(s);
  if (resumeTab != null && tabs.contains(resumeTab)) return resumeTab;
  return tabs.isEmpty ? (sudiFlavor.isField ? '/pickups' : '/home') : tabs.first;
}

const _entryRoutes = <String>{
  '/boot', '/signin', '/unlock', '/revoked', '/setpin', '/phone', '/otp', '/register',
};

String? gate(SessionState session, String location, {String? resumeTab}) {
  switch (session.stage) {
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
      if (session.mustOfferPin) return location == '/setpin' ? null : '/setpin';
      if (!sudiFlavor.isField && session.mustAskGst) return location == '/gst' ? null : '/gst';
      if (_entryRoutes.contains(location)) return homeFor(session, resumeTab: resumeTab);
      // A tab the roles no longer open.
      if (isTabLocation(location) && !allowedTabs(session).contains(location)) {
        return homeFor(session);
      }
      return null;
  }
}

int _id(GoRouterState s) => int.parse(s.pathParameters['id']!);

GoRouter _fieldRouter(Listenable refresh, GoRouterRedirect redirect) => GoRouter(
      initialLocation: '/boot',
      refreshListenable: refresh,
      redirect: redirect,
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
            StatefulShellBranch(routes: [
              GoRoute(path: '/mywork', builder: (_, _) => const MyWorkScreen()),
            ]),
            StatefulShellBranch(routes: [
              GoRoute(path: '/office', builder: (_, _) => const OfficeScreen()),
            ]),
          ],
        ),
        GoRoute(path: '/pickup/:id', builder: (_, s) => PickupDetailScreen(id: _id(s))),
        GoRoute(path: '/pickup/:id/confirm', builder: (_, s) => ConfirmPickupScreen(id: _id(s))),
        GoRoute(path: '/pickup/:id/cancel', builder: (_, s) => CancelPickupScreen(id: _id(s))),
        GoRoute(path: '/onbehalf', builder: (_, _) => const OnBehalfCustomerScreen()),
        GoRoute(path: '/onbehalf/services', builder: (_, _) => const OnBehalfServicesScreen()),
        GoRoute(path: '/onbehalf/pages', builder: (_, _) => const OnBehalfPagesScreen()),
        GoRoute(
          path: '/onbehalf/posted/:local',
          builder: (_, s) => OnBehalfPostedScreen(localId: s.pathParameters['local']!),
        ),
        GoRoute(
          path: '/onbehalf/collect/:local',
          builder: (_, s) => ConfirmPickupScreen(postedLocalId: s.pathParameters['local']!),
        ),
        GoRoute(path: '/delivery/:id/deliver', builder: (_, s) => DeliverScreen(id: _id(s))),
        GoRoute(path: '/jobwork/:id', builder: (_, s) => JobWorkDetailScreen(id: _id(s))),
        GoRoute(path: '/jobwork/:id/log', builder: (_, s) => LogTimeScreen(id: _id(s))),
        GoRoute(path: '/jobwork/:id/department', builder: (_, s) => DepartmentScreen(id: _id(s))),
        GoRoute(path: '/office/:id', builder: (_, s) => OfficeReceiptScreen(id: _id(s))),
        GoRoute(
          path: '/office/:id/entries',
          builder: (_, s) => OfficeEntriesScreen(id: _id(s), addOnOpen: s.uri.queryParameters['add'] == '1'),
        ),
        GoRoute(path: '/office/:id/ready', builder: (_, s) => OfficeReadyScreen(id: _id(s))),
        GoRoute(path: '/notices', builder: (_, _) => const NoticesScreen()),
        GoRoute(path: '/queue', builder: (_, _) => const QueueScreen()),
        GoRoute(path: '/attention', builder: (_, _) => const AttentionScreen()),
        GoRoute(path: '/devices', builder: (_, _) => const DevicesScreen()),
      ],
    );

GoRouter _customerRouter(Listenable refresh, GoRouterRedirect redirect) => GoRouter(
      initialLocation: '/boot',
      refreshListenable: refresh,
      redirect: redirect,
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
        GoRoute(path: '/gst', builder: (_, _) => const GstScreen()),
        GoRoute(path: '/home', builder: (_, _) => const CustomerDashboardScreen()),
        GoRoute(path: '/request', builder: (_, _) => const RequestScreen()),
        GoRoute(path: '/request/jangad', builder: (_, _) => const CustomerJangadScreen()),
        GoRoute(path: '/request/address', builder: (_, _) => const AddressScreen()),
        GoRoute(path: '/submitted', builder: (_, _) => const SubmittedScreen()),
        GoRoute(path: '/devices', builder: (_, _) => const DevicesScreen()),
        GoRoute(path: '/revoked', builder: (_, _) => const RevokedScreen()),
        GoRoute(path: '/unlock', builder: (_, _) => const UnlockScreen()),
      ],
    );
