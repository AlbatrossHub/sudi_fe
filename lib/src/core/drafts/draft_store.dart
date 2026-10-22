import 'dart:async';

import '../store/kv_store.dart';

/// A form, kept on the phone's disk as it is filled in, so it survives the app
/// being swiped off or killed by the phone: confirm pickup, cancel, deliver,
/// the customer's jangad request, a jangad posted for a customer, the office's
/// item table and a manual time entry. Cleared when the form is sent.
class Draft {
  const Draft(this.data, this.savedAt);

  final Map<String, dynamic> data;

  /// When it was last written: "the app was closed at 10:18".
  final DateTime savedAt;
}

class DraftStore {
  DraftStore(this._store, {Duration debounce = const Duration(milliseconds: 400)})
      : _debounce = debounce;

  final KvStore _store;
  final Duration _debounce;
  static const _prefix = 'draft/';

  /// The moment this process started: a draft saved before it was left behind
  /// by an app that went away, which is what the resume banner says.
  static final DateTime launchedAt = DateTime.now();

  final Map<String, Timer> _timers = {};
  final Map<String, Map<String, dynamic>> _pending = {};
  Future<void> _writing = Future.value();

  // Keys, so every screen spells them the same way.
  static String confirmPickup(int id) => 'confirm_pickup:$id';
  static String confirmPosted(String jangadLocalId) => 'confirm_posted:$jangadLocalId';
  static String cancelPickup(int id) => 'cancel_pickup:$id';
  static String deliver(int id) => 'deliver:$id';
  static const customerJangad = 'customer_jangad';
  static const onBehalf = 'on_behalf';
  static String officeLines(int id) => 'office_lines:$id';
  static String timeLog(int id) => 'time_log:$id';

  Future<Draft?> load(String key) async {
    final pending = _pending[key];
    if (pending != null) return Draft(pending, DateTime.now());
    final j = await _store.readJson('$_prefix$key');
    if (j == null || j['data'] is! Map) return null;
    return Draft(
      Map<String, dynamic>.from(j['data'] as Map),
      DateTime.tryParse('${j['saved_at']}')?.toLocal() ?? DateTime.now(),
    );
  }

  /// Saved a moment after the last change: typing goes on in between.
  void save(String key, Map<String, dynamic> data) {
    _pending[key] = data;
    _timers[key]?.cancel();
    _timers[key] = Timer(_debounce, () => unawaited(saveNow(key)));
  }

  /// Saved right away (the app is going to the background, or the step moved).
  Future<void> saveNow(String key, [Map<String, dynamic>? data]) {
    _timers.remove(key)?.cancel();
    final value = data ?? _pending[key];
    _pending.remove(key);
    if (value == null) return _writing;
    return _writing = _writing.then((_) async {
      try {
        await _store.writeJson('$_prefix$key', {
          'saved_at': DateTime.now().toUtc().toIso8601String(),
          'data': value,
        });
      } catch (_) {
        // A full disk must not break the form; it is still in memory.
      }
    });
  }

  /// Every debounced save, now -- called when the app goes to the background.
  Future<void> flushAll() async {
    for (final key in _pending.keys.toList()) {
      await saveNow(key);
    }
    await _writing;
  }

  Future<void> clear(String key) async {
    _timers.remove(key)?.cancel();
    _pending.remove(key);
    await _writing;
    await _store.delete('$_prefix$key');
  }

  /// Every draft key, for the boot-time sweep.
  Future<List<String>> keys() async => [
        for (final k in await _store.keys(_prefix)) k.substring(_prefix.length),
      ];

  Future<Map<String, Draft>> all() async {
    final out = <String, Draft>{};
    for (final key in await keys()) {
      final d = await load(key);
      if (d != null) out[key] = d;
    }
    return out;
  }

  /// The staged pages every live draft still names, under `pages`.
  static Set<String> referencedUploads(Iterable<Draft> drafts) => {
        for (final d in drafts)
          for (final id in (d.data['pages'] as List? ?? const [])) '$id',
      };
}
