import 'package:flutter/material.dart';

/// The two binaries built from this codebase (decision D1).
///
/// They share everything in `core/`; they differ in accent, base path, and
/// which feature tree `app.dart` mounts. Nothing staff-only is reachable from
/// the customer flavor.
enum Flavor {
  field(
    apiPath: '/api/field/v1',
    title: 'Sudi Field',
    // The brand blue, used as a fill.
    accent: Color(0xFF03A9F4),
    // Its legible partner for text and icons: #03A9F4 as 12px type on the
    // ground is 2.1:1, which is unreadable. This is 6.0:1.
    accentInk: Color(0xFF01579B),
    accentShadow: Color(0x5201579B),
    // White on #03A9F4 is 2.6:1 and fails even the large-text bar; this is 5.8.
    onAccent: Color(0xFF06283D),
  ),
  customer(
    apiPath: '/api/customer/v1',
    title: 'Sudi',
    accent: Color(0xFF0E6F66),
    accentInk: Color(0xFF0B564F),
    accentShadow: Color(0x4D09463F),
    onAccent: Color(0xFFFFFFFF),
  );

  const Flavor({
    required this.apiPath,
    required this.title,
    required this.accent,
    required this.accentInk,
    required this.accentShadow,
    required this.onAccent,
  });

  final String apiPath;
  final String title;
  final Color accent;
  final Color accentInk;
  final Color accentShadow;
  final Color onAccent;

  bool get isField => this == Flavor.field;
}

/// Set once by `main_field.dart` / `main_customer.dart` before `runApp`.
///
/// Named `sudiFlavor`, not `appFlavor`: Flutter's own `services.dart` exports an
/// `appFlavor` constant (the `--flavor` string), and the two would collide in
/// any file importing both.
late final Flavor sudiFlavor;
