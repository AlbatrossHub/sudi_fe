import 'package:flutter_test/flutter_test.dart';
import 'package:sudi_fe/src/features/field/office_screens.dart';
import 'package:sudi_fe/src/models/docs.dart';

// Service 3 bills per piece, service 4 per carat (the client's mapping sheet:
// boiling and treatment processes are "cts with Rs.").
const _units = {3: 'pcs', 4: 'ct'};

OfficeDoc _doc() => OfficeDoc.fromJson({
      'id': 1,
      'name': 'HO/IN/00001',
      'customer': {'id': 7, 'name': 'Shah Gems'},
      'services': [
        {'id': 1, 'job_type': {'id': 3, 'name': 'Laser Inscription'}, 'quantity': 120, 'unit': 'pcs'},
        {'id': 2, 'job_type': {'id': 4, 'name': 'Export Boiling'}, 'quantity': 6.2, 'unit': 'ct'},
      ],
      'items': const [],
    });

OfficeLine _line({int? jobType, double pcs = 0, double carats = 0}) =>
    OfficeLine(jobTypeId: jobType, jobTypeName: 'X', pcs: pcs, carats: carats);

ReadyCheck _check(List<ReadyCheck> checks, String contains) =>
    checks.firstWhere((k) => k.text.contains(contains));

void main() {
  test('a carat-billed line without carats blocks READY', () {
    final checks = readyChecks(
      _doc(),
      [_line(jobType: 3, pcs: 120), _line(jobType: 4, pcs: 10)],
      _units,
    );
    final carat = _check(checks, 'needs carats');
    expect(carat.ok, isFalse);
    expect(carat.blocking, isTrue);
    expect(carat.text, contains('Line 2'));
  });

  test('carats on every carat-billed line satisfies the check', () {
    final checks = readyChecks(
      _doc(),
      [_line(jobType: 3, pcs: 120), _line(jobType: 4, pcs: 10, carats: 6.2)],
      _units,
    );
    expect(_check(checks, 'carat-billed line has carats').ok, isTrue);
    expect(checks.any((k) => k.blocking && !k.ok), isFalse);
  });

  test('a piece-only table never shows the carat check', () {
    final checks = readyChecks(_doc(), [_line(jobType: 3, pcs: 120)], _units);
    // No blocking carat check without a carat-billed line; the non-blocking
    // "requested 6.2 ct" reconciliation still shows, as it should.
    expect(checks.any((k) => k.blocking && k.text.contains('carat')), isFalse);
  });

  test('each unit reconciles against its own lines', () {
    final checks = readyChecks(
      _doc(),
      [_line(jobType: 3, pcs: 120), _line(jobType: 4, pcs: 10, carats: 5.0)],
      _units,
    );
    final pcs = _check(checks, 'pcs, as requested');
    expect(pcs.ok, isTrue, reason: 'the carat line’s 10 pcs stay out of the piece tally');
    final ct = _check(checks, 'ct on the carat-billed lines');
    expect(ct.ok, isFalse);
    expect(ct.blocking, isFalse);
    expect(ct.text, contains('6.2'));
  });
}
