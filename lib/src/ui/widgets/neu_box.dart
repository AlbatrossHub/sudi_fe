import 'package:flutter/material.dart';

import '../theme/neu.dart';

/// The one place a neumorphic shadow is drawn.
///
/// Flutter's `BoxShadow` has no `inset`, and inset is load-bearing in this
/// design — every text field, segmented track, status strip and selected tab
/// uses it. So raised styles go through `BoxDecoration` and inset styles go
/// through [_InsetShadowPainter], which clips two blurred shadows to the
/// inside of the rounded rect.
class NeuBox extends StatelessWidget {
  const NeuBox({
    super.key,
    this.style = NeuStyle.raised,
    this.radius = 20,
    this.padding,
    this.margin,
    this.width,
    this.height,
    this.color,
    this.onTap,
    this.child,
  });

  final NeuStyle style;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double? width;
  final double? height;

  /// Defaults to the ground. A neumorphic surface must be the same colour as
  /// its parent — there is no "card colour" in this system.
  final Color? color;
  final VoidCallback? onTap;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final fill = color ?? (style == NeuStyle.insetSm ? c.groundSunk : c.ground);
    final rr = BorderRadius.circular(radius);

    Widget content = Padding(
      padding: padding ?? EdgeInsets.zero,
      child: child,
    );

    switch (style) {
      case NeuStyle.raised:
      case NeuStyle.raisedSm:
        final big = style == NeuStyle.raised;
        content = DecoratedBox(
          decoration: BoxDecoration(
            color: fill,
            borderRadius: rr,
            boxShadow: [
              BoxShadow(
                color: c.shadowDark,
                offset: Offset(big ? 6 : 3, big ? 6 : 3),
                blurRadius: big ? 14 : 8,
              ),
              BoxShadow(
                color: c.shadowLight,
                offset: Offset(big ? -6 : -3, big ? -6 : -3),
                blurRadius: big ? 14 : 8,
              ),
            ],
          ),
          child: content,
        );
      case NeuStyle.inset:
      case NeuStyle.insetSm:
        final big = style == NeuStyle.inset;
        content = CustomPaint(
          painter: _InsetShadowPainter(
            radius: radius,
            fill: fill,
            dark: c.shadowDark,
            light: c.shadowLight,
            offset: big ? 5 : 2,
            blur: big ? 11 : 5,
          ),
          child: content,
        );
      case NeuStyle.flat:
        content = DecoratedBox(
          decoration: BoxDecoration(color: fill, borderRadius: rr),
          child: content,
        );
    }

    if (onTap != null) {
      content = Material(
        color: Colors.transparent,
        borderRadius: rr,
        child: InkWell(
          onTap: onTap,
          borderRadius: rr,
          splashColor: c.accent.withValues(alpha: 0.08),
          highlightColor: c.accent.withValues(alpha: 0.05),
          child: content,
        ),
      );
      // Keep the shadow under the ink.
      content = DecoratedBox(
        decoration: BoxDecoration(borderRadius: rr),
        child: content,
      );
    }

    return Container(
      width: width,
      height: height,
      margin: margin,
      child: content,
    );
  }
}

class _InsetShadowPainter extends CustomPainter {
  _InsetShadowPainter({
    required this.radius,
    required this.fill,
    required this.dark,
    required this.light,
    required this.offset,
    required this.blur,
  });

  final double radius;
  final Color fill;
  final Color dark;
  final Color light;
  final double offset;
  final double blur;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rr = RRect.fromRectAndRadius(rect, Radius.circular(radius));

    canvas.save();
    canvas.clipRRect(rr);
    canvas.drawRRect(rr, Paint()..color = fill);

    void inner(Color color, Offset shift) {
      // Everything outside the shifted rounded rect, blurred and clipped to
      // the shape: that reads as light falling into a dent.
      final outer = Path()..addRect(rect.inflate(blur * 4));
      final hole = Path()..addRRect(rr.shift(shift));
      canvas.drawPath(
        Path.combine(PathOperation.difference, outer, hole),
        Paint()
          ..color = color
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur / 2),
      );
    }

    inner(dark, Offset(offset, offset));
    inner(light, Offset(-offset, -offset));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_InsetShadowPainter old) =>
      old.radius != radius ||
      old.fill != fill ||
      old.dark != dark ||
      old.light != light ||
      old.offset != offset ||
      old.blur != blur;
}
