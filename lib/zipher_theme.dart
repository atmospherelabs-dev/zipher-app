import 'package:flutter/material.dart';

/// Zipher Design System — semantic tokens and shared widgets.

class ZipherColors {
  // Core backgrounds
  static const Color bg = Color(0xFF0A0E27);
  static const Color surface = Color(0xFF141827);
  static const Color surfaceLight = Color(0xFF1A1F37);
  static const Color border = Color(0xFF1E293B);
  static const Color borderLight = Color(0xFF2D3748);

  // Brand colors
  static const Color cyan = Color(0xFF00D4FF);
  static const Color cyanDark = Color(0xFF00A3CC);
  static const Color green = Color(0xFF10E06C);
  static const Color greenDark = Color(0xFF0BBF5B);
  static const Color purple = Color(0xFFA855F7);
  static const Color purpleDark = Color(0xFF7C3AED);
  static const Color orange = Color(0xFFFF6B35);
  static const Color orangeDark = Color(0xFFCC5529);
  static const Color red = Color(0xFFEF4444);

  // Named text colors (static, for themes)
  static const Color textPrimary = Color(0xFFE5E7EB);
  static const Color textSecondary = Color(0xFF9CA3AF);
  static const Color textMuted = Color(0xFF6B7280);
  static const Color textOnBrand = Color(0xFF0A0E27);

  // ── Semantic opacity tokens ─────────────────────────────
  // Use these instead of scattered Colors.white.withValues(alpha: ...).
  // 5 tiers for text, 3 for surfaces.

  static final Color text90 = Colors.white.withValues(alpha: 0.9);
  static final Color text60 = Colors.white.withValues(alpha: 0.6);
  static final Color text40 = Colors.white.withValues(alpha: 0.4);
  static final Color text20 = Colors.white.withValues(alpha: 0.2);
  static final Color text10 = Colors.white.withValues(alpha: 0.1);

  static final Color cardBg = Colors.white.withValues(alpha: 0.04);
  static final Color cardBgElevated = Colors.white.withValues(alpha: 0.06);
  static final Color borderSubtle = Colors.white.withValues(alpha: 0.05);

  // Gradients
  static const LinearGradient primaryGradient = LinearGradient(
    colors: [cyan, green],
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
      Color(0xFF0A0E27),
      Color(0xFF0D1230),
      Color(0xFF0A0E27),
    ],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  // Pool-specific colors
  static const Color transparent = cyan;
  static const Color sapling = purple;
  static const Color orchard = green;
  static const Color shielded = purple;

  // Standard page padding
  static const double pagePadding = 20.0;
}

class ZipherSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;
}

class ZipherRadius {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double full = 999;
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

