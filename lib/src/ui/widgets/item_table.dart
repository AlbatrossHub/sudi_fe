import 'dart:math';

import 'package:flutter/material.dart';

import '../../models/docs.dart';
import '../theme/neu.dart';
import 'neu_box.dart';

/// One row of the item table, whatever it came from: a job-work receipt's
/// lines (read-only) or the office's draft (editable).
class ItemRow {
  const ItemRow({
    required this.sr,
    this.size = '',
    this.pcs,
    this.carats,
    this.service,
    this.remarks,
  });

  final int sr;
  final String size;
  final double? pcs;
  final double? carats;
  final String? service;
  final String? remarks;

  bool get missingService => service == null || service!.trim().isEmpty;
  bool get missingPieces => (pcs ?? 0) <= 0;

  factory ItemRow.fromLine(ItemLine line) => ItemRow(
        sr: line.sr,
        size: line.size.isEmpty ? line.product : line.size,
        pcs: line.pcs,
        carats: line.carats,
        service: line.jobType?.name,
        remarks: line.remarks,
      );

  factory ItemRow.fromOffice(OfficeLine line, int index) => ItemRow(
        sr: index + 1,
        size: line.size,
        pcs: line.pcs,
        carats: line.carats,
        service: line.jobTypeName,
        remarks: line.remarks,
      );
}

enum ItemTableView { table, byService }

/// The phone's one2many: a real table, not a stack of cards.
///
/// * **Sr stays put** while the other columns scroll sideways, so a row is
///   always identifiable.
/// * A **totals footer** sums pieces and carats (never rounded: the figures
///   print as the server sent them).
/// * **Table / By service** switches to the lines grouped under each service.
/// * Tap a row for the whole line: [onRowTap] opens the read-only sheet on a
///   job-work receipt and the edit sheet in the office.
///
/// [editable] draws each value in a sunk cell (the office's table is a form),
/// and outlines the values READY would refuse: a line with no service, or no
/// pieces.
class ItemTable extends StatefulWidget {
  const ItemTable({
    super.key,
    required this.rows,
    this.editable = false,
    this.onRowTap,
    this.initialView = ItemTableView.table,
    this.showToggle = true,
    this.problemRows = const {},
    this.emptyText = 'No lines yet',
  });

  final List<ItemRow> rows;
  final bool editable;
  final ValueChanged<int>? onRowTap;
  final ItemTableView initialView;
  final bool showToggle;

  /// Row indexes the server refused (`detail.problems`), outlined.
  final Set<int> problemRows;
  final String emptyText;

  @override
  State<ItemTable> createState() => _ItemTableState();
}

class _ItemTableState extends State<ItemTable> {
  late ItemTableView _view = widget.initialView;
  final _scroll = ScrollController();

  static const _srWidth = 46.0;
  static const _cols = <(String, double, bool)>[
    ('Size', 76, false),
    ('Pcs', 66, true),
    ('Ct', 76, true),
    ('Service', 176, false),
    ('Remarks', 160, false),
  ];

