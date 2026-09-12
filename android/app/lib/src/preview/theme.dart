import 'package:flutter/material.dart';

/// The P1 prototype's design tokens.
///
/// This file is the single place the milestone's visual parameters live, so the
/// prototype the user approves and the production screens that follow cannot
/// drift into two different designs: nothing here is a one-off number typed
/// into a widget, and the production theme is built by calling [comicTheme]
/// rather than by re-deriving a ThemeData next to it.
///
/// Scope: only Android ships from this repository's milestone, the app is
/// dark-only, and the reading paper keeps black / gray / white. The seed is the
/// indigo the current app already uses — the prototype proposes hierarchy, not
/// a new palette.
class ComicTokens {
  const ComicTokens._();

  // Spacing scale. Every gap in the UI is one of these four values.
  static const double spaceXs = 8;
  static const double spaceSm = 12;
  static const double spaceMd = 16;
  static const double spaceLg = 24;

  /// Minimum touch target. Buttons that render smaller than this still reserve
  /// it, so a dense row never produces an untappable control.
  static const double minTouchTarget = 48;

  /// Book covers are presented in a 2:3 frame. The frame is fixed; the artwork
  /// inside is [BoxFit.cover], so a mismatched source file cannot change the
  /// rhythm of a grid.
  static const double coverAspectRatio = 2 / 3;

  static const double radiusCard = 12;
  static const double radiusSheet = 16;
  static const double radiusChip = 999;

  /// The continue-reading rail is compact on purpose: it answers "what was I
  /// reading", and the grid below it is the actual content of the shelf.
  static const double continueCardWidth = 208;
  static const double continueCardHeight = 104;

  /// Page backgrounds the reader offers. Black and gray are the dark-app
  /// defaults; white exists because some scanned pages need it.
  static const Color pageBlack = Color(0xFF0B0B0D);
  static const Color pageGray = Color(0xFF3A3A3E);
  static const Color pageWhite = Color(0xFFF5F5F5);

  static Color pageBackground(String name) {
    switch (name) {
      case 'gray':
        return pageGray;
      case 'white':
        return pageWhite;
      default:
        return pageBlack;
    }
  }

  /// Grid density. `comfortable` is the shipped default for a fresh install;
  /// existing installs keep whatever they already stored.
  static GridDensitySpec densitySpec(String name) {
    switch (name) {
      case 'compact':
        return const GridDensitySpec(
            maxCrossAxisExtent: 112, spacing: spaceXs, columns: 3);
      case 'spacious':
        return const GridDensitySpec(
            maxCrossAxisExtent: 184, spacing: spaceMd, columns: 2);
      default:
        return const GridDensitySpec(
            maxCrossAxisExtent: 144, spacing: spaceSm, columns: 3);
    }
  }
}

/// One density preset: the extent the grid targets plus a column hint used by
/// the width sweep in the prototype harness.
class GridDensitySpec {
  const GridDensitySpec({
    required this.maxCrossAxisExtent,
    required this.spacing,
    required this.columns,
  });

  final double maxCrossAxisExtent;
  final double spacing;
  final int columns;
}

/// The dark-only theme the milestone ships.
///
/// [textScale] is not a user setting: it exists so the prototype can render the
/// same screen at 1.0 / 1.3 / 2.0 and show what the layout does when the system
/// does the scaling.
ThemeData comicTheme({double textScale = 1.0}) {
  final base = ThemeData(
    colorSchemeSeed: Colors.indigo,
    brightness: Brightness.dark,
    useMaterial3: true,
  );
  final scheme = base.colorScheme;

  return base.copyWith(
    scaffoldBackgroundColor: const Color(0xFF121215),
    canvasColor: const Color(0xFF121215),
    colorScheme: scheme.copyWith(
      surface: const Color(0xFF121215),
      surfaceContainerLow: const Color(0xFF17171B),
      surfaceContainer: const Color(0xFF1C1C21),
      surfaceContainerHigh: const Color(0xFF232329),
      surfaceContainerHighest: const Color(0xFF2A2A31),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: const Color(0xFF121215),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle:
          base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: const Color(0xFF17171B),
      surfaceTintColor: Colors.transparent,
      height: 64,
      indicatorColor: scheme.primary.withValues(alpha: 0.22),
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
    dividerTheme:
        DividerThemeData(color: Colors.white.withValues(alpha: 0.08), space: 1),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFF1C1C21),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ComicTokens.radiusCard),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      isDense: true,
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: const Color(0xFF232329),
      side: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ComicTokens.radiusChip)),
    ),
    cardTheme: CardThemeData(
      color: const Color(0xFF1C1C21),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ComicTokens.radiusCard)),
      margin: EdgeInsets.zero,
    ),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, ComicTokens.minTouchTarget),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ComicTokens.radiusCard)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, ComicTokens.minTouchTarget),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ComicTokens.radiusCard)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
          minimumSize: const Size(0, ComicTokens.minTouchTarget)),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    textTheme: _scaled(base.textTheme, textScale),
  );
}

TextTheme _scaled(TextTheme theme, double scale) {
  if (scale == 1.0) return theme;
  TextStyle? apply(TextStyle? style) =>
      style?.copyWith(fontSize: (style.fontSize ?? 14) * scale);
  return theme.copyWith(
    displayLarge: apply(theme.displayLarge),
    displayMedium: apply(theme.displayMedium),
    displaySmall: apply(theme.displaySmall),
    headlineLarge: apply(theme.headlineLarge),
    headlineMedium: apply(theme.headlineMedium),
    headlineSmall: apply(theme.headlineSmall),
    titleLarge: apply(theme.titleLarge),
    titleMedium: apply(theme.titleMedium),
    titleSmall: apply(theme.titleSmall),
    bodyLarge: apply(theme.bodyLarge),
    bodyMedium: apply(theme.bodyMedium),
    bodySmall: apply(theme.bodySmall),
    labelLarge: apply(theme.labelLarge),
    labelMedium: apply(theme.labelMedium),
    labelSmall: apply(theme.labelSmall),
  );
}
