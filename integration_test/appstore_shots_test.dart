// App Store screenshot run: signs into the review sandbox on production,
// walks the jangad flow and saves the five post-sign-in screenshots into the
// app's Documents/shots/ (pull them with `simctl get_app_container ... data`).
//
//   flutter test integration_test/appstore_shots_test.dart \
//     -d "iPhone 17 Pro Max" --flavor customer \
//     --dart-define=SHOT_PHONE=... --dart-define=SHOT_CODE=...
//
// The camera is replaced by a fake picker that draws a fictional jangad
// slip, so the run needs no camera and no photo library.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:sudi_fe/src/app.dart';
import 'package:sudi_fe/src/config/flavor.dart';
import 'package:sudi_fe/src/core/services.dart';

const _phone = String.fromEnvironment('SHOT_PHONE');
const _code = String.fromEnvironment('SHOT_CODE');
final _shotKey = GlobalKey();

class _FakeImagePicker extends ImagePickerPlatform {
  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async =>
      XFile(await _drawJangad());

  @override
  Future<PickedFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
  }) async =>
      PickedFile(await _drawJangad());
}

/// A fictional handwritten-style jangad slip, 1200x1600.
Future<String> _drawJangad() async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  const w = 1200.0, h = 1600.0;
  c.drawRect(const Rect.fromLTWH(0, 0, w, h), Paint()..color = const Color(0xFFF7F4EC));
  final line = Paint()
    ..color = const Color(0xFF9A958A)
    ..strokeWidth = 2;
  for (double y = 260; y < h - 120; y += 90) {
    c.drawLine(Offset(70, y), Offset(w - 70, y), line);
  }
  void text(String s, double x, double y, double size, {bool bold = false}) {
    final pb = ui.ParagraphBuilder(ui.ParagraphStyle(fontSize: size, fontWeight: bold ? FontWeight.w700 : FontWeight.w400))
      ..pushStyle(ui.TextStyle(color: const Color(0xFF2E2A24)))
      ..addText(s);
    final p = pb.build()..layout(const ui.ParagraphConstraints(width: w - 140));
    c.drawParagraph(p, Offset(x, y));
  }
  text('ASTRA GEMS — JANGAD', 70, 80, 54, bold: true);
  text('No. 00954            Date: 16/11/2026', 70, 170, 40);
  text('12 pcs round brilliant, 0.30 ct avg', 90, 285, 42);
  text('Laser inscription — all stones', 90, 375, 42);
  text('Handle with care. Return in jangad.', 90, 465, 42);
  text('Received by: ______________', 90, 1380, 42);
  final img = await rec.endRecording().toImage(w.toInt(), h.toInt());
  final bytes = (await img.toByteData(format: ui.ImageByteFormat.png))!;
  final dir = await getTemporaryDirectory();
  final f = File('${dir.path}/fake_jangad.png');
  await f.writeAsBytes(Uint8List.view(bytes.buffer));
  return f.path;
}

Future<void> _waitFor(WidgetTester t, Finder f, {Duration timeout = const Duration(seconds: 45)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 300));
    if (f.evaluate().isNotEmpty) return;
  }
  throw TestFailure('timeout waiting for $f');
}

Future<void> _settle(WidgetTester t, [int ms = 1200]) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('appstore shots', (tester) async {
    expect(_phone.isNotEmpty && _code.isNotEmpty, true, reason: 'pass SHOT_PHONE and SHOT_CODE');
    ImagePickerPlatform.instance = _FakeImagePicker();
    sudiFlavor = Flavor.customer;
    final services = await Services.boot();
    await tester.pumpWidget(RepaintBoundary(
      key: _shotKey,
      child: ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: const SudiApp(),
      ),
    ));

    Future<void> shot(String name) async {
      await _settle(tester, 1000);
      final boundary = _shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final ratio = tester.view.devicePixelRatio;
      final img = await boundary.toImage(pixelRatio: ratio);
      final bytes = (await img.toByteData(format: ui.ImageByteFormat.png))!;
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/shots/$name.png');
      await f.parent.create(recursive: true);
      await f.writeAsBytes(Uint8List.view(bytes.buffer));
      debugPrint('SHOT-SAVED $name ${img.width}x${img.height}');
    }

    // Sign in.
    await _waitFor(tester, find.text('Send code on WhatsApp'));
    await tester.enterText(find.byType(TextField).first, _phone);
    await _settle(tester, 400);
    await tester.tap(find.text('Send code on WhatsApp'));
    await _settle(tester, 1500);
    await _waitFor(tester, find.byType(TextField));
    await tester.enterText(find.byType(TextField).first, _code);

    // 2: home.
    await _waitFor(tester, find.text('What should we do?'));
    await _waitFor(tester, find.text('Laser Inscription'));
    await shot('shot-2-home');

    // 3: service sheet with 12 pieces.
    await tester.tap(find.text('Laser Inscription'));
    await _waitFor(tester, find.text('How many pieces?'));
    await tester.enterText(find.byType(TextField).first, '12');
    await shot('shot-3-service');

    // Add and continue to the jangad phase.
    await tester.tap(find.textContaining(RegExp(r'^Add .*pcs$')));
    await _settle(tester, 800);
    await _waitFor(tester, find.text('Next: jangad photo'));
    await tester.tap(find.text('Next: jangad photo'));

    // 4: photograph screen, before any page.
    await _waitFor(tester, find.text('Photograph the jangad'));
    await shot('shot-4-jangad');

    // Photograph (fake) and choose the address.
    await tester.tap(find.text('Photograph it'));
    await _waitFor(tester, find.text('Another page'));
    await tester.tap(find.text('Choose where to collect from').first);
    await _waitFor(tester, find.text('Saved addresses'));
    await _settle(tester, 1500);
    if (find.textContaining(RegExp(r'Mumbai|Opera|Shop')).evaluate().isNotEmpty) {
      await tester.tap(find.textContaining(RegExp(r'Mumbai|Opera|Shop')).first);
    } else {
      await tester.enterText(find.byType(TextField).first, 'Shop 14, Opera House, Charni Road, Mumbai 400004');
      await _settle(tester, 400);
      await tester.tap(find.text('Save and continue'));
    }

    // Send.
    await _waitFor(tester, find.text('Send for pickup'));
    await tester.tap(find.text('Send for pickup'));

    // 5: reference.
    await _waitFor(tester, find.text('We have it'), timeout: const Duration(seconds: 90));
    await shot('shot-5-reference');

    // 6: account sheet.
    await tester.tap(find.text('Send another jangad'));
    await _waitFor(tester, find.text('What should we do?'));
    await tester.tap(find.byTooltip('Account'));
    await _settle(tester, 1800);
    await shot('shot-6-account');

    // 7: account deletion flow — show the dialog, then keep the account so the
    // reviewer's test login stays alive.
    if (find.text('Delete my account').evaluate().isNotEmpty) {
      await tester.tap(find.text('Delete my account'));
      await _waitFor(tester, find.text('Delete your account?'));
      await _settle(tester, 2500);
      await shot('shot-7-delete');
      if (find.text('Keep my account').evaluate().isNotEmpty) {
        await tester.tap(find.text('Keep my account'));
        await _settle(tester, 1200);
      }
    }
  }, timeout: const Timeout(Duration(minutes: 8)));
}
