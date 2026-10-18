import 'package:flutter/material.dart';

const _seed = Color(0xFF4FD1C5);

/// Shared background for read-only code blocks and editable JSON fields.
const kCodePanelBackground = Color(0xFF0B0F14);
const monoFonts = ['SF Mono', 'Menlo', 'Consolas', 'Roboto Mono', 'monospace'];

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: _seed,
    brightness: Brightness.dark,
    surface: const Color(0xFF0F1318),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    visualDensity: VisualDensity.compact,
    cardTheme: CardThemeData(
      elevation: 0,
      color: const Color(0xFF161B22),
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      isDense: true,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: const Color(0xFF0B0F14),
      indicatorColor: scheme.primary.withValues(alpha: 0.18),
    ),
    drawerTheme: const DrawerThemeData(backgroundColor: Color(0xFF0B0F14)),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: 0.4),
      space: 1,
    ),
  );
}

/// Semantic status colours used consistently across pages.
class StatusColors {
  static const ok = Color(0xFF3FB950);
  static const warn = Color(0xFFD29922);
  static const bad = Color(0xFFF85149);
  static const info = Color(0xFF58A6FF);
  static const muted = Color(0xFF8B949E);
}

const kPagePadding = 20.0;
const kWideBreakpoint = 900.0;
