/// Timestamp handling, which is the easiest thing here to get quietly wrong.
///
/// **Responses** carry naive UTC, Odoo-style: `2026-09-23T09:12:00`, no `Z`,
/// no offset. A phone that parses that as local time is hours out.
///
/// **`occurred_at` we send** is the exception: ISO-8601 with an explicit
/// offset, stamped from the server-corrected clock. For a captured event an
/// ambiguous timestamp is a silent data bug.
class OdooTime {
  const OdooTime._();

  static DateTime? parse(Object? value) {
    if (value == null) return null;
    final raw = '$value';
    if (raw.isEmpty) return null;
    final hasZone = raw.endsWith('Z') || RegExp(r'[+-]\d{2}:?\d{2}$').hasMatch(raw);
    final parsed = DateTime.tryParse(hasZone ? raw : '${raw}Z');
    return parsed?.toLocal();
  }

  /// What we put in `occurred_at`: always with an offset.
  static String stamp(DateTime local) => local.toIso8601String().contains('+') ||
          local.isUtc
      ? local.toIso8601String()
      : _withOffset(local);

  static String _withOffset(DateTime local) {
    final offset = local.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final abs = offset.abs();
    final hh = abs.inHours.toString().padLeft(2, '0');
    final mm = (abs.inMinutes % 60).toString().padLeft(2, '0');
    final base = local.toIso8601String().split('.').first;
    return '$base$sign$hh:$mm';
  }

  static String hm(DateTime? value) {
    if (value == null) return '--:--';
    return '${value.hour.toString().padLeft(2, '0')}:'
        '${value.minute.toString().padLeft(2, '0')}';
  }

  static String ago(DateTime? value, {DateTime? now}) {
    if (value == null) return 'never';
    var delta = (now ?? DateTime.now()).difference(value);
    // A stamp in the future means the device clock moved, not that we synced
    // in the future. Clamped, because an unclamped negative delta satisfies
    // every threshold below and pins the label to "just now" permanently --
    // the one lie this strip must never tell an operator with no signal.
    if (delta.isNegative) delta = Duration.zero;
    // A full minute, not 45s: between the two the next line rounds down and
    // the strip reads "0 min ago".
    if (delta.inSeconds < 60) return 'just now';
    if (delta.inMinutes < 60) return '${delta.inMinutes} min ago';
    if (delta.inHours < 24) return '${delta.inHours} h ago';
    return '${delta.inDays} d ago';
  }

  static String duration(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}
