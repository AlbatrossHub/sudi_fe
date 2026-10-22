import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/flavor.dart';
import 'api/api_client.dart';
import 'api/api_error.dart';
import 'auth/auth_repository.dart';
import 'auth/device_identity.dart';
import 'auth/pin_gate.dart';
import 'auth/token_store.dart';
import 'cache/response_cache.dart';
import 'clock/odoo_time.dart';
import 'clock/trusted_clock.dart';
import 'customer_repository.dart';
import 'db/database.dart';
import 'db/records_dao.dart';
import 'drafts/draft_store.dart';
import 'field_repository.dart';
import 'net/connectivity_watch.dart';
import 'net/location_probe.dart';
import 'outbox/outbox_flusher.dart';
import 'outbox/outbox_repository.dart';
import 'resume/resume_store.dart';
import 'store/kv_store.dart';
import 'sync/sync_engine.dart';
import 'uploads/image_pipeline.dart';
import 'uploads/upload_repository.dart';
import 'v2_repository.dart';

/// Everything long-lived, built once in `main()` before `runApp`.
///
/// Constructing this is the only async work at startup, and it does not touch
/// the network: the app must open, unlock and accept captures with no radio and
/// an expired token.
class Services {
  Services._({
    required this.tokens,
    required this.device,
    required this.api,
    required this.db,
    required this.kv,
    required this.records,
    required this.clock,
    required this.outbox,
    required this.uploads,
    required this.flusher,
    required this.sync,
    required this.auth,
    required this.field,
    required this.customer,
    required this.v2,
    required this.cache,
    required this.drafts,
    required this.resume,
    required this.pin,
    required this.net,
    required this.images,
    required this.location,
  });

  final TokenStore tokens;
  final DeviceIdentity device;
  final ApiClient api;
  final AppDatabase db;
  final KvStore kv;
  final RecordsDao records;
  final TrustedClock clock;
  final OutboxRepository outbox;
  final UploadRepository uploads;
  final OutboxFlusher flusher;

  /// Field flavor only — the customer API has no `/sync/pull`.
  final SyncEngine sync;
  final AuthRepository auth;
  final FieldRepository field;
  final CustomerRepository customer;
  final V2Repository v2;
  final ResponseCache cache;
  final DraftStore drafts;
  final ResumeStore resume;
  final PinGate pin;
  final ConnectivityWatch net;
  final ImagePipeline images;
  final LocationProbe location;

  int? myUserId;
  bool wiped = false;

  static Future<Services> boot() => create();

  /// [create] with everything real, or with fakes handed in by tests: an
  /// already-open database, a Dio adapter standing in for the server, a
  /// monotonic clock that does what it is told, a radio that is switched by
  /// hand.
  static Future<Services> create({
    TokenStore? tokens,
    AppDatabase? database,
    HttpClientAdapter? http,
    Transformer? transformer,
    Monotonic? monotonic,
    DateTime Function()? deviceNow,
    int Function()? processMs,
    ConnectivityWatch? net,
    Future<Directory> Function()? stagingDirectory,
    bool housekeeping = true,
  }) async {
    final tokenStore = tokens ?? TokenStore();
    final device = DeviceIdentity(tokenStore);
    final api = ApiClient(tokenStore, adapter: http, transformer: transformer);

    final db = database ?? AppDatabase(tokenStore);
    await db.open();
    if (db.recovered) {
      // The old file could not be opened and was replaced: nothing the
      // session refers to exists any more, so sign in again from scratch.
      await tokenStore.wipe();
    }

    final kv = SqlKvStore(db);
    final records = RecordsDao(db);
    final clock = TrustedClock(
      monotonic: monotonic ?? ChannelMonotonic(),
      store: kv,
      deviceNow: deviceNow,
      processMs: processMs,
    );
    await clock.load();

    final cache = ResponseCache(kv);
    final outbox = OutboxRepository(db, clock);
    final uploads = UploadRepository(db, api, stagingDirectory: stagingDirectory);
    final auth = AuthRepository(api, tokenStore, device, cache);
    final drafts = DraftStore(kv);
    final resume = ResumeStore(
      kv,
      home: sudiFlavor.isField ? '/pickups' : '/home',
      isResumable: isResumableLocation,
      isTab: isTabLocation,
    );

    late final Services services;

    final flusher = OutboxFlusher(
      api: api,
      outbox: outbox,
      uploads: uploads,
      records: records,
      clock: clock,
      store: kv,
      myUserId: () => services.myUserId,
    );

    services = Services._(
      tokens: tokenStore,
      device: device,
      api: api,
      db: db,
      kv: kv,
      records: records,
      clock: clock,
      outbox: outbox,
      uploads: uploads,
      flusher: flusher,
      sync: SyncEngine(
        api: api,
        db: db,
        records: records,
        clock: clock,
        myUserId: () => services.myUserId,
      ),
      auth: auth,
      field: FieldRepository(api, outbox),
      customer: CustomerRepository(outbox, records),
      v2: V2Repository(api, cache, PageCache(db), records),
      cache: cache,
      drafts: drafts,
      resume: resume,
      pin: PinGate(tokenStore),
      net: net ?? ConnectivityWatch(),
      images: ImagePipeline(),
      location: const LocationProbe(),
    );

    api.wire(
      refresher: auth.refresh,
      onWipe: () => services.wiped = true,
    );
    // Online means the server answered: every request says whether it did.
    api.onReachability = services.net.reportServer;
    services.net.probe = services.pinClock;

    await resume.load();
    if (housekeeping) await services.housekeeping();
    await services.net.start();
    return services;
  }

