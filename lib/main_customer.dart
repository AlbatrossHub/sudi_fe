import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/app.dart';
import 'src/config/flavor.dart';
import 'src/core/services.dart';

/// Customer flavor: jangad capture and submission, and nothing else.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  sudiFlavor = Flavor.customer;

  // The only async work at startup, and none of it touches the network.
  final services = await Services.boot();

  runApp(
    ProviderScope(
      overrides: [servicesProvider.overrideWithValue(services)],
      child: const SudiApp(),
    ),
  );
}
