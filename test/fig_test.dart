import 'package:flutter_test/flutter_test.dart';
import 'package:sudi_fe/src/models/v2_docs.dart';

void main() {
  group('Fig', () {
    test('summed lines print without binary noise', () {
      expect(Fig.pcs(61.45 + 26.07), '87.52');
      expect(Fig.ct(61.45 + 26.07), '87.52');
    });

    test('whole pieces, two-place carats, and every real digit kept', () {
      expect(Fig.pcs(120), '120');
      expect(Fig.ct(6.2), '6.20');
      expect(Fig.ct(1.505), '1.505');
      expect(Fig.pcs(0.125), '0.125');
    });
  });
}
