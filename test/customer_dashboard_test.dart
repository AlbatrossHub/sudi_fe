import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sudi_fe/src/config/flavor.dart';
import 'package:sudi_fe/src/core/drafts/draft_store.dart';
import 'package:sudi_fe/src/features/customer/customer_v2_screens.dart';

import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/pump.dart';

void main() {
  sudiFlavor = Flavor.customer;

  FakeServer customerServer() => FakeServer(basePath: '/api/customer/v1')
    ..on('GET', '/services', (_) => FakeResponse.json([
          {'id': 3, 'name': 'Laser Inscription', 'unit': 'pcs', 'description': null},
          {'id': 4, 'name': 'Ultra Sonic Boiling', 'unit': 'pcs'},
          {'id': 9, 'name': 'CVD Diamond Testing', 'unit': 'ct'},
        ]))
    ..on('GET', '/auth/me', (_) => FakeResponse.json({
          'id': 77,
          'name': 'Kiran Gems',
          'login': '9820012345',
          'roles': ['customer'],
          'device_uid': 'device-uid-1',
          'is_customer': true,
          'gst_state': 'present',
        }));

  testWidgets('pick a service, say how many, add it; then remove it from the request', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    // Built on the test's own clock, so every future it makes runs when the
    // test pumps (one made inside runAsync would wait for the real loop).
    final h = await buildHarness(server: customerServer(), roles: const ['customer']);

    await pumpRouted(
      tester,
      services: h.services,
      initial: '/home',
      routes: [
        GoRoute(path: '/home', builder: (_, _) => const CustomerDashboardScreen()),
        GoRoute(path: '/request', builder: (_, _) => const RequestScreen()),
        stubRoute('/request/jangad', 'PHASE 2'),
        stubRoute('/submitted', 'SUBMITTED'),
        stubRoute('/gst', 'GST'),
      ],
    );
    await settle(tester);

    expect(find.text('What should we do?'), findsOneWidget);
    expect(find.byKey(const Key('service-tile-3')), findsOneWidget);
    expect(find.byKey(const Key('request-bar')), findsNothing, reason: 'nothing picked yet');

    // Tap a service: the sheet asks how many.
    await tester.tap(find.byKey(const Key('service-tile-3')));
    await tester.pumpAndSettle();
    expect(find.text('How many pieces?'), findsOneWidget);
    // No presets: whatever count the customer types (the client asked for it).
    expect(find.byKey(const ValueKey('qty-stepper-more')), findsNothing);
    expect(find.text('Add, no count'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('qty-input')), '37');
    await tester.pump();
    expect(find.text('Add 37 pcs'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Please do the small ones too'), 'big stones first');
    await tester.tap(find.byKey(const Key('service-sheet-save')));
    await tester.pumpAndSettle();

    // The tile says it is in, and the bar at the foot sums the request.
    expect(find.text('Added · 37 pcs'), findsOneWidget);
    expect(find.byKey(const Key('request-bar')), findsOneWidget);
    expect(find.text('1 service · 37 pcs'), findsOneWidget);

    // A second one, by the carat.
    await tester.tap(find.byKey(const Key('service-tile-9')));
    await tester.pumpAndSettle();
    expect(find.text('How many carats?'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('qty-input')), '1.25');
    await tester.pump();
    await tester.tap(find.byKey(const Key('service-sheet-save')));
    await tester.pumpAndSettle();
    expect(find.text('2 services · 37 pcs · 1.25 ct'), findsOneWidget);

    // It is a draft on the phone's disk: a killed app would come back to it.
    await drive(tester, h.services.drafts.flushAll());
    final draft = (await drive(tester, h.services.drafts.load(DraftStore.customerJangad)))!;
    expect(draft.data['services'], [
      {'job_type_id': 3, 'quantity': 37.0, 'remarks': 'big stones first', 'name': 'Laser Inscription', 'unit': 'pcs'},
      {'job_type_id': 9, 'quantity': 1.25, 'name': 'CVD Diamond Testing', 'unit': 'ct'},
    ]);

    // Your request: remove one.
    await tester.tap(find.byKey(const Key('request-bar')));
    await tester.pumpAndSettle();
    expect(find.text('Your request'), findsOneWidget);
    expect(find.byKey(const Key('request-service-3')), findsOneWidget);
    expect(find.text('“big stones first”'), findsOneWidget);
    await tester.tap(find.byKey(const Key('remove-service-3')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('request-service-3')), findsNothing);
    expect(find.byKey(const Key('request-service-9')), findsOneWidget);

    // Back on the dashboard the tile is free again.
    await tester.tap(find.text('Add another service'));
    await tester.pumpAndSettle();
    expect(find.text('Added · 37 pcs'), findsNothing);
    expect(find.text('1 service · 1.25 ct'), findsOneWidget);

    // The edit sheet can take a service out too.
    await tester.tap(find.byKey(const Key('service-tile-9')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('request-bar')), findsNothing);
    await drive(tester, h.services.drafts.flushAll());
  });
}
