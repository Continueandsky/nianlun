import 'package:flutter/material.dart';

/// 「年轮」暗夜星空银河主题
/// 深空底色 + 暖黄光 + 紫蓝星云；日记文字衬线字体
abstract final class StarryTheme {
  // ── 色板：深空银河 ──
  static const deepSpace = Color(0xFF0A0D1F); // 最深底色
  static const nebula = Color(0xFF161B36); // 星云面
  static const starPurple = Color(0xFFAFA9EC); // 星紫（强调）
  static const starLight = Color(0xFFEDE9FA); // 主文字
  static const starDim = Color(0xFF8E88B8); // 次文字
  static const warmGlow = Color(0xFFF2EDD8); // 暖黄光（月亮/唱片）

  // ── 翻书态：米白纸质 ──
  static const paper = Color(0xFFF7F1E3);
  static const paperInk = Color(0xFF4A412B);
  static const paperDim = Color(0xFF8A7B5C);

  // 注意：ThemeData 构造成本高，这里必须用 static final 缓存。
  // 之前用 getter，键盘弹出动画期间每次 build 都新建 ThemeData，导致编辑器卡顿。
  static final ThemeData dark = ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: deepSpace,
        colorScheme: const ColorScheme.dark(
          primary: starPurple,
          onPrimary: deepSpace,
          secondary: warmGlow,
          surface: nebula,
          onSurface: starLight,
          onSurfaceVariant: starDim,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          foregroundColor: starLight,
          elevation: 0,
          centerTitle: true,
        ),
        fontFamily: 'SerifUI',
        textTheme: const TextTheme(
          titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
          titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
          bodyMedium: TextStyle(fontSize: 14, height: 1.7),
        ),
        snackBarTheme: const SnackBarThemeData(
          backgroundColor: nebula,
          contentTextStyle: TextStyle(color: starLight),
        ),
      );

  /// 翻书态 / 日记编辑器的「纸质浅色」子主题
  /// （米白纸上的深色墨字，Quill 正文取这里的默认色）
  static final ThemeData paperLight = ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: paper,
        colorScheme: const ColorScheme.light(
          primary: paperInk,
          onPrimary: paper,
          surface: paper,
          onSurface: paperInk,
        ),
        textTheme: const TextTheme(
          bodyMedium: TextStyle(
              fontSize: 14.5, height: 1.95, color: paperInk, letterSpacing: 0.2),
          bodySmall: TextStyle(fontSize: 12, color: paperDim),
        ),
      );
}

/// 星空背景绘制参数
class StarSpec {
  final double x, y, r;
  final double opacity;
  const StarSpec(this.x, this.y, this.r, this.opacity);

  static const List<StarSpec> field = [
    StarSpec(0.08, 0.09, 1.2, 0.8),
    StarSpec(0.22, 0.05, 1.0, 0.5),
    StarSpec(0.38, 0.10, 1.1, 0.6),
    StarSpec(0.55, 0.06, 1.0, 0.4),
    StarSpec(0.70, 0.09, 1.2, 0.7),
    StarSpec(0.85, 0.05, 1.0, 0.4),
    StarSpec(0.95, 0.11, 1.1, 0.6),
    StarSpec(0.05, 0.85, 1.0, 0.5),
    StarSpec(0.92, 0.88, 1.1, 0.6),
    StarSpec(0.30, 0.94, 1.0, 0.4),
    StarSpec(0.65, 0.91, 1.1, 0.5),
    StarSpec(0.48, 0.03, 0.9, 0.3),
    StarSpec(0.12, 0.48, 0.9, 0.35),
    StarSpec(0.90, 0.52, 1.0, 0.4),
  ];
}
