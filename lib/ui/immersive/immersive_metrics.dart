import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 沉浸观影模式的响应式尺寸。
///
/// 这套 UI 原本按电视 / 桌面宽屏设计：左右各 56 留白、150 宽竖版海报卡片、
/// 单行排 6 个导航 tab、Hero 描述框固定 760 宽。手机竖屏下这些数值会
/// 横向溢出，或把内容挤成一条窄柱。
///
/// 统一从这里取值：宽屏完全保持原样，窄屏（宽度 < 720）与矮屏
/// （高度 < 560，通常是手机横屏）收紧留白、缩小卡片、顶栏改成紧凑样式。
/// 所有页面共用同一套数值，便于以后统一调整。
class ImmersiveMetrics {
  ImmersiveMetrics._(this.size, this.padding);

  factory ImmersiveMetrics.of(BuildContext context) {
    final media = MediaQuery.of(context);
    return ImmersiveMetrics._(media.size, media.padding);
  }

  final Size size;
  final EdgeInsets padding;

  double get topPadding => padding.top;

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 手机 / 窄屏（含竖屏平板）。
  bool get compact => size.width < 720;

  /// 矮屏：手机横屏（高度很小且横向更宽），TV 版的两行顶栏和固定底栏放不下。
  ///
  /// 只在安卓生效：桌面窗口再矮也保持原来的 TV 布局，避免影响 Windows。
  bool get short =>
      _isAndroid && size.height < 560 && size.width > size.height;

  /// 顶栏使用紧凑样式（图标 + 小字）：竖屏手机和横屏手机都用这一套。
  bool get chromeCompact => compact || short;

  /// 刘海 / 挖孔在横屏时位于左右两侧，统一折算进左右留白。
  double get _sideSafe => math.max(padding.left, padding.right);

  /// 常规左右留白：宽屏 56，手机纵屏 14，手机横屏 24。
  double get gutter =>
      (compact ? 14.0 : (short ? 24.0 : 56.0)) + _sideSafe;

  /// 外壳顶栏左右留白（桌面原本就是 28，不能跟着内容区放大）。
  double get chromeGutter =>
      (compact ? 14.0 : (short ? 20.0 : 28.0)) + _sideSafe;

  /// 分类页等更宽松的留白。
  double get wideGutter =>
      (compact ? 14.0 : (short ? 24.0 : 64.0)) + _sideSafe;

  /// 外壳顶栏总高度。安卓紧凑栏只保留一行 Tab，桌面保持原来的两行留白。
  double get topBarHeight => compact
      ? topPadding + (_isAndroid ? 56.0 : 44.0 + 48.0)
      : (short ? topPadding + 62.0 : 72.0);

  /// 内容页顶部为顶栏预留的空间。
  double get contentTop => compact || short ? topBarHeight + 8.0 : 92.0;

  /// Hero 文字区左右 / 底部留白。
  double get heroInset => compact ? 14.0 : (short ? 32.0 : 64.0);
  double get heroBottom => compact ? 20.0 : (short ? 26.0 : 64.0);

  /// Hero 高度：宽屏 / 横屏铺满整屏，竖屏手机约半屏（下面还能看到货架）。
  double get heroHeight =>
      compact && !short ? size.height * 0.48 : size.height;

  /// 竖版海报货架的卡片尺寸（2:3 封面 + 标题）。
  double get shelfHeight => compact ? 240.0 : (short ? 210.0 : 300.0);
  double get shelfCardWidth => compact ? 112.0 : (short ? 118.0 : 150.0);

  /// 网格里的竖版海报卡片：宽度上限与整格高度（含片名）。
  double get posterMaxExtent => compact ? 110.0 : (short ? 128.0 : 190.0);
  double get cardExtent => compact ? 270.0 : (short ? 250.0 : 380.0);
  double get categoryCardExtent =>
      compact ? 280.0 : (short ? 260.0 : 390.0);

  /// 直播频道卡片宽度：手机占满一行，宽屏保持 232。
  double get liveTileWidth =>
      compact ? size.width - gutter * 2 : (short ? 200.0 : 232.0);

  /// Hero 标题字号。
  double get heroTitleSize => compact ? 30.0 : (short ? 40.0 : 58.0);

  /// 详情页标题字号（null 表示沿用主题默认）。
  double? get detailTitleSize => compact ? 28.0 : (short ? 32.0 : null);
}
