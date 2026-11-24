import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Zipher Design System — semantic tokens and shared widgets.

class ZipherColors {
  // Core backgrounds (Cipherscan/Cipherpay-aligned dark: #08090F)
  static const Color bg = Color(0xFF08090F);
  // Surfaces are neutral near-blacks, barely lifted from the background.
  // Cards are defined by a hairline, not by a grey fill.
  static const Color surface = Color(0xFF0F1014);
  static const Color surfaceLight = Color(0xFF1A1B20);
  static const Color border = Color(0x17FFFFFF);
  static const Color borderLight = Color(0x24FFFFFF);

  // Brand colors
  static const Color cyan = Color(0xFF00D4FF);
  static const Color cyanDark = Color(0xFF00A3CC);
  static const Color green = Color(0xFF10E06C);
  static const Color greenDark = Color(0xFF0BBF5B);

  /// Warm accent (gradient end, Orchard pool). Keep green for success/positive.
  static const Color warm = Color(0xFFF4B728);
  static const Color warmDark = Color(0xFFD4A020);
  static const Color purple = Color(0xFFA855F7);
  static const Color purpleDark = Color(0xFF7C3AED);
  static const Color orange = Color(0xFFFF6B35);
  static const Color orangeDark = Color(0xFFCC5529);
  static const Color red = Color(0xFFEF4444);
  static const Color blue = Color(0xFF5B9CF6);

  // Named text colors (static, for themes)
  static const Color textPrimary = Color(0xFFE5E7EB);
  static const Color textSecondary = Color(0xFF9CA3AF);
  static const Color textMuted = Color(0xFF8B92A0);
  static const Color textOnBrand = Color(0xFF08090F);

  // ── Semantic opacity tokens ─────────────────────────────
  // Use these instead of scattered Colors.white.withValues(alpha: ...).
  // 5 tiers for text, 3 for surfaces.

  static const Color text90 = textPrimary;
  static const Color text60 = textSecondary;
  static const Color text40 = textMuted;
  static const Color text20 = Color(0xFF686D78);
  static const Color text10 = Color(0xFF383C46);

  // Surfaces must stay opaque, including when used by modal sheets.
  static const Color cardBg = surface;
  static const Color cardBgElevated = surfaceLight;
  static const Color borderSubtle = border;
  static const Color syncPending = Color(0xFFFFD60A);

  // ── Status semantics ───────────────────────────────────
  // One meaning per color: positive = done/in, pending = waiting on the
  // network, negative = failed/refused. Brand cyan is for actions, not status.
  static const Color positive = green;
  static const Color pending = syncPending;
  static const Color negative = red;

  /// Hairline separators inside cards and lists (0.5 pt).
  static const Color separator = Color(0x12FFFFFF);

  // Gradients
  /// Primary brand gradient (sync bar, gradient buttons). Cyan → warm.
  static const LinearGradient primaryGradient = LinearGradient(
    colors: [cyan, warm],
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );

  static const LinearGradient purpleGradient = LinearGradient(
    colors: [purple, cyan],
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );

  static const LinearGradient bgGradient = LinearGradient(
    colors: [
      Color(0xFF08090F),
      Color(0xFF0E1018),
      Color(0xFF08090F),
    ],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  // Pool-specific colors
  static const Color transparent = orange;
  static const Color ironwood = cyan;
  static const Color sapling = purple;
  static const Color orchard = warm;
  static const Color shielded = cyan;

  // Standard page padding
  static const double pagePadding = 20.0;
}

/// Spacing tokens — 8pt base scale (4 for tight UI). Use everywhere; no raw values.
class ZipherSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double smMd = 12;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;
}

/// Frosted glass for small controls that sit on the dark canvas (chips,
/// header pills, the message field). One thin veil (never stacked) with a
/// top sheen and a bright hairline: the edge carries the glass look, so the
/// fill stays near clear instead of turning grey on the dark canvas.
class ZipherGlass {
  static const Color fill = Color(0x08FFFFFF); // white 3%
  static const Color fillTop = Color(0x14FFFFFF); // white 8%
  static const Color edge = Color(0x29FFFFFF); // white 16%

  static BoxDecoration decoration(
          {BorderRadius? radius,
          BoxShape shape = BoxShape.rectangle,
          Color? tint}) =>
      BoxDecoration(
        shape: shape,
        borderRadius: shape == BoxShape.circle
            ? null
            : (radius ?? BorderRadius.circular(ZipherRadius.full)),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: tint == null
              ? const [fillTop, fill]
              : [tint.withValues(alpha: .16), tint.withValues(alpha: .06)],
        ),
        border:
            Border.all(color: tint?.withValues(alpha: .40) ?? edge, width: .5),
      );

  /// Blur what is behind [child], clipped to the same shape.
  static Widget blur(
      {required Widget child,
      BorderRadius? radius,
      bool circle = false,
      double sigma = 16}) {
    final filtered = BackdropFilter(
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma), child: child);
    return circle
        ? ClipOval(child: filtered)
        : ClipRRect(
            borderRadius: radius ?? BorderRadius.circular(ZipherRadius.full),
            child: filtered);
  }
}

