import 'dart:async';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import '../../services/player/player_window_session.dart';
import '../logging/app_log.dart';
import 'window_service.dart';

/// 独立播放器窗口的最小尺寸：比主窗口小，小屏上也能压到 720×405。
const _standaloneMinimumSize = Size(720, 405);

const _channelToMain = 'misa_player_to_main';
const _channelControl = 'misa_player_control';

bool _mainBridgeRegistered = false;
bool _childControlRegistered = false;

bool get supportsStandalonePlayerWindow => Platform.isWindows;

/// 当前引擎所在的窗口参数（`misa-player:<载荷路径>`）；主窗口返回 null。
///
/// 只在按 Dart 入口参数判不出子窗口时兜底用。
Future<String?> standalonePlayerWindowArgument() async {
  if (!supportsStandalonePlayerWindow) return null;
  try {
    final controller = await WindowController.fromCurrentEngine();
    return controller.arguments;
  } catch (_) {
    // 主窗口 / 非桌面环境没有窗口定义
    return null;
  }
}

/// 主窗口：创建独立播放器窗口。已有播放器窗口时先关掉再建新的。
Future<bool> openStandalonePlayerWindow({
  required PlayerWindowPayload payload,
}) async {
  if (!supportsStandalonePlayerWindow) return false;
  await closeAllStandalonePlayerWindows();
  String? path;
  try {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'player-windows'));
    await dir.create(recursive: true);
    await _prunePayloads(dir);
    path = p.join(
      dir.path,
      'session-${DateTime.now().microsecondsSinceEpoch}.json',
    );
    await File(path).writeAsString(payload.encode(), flush: true);
    await WindowController.create(
      WindowConfiguration(
        arguments: '$standalonePlayerWindowArgPrefix$path',
        hiddenAtLaunch: true,
      ),
    );
    AppLog.i('window', '已创建独立播放器窗口 ${p.basename(path)}');
    return true;
  } catch (e, s) {
    AppLog.e('window', '创建独立播放器窗口失败', e, s);
    if (path != null) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
    return false;
  }
}

/// 主窗口：处理子窗口发回的消息（关闭后同步历史/设置、换源搜索）。
Future<void> registerMainPlayerWindowBridge({
  required Future<void> Function() onSync,
  required Future<void> Function(String keyword) onSearch,
  required Future<void> Function() onClosed,
}) async {
  if (!supportsStandalonePlayerWindow || _mainBridgeRegistered) return;
  _mainBridgeRegistered = true;
  const channel = WindowMethodChannel(
    _channelToMain,
    mode: ChannelMode.unidirectional,
  );
  await channel.setMethodCallHandler((call) async {
    switch (call.method) {
      case 'sync':
        await onSync();
        return true;
      case 'closed':
        await onClosed();
        return true;
      case 'search':
        final keyword = call.arguments is Map
            ? (call.arguments as Map)['keyword']?.toString() ?? ''
            : '';
        if (keyword.trim().isNotEmpty) await onSearch(keyword.trim());
        return true;
    }
    return null;
  });
}

/// 子窗口：把清理/同步消息发回主窗口。
Future<void> notifyMainPlayerWindow(String method, {Object? arguments}) async {
  if (!supportsStandalonePlayerWindow) return;
  try {
    const channel = WindowMethodChannel(
      _channelToMain,
      mode: ChannelMode.unidirectional,
    );
    await channel.invokeMethod(method, arguments);
  } catch (_) {
    // 主窗口已退出时忽略
  }
}

