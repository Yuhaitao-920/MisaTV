import 'package:flutter/foundation.dart';

/// Web 平台的 mpv 安装器 stub：所有方法都是无操作，保证跨平台编译通过。
class MpvAndroidDownloadProgress {
  final double? fraction;
  final String stage;

  const MpvAndroidDownloadProgress(this.fraction, this.stage);

  MpvAndroidDownloadProgress.bytes(int received, int total, this.stage)
      : fraction = total > 0 ? (received / total).clamp(0.0, 1.0) : null;
}

class MpvAndroidInstallException implements Exception {
  final String message;

  const MpvAndroidInstallException(this.message);

  @override
  String toString() => message;
}

class MpvAndroidInstaller {
  MpvAndroidInstaller._();

  static final MpvAndroidInstaller instance = MpvAndroidInstaller._();

  bool get supported => false;

  Future<String> get apkDir async => '';

  Future<List<String>> get supportedAbis async => const <String>[];

  Future<bool> get isInstalled async => false;

  Future<String?> get installedVersion async => null;

  Future<String?> get downloadedApk async => null;

  Future<String> download({
    ValueChanged<MpvAndroidDownloadProgress>? onProgress,
  }) async {
    throw const MpvAndroidInstallException('Web 平台不支持下载 mpv-android');
  }

  Future<bool> install(String path) async => false;

  Future<bool> downloadAndInstall({
    ValueChanged<MpvAndroidDownloadProgress>? onProgress,
  }) async {
    return false;
  }

  Future<void> clear() async {}
}
