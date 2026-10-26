import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/clock/odoo_time.dart';
import '../../core/notices/notices.dart';
import '../theme/neu.dart';
import 'neu_box.dart';
import 'neu_widgets.dart';

/// The v2 boards' secondary ink (#3D4658): between `ink` and `inkMuted`,
/// derived from the two so the palette stays the one in DESIGN.md.
extension NeuColorsV2 on NeuColors {
  Color get inkSoft => Color.lerp(ink, inkMuted, 0.5)!;
}

/// Section label: `COLLECT FROM`, `MOVE IT TO`.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    return Text(
      text.toUpperCase(),
      style: NeuText.label(c.inkMuted, size: 12).copyWith(letterSpacing: 0.7),
    );
  }
}

/// A small sunk tag: `Laser Inscription · 120 pcs`, `3 pages`.
class InsetTag extends StatelessWidget {
  const InsetTag(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    return NeuBox(
      style: NeuStyle.insetSm,
      radius: 9,
      color: c.ground,
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      child: Text(text, style: NeuText.label(c.inkSoft, size: 11.5).copyWith(fontWeight: FontWeight.w700)),
    );
  }
}

/// Back button, a mono step line and a title -- every v2 sub-screen.
class StepHeader extends StatelessWidget {
  const StepHeader({
    super.key,
    required this.step,
    required this.title,
    this.onBack,
    this.trailing,
  });

  /// `STEP 2 OF 3 · SHAH GEMS`, `HO/IN/00321 · READY`.
  final String step;
  final String title;
  final VoidCallback? onBack;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    return Row(
      children: [
        NeuIconButton(
          icon: Icons.arrow_back_rounded,
          onPressed: onBack ?? () => context.pop(),
          tooltip: 'Back',
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                step,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: NeuText.data(c.accentInk, size: 11.5).copyWith(letterSpacing: 0.4),
              ),
              const SizedBox(height: 2),
              // Shrunk to fit rather than cut: "Photograph the ja…" on the M31.
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(title, maxLines: 1, softWrap: false, style: NeuText.title(c.ink, size: 22)),
              ),
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 10), trailing!],
      ],
    );
  }
}

/// The bell, with the unread count. Polled while the app is open.
class NoticeBell extends ConsumerWidget {
  const NoticeBell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = NeuTheme.of(context);
    final unread = ref.watch(noticesProvider.select((s) => s.unread));
    return Semantics(
      button: true,
      label: unread == 0 ? 'Notifications' : 'Notifications, $unread unread',
      child: SizedBox(
        width: 44,
        height: 44,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            NeuBox(
              style: NeuStyle.raised,
              radius: 15,
              width: 44,
              height: 44,
              onTap: () => context.push('/notices'),
              child: Center(
                child: Icon(Icons.notifications_none_rounded, size: 21, color: c.inkSoft),
              ),
            ),
            if (unread > 0)
              Positioned(
                top: 5,
                right: 5,
                child: IgnorePointer(
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 16),
                    height: 16,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      color: c.accentInk,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Center(
                      child: Text(
                        unread > 99 ? '99+' : '$unread',
                        style: NeuText.data(Colors.white, size: 10),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// "Back where you left off": a form that came back from its draft after the
/// app went away. Says when, and that nothing was lost.
class ResumeBanner extends StatelessWidget {
  const ResumeBanner({super.key, required this.closedAt, this.what, this.onDismiss});

  final DateTime closedAt;

  /// `Your photos, note and location`.
  final String? what;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    return NeuBox(
      style: NeuStyle.raised,
      radius: 20,
      padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.history_rounded, size: 20, color: c.accentInk),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Back where you left off', style: NeuText.label(c.ink, size: 14)),
                const SizedBox(height: 2),
                Text(
                  'The app was closed at ${OdooTime.hm(closedAt)}. '
                  '${what ?? 'Everything you entered'} ${what == null ? 'is' : 'are all'} still here.',
                  style: NeuText.body_(c.inkMuted, size: 12.5),
                ),
              ],
            ),
          ),
          if (onDismiss != null)
            GestureDetector(
              onTap: onDismiss,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Icon(Icons.close_rounded, size: 18, color: c.inkFaint),
              ),
            ),
        ],
      ),
    );
  }
}

/// A round choice marker: filled with the accent when picked, sunk when not.
class RadioDot extends StatelessWidget {
  const RadioDot({super.key, required this.selected, this.size = 22});
  final bool selected;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    if (selected) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: c.accent, shape: BoxShape.circle),
        child: Icon(Icons.check_rounded, size: size * 0.62, color: c.onAccent),
      );
    }
    return NeuBox(style: NeuStyle.insetSm, radius: size / 2, width: size, height: size, color: c.ground);
  }
}

