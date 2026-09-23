import 'dart:math';

import 'package:sqflite_sqlcipher/sqflite.dart';

import 'odoo_time.dart';

/// A field phone with a wrong date is common, and the server rejects anything
/// more than 60 s in the future or 72 h old. So every captured `occurred_at` is
/// stamped from the *corrected* clock, and the correction comes from
/// `server_time` on the last `/sync/pull`.
///
/// Correcting silently is right. Hiding it is not — past ~10 minutes the app
/// also tells the operator their phone's clock is wrong.
class ServerClock {
  ServerClock(this._db);

  final Database Function() _db;
  int _offsetMs = 0;
  bool _loaded = false;

  Duration get offset => Duration(milliseconds: _offsetMs);

  bool get isSkewed => _offsetMs.abs() > const Duration(minutes: 10).inMilliseconds;

  String get skewLabel {
    final abs = Duration(milliseconds: _offsetMs.abs());
    final direction = _offsetMs < 0 ? 'fast' : 'slow';
    final h = abs.inHours;
    final m = abs.inMinutes % 60;
    return h > 0 ? '$h h $m m $direction' : '$m m $direction';
  }

  Future<void> load() async {
    if (_loaded) return;
    final rows = await _db().query('sync',
        columns: ['server_offset_ms'], where: 'scope = ?', whereArgs: ['_all'], limit: 1);
    if (rows.isNotEmpty) {
      _offsetMs = (rows.first['server_offset_ms'] as num?)?.toInt() ?? 0;
    }
    _loaded = true;
  }

  /// Called with `server_time` from every pull.
  Future<void> observe(DateTime serverTime) async {
    _offsetMs = serverTime.difference(DateTime.now()).inMilliseconds;
    _loaded = true;
    await _db().rawInsert(
      'INSERT INTO sync (scope, server_offset_ms) VALUES (?, ?) '
      'ON CONFLICT(scope) DO UPDATE SET server_offset_ms = excluded.server_offset_ms',
      ['_all', _offsetMs],
    );
  }

  DateTime now() => DateTime.now().add(offset);

  /// The pair that goes in every intent body.
  Map<String, dynamic> envelope() => {
        'occurred_at': OdooTime.stamp(now()),
        'clock_offset_ms': _offsetMs,
      };

  /// How long a captured intent has left before the server refuses it for good.
  Duration remainingFor(DateTime capturedAt) {
    const limit = Duration(hours: 72);
    final age = now().difference(capturedAt);
    return Duration(milliseconds: max(0, (limit - age).inMilliseconds));
  }
}
