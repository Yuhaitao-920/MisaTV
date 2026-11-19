import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../core/logging/app_log.dart';
import '../../core/net/download_mirrors.dart';
import 'mpv_android.dart';

const _tag = 'mpv-installer';

/// 下载进度：fraction 为 null 表示 indeterminate（例如正在解析版本）。
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

/// 在 Android 端下载 mpv-android 官方 release APK 并拉起系统安装器。
///
/// Android 不允许普通应用静默安装第三方 APK，安装一步必须经系统安装界面，
/// 由用户确认。本类负责：查最新 release → 按 ABI 选包 → 多线路下载 → 交给安装器。
class MpvAndroidInstaller {
  MpvAndroidInstaller._();

  static final MpvAndroidInstaller instance = MpvAndroidInstaller._();

  static const MethodChannel _channel =
      MethodChannel('com.kniephos.kniephos/mpv_install');

  static const _api =
      'https://api.github.com/repos/mpv-android/mpv-android/releases/latest';
  static const _apiMirrors = <String>[
    _api,
    'https://gh-proxy.com/https://api.github.com/repos/mpv-android/mpv-android/releases/latest',
    'https://ghfast.top/https://api.github.com/repos/mpv-android/mpv-android/releases/latest',
  ];
  static const _ghProxies = <String>[
    'https://ghfast.top/',
    'https://gh-proxy.com/',
    'https://ghproxy.net/',
  ];

  bool get supported => MpvAndroid.supported;

