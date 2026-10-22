import 'package:flutter/material.dart';

/// Neumorphic tokens. The full rationale lives in `design/DESIGN.md`; the rule
/// that matters here is: **depth is carried by shadow, state never is.** A soft
/// shadow disappears in daylight, so every state below is a saturated chip that
/// clears 4.5:1 against its own fill.
@immutable
class NeuColors {
  const NeuColors({
    required this.ground,
    required this.groundSunk,
    required this.shadowDark,
    required this.shadowLight,
    required this.ink,
    required this.inkMuted,
    required this.inkFaint,
    required this.hairline,
    required this.accent,
    required this.accentInk,
    required this.accentShadow,
    required this.onAccent,
    required this.syncedFill,
    required this.syncedInk,
    required this.queuedFill,
    required this.queuedInk,
    required this.otherFill,
    required this.otherInk,
    required this.attentionFill,
    required this.attentionInk,
    required this.blockedFill,
    required this.blockedInk,
    required this.disabledFill,
    required this.disabledInk,
  });

  final Color ground;
  final Color groundSunk;
  final Color shadowDark;
  final Color shadowLight;
  final Color ink;
  final Color inkMuted;
  final Color inkFaint;
  final Color hairline;
  /// Fills only: pills, the active tab's tint, progress, a ticked box.
  final Color accent;

  /// Accent-*coloured text and icons* on the ground. A brand colour bright
  /// enough to work as a fill is almost never legible as 12px type on a light
  /// surface, so the two are separate tokens and the checker in DESIGN.md
  /// section 2.4 says why.
  final Color accentInk;
  final Color accentShadow;

  /// Text on top of an accent fill.
  final Color onAccent;
  final Color syncedFill;
  final Color syncedInk;
  final Color queuedFill;
  final Color queuedInk;
  final Color otherFill;
  final Color otherInk;
  final Color attentionFill;
  final Color attentionInk;
  final Color blockedFill;
  final Color blockedInk;
  final Color disabledFill;
  final Color disabledInk;

  static NeuColors light(
    Color accent,
    Color accentInk,
    Color accentShadow,
    Color onAccent,
  ) =>
      NeuColors(
        ground: const Color(0xFFE3E8F0),
        groundSunk: const Color(0xFFDDE3EC),
        shadowDark: const Color(0xFFC4CCDA),
        shadowLight: const Color(0xFFFFFFFF),
        ink: const Color(0xFF1A2032),
        inkMuted: const Color(0xFF586178),
        inkFaint: const Color(0xFF79839A),
        hairline: const Color(0xFFD3DAE5),
        accent: accent,
        accentInk: accentInk,
        accentShadow: accentShadow,
        onAccent: onAccent,
        syncedFill: const Color(0xFFD5E8DE),
        syncedInk: const Color(0xFF1B6B48),
        queuedFill: const Color(0xFFF3E2C4),
        queuedInk: const Color(0xFF7A4A00),
        otherFill: const Color(0xFFE2DEF2),
        otherInk: const Color(0xFF57479B),
        attentionFill: const Color(0xFFF3DAD8),
        attentionInk: const Color(0xFF8E2A25),
        blockedFill: const Color(0xFFD7DCE6),
        blockedInk: const Color(0xFF4C5568),
        disabledFill: const Color(0xFFDCE1EA),
        disabledInk: const Color(0xFF79839A),
      );

}

/// Elevation recipes, one per meaning. Nothing outside `NeuBox` should ever
/// write a raw `boxShadow` — that is what keeps 24 screens looking like one app.
/// `accent` is the one primary surface on a screen (DESIGN.md section 2.1):
/// the accent fill with its own coloured shadow.
enum NeuStyle { raised, raisedSm, inset, insetSm, accent, flat }

class NeuTheme extends InheritedWidget {
  const NeuTheme({super.key, required this.colors, required super.child});

  final NeuColors colors;

  static NeuColors of(BuildContext context) {
    final theme = context.dependOnInheritedWidgetOfExactType<NeuTheme>();
    assert(theme != null, 'No NeuTheme in the widget tree');
    return theme!.colors;
  }

  @override
  bool updateShouldNotify(NeuTheme oldWidget) => colors != oldWidget.colors;
}

class NeuText {
  const NeuText._();

  static const String display = 'Sora';
  static const String body = 'Manrope';
  static const String mono = 'IBMPlexMono';

  static TextStyle title(Color c, {double size = 26}) => TextStyle(
        fontFamily: display,
        fontSize: size,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
        color: c,
        height: 1.15,
      );

  static TextStyle label(Color c, {double size = 13}) => TextStyle(
        fontFamily: body,
        fontSize: size,
        fontWeight: FontWeight.w800,
        color: c,
      );

  static TextStyle strong(Color c, {double size = 16}) => TextStyle(
        fontFamily: body,
        fontSize: size,
        fontWeight: FontWeight.w700,
        color: c,
      );

  static TextStyle body_(Color c, {double size = 13, FontWeight w = FontWeight.w500}) =>
      TextStyle(fontFamily: body, fontSize: size, fontWeight: w, color: c, height: 1.45);

  /// Identifiers, carats, pieces, hours, timestamps. Never round a figure the
  /// server sent; display it as given.
  static TextStyle data(Color c, {double size = 12, FontWeight w = FontWeight.w600}) =>
      TextStyle(
        fontFamily: mono,
        fontSize: size,
        fontWeight: w,
        color: c,
        fontFeatures: const [FontFeature.tabularFigures()],
      );
}