/// A row in a choice list: radio, title, optional subtitle and trailing.
class ChoiceRow extends StatelessWidget {
  const ChoiceRow({
    super.key,
    required this.title,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.trailing,
    this.mono = false,
  });

  final String title;
  final String? subtitle;
  final bool selected;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    return NeuBox(
      style: selected ? NeuStyle.inset : NeuStyle.raisedSm,
      radius: 20,
      color: c.ground,
      padding: const EdgeInsets.fromLTRB(15, 13, 15, 13),
      onTap: onTap,
      child: Row(
        children: [
          RadioDot(selected: selected),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: NeuText.strong(c.ink, size: 15)),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: mono
                        ? NeuText.data(c.inkMuted, size: 12)
                        : NeuText.body_(c.inkMuted, size: 12.5),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ],
      ),
    );
  }
}

/// A pill that filters or picks: sunk and accent-ink when on.
class PickChip extends StatelessWidget {
  const PickChip({super.key, required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    return NeuBox(
      style: selected ? NeuStyle.insetSm : NeuStyle.raisedSm,
      radius: 12,
      color: c.ground,
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
      child: Text(
        label,
        maxLines: 1,
        style: selected
            ? NeuText.label(c.accentInk, size: 13)
            : NeuText.label(c.inkSoft, size: 13).copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// − value + in a sunk track. Steps by [step]; never below [min].
class QtyStepper extends StatelessWidget {
  const QtyStepper({
    super.key,
    required this.value,
    required this.onChanged,
    required this.unit,
    this.step = 10,
    this.min = 0,
    this.max = 100000,
    this.big = true,
    this.format,
    this.lessLabel,
    this.moreLabel,
  });

  final double value;
  final ValueChanged<double> onChanged;
  final String unit;
  final double step;
  final double min;
  final double max;
  final bool big;
  final String Function(double)? format;
  final String? lessLabel;
  final String? moreLabel;

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final side = big ? 52.0 : 40.0;
    final k = key;
    final prefix = k is ValueKey<String> ? k.value : 'qty';
    Widget button(String glyph, String label, double next) => Semantics(
          button: true,
          label: label,
          child: NeuBox(
            key: ValueKey('$prefix-${glyph == '+' ? 'more' : 'less'}'),
            style: NeuStyle.raisedSm,
            radius: big ? 16 : 13,
            width: side,
            height: side,
            onTap: () => onChanged(next.clamp(min, max).toDouble()),
            child: Center(
              child: Text(glyph,
                  style: NeuText.strong(c.accentInk, size: big ? 24 : 20)),
            ),
          ),
        );
    final shown = format?.call(value) ??
        (value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toString());
    return NeuBox(
      style: NeuStyle.inset,
      radius: big ? 20 : 18,
      padding: EdgeInsets.all(big ? 9 : 8),
      child: Row(
        children: [
          button('−', lessLabel ?? '${_n(step)} fewer', value - step),
          Expanded(
            // Shrink rather than clip: two half-width steppers at a large font
            // scale cut "45 min" to "45 mi" on the M31.
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(shown, style: NeuText.data(c.ink, size: big ? 34 : 26)),
                  if (unit.isNotEmpty) ...[
                    const SizedBox(width: 5),
                    Text(unit, style: NeuText.label(c.inkMuted, size: 12.5).copyWith(fontWeight: FontWeight.w700)),
                  ],
                ],
              ),
            ),
          ),
          button('+', moreLabel ?? '${_n(step)} more', value + step),
        ],
      ),
    );
  }

  static String _n(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : '$v';
}

/// A sunk field with a small label over it: `Remarks (optional)`.
class LabeledInput extends StatelessWidget {
  const LabeledInput({
    super.key,
    required this.label,
    required this.controller,
    this.hint,
    this.mono = false,
    this.keyboardType,
    this.onChanged,
    this.highlight = false,
    this.maxLines = 1,
    this.size = 15,
    this.inputFormatters,
    this.fieldKey,
    this.autofocus = false,
  });

  final String label;
  final TextEditingController controller;
  final String? hint;
  final bool mono;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;

  /// An outline in the accent: "this is the value that looks wrong".
  final bool highlight;
  final int maxLines;
  final double size;
  final List<TextInputFormatter>? inputFormatters;
  final Key? fieldKey;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final box = NeuBox(
      style: NeuStyle.insetSm,
      radius: 14,
      color: c.ground,
      padding: const EdgeInsets.fromLTRB(13, 9, 13, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: NeuText.label(c.inkMuted, size: 11).copyWith(fontWeight: FontWeight.w700)),
          TextField(
            key: fieldKey,
            controller: controller,
            autofocus: autofocus,
            keyboardType: keyboardType,
            maxLines: maxLines,
            onChanged: onChanged,
            inputFormatters: inputFormatters,
            cursorColor: c.accentInk,
            style: mono ? NeuText.data(c.ink, size: size + 1) : NeuText.strong(c.ink, size: size),
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 5),
              hintText: hint,
              hintStyle: NeuText.body_(c.inkFaint, size: size - 1),
            ),
          ),
        ],
      ),
    );
    if (!highlight) return box;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.accent, width: 2),
      ),
      child: box,
    );
  }
}

