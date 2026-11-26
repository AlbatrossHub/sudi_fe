import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sudi_fe/src/config/flavor.dart';
import 'package:sudi_fe/src/ui/widgets/signature_pad.dart';

import 'support/pump.dart';

void main() {
  sudiFlavor = Flavor.field;

  Future<void> pump(WidgetTester tester, SignatureController controller) async {
    await tester.pumpWidget(themed(Center(
      child: SizedBox(
        width: 300,
        child: SignaturePad(controller: controller, height: 200),
      ),
    )));
  }

  testWidgets('a stroke that wanders off the pad is clamped to its edges', (tester) async {
    final controller = SignatureController();
    await pump(tester, controller);

    final pad = find.byType(SignaturePad);
    final center = tester.getCenter(pad);
    // Drag from the middle to far below and right of the pad.
    final gesture = await tester.startGesture(center);
    await gesture.moveBy(const Offset(400, 500));
    await gesture.moveBy(const Offset(100, 100));
    await gesture.up();
    await tester.pump();

    expect(controller.isEmpty, isFalse);
    for (final stroke in controller.strokes) {
      for (final point in stroke) {
        expect(point.dx, inInclusiveRange(0, controller.size.width),
            reason: 'x inside the pad');
        expect(point.dy, inInclusiveRange(0, controller.size.height),
            reason: 'y inside the pad');
      }
    }
  });

  testWidgets('without a fixed height the pad takes the wide signing ratio', (tester) async {
    final controller = SignatureController();
    await tester.pumpWidget(themed(Center(
      child: SizedBox(
        width: 348,
        child: SignaturePad(controller: controller),
      ),
    )));
    final size = tester.getSize(find.byType(SignaturePad));
    expect(size.width / size.height, moreOrLessEquals(1.2, epsilon: 0.01));
  });
}
