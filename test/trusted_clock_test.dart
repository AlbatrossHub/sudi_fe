import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sudi_fe/src/config/flavor.dart';
import 'package:sudi_fe/src/core/clock/trusted_clock.dart';
import 'package:sudi_fe/src/core/outbox/outbox.dart';
import 'package:sudi_fe/src/core/services.dart';
import 'package:sudi_fe/src/core/store/kv_store.dart';
import 'package:sudi_fe/src/core/sync_status.dart';

import 'support/fake_server.dart';
import 'support/harness.dart';

void main() {
  // The customer flavor: the one that never corrected its clock before v2,
  // because it never calls /sync/pull.
  sudiFlavor = Flavor.customer;

  final server = DateTime.utc(2026, 10, 22, 4, 35);

  group('TrustedClock', () {
    late FakeMonotonic mono;
    late MemoryKvStore store;
    late DateTime device;

    TrustedClock clock() => TrustedClock(
          monotonic: mono,
          store: store,
          deviceNow: () => device,
          processMs: () => 0,
        );

    setUp(() {
      mono = FakeMonotonic(elapsedMs: 5000000, bootId: 3);
      store = MemoryKvStore();
      // The phone is three hours slow.
      device = server.subtract(const Duration(hours: 3)).toLocal();
    });

    test('unpinned, it says so and uses the phone clock', () async {
      final c = clock();
      await c.load();
      expect(c.pinned, isFalse);
      final stamp = await c.stamp();
      expect(stamp.source, ClockSource.device);
      expect(stamp.utc, device.toUtc());
      expect(c.offset, Duration.zero);
    });

    test('pinned to the server, it counts on with uptime and ignores the phone date', () async {
      final c = clock();
      await c.load();
      final before = MonoReading(mono.elapsedMs, 3);
      mono.advance(const Duration(milliseconds: 400));
      final after = MonoReading(mono.elapsedMs, 3);
      await c.pin(server, before, after);

      // Ten minutes of uptime later, with somebody changing the phone's date.
      mono.advance(const Duration(minutes: 10));
      device = DateTime(2031, 1, 1);
      final stamp = await c.stamp();

      expect(stamp.source, ClockSource.server);
      // The pin is the midpoint of the round trip: 200 ms after `before`.
      expect(
        stamp.utc,
        server.add(const Duration(minutes: 10, milliseconds: 200)),
      );
    });

    test('a restarted phone (new boot) falls back to the phone clock', () async {
      final c = clock();
      await c.load();
      await c.pin(server, MonoReading(mono.elapsedMs, 3), MonoReading(mono.elapsedMs, 3));
      mono
        ..bootId = 4
        ..elapsedMs = 1000;
      final stamp = await c.stamp();
      expect(stamp.source, ClockSource.device);
      expect(c.pinned, isFalse);
    });

    test('a pin read across a reboot is thrown away', () async {
      final c = clock();
      await c.load();
      await c.pin(server, const MonoReading(10, 3), const MonoReading(20, 4));
      expect(c.pinned, isFalse);
    });

    test('the anchor survives the app being killed', () async {
      final first = clock();
      await first.load();
      await first.pin(server, MonoReading(mono.elapsedMs, 3), MonoReading(mono.elapsedMs, 3));

      mono.advance(const Duration(minutes: 3));
      final second = clock(); // a new process, same store
      await second.load();
      expect(second.pinned, isTrue);
      expect((await second.stamp()).utc, server.add(const Duration(minutes: 3)));
    });

    test('the envelope carries an offset, the correction and the source', () async {
      final c = clock();
      await c.load();
      await c.pin(server, MonoReading(mono.elapsedMs, 3), MonoReading(mono.elapsedMs, 3));
      final envelope = c.envelopeFor(await c.stamp());
      expect(RegExp(r'([+-]\d{2}:\d{2}|Z)$').hasMatch(envelope['occurred_at'] as String), isTrue);
      expect(envelope['clock_offset_ms'], const Duration(hours: 3).inMilliseconds);
      expect(envelope['clock_source'], 'server');
      expect(c.isSkewed, isTrue);
      expect(c.skewLabel, '3 h 0 m slow');
    });
  });

  group('customer flavor', () {
    test('pins to GET /time and dates its jangad from the server clock', () async {
      final fake = FakeServer(basePath: '/api/customer/v1')..serverTime = server;
      final h = await buildHarness(server: fake, roles: const ['customer']);
      final container = ProviderContainer(
        overrides: [servicesProvider.overrideWithValue(h.services)],
      );
      addTearDown(container.dispose);

      expect(h.services.clock.pinned, isFalse);
      await container.read(syncProvider.notifier).syncNow();
      expect(h.services.clock.pinned, isTrue);
      expect(fake.sent('GET', '/time'), isNotEmpty);

      h.server.offline = true; // capture with no signal
      h.mono.advance(const Duration(minutes: 5));
      final item = await h.services.outbox.enqueue(kind: IntentKind.submitJangad, body: {});
      expect(item.occurredAt, server.add(const Duration(minutes: 5)));
      expect(item.body['clock_source'], 'server');
    });
  });
}
