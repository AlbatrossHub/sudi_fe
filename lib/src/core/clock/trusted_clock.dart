import 'dart:math';

import 'package:flutter/services.dart';

import '../store/kv_store.dart';
import 'odoo_time.dart';

/// Which clock dated an event: the server's, counted forward with the phone's
/// uptime, or -- after a restart while offline, before the first pin -- the
/// phone's own. Sent with every intent so the office can tell them apart.
enum ClockSource { server, device }

class ClockStamp {
  const ClockStamp(this.utc, this.source);

  final DateTime utc;
  final ClockSource source;
}

/// Time since boot (never jumps when somebody changes the date, keeps counting
/// in deep sleep) and an id of the current boot.
///
/// Android: `SystemClock.elapsedRealtime()` + `Settings.Global.BOOT_COUNT`,
/// answered by `MainActivity` on the `sudi/clock` channel.
class MonoReading {
  const MonoReading(this.elapsedMs, this.bootId);

  final int elapsedMs;
  final int bootId;
}

abstract class Monotonic {
  Future<MonoReading> read();
}

class ChannelMonotonic implements Monotonic {
  static const _channel = MethodChannel('sudi/clock');

  // Fallback (tests, a platform without the channel): this process's own
  // stopwatch, valid only until the app restarts -- so the id is the process.
  static final _sw = Stopwatch()..start();
  static final _processId = DateTime.now().microsecondsSinceEpoch;

  @override
  Future<MonoReading> read() async {
    try {
      final r = await _channel.invokeMapMethod<String, Object?>('read');
      if (r != null && r['elapsed'] is num) {
        return MonoReading(
          (r['elapsed'] as num).toInt(),
          (r['boot'] as num? ?? -1).toInt(),
        );
      }
    } on MissingPluginException {
      // fall through
    } on PlatformException {
      // fall through
    }
    return MonoReading(_sw.elapsedMilliseconds, _processId);
  }
}

/// The app's clock for dating what people do.
///
/// Pinned to `GET /time` whenever the server answers, then counted forward with
/// the phone's uptime -- so changing the phone's date or time moves nothing,
/// and a phone that is hours out cannot misdate a pickup or turn a correct
/// capture into a `STALE_INTENT`. Only when the phone has restarted since the
/// last pin (uptime starts again) does it fall back to the phone's own clock,
/// and every stamp says which one it used.
///
/// [now] is synchronous for the screens ("recorded at 10:16"): it counts on from
/// the last uptime reading with a process stopwatch. [stamp] takes a fresh
/// reading and is what every captured intent is dated with.
class TrustedClock {
  TrustedClock({
    required Monotonic monotonic,
    required KvStore store,
    DateTime Function()? deviceNow,
    int Function()? processMs,
  })  : _mono = monotonic,
        _store = store,
        _deviceNow = deviceNow ?? DateTime.now,
        _processMs = processMs ?? _defaultProcessMs;

  static const _key = 'clock/anchor';

  /// Past this the screens tell the operator their phone's clock is wrong.
  static const skewWarnAfter = Duration(minutes: 10);

  /// The server refuses an event older than this, for good.
  static const maxBackdate = Duration(hours: 72);

  static final _process = Stopwatch()..start();
  static int _defaultProcessMs() => _process.elapsedMilliseconds;

  final Monotonic _mono;
  final KvStore _store;
  final DateTime Function() _deviceNow;
  final int Function() _processMs;

  _Anchor? _anchor;
  MonoReading? _last;
  int _lastAtProcessMs = 0;
  bool _loaded = false;

  Future<void> load() async {
    if (!_loaded) {
      _loaded = true;
      final j = await _store.readJson(_key);
      if (j != null && j['server'] is num && j['elapsed'] is num && j['boot'] is num) {
        _anchor = _Anchor(
          (j['server'] as num).toInt(),
          (j['elapsed'] as num).toInt(),
          (j['boot'] as num).toInt(),
        );
      }
    }
    await refresh();
  }

  /// Take a fresh uptime reading. Called on every stamp and when the app comes
  /// back to the foreground (the process stopwatch does not count deep sleep).
  Future<MonoReading> refresh() async {
    final r = await _mono.read();
    _last = r;
    _lastAtProcessMs = _processMs();
    return r;
  }

  /// A raw reading, taken just before and just after the `/time` request.
  Future<MonoReading> reading() => _mono.read();

  /// Pin to [server], read around the request: the server answered somewhere
  /// between [before] and [after], so the midpoint is the best guess and the
  /// error is at most half the round trip.
  Future<void> pin(DateTime server, MonoReading before, MonoReading after) async {
    if (before.bootId != after.bootId) return;
    final mid = (before.elapsedMs + after.elapsedMs) ~/ 2;
    _anchor = _Anchor(server.toUtc().millisecondsSinceEpoch, mid, after.bootId);
    _loaded = true;
    _last = after;
    _lastAtProcessMs = _processMs();
    await _store.writeJson(_key, {
      'server': _anchor!.serverMs,
      'elapsed': _anchor!.elapsedMs,
      'boot': _anchor!.bootId,
    });
  }

  bool _valid(MonoReading r) {
    final a = _anchor;
    return a != null && r.bootId == a.bootId && r.elapsedMs >= a.elapsedMs;
  }

  /// Counting from the server's time right now (as of the last reading).
  bool get pinned {
    final last = _last;
    return last != null && _valid(last);
  }

  ClockSource get source => pinned ? ClockSource.server : ClockSource.device;

  /// Local time, from the server's clock when pinned.
  DateTime now() {
    final last = _last;
    final a = _anchor;
    if (last != null && a != null && _valid(last)) {
      final elapsed = last.elapsedMs + (_processMs() - _lastAtProcessMs);
      return DateTime.fromMillisecondsSinceEpoch(
        a.serverMs + elapsed - a.elapsedMs,
        isUtc: true,
      ).toLocal();
    }
    return _deviceNow();
  }

  /// When something happens now -- what every intent is dated with.
  Future<ClockStamp> stamp() async {
    await refresh();
    return ClockStamp(now().toUtc(), source);
  }

  /// Server minus phone. Zero when not pinned: there is nothing to compare to.
  Duration get offset => pinned ? now().difference(_deviceNow()) : Duration.zero;

  bool get isSkewed => offset.abs() > skewWarnAfter;

  String get skewLabel {
    final ms = offset.inMilliseconds;
    final abs = Duration(milliseconds: ms.abs());
    final direction = ms < 0 ? 'fast' : 'slow';
    final h = abs.inHours;
    final m = abs.inMinutes % 60;
    return h > 0 ? '$h h $m m $direction' : '$m m $direction';
  }

  /// What goes in every intent body.
  Map<String, dynamic> envelopeFor(ClockStamp stamp) => {
        'occurred_at': OdooTime.stamp(stamp.utc.toLocal()),
        'clock_offset_ms': offset.inMilliseconds,
        'clock_source': stamp.source.name,
      };

  /// How long a captured intent has left before the server refuses it for good.
  Duration remainingFor(DateTime capturedAt) {
    final age = now().difference(capturedAt);
    return Duration(milliseconds: max(0, (maxBackdate - age).inMilliseconds));
  }
}

class _Anchor {
  const _Anchor(this.serverMs, this.elapsedMs, this.bootId);

  final int serverMs;
  final int elapsedMs;
  final int bootId;
}