/// Border radius tokens — use these everywhere; no raw values.
/// Scale: xxs (handles/chips) → xs → sm → md → lg → xl → xxl (pills) → full.
class ZipherRadius {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 28;
  static const double full = 999;

  // Semantic radii. Prefer these over the raw scale.
  /// Buttons, inputs, segmented controls.
  static const double control = 14;

  /// Cards and grouped lists.
  static const double card = 20;

  /// Bottom sheets (top corners).
  static const double sheet = 24;
}

/// Type scale, modelled on iOS text styles. Family is left to the theme
/// (Inter, falling back to the system font where it is not bundled).
/// Amounts use tabular figures so digits line up and do not jump.
class ZipherType {
  static const _tabular = [FontFeature.tabularFigures()];

  /// Home balance.
  static const TextStyle hero = TextStyle(
      fontSize: 46,
      fontWeight: FontWeight.w600,
      letterSpacing: -1.6,
      height: 1.1,
      color: ZipherColors.text90,
      fontFeatures: _tabular);

  /// Screen titles ("More").
  static const TextStyle largeTitle = TextStyle(
      fontSize: 32,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.6,
      color: ZipherColors.text90);

  /// Primary amount in a review or sheet.
  static const TextStyle amount = TextStyle(
      fontSize: 26,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.6,
      color: ZipherColors.text90,
      fontFeatures: _tabular);

  static const TextStyle title = TextStyle(
      fontSize: 20, fontWeight: FontWeight.w700, color: ZipherColors.text90);

  /// Navigation titles, sheet titles.
  static const TextStyle headline = TextStyle(
      fontSize: 17, fontWeight: FontWeight.w600, color: ZipherColors.text90);

  static const TextStyle body =
      TextStyle(fontSize: 16, height: 1.4, color: ZipherColors.text90);

  /// List row titles.
  static const TextStyle rowTitle = TextStyle(
      fontSize: 16, fontWeight: FontWeight.w500, color: ZipherColors.text90);

  /// List row values (amounts on the right).
  static const TextStyle rowValue = TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w500,
      color: ZipherColors.text90,
      fontFeatures: _tabular);

  static const TextStyle subhead =
      TextStyle(fontSize: 14, height: 1.4, color: ZipherColors.text60);

  /// Secondary line under a row title.
  static const TextStyle footnote =
      TextStyle(fontSize: 13, height: 1.35, color: ZipherColors.text40);

  /// Section headers in lists.
  static const TextStyle section = TextStyle(
      fontSize: 13, fontWeight: FontWeight.w600, color: ZipherColors.text40);

  static const TextStyle caption = TextStyle(
      fontSize: 12, color: ZipherColors.text40, fontFeatures: _tabular);

  /// Addresses and ids. JetBrains Mono is not bundled; fall back to system mono.
  static const TextStyle mono = TextStyle(
      fontFamily: 'JetBrainsMono',
      fontFamilyFallback: ['Menlo', 'Roboto Mono', 'monospace'],
      fontSize: 13,
      height: 1.45,
      color: ZipherColors.text60);
}

class ZipherTheme {
  static ThemeData get dark {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,

      // Color scheme
      colorScheme: const ColorScheme.dark(
        primary: ZipherColors.cyan,
        onPrimary: ZipherColors.textOnBrand,
        primaryContainer: ZipherColors.cyanDark,
        secondary: ZipherColors.green,
        onSecondary: ZipherColors.textOnBrand,
        secondaryContainer: ZipherColors.greenDark,
        tertiary: ZipherColors.purple,
        onTertiary: Colors.white,
        surface: ZipherColors.surface,
        onSurface: ZipherColors.textPrimary,
        error: ZipherColors.red,
        outline: ZipherColors.border,
        outlineVariant: ZipherColors.borderLight,
      ),

      // Scaffold
      scaffoldBackgroundColor: ZipherColors.bg,

      // AppBar
      appBarTheme: const AppBarTheme(
        backgroundColor: ZipherColors.bg,
        foregroundColor: ZipherColors.textPrimary,
        elevation: 0,
        // No tint or shadow when content scrolls under the bar.
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontFamily: 'Inter',
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: ZipherColors.textPrimary,
        ),
        iconTheme: IconThemeData(color: ZipherColors.cyan),
      ),

