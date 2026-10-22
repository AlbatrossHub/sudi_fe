import 'package:flutter_test/flutter_test.dart';
import 'package:sudi_fe/src/config/flavor.dart';
import 'package:sudi_fe/src/core/outbox/outbox.dart';

import 'support/fake_server.dart';
import 'support/harness.dart';

void main() {
  sudiFlavor = Flavor.field;

  test('online means the server answered, not that the radio is on', () async {
    final h = await buildHarness();
    final changes = <bool>[];
    h.net.changes.listen(changes.add);

    h.server.offline = true; // radio on, server gone (a hotel Wi-Fi, no data left)
    expect(await h.services.pinClock(), isFalse);
    expect(h.net.radio, isTrue);
    expect(h.net.isOnline, isFalse);

    h.server.offline = false;
    await h.services.pinClock();
    expect(h.net.isOnline, isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(changes, [false, true]);
  });

  test('a refusal is still an answer; the radio coming back asks the server', () async {
    final h = await buildHarness();
    h.server.on('POST', '/pickups/{id}/cancel', (_) => FakeResponse.error(404, 'NOT_IN_SCOPE', 'Gone.'));
    await h.services.field.cancelPickup(id: 5, label: 'HO/IN/5', reason: 'Shut');
    await h.services.flusher.flush();
    expect(h.net.isOnline, isTrue);
    expect((await h.services.outbox.open()).single.state, OutboxState.needsAttention);

    h.net.setRadio(false);
    expect(h.net.isOnline, isFalse);
    final before = h.server.sent('GET', '/time').length;
    h.net.setRadio(true);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(h.server.sent('GET', '/time').length, before + 1, reason: 'the radio is only a hint');
    expect(h.net.isOnline, isTrue);
  });
}