/// 子窗口：配置窗口并显示。
///
/// 播放器页自带一整条顶栏（标题 + 返回 + 画面控制），而且那一行本身就是窗口
/// 拖拽区，所以子窗口不挂系统标题栏：留着会白占一行高度，还多出一套和播放器
/// 顶栏重复的按钮。边框也一起去掉，改成 Flutter 自绘的边缘缩放（见 `windowFrame`）。
Future<void> setupStandalonePlayerWindow({required String title}) async {
  if (!supportsStandalonePlayerWindow) return;
  try {
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    setAppWindowMinimumSize(_standaloneMinimumSize);
    final options = WindowOptions(
      size: await _standaloneWindowSize(),
      minimumSize: _standaloneMinimumSize,
      center: true,
      title: title,
      backgroundColor: Colors.black,
      titleBarStyle: TitleBarStyle.hidden,
      skipTaskbar: false,
      windowButtonVisibility: false,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.setAsFrameless();
      await windowManager.show();
      await windowManager.focus();
    });
  } catch (e, s) {
    AppLog.e('window', '独立播放器窗口初始化失败', e, s);
  }
}

/// 子窗口：注册主窗口发来的控制指令。
Future<void> registerPlayerWindowControls({
  required Future<void> Function() onClose,
}) async {
  if (!supportsStandalonePlayerWindow || _childControlRegistered) return;
  _childControlRegistered = true;
  const channel = WindowMethodChannel(
    _channelControl,
    mode: ChannelMode.unidirectional,
  );
  try {
    await channel.setMethodCallHandler((call) async {
      if (call.method == 'close') {
        await onClose();
        return true;
      }
      return null;
    });
  } catch (e, s) {
    // 上一个播放器窗口还没完全注销时会有注册冲突；本次仍可播放，
    // 只是主窗口退出时可能无法主动关这个窗口。
    AppLog.w('window', '播放器控制通道注册失败', e, s);
  }
}

/// 子窗口清理完成后真正关窗。
Future<void> closeStandalonePlayerWindowNow() async {
  if (!supportsStandalonePlayerWindow) return;
  try {
    await windowManager.setPreventClose(false);
    await windowManager.close();
  } catch (_) {}
}

/// 主窗口退出 / 重开播前：关掉所有独立播放器窗口。
Future<void> closeAllStandalonePlayerWindows() async {
  if (!supportsStandalonePlayerWindow) return;
  List<WindowController> windows;
  try {
    windows = await WindowController.getAll();
  } catch (_) {
    return;
  }
  final players = windows
      .where((w) => w.arguments.startsWith(standalonePlayerWindowArgPrefix))
      .toList();
  if (players.isEmpty) return;
  const channel = WindowMethodChannel(
    _channelControl,
    mode: ChannelMode.unidirectional,
  );
  for (final _ in players) {
    try {
      await channel
          .invokeMethod('close')
          .timeout(const Duration(milliseconds: 800));
    } catch (_) {
      // 子窗口可能正在退出 / 引擎已先销毁
    }
  }
  // 等子窗口真正销毁（引擎注销后再建下一个，避免控制通道注册冲突）。
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    try {
      final remaining = (await WindowController.getAll())
          .where((w) => w.arguments.startsWith(standalonePlayerWindowArgPrefix))
          .toList();
      if (remaining.isEmpty) return;
    } catch (_) {
      return;
    }
  }
}

Future<void> deletePlayerWindowPayload(String path) async {
  try {
    final file = File(path);
    if (await file.exists()) await file.delete();
  } catch (_) {}
}

Future<Size> _standaloneWindowSize() async {
  const fallback = Size(1280, 720);
  try {
    final display = await screenRetriever.getPrimaryDisplay();
    final work = display.visibleSize ?? display.size;
    if (work.width <= 0 || work.height <= 0) return fallback;
    final height = (work.height * 0.8).clamp(540.0, work.height).toDouble();
    final width = (height * 16 / 9).clamp(720.0, work.width * 0.92).toDouble();
    return Size(width, width * 9 / 16);
  } catch (_) {
    return fallback;
  }
}

Future<void> _prunePayloads(Directory dir) async {
  try {
    final now = DateTime.now();
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.toLowerCase().endsWith('.json')) {
        continue;
      }
      try {
        final stat = await entity.stat();
        if (now.difference(stat.modified) > const Duration(days: 1)) {
          await entity.delete();
        }
      } catch (_) {}
    }
  } catch (_) {}
}