      // Bottom navigation
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: ZipherColors.surface,
        selectedItemColor: ZipherColors.cyan,
        unselectedItemColor: ZipherColors.textMuted,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
        selectedLabelStyle: TextStyle(
          fontFamily: 'Inter',
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelStyle: TextStyle(
          fontFamily: 'Inter',
          fontSize: 12,
          fontWeight: FontWeight.w400,
        ),
      ),

      // Cards
      cardTheme: CardThemeData(
        color: ZipherColors.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZipherRadius.lg),
          side: const BorderSide(color: ZipherColors.border, width: 1),
        ),
        margin: EdgeInsets.zero,
      ),

      // Buttons: every Material button maps onto a ZipherButton kind, so
      // stock widgets and ZipherButton look identical.
      elevatedButtonTheme: ElevatedButtonThemeData(
          style: ZipherButtonStyle.of(ZipherButtonKind.primary)),
      filledButtonTheme: FilledButtonThemeData(
          style: ZipherButtonStyle.of(ZipherButtonKind.primary)),
      outlinedButtonTheme: OutlinedButtonThemeData(
          style: ZipherButtonStyle.of(ZipherButtonKind.secondary)),
      textButtonTheme: TextButtonThemeData(
          style: ZipherButtonStyle.of(ZipherButtonKind.plain,
              size: ZipherButtonSize.small)),

      // FAB
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: ZipherColors.cyan,
        foregroundColor: ZipherColors.textOnBrand,
        elevation: 4,
        shape: CircleBorder(),
      ),

      // Input decoration
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: ZipherColors.surfaceLight,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ZipherRadius.md),
          borderSide: const BorderSide(color: ZipherColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ZipherRadius.md),
          borderSide: const BorderSide(color: ZipherColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ZipherRadius.md),
          borderSide: const BorderSide(color: ZipherColors.cyan, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ZipherRadius.md),
          borderSide: const BorderSide(color: ZipherColors.red),
        ),
        labelStyle: const TextStyle(color: ZipherColors.textSecondary),
        hintStyle: const TextStyle(color: ZipherColors.textMuted),
        contentPadding: const EdgeInsets.symmetric(
            horizontal: ZipherSpacing.md, vertical: ZipherSpacing.md),
      ),

      // Dialogs
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: ZipherColors.surface,
        modalBackgroundColor: ZipherColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        modalElevation: 0,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(ZipherRadius.sheet)),
        ),
        dragHandleColor: ZipherColors.text10,
        dragHandleSize: Size(36, 5),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: ZipherColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZipherRadius.lg),
          side: const BorderSide(color: ZipherColors.border),
        ),
        titleTextStyle: const TextStyle(
          fontFamily: 'Inter',
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: ZipherColors.textPrimary,
        ),
      ),

      // Snackbar
      snackBarTheme: SnackBarThemeData(
        backgroundColor: ZipherColors.surface,
        contentTextStyle: const TextStyle(
            color: ZipherColors.textPrimary, fontFamily: 'Inter'),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZipherRadius.md),
          side: const BorderSide(color: ZipherColors.border),
        ),
        behavior: SnackBarBehavior.floating,
        insetPadding: const EdgeInsets.fromLTRB(16, 5, 16, 16),
      ),

      // Divider
      dividerTheme: const DividerThemeData(
        color: ZipherColors.border,
        thickness: 1,
        space: 1,
      ),

      // Progress indicator
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: ZipherColors.cyan,
        linearTrackColor: ZipherColors.surfaceLight,
        circularTrackColor: ZipherColors.surfaceLight,
      ),

      // Switch
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return ZipherColors.cyan;
          return ZipherColors.textMuted;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return ZipherColors.cyan.withValues(alpha: 0.3);
          }
          return ZipherColors.surfaceLight;
        }),
      ),

      // Text theme
      textTheme: const TextTheme(
        displayLarge: TextStyle(
          fontFamily: 'Inter',
          fontSize: 48,
          fontWeight: FontWeight.w700,
          color: ZipherColors.textPrimary,
          letterSpacing: -1.5,
        ),
        displayMedium: TextStyle(
          fontFamily: 'Inter',
          fontSize: 36,
          fontWeight: FontWeight.w700,
          color: ZipherColors.textPrimary,
          letterSpacing: -0.5,
        ),
        displaySmall: TextStyle(
          fontFamily: 'Inter',
          fontSize: 28,
          fontWeight: FontWeight.w600,
          color: ZipherColors.textPrimary,
        ),
        headlineLarge: TextStyle(
          fontFamily: 'Inter',
          fontSize: 24,
          fontWeight: FontWeight.w600,
          color: ZipherColors.textPrimary,
        ),
        headlineMedium: TextStyle(
          fontFamily: 'Inter',
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: ZipherColors.textPrimary,
        ),
        headlineSmall: TextStyle(
          fontFamily: 'Inter',
          fontSize: 18,
          fontWeight: FontWeight.w500,
          color: ZipherColors.textPrimary,
        ),
        titleLarge: TextStyle(
          fontFamily: 'Inter',
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: ZipherColors.textPrimary,
        ),
        titleMedium: TextStyle(
          fontFamily: 'Inter',
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: ZipherColors.textSecondary,
        ),
        titleSmall: TextStyle(
          fontFamily: 'Inter',
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: ZipherColors.textSecondary,
        ),
        bodyLarge: TextStyle(
          fontFamily: 'Inter',
          fontSize: 16,
          fontWeight: FontWeight.w400,
          color: ZipherColors.textPrimary,
        ),
        bodyMedium: TextStyle(
          fontFamily: 'Inter',
          fontSize: 14,
          fontWeight: FontWeight.w400,
          color: ZipherColors.textSecondary,
        ),
        bodySmall: TextStyle(
          fontFamily: 'Inter',
          fontSize: 12,
          fontWeight: FontWeight.w400,
          color: ZipherColors.textMuted,
        ),
        labelLarge: TextStyle(
          fontFamily: 'Inter',
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: ZipherColors.textPrimary,
        ),
        labelMedium: TextStyle(
          fontFamily: 'Inter',
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: ZipherColors.textSecondary,
        ),
        labelSmall: TextStyle(
          fontFamily: 'Inter',
          fontSize: 10,
          fontWeight: FontWeight.w400,
          color: ZipherColors.textMuted,
        ),
      ),

      // Data table
      dataTableTheme: DataTableThemeData(
        headingRowColor:
            WidgetStateColor.resolveWith((_) => ZipherColors.surfaceLight),
        dataRowColor: WidgetStateColor.resolveWith((_) => ZipherColors.surface),
        dividerThickness: 1,
        headingTextStyle: const TextStyle(
          fontFamily: 'Inter',
          fontWeight: FontWeight.w600,
          color: ZipherColors.textPrimary,
        ),
        dataTextStyle: const TextStyle(
          fontFamily: 'Inter',
          color: ZipherColors.textSecondary,
        ),
      ),

      // Chip
      chipTheme: ChipThemeData(
        backgroundColor: ZipherColors.surfaceLight,
        selectedColor: ZipherColors.cyan.withValues(alpha: 0.15),
        labelStyle: const TextStyle(
          fontFamily: 'Inter',
          fontSize: 12,
          color: ZipherColors.textSecondary,
        ),
        side: const BorderSide(color: ZipherColors.border),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZipherRadius.full),
        ),
      ),

      // Tab bar
      tabBarTheme: const TabBarThemeData(
        labelColor: ZipherColors.cyan,
        unselectedLabelColor: ZipherColors.textMuted,
        indicatorColor: ZipherColors.cyan,
        labelStyle: TextStyle(
          fontFamily: 'Inter',
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelStyle: TextStyle(
          fontFamily: 'Inter',
          fontSize: 14,
          fontWeight: FontWeight.w400,
        ),
      ),

      // Icon
      iconTheme: const IconThemeData(
        color: ZipherColors.textSecondary,
        size: 24,
      ),

      // List tile
      listTileTheme: const ListTileThemeData(
        tileColor: Colors.transparent,
        textColor: ZipherColors.textPrimary,
        iconColor: ZipherColors.textSecondary,
        contentPadding: EdgeInsets.symmetric(
            horizontal: ZipherSpacing.md, vertical: ZipherSpacing.xs),
      ),

      // Tooltip
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: ZipherColors.surfaceLight,
          borderRadius: BorderRadius.circular(ZipherRadius.sm),
          border: Border.all(color: ZipherColors.border),
        ),
        textStyle: const TextStyle(
            color: ZipherColors.textPrimary, fontFamily: 'Inter'),
      ),
    );
  }
}

