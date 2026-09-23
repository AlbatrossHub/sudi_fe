import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api/api_client.dart';
import 'auth/auth_repository.dart';
import 'auth/device_identity.dart';
import 'auth/pin_gate.dart';
import 'auth/token_store.dart';
import 'clock/server_clock.dart';
import 'customer_repository.dart';
import 'db/database.dart';
import 'db/records_dao.dart';
import 'field_repository.dart';
import 'net/connectivity_watch.dart';
import 'net/location_probe.dart';
import 'outbox/outbox_flusher.dart';
import 'outbox/outbox_repository.dart';
import 'sync/sync_engine.dart';
import 'uploads/image_pipeline.dart';
import 'uploads/upload_repository.dart';

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
    required this.records,
    required this.clock,
    required this.outbox,
    required this.uploads,
    required this.flusher,
    required this.sync,
    required this.auth,
    required this.field,
    required this.customer,
    required this.pin,
    required this.net,
    required this.images,
    required this.location,
  });

  final TokenStore tokens;
  final DeviceIdentity device;
  final ApiClient api;
  final AppDatabase db;
  final RecordsDao records;
  final ServerClock clock;
  final OutboxRepository outbox;
  final UploadRepository uploads;
  final OutboxFlusher flusher;

  /// Field flavor only — the customer API has no `/sync/pull`.
  final SyncEngine sync;
  final AuthRepository auth;
  final FieldRepository field;
  final CustomerRepository customer;
  final PinGate pin;
  final ConnectivityWatch net;
  final ImagePipeline images;
  final LocationProbe location;

  int? myUserId;
  bool wiped = false;

  static Future<Services> boot() async {
    final tokens = TokenStore();
    final device = DeviceIdentity(tokens);
    final api = ApiClient(tokens);

    final db = AppDatabase(tokens);
    await db.open();

    final records = RecordsDao(db);
    final clock = ServerClock(() => db.db);
    await clock.load();

    final outbox = OutboxRepository(db, clock);
    final uploads = UploadRepository(db, api);
    final auth = AuthRepository(api, tokens, device);

    late final Services services;

    final flusher = OutboxFlusher(
      api: api,
      outbox: outbox,
      uploads: uploads,
      records: records,
      clock: clock,
      myUserId: () => services.myUserId,
    );

    services = Services._(
      tokens: tokens,
      device: device,
      api: api,
      db: db,
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
      pin: PinGate(tokens),
      net: ConnectivityWatch(),
      images: ImagePipeline(),
      location: const LocationProbe(),
    );

    api.wire(
      refresher: auth.refresh,
      onWipe: () => services.wiped = true,
    );

    await services.net.start();
    return services;
  }

  /// A `DEVICE_REVOKED` 401, or an explicit sign-out. Both clear everything;
  /// nothing else does.
  Future<void> wipeEverything() async {
    await db.wipe();
    await tokens.wipe();
    myUserId = null;
    wiped = false;
  }
}

/// Overridden in `main()`; reading it before boot is a programming error.
final servicesProvider = Provider<Services>(
  (ref) => throw StateError('servicesProvider was not overridden'),
);
