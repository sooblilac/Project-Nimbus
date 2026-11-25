import 'package:flutter/material.dart';

/// White-and-blue Nimbus colors. Same values as design/tokens.json and the web demo.
class NimbusColors {
  static const primary = Color(0xFF2F6FE4);
  static const onPrimary = Color(0xFFFFFFFF);
  static const wind = Color(0xFF5AA9F5);
  static const danger = Color(0xFFD23F5E);
  static const warning = Color(0xFFB7790A);
  static const ok = Color(0xFF1C9467);
}

@immutable
class NimbusPalette extends ThemeExtension<NimbusPalette> {
  const NimbusPalette({
    required this.background,
    required this.surface,
    required this.surfaceAlt,
    required this.line,
    required this.text,
    required this.muted,
    required this.primarySoft,
    required this.mapGround,
    required this.mapTop,
    required this.mapSide,
    required this.mapSide2,
    required this.mapWater,
  });

  static const light = NimbusPalette(
    background: Color(0xFFF2F7FF),
    surface: Color(0xFFFFFFFF),
    surfaceAlt: Color(0xFFEEF4FD),
    line: Color(0xFFD6E2F5),
    text: Color(0xFF0F2147),
    muted: Color(0xFF566887),
    primarySoft: Color(0xFFDCE8FD),
    mapGround: Color(0xFFF2F6FD),
    mapTop: Color(0xFFFFFFFF),
    mapSide: Color(0xFFC9DAF4),
    mapSide2: Color(0xFFDDE8F8),
    mapWater: Color(0xFFB9D6FA),
  );

  static const dark = NimbusPalette(
    background: Color(0xFF0B1426),
    surface: Color(0xFF121F35),
    surfaceAlt: Color(0xFF1B2A43),
    line: Color(0xFF344660),
    text: Color(0xFFE7EEFC),
    muted: Color(0xFFB0BED4),
    primarySoft: Color(0xFF1D3761),
    mapGround: Color(0xFF17263C),
    mapTop: Color(0xFF1D2D45),
    mapSide: Color(0xFF102038),
    mapSide2: Color(0xFF263B59),
    mapWater: Color(0xFF0C2A48),
  );

  final Color background;
  final Color surface;
  final Color surfaceAlt;
  final Color line;
  final Color text;
  final Color muted;
  final Color primarySoft;
  final Color mapGround;
  final Color mapTop;
  final Color mapSide;
  final Color mapSide2;
  final Color mapWater;

  @override
  NimbusPalette copyWith({
    Color? background,
    Color? surface,
    Color? surfaceAlt,
    Color? line,
    Color? text,
    Color? muted,
    Color? primarySoft,
    Color? mapGround,
    Color? mapTop,
    Color? mapSide,
    Color? mapSide2,
    Color? mapWater,
  }) => NimbusPalette(
    background: background ?? this.background,
    surface: surface ?? this.surface,
    surfaceAlt: surfaceAlt ?? this.surfaceAlt,
    line: line ?? this.line,
    text: text ?? this.text,
    muted: muted ?? this.muted,
    primarySoft: primarySoft ?? this.primarySoft,
    mapGround: mapGround ?? this.mapGround,
    mapTop: mapTop ?? this.mapTop,
    mapSide: mapSide ?? this.mapSide,
    mapSide2: mapSide2 ?? this.mapSide2,
    mapWater: mapWater ?? this.mapWater,
  );

  @override
  NimbusPalette lerp(ThemeExtension<NimbusPalette>? other, double t) {
    if (other is! NimbusPalette) return this;
    return NimbusPalette(
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceAlt: Color.lerp(surfaceAlt, other.surfaceAlt, t)!,
      line: Color.lerp(line, other.line, t)!,
      text: Color.lerp(text, other.text, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      primarySoft: Color.lerp(primarySoft, other.primarySoft, t)!,
      mapGround: Color.lerp(mapGround, other.mapGround, t)!,
      mapTop: Color.lerp(mapTop, other.mapTop, t)!,
      mapSide: Color.lerp(mapSide, other.mapSide, t)!,
      mapSide2: Color.lerp(mapSide2, other.mapSide2, t)!,
      mapWater: Color.lerp(mapWater, other.mapWater, t)!,
    );
  }
}

extension NimbusPaletteContext on BuildContext {
  NimbusPalette get nimbusPalette =>
      Theme.of(this).extension<NimbusPalette>() ??
      (Theme.of(this).brightness == Brightness.dark
          ? NimbusPalette.dark
          : NimbusPalette.light);
}

/// Touch sizes: nothing tappable under 48 dp, the main action at 56 dp.
class NimbusSizes {
  static const minTap = 48.0;
  static const primaryButton = 56.0;
  static const radius = 10.0;
}

ThemeData nimbusTheme({bool dark = false}) {
  final palette = dark ? NimbusPalette.dark : NimbusPalette.light;
  final brightness = dark ? Brightness.dark : Brightness.light;
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: ColorScheme.fromSeed(
      seedColor: NimbusColors.primary,
      brightness: brightness,
      primary: NimbusColors.primary,
      onPrimary: NimbusColors.onPrimary,
      surface: palette.surface,
      onSurface: palette.text,
      error: NimbusColors.danger,
    ),
    scaffoldBackgroundColor: palette.background,
    materialTapTargetSize: MaterialTapTargetSize.padded,
  );
  return base.copyWith(
    extensions: [palette],
    textTheme: base.textTheme.apply(
      bodyColor: palette.text,
      displayColor: palette.text,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(NimbusSizes.primaryButton),
        textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(NimbusSizes.radius),
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: palette.surfaceAlt,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: palette.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: palette.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: NimbusColors.primary, width: 1.5),
      ),
    ),
  );
}
