import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';

typedef _SetThreadExecutionStateNative = Uint32 Function(Uint32);
typedef _SetThreadExecutionStateDart = int Function(int);

/// 播放期间阻止系统自动休眠 / 关屏。
///
/// - Windows：`SetThreadExecutionState` 是**按线程**记录状态的，必须在同一个线程
///   先 `ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED`，结束时再
///   `ES_CONTINUOUS` 撤销。Dart UI isolate 一直存活，所以 acquire/release 成对调用即可。
/// - Android：通过 MethodChannel 调用原生 `WindowManager.LayoutParams
///   .FLAG_KEEP_SCREEN_ON`，播放时保持屏幕常亮，暂停/退出时清除。此前 Android
///   是空实现，导致播放中屏幕按系统超时自动熄屏（黑屏、无法常亮）。
class SleepInhibitor {
  SleepInhibitor._();

  static const _continuous = 0x80000000;
  static const _systemRequired = 0x00000001;
  static const _displayRequired = 0x00000002;

  static const MethodChannel _androidChannel =
      MethodChannel('com.kniephos.kniephos/wakelock');

  static _SetThreadExecutionStateDart? _fn;
  static int _depth = 0;

  /// 引用计数：换集/重进播放器时避免提前撤销。
  static void acquire() {
    _depth++;
    if (_depth != 1) return;
    _call(true, _continuous | _systemRequired | _displayRequired);
  }

  static void release() {
    if (_depth <= 0) return;
    _depth--;
    if (_depth != 0) return;
    _call(false, _continuous);
  }

  /// 播放器销毁时兜底：无论计数多少都恢复系统默认休眠策略。
  static void releaseAll() {
    _depth = 0;
    _call(false, _continuous);
  }

  static void _call(bool keep, int windowsFlags) {
    if (Platform.isAndroid) {
      // Android 保持屏幕常亮；原生端负责 addFlags/clearFlags FLAG_KEEP_SCREEN_ON。
      // 忽略调用异常，失败时不影响播放。
      unawaited(
        _androidChannel
            .invokeMethod<void>(keep ? 'acquire' : 'release')
            .catchError((_) {}),
      );
      return;
    }
    if (!Platform.isWindows) return;
    try {
      _fn ??= DynamicLibrary.open('kernel32.dll')
          .lookupFunction<_SetThreadExecutionStateNative, _SetThreadExecutionStateDart>(
        'SetThreadExecutionState',
      );
      _fn!(windowsFlags);
    } catch (_) {
      // 非 Windows / 调用失败（权限、无桌面会话）时静默忽略，不影响播放
    }
  }
}