      // Elevated buttons
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: ZipherColors.cyan,
          foregroundColor: ZipherColors.textOnBrand,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ZipherRadius.md),
          ),
          textStyle: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),

      // Outlined buttons
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: ZipherColors.cyan,
          side: const BorderSide(color: ZipherColors.border),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ZipherRadius.md),
          ),
          textStyle: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),

      // Text buttons
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: ZipherColors.cyan,
          textStyle: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),

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
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),

      // Dialogs
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
        contentTextStyle:
            const TextStyle(color: ZipherColors.textPrimary, fontFamily: 'Inter'),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZipherRadius.md),
          side: const BorderSide(color: ZipherColors.border),
        ),
        behavior: SnackBarBehavior.floating,
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
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),

      // Tooltip
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: ZipherColors.surfaceLight,
          borderRadius: BorderRadius.circular(ZipherRadius.sm),
          border: Border.all(color: ZipherColors.border),
        ),
        textStyle:
            const TextStyle(color: ZipherColors.textPrimary, fontFamily: 'Inter'),
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

  /// Primary CTA — gradient (cyan → green)
  static Widget gradientButton({
    required String label,
    required VoidCallback onPressed,
    IconData? icon,
    double? width,
    bool enabled = true,
  }) {
    return Opacity(
      opacity: enabled ? 1.0 : 0.4,
      child: Container(
        width: width,
        decoration: BoxDecoration(
          gradient: ZipherColors.primaryGradient,
          borderRadius: BorderRadius.circular(ZipherRadius.md),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: enabled ? onPressed : null,
            borderRadius: BorderRadius.circular(ZipherRadius.md),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (icon != null) ...[
                    Icon(icon, color: ZipherColors.textOnBrand, size: 20),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    label,
                    style: const TextStyle(
                      color: ZipherColors.textOnBrand,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'Inter',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Secondary CTA — cyan tint
  static Widget secondaryButton({
    required String label,
    required VoidCallback onPressed,
    IconData? icon,
    double? width,
    Color color = ZipherColors.cyan,
    bool enabled = true,
  }) {
    return Opacity(
      opacity: enabled ? 1.0 : 0.4,
      child: Container(
        width: width,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: enabled ? onPressed : null,
            borderRadius: BorderRadius.circular(ZipherRadius.md),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(ZipherRadius.md),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (icon != null) ...[
                    Icon(icon, color: color, size: 20),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    label,
                    style: TextStyle(
                      color: color,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'Inter',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Ghost button — subtle outline
  static Widget ghostButton({
    required String label,
    required VoidCallback onPressed,
    IconData? icon,
    double? width,
  }) {
    return Container(
      width: width,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(ZipherRadius.md),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            decoration: BoxDecoration(
              color: ZipherColors.cardBg,
              borderRadius: BorderRadius.circular(ZipherRadius.md),
              border: Border.all(color: ZipherColors.borderSubtle),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Icon(icon, color: ZipherColors.text60, size: 20),
                  const SizedBox(width: 8),
                ],
                Text(
                  label,
                  style: TextStyle(
                    color: ZipherColors.text90,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'Inter',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

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
          Icons.arrow_back_rounded,
          size: 18,
          color: ZipherColors.text60,
        ),
      ),
    );
  }

  /// Uppercase sub-page header (e.g. "BACKUP", "ABOUT")
  static Widget pageHeader(
    BuildContext context,
    String title, {
    List<Widget>? actions,
  }) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        ZipherColors.pagePadding,
        MediaQuery.of(context).padding.top + 14,
        ZipherColors.pagePadding,
        16,
      ),
      child: Row(
        children: [
          backButton(context),
          const SizedBox(width: 14),
          Text(
            title.toUpperCase(),
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.5,
              color: ZipherColors.text60,
            ),
          ),
          const Spacer(),
          if (actions != null) ...actions,
        ],
      ),
    );
  }

  /// Section label (e.g. "Security & Tools", "General")
  static Widget sectionLabel(String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
        color: ZipherColors.text20,
      ),
    );
  }

  /// Card container (standardized bg, radius, border)
  static Widget card({required Widget child, EdgeInsets? padding}) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ZipherColors.borderSubtle),
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
        borderRadius: BorderRadius.circular(ZipherRadius.lg),
        border: Border.all(color: borderColor ?? ZipherColors.border),
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
      padding: const EdgeInsets.symmetric(vertical: 48),
      decoration: BoxDecoration(
        color: ZipherColors.cardBg,
        borderRadius: BorderRadius.circular(14),
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
          const SizedBox(height: 12),
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: ZipherColors.text20,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: TextStyle(fontSize: 12, color: ZipherColors.text10),
            ),
          ],
        ],
      ),
    );
  }

  /// Error banner
  static Widget errorBanner(String message, {VoidCallback? onRetry}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ZipherColors.red.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: ZipherColors.red.withValues(alpha: 0.15),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded,
              size: 18, color: ZipherColors.red.withValues(alpha: 0.7)),
          const SizedBox(width: 10),
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
                padding: const EdgeInsets.only(left: 8),
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
        margin: const EdgeInsets.only(top: 10, bottom: 6),
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: ZipherColors.cardBgElevated,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  /// Standard bottom sheet decoration
  static BoxDecoration get sheetDecoration => BoxDecoration(
        color: ZipherColors.bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border(
          top: BorderSide(color: ZipherColors.cardBgElevated, width: 0.5),
        ),
      );

  /// Pool indicator dot
  static Widget poolDot(String pool) {
    final color = pool == 'transparent'
        ? ZipherColors.transparent
        : pool == 'sapling'
            ? ZipherColors.sapling
            : ZipherColors.orchard;
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
    );
  }

  /// Sync progress bar (cyan → green gradient)
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
