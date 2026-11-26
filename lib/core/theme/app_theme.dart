import 'package:flutter/material.dart';

import '../app_variant.dart';

class AppTheme {
  /// 标题字体。
  ///
  /// 全功能版用 MiSans（小米 HyperOS 默认字体，免费商用），随包只带
  /// 400/500/700 三个字重（每个 TTF 压缩后约 5.2 MB）。代码里写到 600/800
  /// 的地方由字体匹配回退到最近字重。
  ///
  /// **TV 版不随包字体**：TV 端由 CI 删掉 MiSans 文件（省 5.3 MB），这里改成
  /// 系统字体。电视远看分辨不出字体差异，用 `null` 让 Flutter 走平台默认，
  /// 中文由系统的思源/苹方/雅黑渲染，显示完全正常。
  static String? get fontFamily => kMisaTv ? null : 'MiSans';

  /// MiSans 不含 emoji / 部分生僻符号，交给系统字体兜底。
  ///
  /// TV 版没有 MiSans，这里只留系统字体（Android 上中文由系统字体渲染）。
  static const List<String> fontFamilyFallback = [
    'Microsoft YaHei UI',
    'Microsoft YaHei',
    'Segoe UI',
    'Segoe UI Emoji',
    'Noto Sans CJK SC',
    'sans-serif',
  ];

  /// 正文 / 控件字体：Windows 自带的「微软雅黑 UI」。
  ///
  /// MiSans 的字面偏细，Windows 又只有灰度抗锯齿（没有 ClearType 的着色渲染），
  /// 在 125% / 150% 这类分数缩放下，13-14px 的笔画常常只剩 1 个物理像素，
  /// 观感就是「虚」。雅黑 UI 是为小字号屏幕阅读设计的字体，同字号下笔画更实、
  /// 字面更紧凑；标题继续用 MiSans 保持品牌观感。
  static const String bodyFontFamily = 'Microsoft YaHei UI';

  static const List<String> bodyFontFamilyFallback = [
    'Microsoft YaHei',
    // 全功能版回退到随包 MiSans；TV 版没有该字体，会继续往后面的系统字体找。
    'MiSans',
    'Segoe UI',
    'Segoe UI Emoji',
  ];

  /// 主题色作**前景**（文字 / 图标 / 描边）时的颜色。
  ///
  /// 浅色主题里 primary 是粉彩色，直接画在白底上几乎看不清；压暗后再用，
  /// 深色主题保持原样。
  static Color accentForeground(ColorScheme scheme) {
    if (scheme.brightness == Brightness.dark) return scheme.primary;
    return Color.lerp(scheme.primary, const Color(0xFF11170F), 0.45)!;
  }

  static ThemeData build(Color seed, Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final scheme =
        ColorScheme.fromSeed(
          seedColor: seed,
          brightness: brightness,
          surface: isDark ? const Color(0xFF171C14) : const Color(0xFFF8FAF6),
        ).copyWith(
          primary: seed,
          secondary: seed,
          // primary 被换成粉彩色后，浅色主题的 onPrimary 仍是白色：白字压浅底几乎看不清。
          onPrimary: isDark ? null : const Color(0xFF10160E),
          outlineVariant: isDark
              ? const Color(0xFF2B3327)
              : const Color(0xFFE2E9DD),
        );

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: fontFamily,
      scaffoldBackgroundColor: isDark
          ? const Color(0xFF0F130D)
          : const Color(0xFFF3F7F0),
      splashFactory: InkRipple.splashFactory,
    );