  Future<T?> _invoke<T>(String method, [dynamic arguments]) async {
    if (!supported) return null;
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    } catch (e) {
      AppLog.w(_tag, '$method 失败：$e');
      return null;
    }
  }

  /// 原生分配、FileProvider 可分享的下载目录。
  Future<String> get apkDir async {
    final native = await _invoke<String>('apkDir');
    if (native != null && native.isNotEmpty) {
      final dir = Directory(native);
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir.path;
    }
    // 原生通道不可用时退回 Dart 侧目录（仅用于展示/下载，安装仍需原生）。
    final support = await getApplicationSupportDirectory();
    final dir = Directory(
      '${support.path}${Platform.pathSeparator}mpv-android',
    );
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  Future<List<String>> get supportedAbis async {
    final list = await _invoke<List<dynamic>>('supportedAbis');
    return list?.map((e) => e.toString()).toList() ?? const <String>[];
  }

  Future<bool> get isInstalled async =>
      await _invoke<bool>('isInstalled') ?? false;

  Future<String?> get installedVersion async =>
      await _invoke<String>('installedVersion');

  /// 本地已下载、等待安装的 APK 路径（无则返回 null）。
  Future<String?> get downloadedApk async {
    try {
      final dir = Directory(await apkDir);
      if (!await dir.exists()) return null;
      final apks = await dir
          .list()
          .where((e) => e is File && e.path.endsWith('.apk'))
          .cast<File>()
          .toList();
      if (apks.isEmpty) return null;
      apks.sort((a, b) => b.path.compareTo(a.path));
      return apks.first.path;
    } catch (_) {
      return null;
    }
  }

  /// 根据设备 ABI 从 release assets 里挑最合适的 APK。
  Map<String, dynamic>? _pickAsset(
    Map<String, dynamic> data,
    List<String> abis,
  ) {
    final assets = (data['assets'] as List?) ?? const [];
    final usable = assets
        .whereType<Map>()
        .where((a) {
          final name = (a['name'] ?? '').toString().toLowerCase();
          return name.endsWith('-release.apk') && !name.contains('allstorage');
        })
        .toList();
    if (usable.isEmpty) return null;

    // arm64 机型优先小包（约 34 MB），universal 作为兜底（约 135 MB）。
    // 上游 release 文件名用连字符（app-default-arm64-v8a-release.apk），
    // Android 返回的 ABI 也是连字符；两种分隔符都尝试，避免误选 universal 大包。
    final preferred = <String>[];
    for (final abi in abis) {
      final lower = abi.toLowerCase();
      preferred.add('app-default-$lower-release.apk');
      preferred.add('app-default-${lower.replaceAll('-', '_')}-release.apk');
    }
    preferred.addAll(const [
      'app-default-arm64-v8a-release.apk',
      'app-default-armeabi-v7a-release.apk',
      'app-default-x86_64-release.apk',
      'app-default-x86-release.apk',
      'app-default-universal-release.apk',
    ]);
    for (final name in preferred) {
      for (final a in usable) {
        if ((a['name'] ?? '').toString().toLowerCase() == name) {
          return Map<String, dynamic>.from(a);
        }
      }
    }
    return Map<String, dynamic>.from(usable.first);
  }

  Future<Map<String, dynamic>?> _fetchLatest(http.Client client) async {
    final ranked = await rankMirrors(_apiMirrors);
    final apis = ranked.isEmpty ? _apiMirrors : ranked;
    var lastError = '';
    for (final api in apis) {
      try {
        final resp = await client.get(
          Uri.parse(api),
          headers: const {
            'User-Agent': 'MisaTV/0.1',
            'Accept': 'application/vnd.github+json',
          },
        );
        if (resp.statusCode != 200) {
          lastError = 'HTTP ${resp.statusCode}';
          continue;
        }
        final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (e) {
        lastError = '$e';
      }
    }
    AppLog.w(_tag, '获取 release 失败：$lastError');
    return null;
  }

  /// 下载最新 release APK，返回本地路径。
  Future<String> download({
    ValueChanged<MpvAndroidDownloadProgress>? onProgress,
  }) async {
    if (!supported) {
      throw const MpvAndroidInstallException('仅 Android 支持下载 mpv-android');
    }
    final client = http.Client();
    try {
      onProgress?.call(const MpvAndroidDownloadProgress(null, '正在获取版本信息'));
      final data = await _fetchLatest(client);
      if (data == null) {
        throw const MpvAndroidInstallException('获取 mpv-android 版本信息失败');
      }
      final abis = await supportedAbis;
      final asset = _pickAsset(data, abis);
      if (asset == null) {
        throw const MpvAndroidInstallException('未找到可下载的 mpv-android APK');
      }
      final url = (asset['browser_download_url'] ?? '').toString();
      if (url.isEmpty) {
        throw const MpvAndroidInstallException('APK 下载地址为空');
      }
      final name = (asset['name'] ?? 'mpv-android.apk').toString();
      final total = (asset['size'] as num?)?.toInt() ?? 0;
      final tag = (data['tag_name'] ?? '').toString();
      AppLog.i(_tag, '选中 APK name=$name tag=$tag bytes=$total abis=$abis');

      final dir = Directory(await apkDir);
      if (!await dir.exists()) await dir.create(recursive: true);
      final target = File('${dir.path}${Platform.pathSeparator}$name');

      // 已存在且大小一致则直接复用，避免重复下载。
      if (await target.exists() && total > 0 && await target.length() == total) {
        onProgress?.call(const MpvAndroidDownloadProgress(1, '已下载，待安装'));
        return target.path;
      }

      onProgress?.call(const MpvAndroidDownloadProgress(null, '测速选择下载线路'));
      final mirrors = <String>[url, ..._ghProxies.map((p) => '$p$url')];
      final ranked = await rankMirrors(mirrors);
      final candidates = ranked.isEmpty ? mirrors : ranked;

      var lastError = '';
      var received = 0;
      var length = total;
      for (final mirror in candidates) {
        try {
          onProgress?.call(MpvAndroidDownloadProgress(null, '正在下载 $name'));
          final request = http.Request('GET', Uri.parse(mirror));
          request.headers['User-Agent'] = 'MisaTV/0.1';
          final response = await client.send(request);
          if (response.statusCode != 200) {
            await response.stream.drain<void>();
            throw MpvAndroidInstallException('HTTP ${response.statusCode}');
          }
          length = response.contentLength ?? total;
          received = 0;
          final sink = target.openWrite();
          try {
            await for (final chunk in response.stream) {
              sink.add(chunk);
              received += chunk.length;
              onProgress?.call(
                MpvAndroidDownloadProgress.bytes(received, length, '正在下载 $name'),
              );
            }
          } finally {
            await sink.close();
          }
          lastError = '';
          break;
        } catch (e) {
          lastError = '$e';
          try {
            if (await target.exists()) await target.delete();
          } catch (_) {}
        }
      }
      if (lastError.isNotEmpty) {
        throw MpvAndroidInstallException('下载失败（所有线路）：$lastError');
      }
      onProgress?.call(
        MpvAndroidDownloadProgress.bytes(received, length, '下载完成'),
      );
      AppLog.i(_tag, 'downloaded $name tag=$tag bytes=$received');
      return target.path;
    } finally {
      client.close();
    }
  }

  /// 拉起系统安装器。返回是否成功发出安装请求（不代表已安装完成）。
  Future<bool> install(String path) async {
    final ok = await _invoke<bool>('install', path) ?? false;
    if (ok) AppLog.i(_tag, 'launched installer for $path');
    return ok;
  }

  /// 一步到位：下载最新包并拉起系统安装器。
  Future<bool> downloadAndInstall({
    ValueChanged<MpvAndroidDownloadProgress>? onProgress,
  }) async {
    final path = await download(onProgress: onProgress);
    return install(path);
  }

  /// 清掉下载的 APK（不影响已安装的 mpv-android）。
  Future<void> clear() async {
    try {
      final dir = Directory(await apkDir);
      if (!await dir.exists()) return;
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.apk')) {
          await entity.delete();
        }
      }
    } catch (e) {
      AppLog.w(_tag, 'clear 失败：$e');
    }
  }
}
