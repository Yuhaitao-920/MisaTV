import 'dart:io';

import 'package:flutter/services.dart';

/// 把内部长驻子进程交给 Windows Job Object 收养。
///
/// 收养后，主程序以任何方式结束（正常关窗、崩溃、任务管理器强杀）时，
/// 整棵子进程树都会被系统一并终止——这是 [JarSpiderHost]/[JarServeHost]
/// 自身 `killNow()` 之外的最后一道兜底。只收养 JVM / Python / aria2 这类
/// 必须随应用退出的运行时；更新安装器、外部播放器、浏览器等显式脱离的
/// 进程不能收养。
class ProcessJob {
  const ProcessJob._();

  static const MethodChannel _channel = MethodChannel('misatv/process_job');

  /// 收养成功返回 true；非 Windows、原生侧未注册（旧 runner / 测试）或
  /// 调用失败返回 false。失败只影响崩溃兜底，不影响进程正常使用。
  static Future<bool> adopt(int pid) async {
    if (!Platform.isWindows || pid <= 0) return false;
    try {
      return await _channel.invokeMethod<bool>('adopt', pid) ?? false;
    } catch (_) {
      return false;
    }
  }
}
