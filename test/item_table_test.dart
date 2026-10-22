import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sudi_fe/src/config/flavor.dart';
import 'package:sudi_fe/src/ui/widgets/item_table.dart';

import 'support/pump.dart';

const _rows = [
  ItemRow(sr: 1, size: '+11', pcs: 64, carats: 6.2, service: 'Laser Inscription', remarks: 'big stones first'),
  ItemRow(sr: 2, size: '-2', pcs: 56, carats: 3.1, service: 'Laser Inscription'),
  ItemRow(sr: 3, size: '+6.5', pcs: 52, carats: 5.6, service: 'Ultra Sonic Boiling', remarks: '2 chipped'),
  ItemRow(sr: 4, size: 'Stars', pcs: 38, carats: 3.5, service: 'Ultra Sonic Boiling'),
];

void main() {
  sudiFlavor = Flavor.field;

  Future<void> pumpTable(WidgetTester tester, Widget table) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(themed(SingleChildScrollView(padding: const EdgeInsets.all(20), child: table)));
  }

  group('read-only (job work)', () {
    testWidgets('every line, and a totals footer that never rounds', (tester) async {
      await pumpTable(tester, const ItemTable(rows: _rows));
      for (var i = 0; i < _rows.length; i++) {
        expect(find.byKey(Key('item-table-row-$i')), findsOneWidget);
        expect(find.byKey(Key('item-table-sr-$i')), findsOneWidget);
      }
      final totals = find.byKey(const Key('item-table-totals'));
      expect(find.descendant(of: totals, matching: find.text('4 lines')), findsOneWidget);
      expect(find.descendant(of: totals, matching: find.text('210')), findsOneWidget);
      expect(find.descendant(of: totals, matching: find.text('18.40')), findsOneWidget);
      expect(find.descendant(of: totals, matching: find.text('2 services')), findsOneWidget);
    });

    testWidgets('Sr stays put while the other columns scroll sideways', (tester) async {
      await pumpTable(tester, const ItemTable(rows: _rows));
      final srBefore = tester.getTopLeft(find.byKey(const Key('item-table-sr-2')));
      final remarksBefore = tester.getTopLeft(find.text('2 chipped'));

      await tester.drag(find.byKey(const Key('item-table-scroll')), const Offset(-250, 0));
      await tester.pumpAndSettle();

      expect(tester.getTopLeft(find.byKey(const Key('item-table-sr-2'))), srBefore);
      expect(tester.getTopLeft(find.text('2 chipped')).dx, lessThan(remarksBefore.dx));
    });

    testWidgets('tapping a row, on either side of the sticky column, opens it', (tester) async {
      final tapped = <int>[];
      await pumpTable(tester, ItemTable(rows: _rows, onRowTap: tapped.add));
      await tester.tap(find.text('+6.5'));
      await tester.tap(find.byKey(const Key('item-table-sr-0')));
      expect(tapped, [2, 0]);
    });

    testWidgets('By service groups the lines under each service', (tester) async {
      final tapped = <int>[];
      await pumpTable(tester, ItemTable(rows: _rows, onRowTap: tapped.add));
      await tester.tap(find.byKey(const Key('item-table-view-byService')));
      await tester.pumpAndSettle();
      expect(find.text('Laser Inscription'), findsOneWidget);
      expect(find.text('Ultra Sonic Boiling'), findsOneWidget);
      expect(find.text('2 · 120 pcs · 9.30 ct'), findsOneWidget);
      expect(find.text('Σ 4 lines'), findsOneWidget);
      await tester.tap(find.byKey(const Key('item-table-group-row-3')));
      expect(tapped, [3]);
    });
  });

  group('editable (office)', () {
    testWidgets('outlines what READY would refuse, and taps open the row', (tester) async {
      final tapped = <int>[];
      await pumpTable(
        tester,
        ItemTable(
          editable: true,
          showToggle: false,
          onRowTap: tapped.add,
          rows: const [
            ItemRow(sr: 1, size: '+11', pcs: 64, carats: 6.2, service: 'Laser Inscription'),
            ItemRow(sr: 2, size: 'Stars', pcs: 0, carats: 0),
          ],
        ),
      );
      expect(find.byKey(const Key('item-table-view-table')), findsNothing, reason: 'no toggle in the office');
      expect(find.text('No service'), findsOneWidget);
      // The two flagged cells (no pieces, no service) carry the accent outline.
      final outlined = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .where((b) => b.decoration is BoxDecoration && (b.decoration as BoxDecoration).border != null)
          .where((b) => ((b.decoration as BoxDecoration).border as Border).top.width == 2);
      expect(outlined.length, 2);

      await tester.tap(find.text('Stars'));
      expect(tapped, [1]);
    });

    testWidgets('an empty table says what to do', (tester) async {
      await pumpTable(tester, const ItemTable(rows: [], editable: true, emptyText: 'No lines yet. Add the first one below.'));
      expect(find.text('No lines yet. Add the first one below.'), findsOneWidget);
    });
  });
}
