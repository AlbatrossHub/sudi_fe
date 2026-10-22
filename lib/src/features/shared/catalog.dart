import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_error.dart';
import '../../core/services.dart';
import '../../models/docs.dart';
import '../../ui/theme/neu.dart';
import '../../ui/widgets/neu_box.dart';
import '../../ui/widgets/neu_widgets.dart';
import '../../ui/widgets/v2_widgets.dart';

/// Every catalogue read opens from the saved copy and then asks the server:
/// the copy is on screen at once (offline too), the fresh answer replaces it
/// when it lands, and a failure with a copy on screen changes nothing.
Stream<T> savedThenFresh<T>(Future<T?> Function() saved, Future<T> Function() fresh) async* {
  final copy = await saved();
  if (copy != null) yield copy;
  try {
    yield await fresh();
  } on ApiError {
    if (copy == null) rethrow;
  }
}

/// Staff: services, which are also departments.
final jobTypesProvider = StreamProvider.autoDispose<List<JobTypeInfo>>((ref) {
  final v2 = ref.read(servicesProvider).v2;
  return savedThenFresh(v2.savedJobTypes, v2.jobTypes);
});

/// Staff with the "post for customers" tick: the customer directory.
final customersProvider = StreamProvider.autoDispose<List<CustomerEntry>>((ref) {
  final v2 = ref.read(servicesProvider).v2;
  return savedThenFresh(v2.savedCustomers, v2.customers);
});

/// Customer: the dashboard's services.
final serviceCatalogProvider = StreamProvider.autoDispose<List<ServiceInfo>>((ref) {
  final v2 = ref.read(servicesProvider).v2;
  return savedThenFresh(v2.savedServices, v2.services);
});

/// Customer: saved pickup addresses.
final savedAddressesProvider = StreamProvider.autoDispose<List<AddressSuggestion>>((ref) {
  final v2 = ref.read(servicesProvider).v2;
  return savedThenFresh(v2.savedAddresses, v2.addresses);
});

class ServiceSheetResult {
  const ServiceSheetResult({required this.quantity, this.remarks, this.remove = false});
  final double quantity;
  final String? remarks;
  final bool remove;
}

/// "Add to your request": how many, a remark, add. One service at a time.
/// The same sheet for the customer's dashboard and for an operator posting on
/// a customer's behalf; [existing] makes it the edit sheet, with Remove.
Future<ServiceSheetResult?> showAddServiceSheet(
  BuildContext context, {
  required String name,
  required String unit,
  ServiceRequest? existing,
}) =>
    showNeuSheet<ServiceSheetResult>(
      context,
      builder: (sheetContext) => _AddServiceSheet(name: name, unit: unit, existing: existing),
    );

class _AddServiceSheet extends StatefulWidget {
  const _AddServiceSheet({required this.name, required this.unit, this.existing});
  final String name;
  final String unit;
  final ServiceRequest? existing;

  @override
  State<_AddServiceSheet> createState() => _AddServiceSheetState();
}

class _AddServiceSheetState extends State<_AddServiceSheet> {
  late double _qty = widget.existing?.quantity ?? 0;
  late final _qtyText = TextEditingController(text: _fmt(_qty));
  late final _remarks = TextEditingController(text: widget.existing?.remarks ?? '');

  bool get _carats => widget.unit == 'ct';
  double get _step => _carats ? 1 : 10;
  List<double> get _quick => _carats ? const [1, 2, 5, 10] : const [10, 25, 50, 100];

  String _fmt(double v) => _carats ? Fig.ct(v) : Fig.pcs(v);

  void _set(double v) {
    setState(() => _qty = v < 0 ? 0 : v);
    _qtyText.text = _fmt(_qty);
  }

  @override
  void dispose() {
    _qtyText.dispose();
    _remarks.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final unitLabel = _carats ? 'ct' : (widget.unit == 'pcs' ? 'pcs' : '');
    final verb = widget.existing == null ? 'Add' : 'Save';
    final label = _qty > 0 ? '$verb ${Fig.qty(_qty, widget.unit)}' : '$verb, no count';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.existing == null ? 'ADD TO THE REQUEST' : 'IN THE REQUEST',
          style: NeuText.label(c.accentInk, size: 12).copyWith(letterSpacing: 0.6),
        ),
        const SizedBox(height: 4),
        Text(widget.name, style: NeuText.title(c.ink, size: 22)),
        const SizedBox(height: 16),
        Text(
          _carats ? 'How many carats?' : (widget.unit == 'pcs' ? 'How many pieces?' : 'How many?'),
          style: NeuText.label(c.inkMuted, size: 12),
        ),
        const SizedBox(height: 8),
        QtyStepper(
          key: const Key('qty-stepper'),
          value: _qty,
          unit: unitLabel,
          step: _step,
          format: _fmt,
          lessLabel: _carats ? 'One carat less' : 'Ten fewer',
          moreLabel: _carats ? 'One carat more' : 'Ten more',
          onChanged: _set,
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            for (var i = 0; i < _quick.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              Expanded(
                child: NeuBox(
                  style: NeuStyle.raisedSm,
                  radius: 12,
                  onTap: () => _set(_quick[i]),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Center(
                    child: Text(_fmt(_quick[i]),
                        style: NeuText.label(c.inkSoft, size: 13).copyWith(fontWeight: FontWeight.w700)),
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),
        LabeledInput(
          label: 'Or type it',
          controller: _qtyText,
          mono: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
          onChanged: (v) => setState(() => _qty = double.tryParse(v) ?? 0),
        ),
        const SizedBox(height: 12),
        LabeledInput(
          label: 'Remarks (optional)',
          controller: _remarks,
          hint: 'Please do the small ones too',
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: NeuButton(
                label: widget.existing == null ? 'Cancel' : 'Remove',
                kind: widget.existing == null ? NeuButtonKind.secondary : NeuButtonKind.destructive,
                height: 54,
                onPressed: () => Navigator.of(context).pop(
                  widget.existing == null
                      ? null
                      : const ServiceSheetResult(quantity: 0, remove: true),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: NeuButton(
                key: const Key('service-sheet-save'),
                label: label,
                kind: NeuButtonKind.primary,
                icon: Icons.add_rounded,
                height: 54,
                onPressed: () => Navigator.of(context).pop(
                  ServiceSheetResult(
                    quantity: _qty,
                    remarks: _remarks.text.trim().isEmpty ? null : _remarks.text.trim(),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
