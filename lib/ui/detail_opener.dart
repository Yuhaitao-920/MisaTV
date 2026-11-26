import 'package:flutter/material.dart';

import '../models/vod.dart';

/// 「打开详情页」的注入点。
///
/// 为什么需要这个：
///   沉浸界面要跳详情页，但全功能版用 `pages/detail_page.dart`（4152 行），
///   TV 版用 `tv_detail_page.dart`（精简版）。如果沉浸界面直接
///   `import 'pages/detail_page.dart'`，**TV 构建也会把 4152 行编译进
///   `libapp.so`** —— Dart 的 tree-shaking 不跨 import 剪枝，
///   靠 `kMisaTv ? TvDetailPage : DetailPage` 这种运行时分支省不掉体积。
///
/// 做法：沉浸界面只依赖这个 typedef，具体实现由各入口在启动时注入：
///   · `main.dart`    → `installDetailOpener(openFullDetail)`
///   · `main_tv.dart` → `installDetailOpener(openTvDetail)`
/// 这样 TV 构建的依赖闭包里根本没有 `detail_page.dart`。
typedef DetailOpener = Future<void> Function(
  BuildContext context,
  VodItem item, {
  required bool autoPlay,
  required bool fromStart,
});

DetailOpener? _opener;

/// 安装详情页打开器（各入口在 runApp 之前调用）。
void installDetailOpener(DetailOpener opener) => _opener = opener;

/// 沉浸界面调用它打开详情页。
///
/// 未安装时不崩溃：退化成提示，避免"点了没反应"这种更难查的问题。
void openImmersiveDetail(
  BuildContext context,
  VodItem item, {
  bool autoPlay = false,
  bool fromStart = false,
}) {
  final opener = _opener;
  if (opener == null) {
    debugPrint('[immersive] 详情页打开器未安装，忽略对 ${item.name} 的点击');
    return;
  }
  opener(context, item, autoPlay: autoPlay, fromStart: fromStart);
}
