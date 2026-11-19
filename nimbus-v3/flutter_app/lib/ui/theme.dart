import 'package:flutter/material.dart';

/// White-and-blue Nimbus colors. Same values as design/tokens.json and the web demo.
class NimbusColors {
  static const background = Color(0xFFFFFFFF);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceAlt = Color(0xFFEEF4FD);
  static const line = Color(0xFFD6E2F5);
  static const text = Color(0xFF0F2147);
  static const muted = Color(0xFF566887);
  static const primary = Color(0xFF2F6FE4);
  static const primarySoft = Color(0xFFDCE8FD);
  static const onPrimary = Color(0xFFFFFFFF);
  static const wind = Color(0xFF5AA9F5);
  static const danger = Color(0xFFD23F5E);
  static const warning = Color(0xFFB7790A);
  static const ok = Color(0xFF1C9467);
  static const mapGround = Color(0xFFF2F6FD);
  static const mapTop = Color(0xFFFFFFFF);
  static const mapSide = Color(0xFFC9DAF4);
  static const mapSide2 = Color(0xFFDDE8F8);
  static const mapWater = Color(0xFFB9D6FA);
}

/// Touch sizes: nothing tappable under 48 dp, the main action at 56 dp.
class NimbusSizes {
  static const minTap = 48.0;
  static const primaryButton = 56.0;
  static const radius = 18.0;
}

ThemeData nimbusTheme() {
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: NimbusColors.primary,
      primary: NimbusColors.primary,
      onPrimary: NimbusColors.onPrimary,
      surface: NimbusColors.surface,
      onSurface: NimbusColors.text,
      error: NimbusColors.danger,
    ),
    scaffoldBackgroundColor: NimbusColors.background,
    materialTapTargetSize: MaterialTapTargetSize.padded,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: NimbusColors.text, displayColor: NimbusColors.text),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(NimbusSizes.primaryButton),
        textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: NimbusColors.surfaceAlt,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: NimbusColors.line)),
    ),
  );
}
