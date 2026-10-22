import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sudi_fe/src/core/auth/token_store.dart';
import 'package:sudi_fe/src/core/clock/trusted_clock.dart';
import 'package:sudi_fe/src/core/db/database.dart';
import 'package:sudi_fe/src/core/net/connectivity_watch.dart';
import 'package:sudi_fe/src/core/notices/notices.dart';
import 'package:sudi_fe/src/core/services.dart';

import 'fake_server.dart';

/// Uptime that only moves when the test says so.
class FakeMonotonic implements Monotonic {
  FakeMonotonic({this.elapsedMs = 1000000, this.bootId = 7});

  int elapsedMs;
  int bootId;

  void advance(Duration d) => elapsedMs += d.inMilliseconds;

  @override
  Future<MonoReading> read() async => MonoReading(elapsedMs, bootId);
}

/// A real SQLite (the system library, no cipher), in memory, with the schema
/// the app ships: the SQL under test is the SQL that runs on the phone.
Future<AppDatabase> openTestDatabase() async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfiNoIsolate.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: AppDatabase.schemaVersion,
      onConfigure: AppDatabase.configure,
      onCreate: AppDatabase.create,
      onUpgrade: AppDatabase.upgrade,
      singleInstance: false,
    ),
  );
  return AppDatabase.withDatabase(db);
}

/// Signed-in secure storage, with a token that will not need refreshing.
void signedInStorage({List<String> roles = const ['pickup_delivery', 'job_work', 'office']}) {
  FlutterSecureStorage.setMockInitialValues({
    'sudi.access_token': 'access-1',
    'sudi.refresh_token': 'refresh-1',
    'sudi.access_expires_at': DateTime.now().add(const Duration(days: 1)).toIso8601String(),
    'sudi.device_uid': 'device-uid-1',
    'sudi.roles': '[${roles.map((r) => '"$r"').join(',')}]',
  });
}

class Harness {
  Harness(this.services, this.server, this.mono, this.net, this.staging);

  final Services services;
  final FakeServer server;
  final FakeMonotonic mono;
  final ConnectivityWatch net;
  final Directory staging;

  /// A staged jangad page on disk, as the camera would leave it.
  Future<File> photo(String name) async {
    final file = File('${staging.path}/$name.jpg');
    await file.writeAsBytes(List<int>.generate(64, (i) => i));
    return file;
  }
}

/// Services wired to the fake server, an in-memory database and a hand-driven
/// clock and radio. No platform plugin is touched.
Future<Harness> buildHarness({
  FakeServer? server,
  FakeMonotonic? mono,
  bool radio = true,
  List<String> roles = const ['pickup_delivery', 'job_work', 'office', 'jangad_on_behalf'],
}) async {
  NoticeAlerts.enabled = false;
  signedInStorage(roles: roles);
  final fake = server ?? FakeServer();
  final clock = mono ?? FakeMonotonic();
  final net = ConnectivityWatch.manual(radio: radio);
  // Synchronous: a widget test builds this on its fake clock, where real
  // file-system futures never complete.
  final staging = Directory.systemTemp.createTempSync('sudi_staging_');
  final services = await Services.create(
    tokens: TokenStore(),
    database: await openTestDatabase(),
    http: fake,
    transformer: SyncTransformer(),
    monotonic: clock,
    processMs: () => 0,
    net: net,
    stagingDirectory: () async => staging,
  );
  return Harness(services, fake, clock, net, staging);
}
