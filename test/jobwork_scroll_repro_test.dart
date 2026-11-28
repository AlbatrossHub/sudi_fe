import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sudi_fe/src/config/flavor.dart';
import 'package:sudi_fe/src/features/field/jobwork_screens.dart';

import 'support/harness.dart';
import 'support/pump.dart';

/// Production 28 Nov: 15 ready receipts, 5 of them with timers that have been
/// running for days, most receipts never started by any department.
Map<String, dynamic> _doc(int i, {bool running = false, String? dept}) => {
      'id': 1000 + i,
      'rev': 1,
      'name': 'HO/IN/011${i.toString().padLeft(2, '0')}',
      'state': 'assigned',
      'total_hours': 0.0,
      'timer': {'running': running, 'started_at': '2026-11-24T06:00:00'},
      'items': [
        {
          'move_id': 5000 + i,
          'sr': 1,
          'product': 'Customer Diamond Parcel',
          'size': '+11',
          'pcs': 10,
          'carats': 2.5,
          'job_type': {'id': 61, 'name': 'White Hole Drilling'},
        },
      ],
      'involved_departments': [
        {'id': 61, 'name': 'White Hole Drilling'},
      ],
      'jangad_pages': 1,
      'customer': {'id': 7, 'name': 'CUSTOMER $i'},
      'scheduled_date': '2026-11-${(22 + i).toString().padLeft(2, '0')}T04:00:00',
      if (dept != null) 'current_department': {'id': 9, 'name': dept},
      'services': const [],
    };

void main() {
  sudiFlavor = Flavor.field;

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final h = await buildHarness();
    await h.services.records.upsertJobWork([
      for (var i = 1; i <= 5; i++) _doc(i, running: true, dept: 'Hard Process'),
      for (var i = 6; i <= 15; i++) _doc(i),
    ]);
    await pumpRouted(
      tester,
      services: h.services,
      initial: '/jobwork',
      routes: [
        GoRoute(path: '/jobwork', builder: (_, _) => const JobWorkScreen()),
        stubRoute('/queue', 'QUEUE'),
        stubRoute('/jobwork/:id', 'DETAIL'),
      ],
    );
    await settle(tester);
  }

  testWidgets('five day-old timers scroll with the queue instead of pinning it', (tester) async {
    await pump(tester);
    expect(tester.takeException(), isNull);

    // Timers running for days say so, and a running receipt is a strip only,
    // never also a card further down.
    expect(find.textContaining('STILL RUNNING'), findsNWidgets(5));
    expect(find.text('HO/IN/01101'), findsNothing, reason: 'no duplicate card for a running receipt');

    // The strips live inside the one scrollable: dragging up moves them away
    // and brings the waiting queue in, oldest receipt first.
    final list = find.descendant(of: find.byType(RefreshIndicator), matching: find.byType(Scrollable)).first;
    await tester.drag(list, const Offset(0, -500), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('HO/IN/01106'), findsOneWidget, reason: 'oldest waiting receipt follows the strips');

    // The far end is reachable too.
    await tester.drag(list, const Offset(0, -4000), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('HO/IN/01115'), findsOneWidget, reason: 'the newest receipt is reachable by scrolling');
  });

  testWidgets('chips cover every involved department, not just started ones', (tester) async {
    await pump(tester);

    // All fifteen receipts involve White Hole Drilling even though nobody has
    // started that department: it still gets a chip (further along the row).
    expect(find.text('Hard Process · 5'), findsOneWidget);
    await tester.drag(find.text('Hard Process · 5'), const Offset(-250, 0), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('White Hole Drilling · 15'), findsOneWidget);

    // Filtering to the started department leaves the five running strips and
    // no waiting cards.
    await tester.tap(find.text('Hard Process · 5'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('STILL RUNNING'), findsNWidgets(5));
    expect(find.text('HO/IN/01106'), findsNothing);
  });
}
