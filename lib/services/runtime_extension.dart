import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'jvm/arm_bridge_runtime.dart';
import 'jvm/jvm_runtime.dart';
import 'py_spider/py_runtime.dart';

/// 源调用链里按需用到的桌面扩展。
enum RuntimeExtension { jvm, guard, python }

extension RuntimeExtensionInfo on RuntimeExtension {
  String get title => switch (this) {
    RuntimeExtension.jvm => 'JVM 运行时',
    RuntimeExtension.guard => '加固壳支持',
    RuntimeExtension.python => 'Python 运行时',
  };

  String get promptBody => switch (this) {
    RuntimeExtension.jvm =>
      '该源是 JAR 蜘蛛，需要 JVM 运行时（约 85 MB）。\n\n'
          '点击「下载」会自动打开设置页并开始安装，完成后回到这里重试即可。',
    RuntimeExtension.guard =>
      '该源是加固壳，首次使用需要「加固壳支持」（约 39 MB）。\n\n'
          '点击「下载」会自动打开设置页并开始安装，完成后回到这里重试即可。',
    RuntimeExtension.python =>
      defaultTargetPlatform == TargetPlatform.android
          ? '该源是 PY 蜘蛛，Python 运行时随 APK 内置，无需下载。\n\n'
                '若提示运行时缺失，请重新安装应用后重试。'
          : '该源是 PY 蜘蛛，需要 Python 运行时（约 20 MB）。\n\n'
                '点击「下载」会自动打开设置页并开始安装，完成后回到这里重试即可。',
  };

  IconData get icon => switch (this) {
    RuntimeExtension.jvm => Icons.coffee_rounded,
    RuntimeExtension.guard => Icons.lock_outline_rounded,
    RuntimeExtension.python => Icons.terminal_rounded,
  };

  /// Python 运行时在 Windows（按需下载）与 Android（Chaquopy 内置）可用；
  /// JVM / 加固壳仍然只在桌面端提供（Android 走 ART / DexClassLoader）。
  bool get supported => switch (this) {
    RuntimeExtension.python =>
      !kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.windows ||
              defaultTargetPlatform == TargetPlatform.android),
    _ => !kIsWeb && defaultTargetPlatform == TargetPlatform.windows,
  };

  Future<bool> installed() async {
    if (!supported) return false;
    return switch (this) {
      RuntimeExtension.jvm => JvmRuntime.instance.installed(),
      RuntimeExtension.guard => ArmBridgeRuntime.instance.installed(),
      RuntimeExtension.python => PyRuntime.instance.installed(),
    };
  }

  bool get installing => switch (this) {
    RuntimeExtension.jvm => JvmRuntime.instance.installing,
    RuntimeExtension.guard => ArmBridgeRuntime.instance.installing,
    RuntimeExtension.python => PyRuntime.instance.installing,
  };
}

/// 弹窗结果：调用方据此决定提示文案。
enum RuntimePromptResult { ready, downloading, canceled, unavailable }

extension RuntimePromptResultMessage on RuntimePromptResult {
  String messageFor(RuntimeExtension kind) => switch (this) {
    RuntimePromptResult.ready => '',
    RuntimePromptResult.downloading => '正在下载${kind.title}，完成后重试即可',
    RuntimePromptResult.canceled => '已取消下载${kind.title}，该源暂不可用',
    RuntimePromptResult.unavailable =>
      kind == RuntimeExtension.python &&
              defaultTargetPlatform == TargetPlatform.android
          ? 'Python 运行时随 APK 内置，请重新安装应用后重试'
          : '需要${kind.title}，请到设置 → 播放中下载后重试',
  };
}

/// 源调用发现扩展未安装时的统一确认弹窗。
///
/// 服务层只负责「问」和「让用户去装」：点「下载」后交给 AppShell 切到设置页、
/// 展开「播放」并滚动到对应卡片，再由卡片自己的安装流程开始下载。
class RuntimeInstallPrompt {
  RuntimeInstallPrompt._();

  static final instance = RuntimeInstallPrompt._();

  /// AppShell 的上下文，用于弹窗；Shell 销毁时清空。
  BuildContext? hostContext;

  /// AppShell 注册：切页 + 滚动 + 开始安装。
  Future<void> Function(RuntimeExtension kind)? onReveal;

  bool _showing = false;

  Future<RuntimePromptResult> ensure(RuntimeExtension kind) async {
    if (await kind.installed()) return RuntimePromptResult.ready;
    if (!kind.supported) return RuntimePromptResult.unavailable;
    if (kind.installing) return RuntimePromptResult.downloading;
    final context = hostContext;
    if (context == null || !context.mounted) {
      return RuntimePromptResult.unavailable;
    }
    // 并发源调用时只弹一次，其余按「正在下载」处理。
    if (_showing) return RuntimePromptResult.downloading;
    _showing = true;
    try {
      final download = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          icon: Icon(kind.icon, size: 30),
          title: Text('需要下载${kind.title}'),
          content: Text(kind.promptBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('下载'),
            ),
          ],
        ),
      );
      if (download != true) return RuntimePromptResult.canceled;
      final reveal = onReveal;
      if (reveal == null) return RuntimePromptResult.unavailable;
      unawaited(reveal(kind));
      return RuntimePromptResult.downloading;
    } finally {
      _showing = false;
    }
  }
}
