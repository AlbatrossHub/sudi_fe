import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sudi_fe/src/config/flavor.dart';
import 'package:sudi_fe/src/core/outbox/outbox.dart';
import 'package:sudi_fe/src/core/outbox/outbox_flusher.dart';
import 'package:sudi_fe/src/models/docs.dart';

import 'support/fake_server.dart';
import 'support/harness.dart';

OutboxItem _item(String id, IntentKind kind, {int? record, List<int> records = const [], int seq = 0}) =>
    OutboxItem(
      localId: id,
      kind: kind,
      recordId: record,
      recordIds: records,
      idemKey: 'idem-$id',
      occurredAt: DateTime.utc(2026, 10, 22, 4, seq),
      createdAt: DateTime.utc(2026, 10, 22, 4, seq),
      seq: seq,
      body: const {},
    );

Map<String, dynamic> _pickupDoc(int id, {int rev = 1, String stage = 'awaiting'}) => {
      'id': id,
      'rev': rev,
      'name': 'HO/IN/$id',
      'stage': stage,
      'jangad_pages': 1,
      'customer': {'id': 412, 'name': 'Shah Gems'},
      'services': [],
    };

void main() {
  sudiFlavor = Flavor.field;

  group('one chain per record', () {
    test('different verbs on one record share a chain', () {
      // Regression: the key was `<verb prefix>:<id>`, so a confirm and a cancel
      // on the same pickup flushed in parallel, in either order.
      final confirm = _item('a', IntentKind.confirmPickup, record: 42);
      final cancel = _item('b', IntentKind.cancelPickup, record: 42);
      final timer = _item('c', IntentKind.timer, record: 7);
      final department = _item('d', IntentKind.department, record: 7);
      expect(confirm.chainKey, cancel.chainKey);
      expect(timer.chainKey, department.chainKey);
      expect(confirm.chainKey, isNot(timer.chainKey));
    });

    test('a multi-record take joins the chains of every parcel it names', () {
      final take = _item('t', IntentKind.takeDeliveries, records: [1, 2], seq: 1);
      final deliver2 = _item('d2', IntentKind.markDelivered, record: 2, seq: 2);
      final release1 = _item('r1', IntentKind.releaseDelivery, record: 1, seq: 3);
      final other = _item('o', IntentKind.markDelivered, record: 3, seq: 4);
      final chains = outboxChains([release1, other, deliver2, take]);
      expect(chains, hasLength(2));
      final joined = chains.firstWhere((c) => c.length == 3);
      expect([for (final i in joined) i.localId], ['t', 'd2', 'r1']);
    });

    test('an on-behalf jangad and its confirm are one chain before either has a record', () {
      final jangad = OutboxItem(
        localId: 'j',
        kind: IntentKind.submitOnBehalf,
        chain: 'local:j',
        idemKey: 'i1',
        occurredAt: DateTime.utc(2026),
        createdAt: DateTime.utc(2026),
        body: const {},
      );
      final confirm = OutboxItem(
        localId: 'c',
        kind: IntentKind.confirmPickup,
        chain: 'local:j',
        dependsOn: 'j',
        idemKey: 'i2',
        occurredAt: DateTime.utc(2026),
        createdAt: DateTime.utc(2026),
        seq: 1,
        body: const {},
      );
      expect(outboxChains([confirm, jangad]).single.map((i) => i.localId), ['j', 'c']);
    });

    test('intents on one record go in capture order, and wait behind a backing-off one',
        () async {
      final h = await buildHarness();
      final s = h.services;
      final order = <String>[];
      h.server.on('POST', '/pickups/{id}/confirm', (r) {
        order.add('confirm');
        return FakeResponse.error(503, 'SERVER', 'Busy.', retryable: true);
      });
      h.server.on('POST', '/pickups/{id}/cancel', (r) {
        order.add('cancel');
        return FakeResponse.json({'code': 'OK', 'record': _pickupDoc(42, rev: 2)});
      });
      await s.records.upsertPickups([_pickupDoc(42)]);
      await s.field.confirmPickup(id: 42, label: 'HO/IN/42');
      await s.field.cancelPickup(id: 42, label: 'HO/IN/42', reason: 'Shut');

      await s.flusher.flush();
      // The confirm failed and is backing off; the cancel behind it must wait.
      expect(order, ['confirm']);
      final open = await s.outbox.open();
      expect(open.map((i) => i.state), [OutboxState.retrying, OutboxState.pending]);

      await s.flusher.flush();
      expect(order, ['confirm'], reason: 'still inside the backoff window');
    });
  });

  group('boot', () {
    test('a row left sending by a killed app is retried', () async {
      final h = await buildHarness();
      final s = h.services;
      var sent = 0;
      h.server.on('POST', '/jobwork/{id}/timer', (r) {
        sent++;
        return FakeResponse.json({'code': 'OK'});
      });
      final item = await s.field.timer(id: 9, label: 'HO/IN/9', start: true);
      // The app died mid-request.
      await s.outbox.save(item.copyWith(state: OutboxState.sending));

      await s.flusher.flush();
      expect(sent, 0, reason: 'a sending row is never picked up as it is');

      await s.housekeeping(); // what boot runs
      expect((await s.outbox.byId(item.localId))!.state, OutboxState.pending);
      await s.flusher.flush();
      expect(sent, 1);
      expect(await s.outbox.open(), isEmpty);
      // Same idempotency key as at capture: the server can replay its answer.
      expect(h.server.sent('POST', '/jobwork').single.headers['Idempotency-Key'], item.idemKey);
    });
  });

  group('multi-record take', () {
    test('every parcel it names shows it queued', () async {
      final h = await buildHarness();
      await h.services.field.takeDeliveries([11, 12, 13]);
      final pending = await h.services.outbox.pendingByRecord();
      expect(pending.keys.toSet(), {11, 12, 13});
      expect(pending[12]!.single.kind, IntentKind.takeDeliveries);
    });
  });

  group('jangad for a customer, then collect it now', () {
    Future<Harness> setUp({FakeResponse Function(FakeRequest)? jangads}) async {
      final h = await buildHarness();
      h.server
        ..on('POST', '/uploads', (r) => FakeResponse.json({'reference': 'up-1'}))
        ..on('POST', '/jangads', jangads ??
            (r) => FakeResponse.json({
                  'picking_id': 501,
                  'reference': 'HO/IN/00501',
                  'pickup': _pickupDoc(501),
                }))
        ..on('POST', '/pickups/{id}/confirm', (r) => FakeResponse.json({
              'code': 'OK',
              'record': _pickupDoc(r.param('id'), rev: 2, stage: 'collected'),
            }));
      return h;
    }

    Future<(OutboxItem, OutboxItem)> post(Harness h) async {
      final s = h.services;
      final page = await s.uploads.stage(await h.photo('p1'), pageIndex: 0);
      final jangad = await s.field.postOnBehalf(
        request: const OnBehalfRequest(
          partnerId: 412,
          pickupAddressId: 418,
          services: [ServiceRequest(jobTypeId: 3, name: 'Laser Inscription', unit: 'pcs', quantity: 120)],
        ),
        pageLocalIds: [page.localId],
        customerName: 'Shah Gems',
        addressLabel: 'Opera House',
      );
      final confirm = await s.field.confirmAfterPosting(jangad: jangad, label: 'Shah Gems');
      return (jangad, confirm);
    }

    test('both go in order, and the confirm uses the id the post returned', () async {
      final h = await setUp();
      final (jangad, confirm) = await post(h);
      expect(confirm.recordId, isNull);
      expect(confirm.chainKey, jangad.chainKey);

      await h.services.flusher.flush();

      final posts = h.server.sent('POST');
      expect(posts.map((r) => r.path).toList(), ['/uploads', '/jangads', '/pickups/501/confirm']);
      final body = posts[1].json;
      expect(body['customer'], {'partner_id': 412});
      expect(body['upload_ids'], ['up-1']);
      expect(body['services'], [
        {'job_type_id': 3, 'quantity': 120.0},
      ]);
      expect(body['occurred_at'], isNotNull);
      expect(posts[2].headers['Idempotency-Key'], confirm.idemKey);

      expect(await h.services.outbox.open(), isEmpty);
      final pickup = await h.services.records.pickup(501);
      expect(pickup!.isCollected, isTrue);
      final landed = await h.services.kv.readJson(OutboxFlusher.postedKey(jangad.localId));
      expect(landed!['picking_id'], 501);
      expect(landed['reference'], 'HO/IN/00501');
      // The outbox row is gone, so the "posted" screen reads what was posted from
      // here (found on the phone: it showed "the customer" and dashes instead).
      expect((landed['meta'] as Map)['customer_name'], 'Shah Gems');
      expect((landed['meta'] as Map)['pages'], 1);
      expect(DateTime.tryParse('${landed['occurred_at']}'), isNotNull);
    });

    test('offline, both wait; nothing is sent ahead of the jangad', () async {
      final h = await setUp();
      await post(h);
      h.server.offline = true;
      await h.services.flusher.flush();
      final open = await h.services.outbox.open();
      expect(open.first.state, OutboxState.retrying);
      expect(open.last.state, OutboxState.pending);

      h.server.offline = false;
      await h.services.flusher.flush(ignoreBackoff: true);
      expect(h.server.sent('POST').map((r) => r.path).last, '/pickups/501/confirm');
      expect(await h.services.outbox.open(), isEmpty);
    });

    test('a refused jangad holds its confirm back, visibly', () async {
      final h = await setUp(
        jangads: (r) => FakeResponse.error(422, 'VALIDATION', 'That number belongs to staff.'),
      );
      final (_, confirm) = await post(h);
      await h.services.flusher.flush();
      await h.services.flusher.flush();
      final held = await h.services.outbox.byId(confirm.localId);
      expect(held!.state, OutboxState.needsAttention);
      expect(held.lastErrorCode, 'DEPENDENCY');
      expect(h.server.sent('POST', '/pickups'), isEmpty);
    });
  });

  group('resync', () {
    test('a lost race names records to re-pull, and the re-pull skips the ETag', () async {
      final h = await buildHarness();
      final s = h.services;
      await s.records.upsertPickups([_pickupDoc(42)]);
      await s.records.saveCursor('_all', cursor: '10', etag: 'W/"abc"');
      h.server
        ..on('POST', '/pickups/{id}/confirm',
            (r) => FakeResponse.error(409, 'ALREADY_CONFIRMED', 'Rakesh got it.', resync: [42]))
        ..on('GET', '/sync/pull', (r) => FakeResponse.json({
              'cursor': 11,
              'full_resync': false,
              'has_more': false,
              'server_time': '2026-10-22T04:35:00',
              'scopes': {
                'pickup': {
                  'upserts': [_pickupDoc(42, rev: 5, stage: 'collected')],
                  'gone': [],
                },
              },
            }));
      await s.field.confirmPickup(id: 42, label: 'HO/IN/42');
      await s.flusher.flush();

      final resync = s.flusher.takeResync();
      expect(resync.resync, contains(42));

      final outcome = await s.sync.pull(resyncIds: resync.resync);
      expect(outcome.touched, contains(42));
      expect(h.server.sent('GET', '/sync/pull').single.headers['If-None-Match'], isNull);
      expect((await s.records.pickup(42))!.rev, 5);
    });
  });

  group('flush', () {
    test('an intent captured during a flush is sent by the same call', () async {
      final h = await buildHarness();
      final s = h.services;
      final gate = Completer<void>();
      h.server.on('POST', '/jobwork/{id}/timer', (r) async {
        if (!gate.isCompleted) await gate.future;
        return FakeResponse.json({'code': 'OK'});
      });
      await s.field.timer(id: 1, label: 'A', start: true);
      final first = s.flusher.flush();
      await s.field.timer(id: 2, label: 'B', start: true);
      final second = s.flusher.flush();
      gate.complete();
      await Future.wait([first, second]);
      expect(h.server.sent('POST', '/jobwork'), hasLength(2));
    });
  });
}