  double get _rowHeight => widget.editable ? 52 : 46;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  double get _pcs => widget.rows.fold(0, (a, r) => a + (r.pcs ?? 0));
  double get _ct => widget.rows.fold(0, (a, r) => a + (r.carats ?? 0));
  int get _services => widget.rows.map((r) => r.service).whereType<String>().toSet().length;

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.showToggle) ...[
          Row(
            children: [
              _toggle(context),
              const SizedBox(width: 8),
              if (_view == ItemTableView.table && widget.rows.isNotEmpty)
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Flexible(
                        child: Text('Swipe for more',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: NeuText.label(c.inkMuted, size: 11.5).copyWith(fontWeight: FontWeight.w700)),
                      ),
                      const SizedBox(width: 4),
                      Icon(Icons.swipe_left_alt_rounded, size: 15, color: c.inkMuted),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        if (widget.rows.isEmpty)
          NeuBox(
            style: NeuStyle.inset,
            radius: 20,
            padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 18),
            child: Center(child: Text(widget.emptyText, style: NeuText.body_(c.inkMuted, size: 13))),
          )
        else if (_view == ItemTableView.table)
          _table(context)
        else
          _byService(context),
      ],
    );
  }

  Widget _toggle(BuildContext context) {
    final c = NeuTheme.of(context);
    Widget seg(String label, ItemTableView view) {
      final on = _view == view;
      return GestureDetector(
        key: Key('item-table-view-${view.name}'),
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _view = view),
        child: on
            ? NeuBox(
                style: NeuStyle.raisedSm,
                radius: 11,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Text(label, style: NeuText.label(c.accentInk, size: 12.5)),
              )
            : Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Text(label,
                    style: NeuText.label(c.inkMuted, size: 12.5).copyWith(fontWeight: FontWeight.w700)),
              ),
      );
    }

    return NeuBox(
      style: NeuStyle.inset,
      radius: 14,
      padding: const EdgeInsets.all(4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [seg('Table', ItemTableView.table), const SizedBox(width: 4), seg('By service', ItemTableView.byService)],
      ),
    );
  }

  // ------------------------------------------------------------- table

  Widget _table(BuildContext context) {
    final c = NeuTheme.of(context);
    final head = NeuText.label(c.inkMuted, size: 10.5).copyWith(letterSpacing: 0.6);
    final rows = widget.rows;

    Widget cell(String text, {required double width, bool number = false, bool bold = false, bool faint = false, bool flag = false}) {
      final style = number
          ? NeuText.data(faint ? c.inkFaint : c.ink, size: 13, w: bold ? FontWeight.w600 : FontWeight.w600)
          : (bold ? NeuText.label(c.ink, size: 13.5) : NeuText.body_(faint ? c.inkFaint : c.ink, size: 13.5, w: FontWeight.w600));
      Widget value = Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: number ? TextAlign.right : TextAlign.left,
        style: style,
      );
      if (widget.editable) {
        value = NeuBox(
          style: NeuStyle.insetSm,
          radius: 9,
          color: c.ground,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Align(alignment: number ? Alignment.centerRight : Alignment.centerLeft, widthFactor: 1, child: value),
        );
        if (flag) {
          value = DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: c.accent, width: 2),
            ),
            child: value,
          );
        }
      }
      return SizedBox(
        width: width,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Align(alignment: number ? Alignment.centerRight : Alignment.centerLeft, child: value),
        ),
      );
    }

    Widget line(int i) {
      final r = rows[i];
      final problem = widget.problemRows.contains(i);
      return _RowTap(
        key: Key('item-table-row-$i'),
        height: _rowHeight,
        onTap: widget.onRowTap == null ? null : () => widget.onRowTap!(i),
        hairline: c.hairline,
        background: problem ? c.attentionFill.withValues(alpha: 0.45) : c.ground,
        child: Row(
          children: [
            cell(r.size.isEmpty ? '—' : r.size, width: _cols[0].$2, faint: r.size.isEmpty),
            cell(Fig.pcs(r.pcs ?? 0), width: _cols[1].$2, number: true, faint: r.missingPieces, flag: r.missingPieces),
            cell(Fig.ct(r.carats ?? 0), width: _cols[2].$2, number: true, faint: (r.carats ?? 0) == 0),
            cell(r.service ?? 'No service', width: _cols[3].$2, faint: r.missingService, flag: r.missingService),
            cell((r.remarks == null || r.remarks!.isEmpty) ? (widget.editable ? '—' : '') : r.remarks!,
                width: _restWidthExtra + _cols[4].$2, faint: r.remarks == null || r.remarks!.isEmpty),
          ],
        ),
      );
    }

    return NeuBox(
      style: NeuStyle.raised,
      radius: 20,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final natural = _cols.fold<double>(0, (a, col) => a + col.$2);
            _restWidthExtra = max(0, constraints.maxWidth - _srWidth - natural);
            final restWidth = natural + _restWidthExtra;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Sticky Sr: its own column, outside the horizontal scroll.
                Container(
                  width: _srWidth,
                  decoration: BoxDecoration(
                    color: c.groundSunk,
                    border: Border(right: BorderSide(color: c.hairline)),
                  ),
                  child: Column(
                    children: [
                      _headCell('Sr', head, _srWidth, alignRight: false, sunk: true),
                      for (var i = 0; i < rows.length; i++)
                        _RowTap(
                          key: Key('item-table-sr-$i'),
                          height: _rowHeight,
                          hairline: c.hairline,
                          background: Colors.transparent,
                          onTap: widget.onRowTap == null ? null : () => widget.onRowTap!(i),
                          child: Center(child: Text('${rows[i].sr}', style: NeuText.data(c.inkMuted, size: 13))),
                        ),
                      SizedBox(
                        height: 46,
                        child: Center(child: Text('Σ', style: NeuText.label(c.ink, size: 14))),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    key: const Key('item-table-scroll'),
                    controller: _scroll,
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: restWidth,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.hairline))),
                            child: Row(
                              children: [
                                for (var k = 0; k < _cols.length; k++)
                                  _headCell(_cols[k].$1, head, _cols[k].$2 + (k == _cols.length - 1 ? _restWidthExtra : 0),
                                      alignRight: _cols[k].$3),
                              ],
                            ),
                          ),
                          for (var i = 0; i < rows.length; i++) line(i),
                          Container(
                            key: const Key('item-table-totals'),
                            height: 46,
                            color: c.groundSunk,
                            child: Row(
                              children: [
                                _footCell('${rows.length} line${rows.length == 1 ? '' : 's'}', _cols[0].$2, c),
                                _footCell(Fig.pcs(_pcs), _cols[1].$2, c, number: true),
                                _footCell(Fig.ct(_ct), _cols[2].$2, c, number: true),
                                _footCell('$_services service${_services == 1 ? '' : 's'}', _cols[3].$2, c),
                                SizedBox(width: _cols[4].$2 + _restWidthExtra),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  double _restWidthExtra = 0;

  Widget _headCell(String text, TextStyle style, double width, {required bool alignRight, bool sunk = false}) {
    final c = NeuTheme.of(context);
    return Container(
      width: width,
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: sunk ? BoxDecoration(border: Border(bottom: BorderSide(color: c.hairline))) : null,
      alignment: sunk ? Alignment.center : (alignRight ? Alignment.centerRight : Alignment.centerLeft),
      child: Text(text.toUpperCase(), style: style),
    );
  }

  Widget _footCell(String text, double width, NeuColors c, {bool number = false}) => SizedBox(
        width: width,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Align(
            alignment: number ? Alignment.centerRight : Alignment.centerLeft,
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: number ? NeuText.data(c.ink, size: 13) : NeuText.label(c.ink, size: 13),
            ),
          ),
        ),
      );

  // -------------------------------------------------------- by service

  Widget _byService(BuildContext context) {
    final c = NeuTheme.of(context);
    final groups = <String, List<int>>{};
    for (var i = 0; i < widget.rows.length; i++) {
      final key = widget.rows[i].missingService ? 'No service yet' : widget.rows[i].service!;
      (groups[key] ??= []).add(i);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final entry in groups.entries) ...[
          NeuBox(
            style: NeuStyle.raised,
            radius: 20,
            padding: const EdgeInsets.fromLTRB(16, 13, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(entry.key,
                          style: NeuText.strong(entry.key == 'No service yet' ? c.attentionInk : c.ink, size: 14.5)),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${entry.value.length} · ${Fig.pcs(entry.value.fold<double>(0, (a, i) => a + (widget.rows[i].pcs ?? 0)))} pcs · '
                      '${Fig.ct(entry.value.fold<double>(0, (a, i) => a + (widget.rows[i].carats ?? 0)))} ct',
                      style: NeuText.data(c.inkMuted, size: 11.5),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                for (final i in entry.value)
                  InkWell(
                    key: Key('item-table-group-row-$i'),
                    onTap: widget.onRowTap == null ? null : () => widget.onRowTap!(i),
                    child: Container(
                      height: 40,
                      decoration: BoxDecoration(border: Border(top: BorderSide(color: c.hairline))),
                      child: Row(
                        children: [
                          SizedBox(width: 30, child: Text('${widget.rows[i].sr}', style: NeuText.data(c.inkMuted, size: 12.5))),
                          Expanded(
                            child: Text(
                              widget.rows[i].size.isEmpty ? '—' : widget.rows[i].size,
                              style: NeuText.body_(c.ink, size: 13.5, w: FontWeight.w600),
                            ),
                          ),
                          SizedBox(
                            width: 64,
                            child: Text(Fig.pcs(widget.rows[i].pcs ?? 0),
                                textAlign: TextAlign.right, style: NeuText.data(c.ink, size: 13)),
                          ),
                          SizedBox(
                            width: 72,
                            child: Text(Fig.ct(widget.rows[i].carats ?? 0),
                                textAlign: TextAlign.right, style: NeuText.data(c.ink, size: 13)),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        NeuBox(
          style: NeuStyle.inset,
          radius: 16,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Text('Σ ${widget.rows.length} lines', style: NeuText.label(c.ink, size: 13)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${Fig.pcs(_pcs)} pcs · ${Fig.ct(_ct)} ct',
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NeuText.data(c.ink, size: 13),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RowTap extends StatelessWidget {
  const _RowTap({
    super.key,
    required this.height,
    required this.child,
    required this.hairline,
    required this.background,
    this.onTap,
  });

  final double height;
  final Widget child;
  final Color hairline;
  final Color background;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: background,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: height,
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: hairline))),
          child: child,
        ),
      ),
    );
  }
}

/// The customer's requested services, as the office reads them: Service, Qty,
/// Remarks. Not an item table -- nothing has been counted yet.
class RequestedServicesTable extends StatelessWidget {
  const RequestedServicesTable({super.key, required this.services});
  final List<ServiceLine> services;

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final head = NeuText.label(c.inkMuted, size: 10.5).copyWith(letterSpacing: 0.6);
    return NeuBox(
      style: NeuStyle.inset,
      radius: 18,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: Column(
        children: [
          SizedBox(
            height: 34,
            child: Row(
              children: [
                Expanded(flex: 5, child: Text('SERVICE', style: head)),
                Expanded(flex: 3, child: Text('QTY', textAlign: TextAlign.right, style: head)),
                const SizedBox(width: 12),
                Expanded(flex: 4, child: Text('REMARKS', style: head)),
              ],
            ),
          ),
          for (final s in services)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 11),
              decoration: BoxDecoration(border: Border(top: BorderSide(color: c.hairline))),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 5, child: Text(s.name, style: NeuText.label(c.ink, size: 13.5))),
                  Expanded(
                    flex: 3,
                    child: Text(s.quantityLabel, textAlign: TextAlign.right, style: NeuText.data(c.ink, size: 13)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 4,
                    child: Text(s.remarks ?? '', style: NeuText.body_(c.inkMuted, size: 12.5)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