/// Reusable Zipher widgets
class ZipherWidgets {
  /// Brand wordmark: cyan Z + white IPHER
  static Widget brandText({double fontSize = 24}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Z',
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.w700,
            color: ZipherColors.cyan,
            fontFamily: 'Inter',
            letterSpacing: 2,
          ),
        ),
        Text(
          'IPHER',
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.w700,
            color: Colors.white,
            fontFamily: 'Inter',
            letterSpacing: 2,
          ),
        ),
      ],
    );
  }

  // ── Button tiers ─────────────────────────────────────────
  // One primary per screen: solid cyan, 52 pt tall, pinned to the bottom.
  // Secondary is a tint of its color; ghost is a quiet neutral fill.

  /// Primary CTA. Kept under its historical name; prefer [ZipherButton].
  static Widget gradientButton({
    required String label,
    required VoidCallback onPressed,
    IconData? icon,
    double? width,
    bool enabled = true,
  }) =>
      _sized(
          width,
          ZipherButton(
              label: label, icon: icon, onPressed: enabled ? onPressed : null));

  /// Tinted CTA in [color] (red for destructive). Prefer [ZipherButton].
  static Widget secondaryButton({
    required String label,
    required VoidCallback onPressed,
    IconData? icon,
    double? width,
    Color color = ZipherColors.cyan,
    bool enabled = true,
  }) =>
      _sized(
          width,
          ZipherButton(
              label: label,
              icon: icon,
              kind: ZipherButtonKind.tinted,
              color: color,
              onPressed: enabled ? onPressed : null));

  /// Neutral secondary CTA ("Not now", "Cancel"). Prefer [ZipherButton].
  static Widget ghostButton({
    required String label,
    required VoidCallback onPressed,
    IconData? icon,
    double? width,
  }) =>
      _sized(
          width,
          ZipherButton(
              label: label,
              icon: icon,
              kind: ZipherButtonKind.secondary,
              onPressed: onPressed));

  static Widget _sized(double? width, Widget child) =>
      width == null ? child : SizedBox(width: width, child: child);

  /// Actions pinned to the bottom of a screen, above the home indicator.
  /// Content scrolls behind; the primary action never does.
  static Widget bottomActions(List<Widget> children) => Container(
        decoration: const BoxDecoration(
          color: ZipherColors.bg,
          border: Border(
              top: BorderSide(color: ZipherColors.separator, width: 0.5)),
        ),
        child: SafeArea(
          top: false,
          minimum: const EdgeInsets.only(bottom: ZipherSpacing.sm),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(ZipherColors.pagePadding,
                ZipherSpacing.smMd, ZipherColors.pagePadding, 0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0) const SizedBox(height: ZipherSpacing.sm),
                  children[i],
                ],
              ],
            ),
          ),
        ),
      );

  /// Small status dot (sync, pairing).
  static Widget statusDot(Color color, {double size = 8}) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );

  /// Rounded-square icon tile used at the start of list rows.
  static Widget iconTile(IconData icon,
          {Color color = ZipherColors.text60, double size = 34}) =>
      Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(ZipherRadius.sm + 2),
        ),
        child: Icon(icon, size: size * 0.5, color: color),
      );

  /// Grouped list: rows in one card separated by inset hairlines.
  static Widget group(List<Widget> rows, {double inset = 62}) => card(
        child: Column(
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0)
                Divider(
                    height: 0.5,
                    thickness: 0.5,
                    indent: inset,
                    color: ZipherColors.separator),
              rows[i],
            ],
          ],
        ),
      );

  /// A tappable row: icon tile, title, optional subtitle and trailing widget.
  static Widget row({
    required IconData icon,
    required String title,
    String? subtitle,
    Widget? trailing,
    Color iconColor = ZipherColors.text60,
    VoidCallback? onTap,
    bool chevron = true,
  }) =>
      Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: ZipherSpacing.md, vertical: ZipherSpacing.smMd),
              child: Row(
                children: [
                  iconTile(icon, color: iconColor),
                  const SizedBox(width: ZipherSpacing.smMd),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: ZipherType.rowTitle),
                        if (subtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(subtitle, style: ZipherType.footnote),
                        ],
                      ],
                    ),
                  ),
                  if (trailing != null) ...[
                    const SizedBox(width: ZipherSpacing.sm),
                    trailing,
                  ],
                  if (onTap != null && chevron)
                    const Padding(
                      padding: EdgeInsets.only(left: ZipherSpacing.xs),
                      child: Icon(Icons.chevron_right_rounded,
                          size: 20, color: ZipherColors.text20),
                    ),
                ],
              ),
            ),
          ),
        ),
      );

  // ── Shared structural widgets ────────────────────────────

  /// Standard back button (36×36 circle, consistent across all sub-pages)
  static Widget backButton(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.of(context).pop(),
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: ZipherColors.cardBgElevated,
          shape: BoxShape.circle,
        ),
        child: Icon(
          Icons.arrow_back_ios_new_rounded,
          size: 16,
          color: ZipherColors.text90,
        ),
      ),
    );
  }

  /// Sub-page header: back button, centered sentence-case title, actions.
  static Widget pageHeader(
    BuildContext context,
    String title, {
    List<Widget>? actions,
  }) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        ZipherSpacing.md,
        MediaQuery.of(context).padding.top + ZipherSpacing.sm,
        ZipherSpacing.md,
        ZipherSpacing.sm,
      ),
      child: SizedBox(
        height: 44,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 56),
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ZipherType.headline,
              ),
            ),
            Row(
              children: [
                backButton(context),
                const Spacer(),
                if (actions != null) ...actions,
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Section label (e.g. "Security & Tools", "General")
  static Widget sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: ZipherSpacing.xs),
      child: Text(text, style: ZipherType.section),
    );
  }

  /// Card container (standardized bg, radius, border)
  static Widget card({required Widget child, EdgeInsets? padding}) {
    return Container(
      padding: padding,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(ZipherRadius.card),
        border: Border.all(color: ZipherColors.borderSubtle, width: 0.5),
      ),
      child: child,
    );
  }

  /// Surface card with padding
  static Widget surfaceCard({
    required Widget child,
    EdgeInsets? padding,
    Color? borderColor,
  }) {
    return Container(
      padding: padding ?? const EdgeInsets.all(ZipherSpacing.lg),
      decoration: BoxDecoration(
        color: ZipherColors.surface,
        borderRadius: BorderRadius.circular(ZipherRadius.card),
        border:
            Border.all(color: borderColor ?? ZipherColors.border, width: 0.5),
      ),
      child: child,
    );
  }

  /// Empty state (centered icon + title + optional subtitle)
  static Widget emptyState({
    required IconData icon,
    required String title,
    String? subtitle,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: ZipherSpacing.xxl),
      decoration: BoxDecoration(
        color: ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(ZipherRadius.lg),
        border: Border.all(color: ZipherColors.borderSubtle),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: ZipherColors.cardBg,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 24, color: ZipherColors.text10),
          ),
          const SizedBox(height: ZipherSpacing.smMd),
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: ZipherColors.text20,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: ZipherSpacing.xs),
            Text(
              subtitle,
              style: TextStyle(fontSize: 12, color: ZipherColors.text20),
            ),
          ],
        ],
      ),
    );
  }

  /// Error banner
  static Widget errorBanner(String message, {VoidCallback? onRetry}) {
    return Container(
      padding: const EdgeInsets.all(ZipherSpacing.md),
      decoration: BoxDecoration(
        color: ZipherColors.red.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(ZipherRadius.md),
        border: Border.all(
          color: ZipherColors.red.withValues(alpha: 0.15),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded,
              size: 18, color: ZipherColors.red.withValues(alpha: 0.7)),
          const SizedBox(width: ZipherSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 13,
                color: ZipherColors.red.withValues(alpha: 0.9),
              ),
            ),
          ),
          if (onRetry != null)
            GestureDetector(
              onTap: onRetry,
              child: Padding(
                padding: const EdgeInsets.only(left: ZipherSpacing.sm),
                child: Text(
                  'Retry',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: ZipherColors.red.withValues(alpha: 0.9),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Bottom sheet handle bar
  static Widget sheetHandle() {
    return Center(
      child: Container(
        margin: const EdgeInsets.only(
            top: ZipherSpacing.sm, bottom: ZipherSpacing.sm),
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: ZipherColors.cardBgElevated,
          borderRadius: BorderRadius.circular(ZipherRadius.xxs),
        ),
      ),
    );
  }

  /// Standard bottom sheet decoration
  static BoxDecoration get sheetDecoration => BoxDecoration(
        color: ZipherColors.bg,
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(ZipherRadius.xl)),
        border: Border(
          top: BorderSide(color: ZipherColors.cardBgElevated, width: 0.5),
        ),
      );

  /// Sync progress bar (cyan → warm gradient)
  static Widget syncProgressBar(double progress) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(ZipherRadius.full),
      child: SizedBox(
        height: 4,
        child: Stack(
          children: [
            Container(color: ZipherColors.surfaceLight),
            FractionallySizedBox(
              widthFactor: progress.clamp(0, 1),
              child: Container(
                decoration: const BoxDecoration(
                  gradient: ZipherColors.primaryGradient,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// iOS-style segmented control. Each segment may carry a count badge.
class ZipherSegmented<T> extends StatelessWidget {
  const ZipherSegmented(
      {super.key,
      required this.segments,
      required this.selected,
      required this.onChanged});
  final List<({T value, String label, int badge})> segments;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => Container(
        height: 36,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: ZipherColors.surface,
          borderRadius: BorderRadius.circular(ZipherRadius.md - 2),
        ),
        child: Row(
          children: [
            for (final s in segments)
              Expanded(
                child: Semantics(
                  selected: s.value == selected,
                  button: true,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => onChanged(s.value),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOut,
                      decoration: BoxDecoration(
                        color: s.value == selected
                            ? ZipherColors.surfaceLight
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(ZipherRadius.sm),
                        boxShadow: s.value == selected
                            ? const [
                                BoxShadow(
                                    color: Color(0x40000000),
                                    blurRadius: 6,
                                    offset: Offset(0, 1))
                              ]
                            : null,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(s.label,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: s.value == selected
                                    ? ZipherColors.text90
                                    : ZipherColors.text40,
                              )),
                          if (s.badge > 0) ...[
                            const SizedBox(width: 6),
                            Container(
                              constraints: const BoxConstraints(minWidth: 18),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(
                                color: ZipherColors.cyan,
                                borderRadius:
                                    BorderRadius.circular(ZipherRadius.full),
                              ),
                              child: Text(
                                s.badge > 99 ? '99+' : '${s.badge}',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: ZipherColors.textOnBrand),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
}

enum ZipherButtonKind {
  /// The one main action: solid cyan.
  primary,

  /// Neutral alternative: Cancel, Not now, Copy, View on explorer.
  secondary,

  /// A colored alternative; with red, a destructive action.
  tinted,

  /// Text only: inline links and low-emphasis actions.
  plain,
}

enum ZipherButtonSize {
  /// 52 pt, for actions at the bottom of a screen or card.
  large,

  /// 36 pt pill, for inline actions (Max, Paste, Retry, Copy).
  small,
}

/// The single source of button styling. Used by [ZipherButton] and by the
/// theme for stock Material buttons.
class ZipherButtonStyle {
  static ButtonStyle of(ZipherButtonKind kind,
      {ZipherButtonSize size = ZipherButtonSize.large,
      Color color = ZipherColors.cyan}) {
    final large = size == ZipherButtonSize.large;
    final (Color fill, Color fg) = switch (kind) {
      ZipherButtonKind.primary => (color, ZipherColors.textOnBrand),
      ZipherButtonKind.secondary => (
          Colors.white.withValues(alpha: 0.08),
          ZipherColors.text90
        ),
      ZipherButtonKind.tinted => (color.withValues(alpha: 0.14), color),
      ZipherButtonKind.plain => (Colors.transparent, color),
    };
    return ButtonStyle(
      minimumSize:
          WidgetStatePropertyAll(Size(large ? 64 : 36, large ? 52 : 36)),
      padding: WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: large ? ZipherSpacing.lg : 14)),
      shape: const WidgetStatePropertyAll(StadiumBorder()),
      side: WidgetStatePropertyAll(switch (kind) {
        ZipherButtonKind.primary =>
          BorderSide(color: Colors.white.withValues(alpha: 0.28), width: 0.5),
        ZipherButtonKind.secondary =>
          BorderSide(color: Colors.white.withValues(alpha: 0.14), width: 0.5),
        ZipherButtonKind.tinted =>
          BorderSide(color: color.withValues(alpha: 0.28), width: 0.5),
        ZipherButtonKind.plain => BorderSide.none,
      }),
      elevation: const WidgetStatePropertyAll(0),
      shadowColor: const WidgetStatePropertyAll(Colors.transparent),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.standard,
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (!states.contains(WidgetState.disabled)) return fill;
        return kind == ZipherButtonKind.plain
            ? Colors.transparent
            : Colors.white.withValues(alpha: 0.05);
      }),
      foregroundColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.disabled) ? ZipherColors.text20 : fg),
      iconColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.disabled) ? ZipherColors.text20 : fg),
      iconSize: WidgetStatePropertyAll(large ? 20 : 16),
      // iOS-like press feedback: a light dim instead of a ripple.
      overlayColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.pressed)
              ? (kind == ZipherButtonKind.primary
                  ? Colors.black.withValues(alpha: 0.12)
                  : Colors.white.withValues(alpha: 0.06))
              : Colors.transparent),
      splashFactory: NoSplash.splashFactory,
      textStyle: WidgetStatePropertyAll(TextStyle(
          fontFamily: 'Inter',
          fontSize: large ? 17 : 15,
          fontWeight: FontWeight.w600)),
    );
  }
}

/// The app's button: a capsule, iOS-style. Primary has a soft sheen and a
/// glow in its own color; secondary is frosted glass; pressing shrinks the
/// button slightly with a light haptic. One primary per screen.
/// Large buttons fill the available width.
class ZipherButton extends StatefulWidget {
  const ZipherButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.kind = ZipherButtonKind.primary,
    this.size = ZipherButtonSize.large,
    this.icon,
    this.color = ZipherColors.cyan,
    this.loading = false,
  });

  final String label;

  /// Null disables the button.
  final VoidCallback? onPressed;
  final ZipherButtonKind kind;
  final ZipherButtonSize size;
  final IconData? icon;

  /// Accent for primary, tinted and plain buttons.
  final Color color;

  /// Shows a spinner in place of the label and ignores taps.
  final bool loading;

  @override
  State<ZipherButton> createState() => _ZipherButtonState();
}

class _ZipherButtonState extends State<ZipherButton> {
  bool _down = false;

  bool get _enabled => widget.onPressed != null;
  bool get _large => widget.size == ZipherButtonSize.large;

  void _press(bool down) {
    if (_down != down && mounted) setState(() => _down = down);
  }

  void _tap() {
    if (widget.loading || widget.onPressed == null) return;
    if (widget.kind == ZipherButtonKind.primary) {
      HapticFeedback.lightImpact();
    } else {
      HapticFeedback.selectionClick();
    }
    widget.onPressed!();
  }

  Color get _foreground {
    if (!_enabled) return ZipherColors.text20;
    return switch (widget.kind) {
      ZipherButtonKind.primary => ZipherColors.textOnBrand,
      ZipherButtonKind.secondary => ZipherColors.text90,
      ZipherButtonKind.tinted || ZipherButtonKind.plain => widget.color,
    };
  }

  BoxDecoration? get _decoration {
    final c = widget.color;
    if (!_enabled) {
      return widget.kind == ZipherButtonKind.plain
          ? null
          : BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(ZipherRadius.full),
              border: Border.all(
                  color: Colors.white.withValues(alpha: 0.06), width: 0.5));
    }
    return switch (widget.kind) {
      ZipherButtonKind.primary => BoxDecoration(
          borderRadius: BorderRadius.circular(ZipherRadius.full),
          // A soft sheen from the top, like light on a curved surface.
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color.lerp(c, Colors.white, 0.14)!, c],
          ),
          border: Border.all(
              color: Colors.white.withValues(alpha: 0.28), width: 0.5),
        ),
      // Frosted glass: a faint white veil over a blur of what is behind.
      ZipherButtonKind.secondary => BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(ZipherRadius.full),
          border: Border.all(
              color: Colors.white.withValues(alpha: 0.14), width: 0.5),
        ),
      ZipherButtonKind.tinted => BoxDecoration(
          color: c.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(ZipherRadius.full),
          border: Border.all(color: c.withValues(alpha: 0.28), width: 0.5),
        ),
      ZipherButtonKind.plain => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final fg = _foreground;
    final height = _large ? 52.0 : 36.0;
    final label = widget.loading
        ? SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: fg))
        : Row(mainAxisSize: MainAxisSize.min, children: [
            if (widget.icon != null) ...[
              Icon(widget.icon, size: _large ? 20 : 16, color: fg),
              SizedBox(width: _large ? ZipherSpacing.sm : 6),
            ],
            Flexible(
                child: Text(widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: _large ? 17 : 15,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.2,
                        color: fg))),
          ]);
    Widget body = Container(
      height: height,
      constraints: BoxConstraints(minWidth: _large ? 64 : 36),
      padding: EdgeInsets.symmetric(horizontal: _large ? ZipherSpacing.lg : 14),
      alignment: Alignment.center,
      decoration: _decoration,
      child: label,
    );
    if (widget.kind == ZipherButtonKind.secondary && _enabled) {
      body = ClipRRect(
        borderRadius: BorderRadius.circular(ZipherRadius.full),
        child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20), child: body),
      );
    }
    final interactive = _enabled && !widget.loading;
    return Semantics(
      button: true,
      enabled: _enabled,
      label: widget.loading ? '${widget.label}, in progress' : widget.label,
      excludeSemantics: true,
      onTap: interactive ? _tap : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: interactive ? (_) => _press(true) : null,
        onTapUp: interactive ? (_) => _press(false) : null,
        onTapCancel: interactive ? () => _press(false) : null,
        onTap: interactive ? _tap : null,
        child: AnimatedScale(
          scale: _down ? 0.97 : 1,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: AnimatedOpacity(
            opacity: _down ? 0.85 : 1,
            duration: const Duration(milliseconds: 120),
            child:
                _large ? SizedBox(width: double.infinity, child: body) : body,
          ),
        ),
      ),
    );
  }
}

/// The soft cyan glow at the top of the home screen, behind the balance.
/// Screens that should read as part of home (the splash, About) place it
/// the same way: first child of a [Stack], full width, from the top edge.
/// Keep the values in step with the home screen (`wallet_chat.dart`).
class ZipherTopGlow extends StatelessWidget {
  const ZipherTopGlow({super.key, this.height = 380, this.intensity = 1});

  /// Height below the status bar; the glow fades out before the bottom.
  final double height;

  /// Scales the glow's opacity (1 = home).
  final double intensity;

  static const _center = Alignment(0, -.45);

  @override
  Widget build(BuildContext context) => Positioned(
        top: 0,
        left: 0,
        right: 0,
        height: height + MediaQuery.paddingOf(context).top,
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: _center,
                radius: .72,
                colors: [
                  ZipherColors.cyan.withValues(alpha: .10 * intensity),
                  ZipherColors.cyan.withValues(alpha: .03 * intensity),
                  ZipherColors.cyan.withValues(alpha: 0),
                ],
                stops: const [0, .5, 1],
              ),
            ),
          ),
        ),
      );
}
