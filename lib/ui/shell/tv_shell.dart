import 'package:flutter/material.dart';

import '../immersive/immersive_shell.dart';

/// TV 版的根界面：只渲染沉浸观影界面。
///
/// 由 `main_tv.dart` 传入 `KniephosApp.rootBuilder`。
///
/// 存在的意义是**隔离编译单元**：全功能版的 `AppShell` 导入了六个常规页面
/// （home / favorites / history / live / search / settings，合计约 7600 行），
/// Dart 的 tree-shaking 无法跨 `import` 剪枝 —— 只要被导入就会编译进
/// `libapp.so`。TV 版走这个文件，完全不碰常规页面。
class TvShell extends StatelessWidget {
  const TvShell({super.key});

  @override
  Widget build(BuildContext context) => const ImmersiveShell();
}
