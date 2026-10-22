import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sudi_fe/src/config/flavor.dart';
import 'package:sudi_fe/src/core/services.dart';
import 'package:sudi_fe/src/ui/theme/neu.dart';

NeuColors flavorColors() => NeuColors.light(
      sudiFlavor.accent,
      sudiFlavor.accentInk,
      sudiFlavor.accentShadow,
      sudiFlavor.onAccent,
    );

/// A widget on the app's ground, with the theme the screens expect.
Widget themed(Widget child) {
  final colors = flavorColors();
  return NeuTheme(
    colors: colors,
    child: MaterialApp(
      home: NeuTheme(colors: colors, child: Scaffold(backgroundColor: colors.ground, body: child)),
    ),
  );
}

/// Screens under a real router (they push and pop) and the given services.
Future<GoRouter> pumpRouted(
  WidgetTester tester, {
  required Services services,
  required String initial,
  required List<RouteBase> routes,
  List overrides = const [],
}) async {
  final router = GoRouter(initialLocation: initial, routes: routes);
  final colors = flavorColors();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [servicesProvider.overrideWithValue(services), ...overrides],
      child: NeuTheme(
        colors: colors,
        child: MaterialApp.router(
          routerConfig: router,
          builder: (context, child) => NeuTheme(colors: colors, child: child ?? const SizedBox()),
        ),
      ),
    ),
  );
  return router;
}

/// A placeholder page a screen navigates to.
GoRoute stubRoute(String path, String label) =>
    GoRoute(path: path, builder: (_, _) => Scaffold(body: Center(child: Text(label))));

/// Let microtasks, database futures and the fake server settle.
Future<void> settle(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Await [future] while pumping: database and draft writes made from inside a
/// widget test complete on the test's fake clock, so a bare `await` would wait
/// for time that never passes.
Future<T> drive<T>(WidgetTester tester, Future<T> future, {int maxFrames = 200}) async {
  var done = false;
  late T value;
  Object? error;
  future.then((v) {
    value = v;
    done = true;
  }, onError: (Object e) {
    error = e;
    done = true;
  });
  for (var i = 0; i < maxFrames && !done; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  if (error != null) throw error!;
  if (!done) throw StateError('drive(): the future did not complete');
  return value;
}
