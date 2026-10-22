import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sudi_fe/src/config/env.dart';
import 'package:sudi_fe/src/config/flavor.dart';
import 'package:sudi_fe/src/core/auth/token_store.dart';
import 'package:sudi_fe/src/core/cache/response_cache.dart';
import 'package:sudi_fe/src/core/drafts/draft_store.dart';
import 'package:sudi_fe/src/core/resume/resume_store.dart';
import 'package:sudi_fe/src/core/services.dart';
import 'package:sudi_fe/src/core/store/kv_store.dart';
import 'package:sudi_fe/src/core/sync_status.dart';

import 'support/fake_server.dart';
import 'support/harness.dart';

Map<String, dynamic> _job(int id, int rev, {String name = 'HO/IN/1'}) => {
      'id': id,
      'rev': rev,
      'name': name,
      'state': 'assigned',
      'total_hours': 0,
      'timer': {'running': false},
      'jangad_pages': 0,
    };

void main() {
  sudiFlavor = Flavor.field;

  group('records keep the newest revision', () {
    test('an older document arriving late does not overwrite a newer one', () async {
      final h = await buildHarness();
      final records = h.services.records;
      await records.upsertJobWork([_job(5, 7, name: 'seven')]);
      await records.upsertJobWork([_job(5, 3, name: 'three')]);
      expect((await records.jobWorkOne(5))!.name, 'seven');

      await records.upsertJobWork([_job(5, 7, name: 'seven again')]);
      expect((await records.jobWorkOne(5))!.name, 'seven again', reason: 'equal rev replaces');
      await records.upsertJobWork([_job(5, 9, name: 'nine')]);
      expect((await records.jobWorkOne(5))!.rev, 9);
    });

    test('an intent answer older than the pull is ignored too', () async {
      final h = await buildHarness();
      final records = h.services.records;
      await records.upsertPickups([
        {'id': 8, 'rev': 4, 'name': 'new', 'stage': 'collected', 'jangad_pages': 1},
      ]);
      await records.applyIntentRecord('pickup', {
        'id': 8,
        'rev': 2,
        'name': 'old',
        'stage': 'awaiting',
        'jangad_pages': 1,
      });
      expect((await records.pickup(8))!.isCollected, isTrue);
    });

    test('the office scope is stored and read back', () async {
      final h = await buildHarness();
      await h.services.records.upsertOffice([
        {
          'id': 325,
          'rev': 1,
          'name': 'HO/IN/00325',
          'stage': 'collected',
          'jangad_pages': 2,
          'jangad_source': 'on_behalf',
          'posted_by': {'id': 9, 'name': 'Rakesh Patel'},
          'services': [
            {
              'id': 1,
              'job_type': {'id': 3, 'name': 'Laser Inscription'},
              'quantity': 120,
              'unit': 'pcs',
              'remarks': 'big stones first',
            },
          ],
          'items': [],
        },
      ]);
      final doc = (await h.services.records.officeOne(325))!;
      expect(doc.sourceLabel, 'Posted by Rakesh');
      expect(doc.services.single.quantityLabel, '120 pcs');
      expect(doc.requestedPcs, 120);
    });
  });

  group('saved copy of every GET', () {
    test('keys include the query in a stable order', () {
      expect(
        ResponseCache.keyFor('/me/productivity', {'date_to': '2026-10-26', 'date_from': '2026-10-20'}),
        'cache//me/productivity?date_from=2026-10-20&date_to=2026-10-26',
      );
    });

    test('a screen opens from the copy offline, and a 304 hands the copy back', () async {
      final h = await buildHarness();
      var calls = 0;
      h.server.on('GET', '/catalog/job-types', (r) {
        calls++;
        if (r.headers['If-None-Match'] == 'W/"v1"') return FakeResponse.json(null, status: 304);
        return FakeResponse.json(
          [
            {'id': 3, 'name': 'Laser Inscription', 'unit': 'pcs', 'sequence': 1},
          ],
          headers: {
            'etag': ['W/"v1"'],
          },
        );
      });
      final v2 = h.services.v2;
      expect(await v2.savedJobTypes(), isNull);
      expect((await v2.jobTypes()).single.name, 'Laser Inscription');

      final again = await v2.jobTypes();
      expect(calls, 2);
      expect(again.single.id, 3, reason: '304 answered from the saved copy');

      h.server.offline = true;
      expect((await v2.savedJobTypes())!.single.name, 'Laser Inscription');
    });

    test('a jangad page is kept, encrypted with the rest, for offline', () async {
      final h = await buildHarness();
      h.server.on('GET', '/pickups/{id}/jangad/{page}',
          (r) => FakeResponse.bytes(Uint8List.fromList([1, 2, 3])));
      await h.services.v2.jangadPage(42, 0);
      h.server.offline = true;
      expect(await h.services.v2.savedPage(42, 0), [1, 2, 3]);
    });

    test('signing out clears the copies but not the clock anchor', () async {
      final h = await buildHarness();
      await h.services.cache.put('/customers', [1]);
      await h.services.kv.write('clock/anchor', '{"server":1,"elapsed":1,"boot":1}');
      await h.services.db.wipe();
      expect(await h.services.cache.get('/customers'), isNull);
      expect(await h.services.kv.read('clock/anchor'), isNotNull);
    });
  });

  group('resume where you left off', () {
    ResumeStore store(KvStore kv) => ResumeStore(
          kv,
          home: '/pickups',
          isResumable: isResumableLocation,
          isTab: isTabLocation,
        );

    test('the page, the tab under it and the segment survive a kill', () async {
      final kv = MemoryKvStore();
      final first = store(kv)..location('/jobwork');
      first
        ..location('/jobwork/12/log')
        ..setSegment('pickups', 1);
      await first.flush();

      final second = store(kv); // the app came back
      final point = await second.load();
      expect(point.location, '/jobwork/12/log');
      expect(point.tab, '/jobwork');
      expect(point.hasPage, isTrue);
      expect(second.segment('pickups'), 1);
    });

    test('sign-in and lock screens are never somewhere to come back to', () async {
      final kv = MemoryKvStore();
      final s = store(kv)
        ..location('/office')
        ..location('/unlock')
        ..location('/signin');
      await s.flush();
      final point = await store(kv).load();
      expect(point.location, '/office');
    });
  });

  group('drafts survive a kill', () {
    test('saved after a pause in typing, read back by a fresh process', () {
      fakeAsync((async) {
        final kv = MemoryKvStore();
        final drafts = DraftStore(kv);
        drafts.save(DraftStore.confirmPickup(42), {'note': 'Sealed', 'pages': ['p1']});
        drafts.save(DraftStore.confirmPickup(42), {'note': 'Sealed packet', 'pages': ['p1']});
        async.flushMicrotasks();
        expect(kv.data, isEmpty, reason: 'debounced while typing');
        async.elapse(const Duration(milliseconds: 500));

        Draft? restored;
        DraftStore(kv).load(DraftStore.confirmPickup(42)).then((d) => restored = d);
        async.flushMicrotasks();
        expect(restored!.data['note'], 'Sealed packet');
        expect(restored!.data['pages'], ['p1']);
      });
    });

    test('flushAll writes what is still waiting (the app is going away)', () async {
      final kv = MemoryKvStore();
      final drafts = DraftStore(kv, debounce: const Duration(hours: 1));
      drafts.save(DraftStore.onBehalf, {'step': 2});
      await drafts.flushAll();
      expect((await DraftStore(kv).load(DraftStore.onBehalf))!.data['step'], 2);
      await drafts.clear(DraftStore.onBehalf);
      expect(await DraftStore(kv).load(DraftStore.onBehalf), isNull);
    });

    test('staged pages no draft names are swept at boot; named ones stay', () async {
      final h = await buildHarness();
      final s = h.services;
      final kept = await s.uploads.stage(await h.photo('kept'));
      final orphan = await s.uploads.stage(await h.photo('orphan'));
      await s.drafts.saveNow(DraftStore.customerJangad, {'pages': [kept.localId]});

      final swept = await s.uploads.sweepOrphans(
        keep: DraftStore.referencedUploads((await s.drafts.all()).values),
        now: DateTime.now().add(const Duration(days: 1)),
      );
      expect(swept, greaterThanOrEqualTo(1));
      final left = await s.uploads.unattached();
      expect(left.map((u) => u.localId), [kept.localId]);
      expect(File(orphan.filePath).existsSync(), isFalse);
      expect(File(kept.filePath).existsSync(), isTrue);
    });
  });

  group('sign-out', () {
    test('the database key survives it, or the next launch cannot open the file', () async {
      // Found on the M31: sign out, sign in as someone else, relaunch -- the
      // key had been dropped with the tokens while the encrypted file stayed,
      // so the app hung on a blank screen at every start.
      FlutterSecureStorage.setMockInitialValues({});
      final tokens = TokenStore();
      final key = await tokens.databaseKey(() => 'k1');
      await tokens.wipe();
      expect(await tokens.databaseKey(() => 'k2'), key);
      await tokens.forgetDatabaseKey();
      expect(await tokens.databaseKey(() => 'k3'), 'k3');
    });
  });

  group('polling', () {
    test('the back-off interval is read before every poll, not once', () {
      fakeAsync((async) {
        var interval = Env.pollInterval;
        var ticks = 0;
        final poll = PollScheduler(
          interval: () => interval,
          tick: () async {
            ticks++;
            // After this poll the server has said "nothing changed" enough times.
            interval = Env.pollIntervalBackedOff;
          },
        )..start();

        async.elapse(Env.pollInterval);
        expect(ticks, 1);
        // With Timer.periodic the next poll came 60 s later regardless.
        async.elapse(Env.pollInterval);
        expect(ticks, 1);
        async.elapse(Env.pollIntervalBackedOff - Env.pollInterval);
        expect(ticks, 2);
        poll.stop();
      });
    });

    test('our own change ends the 304 back-off, so it is pulled within seconds', () async {
      // Found on the phone: a pickup collected one second before a pull was still
      // inside the server's visibility lag, the pull answered 304, three of those
      // had backed polling off to five minutes, and the receipt took that long to
      // reach the Office tab.
      final h = await buildHarness();
      final s = h.services;
      await s.records.saveCursor('_all', cursor: '8', etag: 'W/"c8"');
      h.server.on('GET', '/sync/pull', (r) => FakeResponse.json(null, status: 304));
      for (var i = 0; i < 3; i++) {
        await s.sync.pull();
      }
      expect(s.sync.pollInterval, Env.pollIntervalBackedOff);
      s.sync.noteLocalChange();
      expect(s.sync.pollInterval, Env.pollInterval);
      expect(SyncController.followUpAfterOwnChange, lessThan(Env.pollInterval));
    });
  });
}