  /// Boot-time repairs, before anything is drawn.
  ///
  /// * A row left `sending` by a killed app goes back to pending; so does an
  ///   upload left `uploading`.
  /// * Staged pages no draft and no intent names are swept (with their files).
  /// * A draft for a record that is no longer on this phone is dropped.
  Future<void> housekeeping() async {
    await outbox.recoverInterrupted();
    await uploads.recoverInterrupted();
    final all = await drafts.all();
    for (final entry in all.entries) {
      final id = _recordOfDraft(entry.key);
      final stale = DateTime.now().difference(entry.value.savedAt) > const Duration(days: 7);
      if (stale || (id != null && !await _recordExists(entry.key, id))) {
        await drafts.clear(entry.key);
      }
    }
    final keep = DraftStore.referencedUploads((await drafts.all()).values);
    await uploads.sweepOrphans(keep: keep);
  }

  static int? _recordOfDraft(String key) {
    final colon = key.indexOf(':');
    if (colon < 0) return null;
    return int.tryParse(key.substring(colon + 1));
  }

  Future<bool> _recordExists(String key, int id) async {
    if (key.startsWith('confirm_pickup:') || key.startsWith('cancel_pickup:')) {
      return await records.pickup(id) != null;
    }
    if (key.startsWith('deliver:')) return await records.delivery(id) != null;
    if (key.startsWith('time_log:')) return await records.jobWorkOne(id) != null;
    if (key.startsWith('office_lines:')) return await records.officeOne(id) != null;
    return true;
  }

  /// `GET /time`, read between two uptime readings, pins the trusted clock.
  /// Also the reachability probe: true when the server answered.
  Future<bool> pinClock() async {
    try {
      final before = await clock.reading();
      final response = await api.get<Map<String, dynamic>>(V2Paths.time, skipAuth: true);
      final after = await clock.reading();
      final server = OdooTime.parse((response.data ?? const {})['server_time']);
      if (server != null) await clock.pin(server, before, after);
      return true;
    } on ApiError catch (e) {
      // A server without /time yet still answered.
      return e.code != ApiError.network;
    }
  }

  /// A `DEVICE_REVOKED` 401, or an explicit sign-out. Both clear everything;
  /// nothing else does.
  Future<void> wipeEverything() async {
    await resume.clear();
    await db.wipe();
    await tokens.wipe();
    myUserId = null;
    wiped = false;
  }
}

/// Locations worth coming back to after the app went away. Sign-in, the lock
/// screen and one-off acknowledgements are not.
bool isResumableLocation(String location) {
  final path = location.split('?').first;
  if (sudiFlavor.isField) {
    return isTabLocation(path) ||
        RegExp(r'^/(pickup|delivery|jobwork|office)/\d+(/[a-z]+)?$').hasMatch(path) ||
        path.startsWith('/onbehalf') ||
        path == '/notices' ||
        path == '/queue';
  }
  return const {'/home', '/request', '/request/jangad', '/request/address', '/submitted'}
      .contains(path);
}

bool isTabLocation(String location) => sudiFlavor.isField
    ? const {'/pickups', '/deliveries', '/jobwork', '/mywork', '/office'}.contains(location)
    : location == '/home';

/// Overridden in `main()`; reading it before boot is a programming error.
final servicesProvider = Provider<Services>(
  (ref) => throw StateError('servicesProvider was not overridden'),
);
