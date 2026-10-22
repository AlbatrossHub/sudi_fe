import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sudi_fe/src/config/flavor.dart';
import 'package:sudi_fe/src/core/drafts/draft_store.dart';
import 'package:sudi_fe/src/core/sync_status.dart';
import 'package:sudi_fe/src/features/field/office_screens.dart';
import 'package:sudi_fe/src/models/docs.dart';

import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/pump.dart';

Map<String, dynamic> _office({List<Map<String, dynamic>> items = const []}) => {
      'id': 325,
      'rev': 3,
      'name': 'HO/IN/00325',
      'stage': 'collected',
      'jangad_pages': 2,
      'customer': {'id': 412, 'name': 'Shah Gems'},
      'collected_at': '2026-10-22T05:50:00',
      'jangad_source': 'on_behalf',
      'posted_by': {'id': 9, 'name': 'Rakesh Patel'},
      'services': [
        {'id': 1, 'job_type': {'id': 3, 'name': 'Laser Inscription'}, 'quantity': 120, 'unit': 'pcs'},
        {'id': 2, 'job_type': {'id': 4, 'name': 'Ultra Sonic Boiling'}, 'quantity': 40, 'unit': 'pcs'},
      ],
      'items': items,
    };

Map<String, dynamic> _line(int moveId, int sr, double pcs, {int? jobType, String? jobName}) => {
      'move_id': moveId,
      'sr': sr,
      'product': 'Customer Diamond Parcel',
      'size': '+11',
      'pcs': pcs,
      'carats': 6.2,
      'job_type': jobType == null ? null : {'id': jobType, 'name': jobName},
    };

/// The sync controller, pinned offline: what the screen sees with no signal.
class _Offline extends SyncController {
  @override
  SyncStatus build() => const SyncStatus(online: false);
}

void main() {
  sudiFlavor = Flavor.field;

  Future<Harness> setUp(WidgetTester tester, Map<String, dynamic> office) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final h = await buildHarness();
    await h.services.records.upsertOffice([office]);
    return h;
  }

  List<RouteBase> routes() => [
        GoRoute(path: '/office/:id/ready', builder: (_, s) => OfficeReadyScreen(id: int.parse(s.pathParameters['id']!))),
        stubRoute('/office', 'OFFICE LIST'),
      ];

  testWidgets('a line with no service holds the button, and says which line', (tester) async {
    final h = await setUp(
      tester,
      _office(items: [
        _line(11, 1, 64, jobType: 3, jobName: 'Laser Inscription'),
        _line(12, 2, 96),
      ]),
    );
    await pumpRouted(tester, services: h.services, initial: '/office/325/ready', routes: routes());
    await settle(tester);

    expect(find.text('Customer is set — Shah Gems'), findsOneWidget);
    expect(find.text('Line 2 needs a service'), findsOneWidget);
    expect(find.text('Every line has pieces'), findsOneWidget);
    expect(find.text('160 pcs, as requested'), findsOneWidget);
    expect(find.text('Fix the lines marked × first'), findsOneWidget);

    await tester.tap(find.byKey(const Key('mark-ready')));
    await settle(tester);
    expect(h.server.sent('POST', '/receipts'), isEmpty);
  });

  testWidgets('with no signal it waits, and says the entries stay on the phone', (tester) async {
    final h = await setUp(tester, _office(items: [_line(11, 1, 160, jobType: 3, jobName: 'Laser Inscription')]));
    await pumpRouted(
      tester,
      services: h.services,
      initial: '/office/325/ready',
      routes: routes(),
      overrides: [syncProvider.overrideWith(_Offline.new)],
    );
    await settle(tester);

    expect(find.byKey(const Key('needs-signal')), findsOneWidget);
    expect(find.textContaining('your entries stay saved here'), findsOneWidget);
    await tester.tap(find.byKey(const Key('mark-ready')));
    await settle(tester);
    expect(h.server.sent('POST', '/receipts'), isEmpty);
  });

  testWidgets('online and complete: the draft is saved, then READY, then back to the list', (tester) async {
    final h = await setUp(tester, _office(items: [_line(11, 1, 120, jobType: 3, jobName: 'Laser Inscription')]));
    // A draft on the phone: the office split the parcel into two lines.
    await h.services.drafts.saveNow(DraftStore.officeLines(325), {
      'base_rev': 3,
      'lines': [
        const OfficeLine(moveId: 11, size: '+11', pcs: 120, carats: 6.2, jobTypeId: 3, jobTypeName: 'Laser Inscription')
            .toDraft(),
        const OfficeLine(size: 'Stars', pcs: 40, carats: 3.5, jobTypeId: 4, jobTypeName: 'Ultra Sonic Boiling', requestId: 2)
            .toDraft(),
      ],
    });
    h.server
      ..on('PUT', '/receipts/{id}/lines', (r) => FakeResponse.json(_office(items: [
            _line(11, 1, 120, jobType: 3, jobName: 'Laser Inscription'),
            _line(13, 2, 40, jobType: 4, jobName: 'Ultra Sonic Boiling'),
          ])..['rev'] = 4))
      ..on('POST', '/receipts/{id}/ready',
          (r) => FakeResponse.json({'code': 'OK', 'state': 'assigned', 'reference': 'HO/IN/00325'}));

    await pumpRouted(tester, services: h.services, initial: '/office/325/ready', routes: routes());
    await settle(tester);

    expect(find.text('2 lines, each with a service'), findsOneWidget);
    expect(find.text('160 pcs, as requested'), findsOneWidget);
    expect(find.byKey(const Key('needs-signal')), findsNothing);

    await tester.tap(find.byKey(const Key('mark-ready')));
    await settle(tester, frames: 12);

    final put = h.server.sent('PUT', '/receipts/325/lines').single;
    expect(put.json['lines'], [
      {'move_id': 11, 'size': '+11', 'pcs': 120.0, 'carats': 6.2, 'job_type_id': 3, 'remarks': null},
      {'size': 'Stars', 'pcs': 40.0, 'carats': 3.5, 'job_type_id': 4, 'remarks': null, 'request_id': 2},
    ]);
    final ready = h.server.sent('POST', '/receipts/325/ready').single;
    expect(ready.headers['Idempotency-Key'], isNotNull);
    expect(find.text('OFFICE LIST'), findsOneWidget);
    expect(await drive(tester, h.services.records.officeOne(325)), isNull, reason: 'it left the office scope');
    expect(await drive(tester, h.services.drafts.load(DraftStore.officeLines(325))), isNull);
  });

  testWidgets('a refusal from the server is shown on the screen', (tester) async {
    final h = await setUp(tester, _office(items: [_line(11, 1, 160, jobType: 3, jobName: 'Laser Inscription')]));
    h.server.on('POST', '/receipts/{id}/ready', (r) => FakeResponse.json({
          'code': 'VALIDATION',
          'message': 'Line 1 needs a job type.',
          'retryable': false,
          'detail': {
            'problems': [
              {'move_id': 11, 'sr': 1, 'field': 'job_type_id', 'message': 'Line 1 needs a job type.'},
            ],
          },
        }, status: 422));
    await pumpRouted(tester, services: h.services, initial: '/office/325/ready', routes: routes());
    await settle(tester);
    await tester.tap(find.byKey(const Key('mark-ready')));
    await settle(tester, frames: 12);
    expect(find.text('Not ready yet'), findsOneWidget);
    expect(find.text('Line 1 needs a job type.'), findsOneWidget);
    expect(find.text('OFFICE LIST'), findsNothing);
  });
}
