import 'package:flutter/material.dart';

import '../theme/neu.dart';
import 'neu_box.dart';

/// Page background plus the ground colour every neumorphic surface sits on.
class NeuScaffold extends StatelessWidget {
  const NeuScaffold({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    return Scaffold(
      backgroundColor: c.ground,
      body: SafeArea(
        child: Padding(padding: padding ?? const EdgeInsets.fromLTRB(20, 14, 20, 0), child: child),
      ),
    );
  }
}

enum NeuButtonKind { primary, secondary, destructive }

/// One primary action per screen. A destructive action is never a filled pill
/// — the accent is red, and two red pills is how somebody cancels a pickup
/// they meant to confirm (DESIGN.md section 2.5a).
class NeuButton extends StatelessWidget {
  const NeuButton({
    super.key,
    required this.label,
    this.onPressed,
    this.kind = NeuButtonKind.secondary,
    this.icon,
    this.disabledReason,
    this.height = 56,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final NeuButtonKind kind;
  final IconData? icon;

  /// Shown above the button when [onPressed] is null. A disabled control in
  /// this design always says why.
  final String? disabledReason;
  final double height;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final enabled = onPressed != null && !busy;

    Color fill;
    Color ink;
    NeuStyle style;
    List<BoxShadow>? accentShadow;

    if (!enabled) {
      fill = c.disabledFill;
      ink = c.disabledInk;
      style = NeuStyle.flat;
    } else {
      switch (kind) {
        case NeuButtonKind.primary:
          fill = c.accent;
          ink = c.onAccent;
          style = NeuStyle.flat;
          accentShadow = [
            BoxShadow(color: c.accentShadow, offset: const Offset(5, 6), blurRadius: 14),
            BoxShadow(color: c.shadowLight, offset: const Offset(-4, -4), blurRadius: 10),
          ];
        case NeuButtonKind.secondary:
          fill = c.ground;
          ink = c.inkMuted;
          style = NeuStyle.raised;
        case NeuButtonKind.destructive:
          fill = c.ground;
          ink = c.attentionInk;
          style = NeuStyle.raised;
      }
    }

    // Side padding so a long label ellipsises inside the pill, never at its edge.
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Center(
        child: busy
            ? SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: ink))
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null || kind == NeuButtonKind.destructive) ...[
                    Icon(icon ?? Icons.warning_amber_rounded, size: 19, color: ink),
                    const SizedBox(width: 10),
                  ],
                  Flexible(
                    child: Text(label, overflow: TextOverflow.ellipsis, style: NeuText.strong(ink, size: 16)),
                  ),
                ],
              ),
      ),
    );

    Widget button;
    if (accentShadow != null) {
      button = DecoratedBox(
        decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(19), boxShadow: accentShadow),
        child: SizedBox(height: height, child: content),
      );
      button = Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(19),
        child: InkWell(onTap: onPressed, borderRadius: BorderRadius.circular(19), child: button),
      );
    } else {
      button = NeuBox(
        style: style,
        radius: 19,
        height: height,
        color: fill,
        onTap: enabled ? onPressed : null,
        child: content,
      );
    }

    if (!enabled && disabledReason != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.lock_outline_rounded, size: 14, color: c.blockedInk),
              const SizedBox(width: 7),
              Flexible(
                child: Text(disabledReason!, style: NeuText.body_(c.blockedInk, size: 12, w: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          button,
        ],
      );
    }
    return button;
  }
}

enum ChipKind { synced, queued, other, attention, blocked, accent }

/// State is never carried by a shadow. It is carried here.
class StateChip extends StatelessWidget {
  const StateChip(this.label, {super.key, required this.kind, this.icon});

  final String label;
  final ChipKind kind;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final (fill, ink) = switch (kind) {
      ChipKind.synced => (c.syncedFill, c.syncedInk),
      ChipKind.queued => (c.queuedFill, c.queuedInk),
      ChipKind.other => (c.otherFill, c.otherInk),
      ChipKind.attention => (c.attentionFill, c.attentionInk),
      ChipKind.blocked => (c.blockedFill, c.blockedInk),
      ChipKind.accent => (c.accent.withValues(alpha: 0.16), c.accentInk),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(11)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 12, color: ink), const SizedBox(width: 5)],
          // Ellipsise inside a Flexible: "In Laser Inscription · new" ran off
          // the card on the M31.
          Flexible(
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: NeuText.label(ink, size: 11)),
          ),
        ],
      ),
    );
  }
}

