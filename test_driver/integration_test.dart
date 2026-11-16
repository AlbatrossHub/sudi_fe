import 'dart:io';
import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() => integrationDriver(
      onScreenshot: (String name, List<int> bytes, [Map<String, Object?>? args]) async {
        final file = File('store/appstore/shots/$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes);
        return true;
      },
    );
