import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sudi_fe/src/core/api/api_error.dart';
import 'package:sudi_fe/src/core/clock/odoo_time.dart';
import 'package:sudi_fe/src/core/outbox/outbox.dart';

void main() {
  group('OdooTime', () {
    test('parses a naive Odoo timestamp as UTC, not as local time', () {
      // The server sends `2026-09-23T09:12:00` with no Z and no offset. A phone
      // that reads that as local time is hours out.
      final parsed = OdooTime.parse('2026-09-23T09:12:00')!;
      expect(parsed.toUtc().hour, 9);
      expect(parsed.toUtc().minute, 12);
    });

    test('respects an explicit zone when one is present', () {
      final parsed = OdooTime.parse('2026-09-23T09:12:00Z')!;
      expect(parsed.toUtc().hour, 9);
    });

    test('stamps occurred_at with an explicit offset', () {
      final stamped = OdooTime.stamp(DateTime(2026, 9, 23, 10, 4));
      expect(
        RegExp(r'([+-]\d{2}:\d{2}|Z)$').hasMatch(stamped),
        isTrue,
        reason: 'an ambiguous captured timestamp is a silent data bug',
      );
    });

    test('returns null rather than throwing on rubbish', () {
      expect(OdooTime.parse(null), isNull);
      expect(OdooTime.parse(''), isNull);
      expect(OdooTime.parse('not a date'), isNull);
    });

    test('anything persisted survives the round-trip through parse', () {
      // What the sync table stores has to come back as the same instant.
      // `last_pulled_at` was written with a bare `toIso8601String()` -- naive
      // *local* -- and `parse` reads a naive string as UTC, so in IST it came
      // back 5h30m in the future and the status strip read "just now" forever.
      final twoHoursAgo = DateTime.now().subtract(const Duration(hours: 2));
      final roundTripped = OdooTime.parse(OdooTime.stamp(twoHoursAgo))!;

      expect(
        roundTripped.difference(twoHoursAgo).inSeconds.abs(),
        lessThan(2),
        reason: 'a persisted timestamp must not shift by the UTC offset',
      );
      expect(OdooTime.ago(roundTripped), '2 h ago');
    });

    test('ago clamps a future stamp instead of matching every threshold', () {
      // A negative Duration is less than 45 seconds, less than 60 minutes and
      // less than 24 hours, so an unclamped future value pins the label to
      // "just now" no matter how stale the data really is.
      final now = DateTime(2026, 9, 23, 22, 0);
      final future = now.add(const Duration(hours: 5, minutes: 30));

      expect(OdooTime.ago(future, now: now), 'just now');
      // No "0 min ago" window between the two thresholds.
      expect(OdooTime.ago(now.subtract(const Duration(seconds: 50)), now: now), 'just now');
      expect(OdooTime.ago(now.subtract(const Duration(seconds: 61)), now: now), '1 min ago');
      expect(OdooTime.ago(now.subtract(const Duration(hours: 3)), now: now), '3 h ago');
      expect(OdooTime.ago(now.subtract(const Duration(days: 2)), now: now), '2 d ago');
      expect(OdooTime.ago(null), 'never');
    });
  });

  group('ApiError', () {
    ApiError fromBody(Map<String, dynamic> body, int status) => ApiError.fromDio(
          DioException(
            requestOptions: RequestOptions(path: '/x'),
            response: Response<Map<String, dynamic>>(
              requestOptions: RequestOptions(path: '/x'),
              statusCode: status,
              data: body,
            ),
            type: DioExceptionType.badResponse,
          ),
        );

    test('reads the server envelope verbatim', () {
      final error = fromBody({
        'code': 'ALREADY_TAKEN',
        'message': 'Taken for delivery by Rakesh at 09:12.',
        'retryable': false,
        'resync': [1234],
        'detail': {'user': 'Rakesh'},
      }, 409);

      expect(error.code, ApiError.alreadyTaken);
      expect(error.isLostRace, isTrue);
      expect(error.isPermanent, isTrue);
      expect(error.resync, [1234]);
      expect(error.detail['user'], 'Rakesh');
    });

    test('ALREADY_DONE is a success, not a failure', () {
      final error = fromBody(
        {'code': 'ALREADY_DONE', 'message': 'Already confirmed.', 'retryable': false},
        200,
      );
      expect(error.isReplay, isTrue);
      expect(error.isPermanent, isFalse);
    });

    test('DEVICE_REVOKED is the wipe signal', () {
      final error = fromBody(
        {'code': 'DEVICE_REVOKED', 'message': 'Revoked.', 'retryable': false},
        401,
      );
      expect(error.isWipe, isTrue);
    });

    test('a timeout is retryable network trouble, not a server refusal', () {
      final error = ApiError.fromDio(
        DioException(
          requestOptions: RequestOptions(path: '/x'),
          type: DioExceptionType.connectionTimeout,
        ),
      );
      expect(error.code, ApiError.network);
      expect(error.retryable, isTrue);
    });

    test('a bodyless 5xx is retryable', () {
      final error = ApiError.fromDio(
        DioException(
          requestOptions: RequestOptions(path: '/x'),
          response: Response<dynamic>(
            requestOptions: RequestOptions(path: '/x'),
            statusCode: 503,
          ),
          type: DioExceptionType.badResponse,
        ),
      );
      expect(error.retryable, isTrue);
    });
  });

  group('OutboxItem', () {
    OutboxItem sample() => OutboxItem(
          localId: 'local-1',
          kind: IntentKind.markDelivered,
          recordId: 5678,
          recordLabel: 'WH/OUT/00031',
          idemKey: 'idem-1',
          occurredAt: DateTime(2026, 9, 23, 11, 20),
          createdAt: DateTime(2026, 9, 23, 11, 20),
          body: const {'receiver_name': 'Jayesh Patel'},
        );

    test('survives a round trip through a database row', () {
      final restored = OutboxItem.fromRow(sample().toRow());
      expect(restored.localId, 'local-1');
      expect(restored.kind, IntentKind.markDelivered);
      expect(restored.recordId, 5678);
      expect(restored.body['receiver_name'], 'Jayesh Patel');
    });

    test('keeps its idempotency key across a retry', () {
      // This is what makes "the response was lost on a train" safe: a fresh key
      // on retry defeats the whole mechanism.
      final item = sample();
      final retried = item.copyWith(state: OutboxState.retrying, attempts: 3);
      expect(retried.idemKey, item.idemKey);
      expect(retried.occurredAt, item.occurredAt);
    });

    test('chains per record, so one conflict cannot block another parcel', () {
      final a = sample();
      final b = OutboxItem(
        localId: 'local-2',
        kind: IntentKind.releaseDelivery,
        recordId: 9999,
        idemKey: 'idem-2',
        occurredAt: DateTime(2026, 9, 23, 11, 25),
        createdAt: DateTime(2026, 9, 23, 11, 25),
        body: const {},
      );
      expect(a.chainKey, isNot(b.chainKey));
    });

    test('a jangad has no record, so it chains on itself', () {
      final jangad = OutboxItem(
        localId: 'local-3',
        kind: IntentKind.submitJangad,
        idemKey: 'idem-3',
        occurredAt: DateTime(2026, 9, 23, 10, 4),
        createdAt: DateTime(2026, 9, 23, 10, 4),
        body: const {},
      );
      expect(jangad.chainKey, 'local-3');
    });
  });
}