    // 标题沿用 MiSans；正文 / 标签在下面换成雅黑 UI（字重更实，小字号更清楚）。
    final applied = base.textTheme.apply(
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
    );
    final text = applied.copyWith(
      headlineMedium: applied.headlineMedium?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: -0.6,
      ),
      headlineSmall: applied.headlineSmall?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: -0.4,
      ),
      titleLarge: applied.titleLarge?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
      ),
      titleMedium: applied.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      titleSmall: applied.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      // 正文 / 标签换成雅黑 UI：见 [bodyFontFamily] 的说明。
      bodyLarge: applied.bodyLarge?.copyWith(
        fontFamily: bodyFontFamily,
        fontFamilyFallback: bodyFontFamilyFallback,
        fontWeight: FontWeight.w500,
        height: 1.5,
      ),
      bodyMedium: applied.bodyMedium?.copyWith(
        fontFamily: bodyFontFamily,
        fontFamilyFallback: bodyFontFamilyFallback,
        fontWeight: FontWeight.w500,
        height: 1.5,
      ),
      bodySmall: applied.bodySmall?.copyWith(
        fontFamily: bodyFontFamily,
        fontFamilyFallback: bodyFontFamilyFallback,
        fontWeight: FontWeight.w500,
        height: 1.45,
      ),
      labelLarge: applied.labelLarge?.copyWith(
        fontFamily: bodyFontFamily,
        fontFamilyFallback: bodyFontFamilyFallback,
        fontWeight: FontWeight.w600,
      ),
      labelMedium: applied.labelMedium?.copyWith(
        fontFamily: bodyFontFamily,
        fontFamilyFallback: bodyFontFamilyFallback,
        fontWeight: FontWeight.w600,
      ),
      labelSmall: applied.labelSmall?.copyWith(
        fontFamily: bodyFontFamily,
        fontFamilyFallback: bodyFontFamilyFallback,
        fontWeight: FontWeight.w500,
      ),
    );

    return base.copyWith(
      textTheme: text,
      primaryTextTheme: base.primaryTextTheme.apply(
        fontFamily: bodyFontFamily,
        fontFamilyFallback: bodyFontFamilyFallback,
      ),
      dividerColor: isDark ? const Color(0xFF242B21) : const Color(0xFFE7EDE2),
      cardTheme: CardThemeData(
        elevation: 0,
        color: isDark
            ? const Color(0xFF1A2118)
            : Colors.white.withValues(alpha: 0.82),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        clipBehavior: Clip.antiAlias,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: isDark
            ? const Color(0xFF1A2118)
            : const Color(0xFFFDFEFA),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: isDark
            ? const Color(0xFF171C14)
            : const Color(0xFFFDFEFA),
        modalBackgroundColor: isDark
            ? const Color(0xFF171C14)
            : const Color(0xFFFDFEFA),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        showDragHandle: true,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark
            ? const Color(0xFF1D241A)
            : Colors.white.withValues(alpha: 0.78),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(
            color: isDark ? const Color(0xFF2A3226) : const Color(0xFFE3EBDE),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: seed, width: 1.4),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark
            ? const Color(0xFF2B3327)
            : const Color(0xFF25301F),
        contentTextStyle: const TextStyle(
          fontFamily: bodyFontFamily,
          fontFamilyFallback: bodyFontFamilyFallback,
          color: Colors.white,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      chipTheme: base.chipTheme.copyWith(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
        side: BorderSide.none,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        // 浅色主题必须显式给标签颜色：只覆盖字重/字号会让 Chip 丢掉颜色，
        // 未选中的线路标签几乎渲染成白色，完全看不清。深色主题保持原样。
        backgroundColor: isDark ? null : const Color(0xFFE7EDE1),
        selectedColor: isDark ? null : scheme.secondaryContainer,
        labelStyle: isDark
            ? const TextStyle(
                fontFamily: bodyFontFamily,
                fontFamilyFallback: bodyFontFamilyFallback,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              )
            : TextStyle(
                fontFamily: bodyFontFamily,
                fontFamilyFallback: bodyFontFamilyFallback,
                fontWeight: FontWeight.w600,
                fontSize: 13,
                color: WidgetStateColor.resolveWith(
                  (states) => states.contains(WidgetState.selected)
                      ? scheme.onSecondaryContainer
                      : scheme.onSurface,
                ),
              ),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(seed.withValues(alpha: 0.28)),
        radius: const Radius.circular(8),
        thickness: const WidgetStatePropertyAll(5),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.windows: _SoftFadePageTransitionsBuilder(),
          TargetPlatform.linux: _SoftFadePageTransitionsBuilder(),
          TargetPlatform.macOS: _SoftFadePageTransitionsBuilder(),
          TargetPlatform.android: _SoftFadePageTransitionsBuilder(),
          TargetPlatform.iOS: _SoftFadePageTransitionsBuilder(),
        },
      ),
    );
  }
}

/// 只做透明度过渡，避免整页位移带来的逐帧重绘。
class _SoftFadePageTransitionsBuilder extends PageTransitionsBuilder {
  const _SoftFadePageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return FadeTransition(
      opacity: CurvedAnimation(
        parent: animation,
        curve: Curves.easeOut,
        reverseCurve: Curves.easeIn,
      ),
      child: child,
    );
  }
}