class NeuField extends StatelessWidget {
  const NeuField({
    super.key,
    required this.controller,
    this.label,
    this.hint,
    this.icon,
    this.obscure = false,
    this.keyboardType,
    this.maxLines = 1,
    this.required_ = false,
    this.textStyle,
    this.onChanged,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String? label;
  final String? hint;
  final IconData? icon;
  final bool obscure;
  final TextInputType? keyboardType;
  final int maxLines;
  final bool required_;
  final TextStyle? textStyle;
  final ValueChanged<String>? onChanged;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null) ...[
          Row(
            children: [
              Text(label!, style: NeuText.label(c.inkMuted, size: 12)),
              if (required_) ...[
                const SizedBox(width: 6),
                Text('required', style: NeuText.label(c.attentionInk, size: 11)),
              ],
            ],
          ),
          const SizedBox(height: 9),
        ],
        NeuBox(
          style: NeuStyle.inset,
          radius: 18,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (icon != null) ...[Icon(icon, size: 19, color: c.inkFaint), const SizedBox(width: 12)],
              Expanded(
                child: TextField(
                  controller: controller,
                  obscureText: obscure,
                  keyboardType: keyboardType,
                  maxLines: maxLines,
                  autofocus: autofocus,
                  onChanged: onChanged,
                  cursorColor: c.accentInk,
                  style: textStyle ?? NeuText.strong(c.ink, size: 15),
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 14),
                    hintText: hint,
                    hintStyle: NeuText.body_(c.inkFaint, size: 15),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class NeuSegmented extends StatelessWidget {
  const NeuSegmented({super.key, required this.labels, required this.index, required this.onChanged});

  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    return NeuBox(
      style: NeuStyle.inset,
      radius: 17,
      padding: const EdgeInsets.all(5),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            Expanded(
              child: GestureDetector(
                onTap: () => onChanged(i),
                behavior: HitTestBehavior.opaque,
                child: i == index
                    ? NeuBox(
                        style: NeuStyle.raisedSm,
                        radius: 13,
                        color: Color.lerp(c.ground, c.shadowLight, 0.35),
                        padding: const EdgeInsets.symmetric(vertical: 11),
                        child: Center(
                          child: Text(
                            labels[i],
                            textAlign: TextAlign.center,
                            overflow: TextOverflow.ellipsis,
                            style: NeuText.label(c.accentInk, size: 12.5),
                          ),
                        ),
                      )
                    : Padding(
                        padding: const EdgeInsets.symmetric(vertical: 11),
                        child: Center(
                          child: Text(
                            labels[i],
                            textAlign: TextAlign.center,
                            overflow: TextOverflow.ellipsis,
                            style: NeuText.body_(c.inkMuted, size: 12.5, w: FontWeight.w700),
                          ),
                        ),
                      ),
              ),
            ),
        ],
      ),
    );
  }
}

class NeuIconButton extends StatelessWidget {
  const NeuIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    required this.tooltip,
    this.color,
    this.size = 44,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String tooltip;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    return Semantics(
      button: true,
      label: tooltip,
      child: NeuBox(
        style: NeuStyle.raised,
        radius: 15,
        width: size,
        height: size,
        onTap: onPressed,
        child: Center(child: Icon(icon, size: 20, color: color ?? c.inkMuted)),
      ),
    );
  }
}

/// A short banner for information that is not an error: a lost race, a note
/// from the server, a dependency being waited on.
class NeuNote extends StatelessWidget {
  const NeuNote({
    super.key,
    required this.text,
    this.title,
    this.icon = Icons.info_outline_rounded,
    this.kind = ChipKind.blocked,
    this.style = NeuStyle.inset,
  });

  final String text;
  final String? title;
  final IconData icon;
  final ChipKind kind;
  final NeuStyle style;

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final ink = switch (kind) {
      ChipKind.synced => c.syncedInk,
      ChipKind.queued => c.queuedInk,
      ChipKind.other => c.otherInk,
      ChipKind.attention => c.attentionInk,
      ChipKind.blocked => c.blockedInk,
      ChipKind.accent => c.accentInk,
    };
    return NeuBox(
      style: style,
      radius: 18,
      padding: const EdgeInsets.fromLTRB(16, 15, 17, 15),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: ink),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title != null) ...[Text(title!, style: NeuText.strong(ink, size: 13)), const SizedBox(height: 4)],
                Text(text, style: NeuText.body_(c.inkMuted, size: 12.5)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// An empty list is a normal state, not an error. It still says what to do.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.message,
    this.hint = 'Pull down to check again',
    this.icon = Icons.inbox_outlined,
    this.inline = false,
  });

  final String message;
  final String hint;
  final IconData icon;

  /// Inside a screen that already scrolls as one list. A list inside a list
  /// gets unbounded height and a release build then draws nothing at all
  /// (found on the phone: the customer's "What you have sent" was blank).
  final bool inline;

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final children = [
      const SizedBox(height: 60),
      Center(child: Icon(icon, size: 44, color: c.inkFaint)),
      const SizedBox(height: 14),
      Center(child: Text(message, style: NeuText.body_(c.inkMuted, size: 14))),
      const SizedBox(height: 8),
      Center(child: Text(hint, style: NeuText.body_(c.inkFaint, size: 12))),
    ];
    return inline ? Column(children: children) : ListView(children: children);
  }
}

/// Odoo addresses arrive with embedded newlines and blank lines. On a card
/// that turns one parcel into half a screen, so they are flattened and the
/// caller clamps the line count.
String oneLineAddress(String raw) =>
    raw.split(RegExp(r'[\r\n]+')).map((l) => l.trim()).where((l) => l.isNotEmpty).join(', ');