/// A sunk read-only well with a label: `Size  +6.5`.
class ValueWell extends StatelessWidget {
  const ValueWell({super.key, required this.label, required this.value, this.mono = true});
  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    return NeuBox(
      style: NeuStyle.insetSm,
      radius: 14,
      color: c.ground,
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: NeuText.label(c.inkMuted, size: 11).copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 3),
          Text(
            value,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: mono ? NeuText.data(c.ink, size: 18) : NeuText.body_(c.ink, size: 15),
          ),
        ],
      ),
    );
  }
}

/// A 64-tall pressable tile: icon over a short label.
class ActionTile extends StatelessWidget {
  const ActionTile({super.key, required this.icon, required this.label, this.onTap, this.ink});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color? ink;

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final color = onTap == null ? c.disabledInk : (ink ?? c.accentInk);
    return NeuBox(
      style: onTap == null ? NeuStyle.flat : NeuStyle.raised,
      color: onTap == null ? c.disabledFill : null,
      radius: 18,
      height: 64,
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(height: 4),
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: NeuText.label(color, size: 12)),
        ],
      ),
    );
  }
}

/// `Customer ........ Shah Gems`.
class SummaryRow extends StatelessWidget {
  const SummaryRow({super.key, required this.label, this.value, this.child, this.mono = false});

  final String label;
  final String? value;
  final Widget? child;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    return Row(
      children: [
        Text(label, style: NeuText.body_(c.inkMuted, size: 13.5)),
        const SizedBox(width: 12),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: child ??
                Text(
                  value ?? '',
                  textAlign: TextAlign.right,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: mono ? NeuText.data(c.ink, size: 13) : NeuText.strong(c.ink, size: 13.5),
                ),
          ),
        ),
      ],
    );
  }
}

/// The two phase bars of the customer's request.
class PhaseBars extends StatelessWidget {
  const PhaseBars({super.key, required this.done, this.total = 2});
  final int done;
  final int total;

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    return Row(
      children: [
        for (var i = 0; i < total; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: i < done
                ? Container(
                    height: 6,
                    decoration: BoxDecoration(color: c.accent, borderRadius: BorderRadius.circular(3)),
                  )
                : NeuBox(style: NeuStyle.insetSm, radius: 3, height: 6, color: c.ground),
          ),
        ],
      ],
    );
  }
}

/// "Works offline · ..." under a form's main button.
class OfflineHint extends StatelessWidget {
  const OfflineHint(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    return Text(text, textAlign: TextAlign.center, style: NeuText.body_(c.inkMuted, size: 12));
  }
}

/// A bottom sheet on the ground colour (sheets never go white here), with the
/// grab handle, rounded 30 at the top.
Future<T?> showNeuSheet<T>(
  BuildContext context, {
  required Widget Function(BuildContext sheetContext) builder,
}) {
  final c = NeuTheme.of(context);
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: c.ground,
    barrierColor: const Color(0x471A2032),
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(30))),
    builder: (sheetContext) => NeuTheme(
      colors: c,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 12, 22, 26),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 44,
                    height: 5,
                    decoration: BoxDecoration(color: c.shadowDark, borderRadius: BorderRadius.circular(3)),
                  ),
                ),
                const SizedBox(height: 15),
                builder(sheetContext),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// `22 Oct · 10:05`.
String dayAndTime(DateTime? t) {
  if (t == null) return '—';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${t.day} ${months[t.month - 1]} · ${OdooTime.hm(t)}';
}

/// `Today 11:02`, `Yesterday 17:30`, `20 Oct 09:12`.
String relativeDayTime(DateTime? t, {DateTime? now}) {
  if (t == null) return '';
  final n = now ?? DateTime.now();
  final today = DateTime(n.year, n.month, n.day);
  final day = DateTime(t.year, t.month, t.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return OdooTime.hm(t);
  if (diff == 1) return 'Yesterday ${OdooTime.hm(t)}';
  return dayAndTime(t).replaceFirst(' · ', ' ');
}

const weekdayShort = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const monthShort = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
