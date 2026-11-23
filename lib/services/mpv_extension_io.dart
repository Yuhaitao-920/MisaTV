import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../core/logging/app_log.dart';
import '../core/logging/log_redact.dart';
import '../core/net/github_proxy.dart';
import 'update/update_service.dart';

/// 管理 Yaozhil/mpv-Yaozhi 整合包：按需下载、解压、外部播放。
class MpvExtension {
  MpvExtension._();
  static final MpvExtension instance = MpvExtension._();

  static const _api =
      'https://api.github.com/repos/Yaozhil/mpv-Yaozhi/releases/latest';

  String? _exePath;
  Map<String, String> _meta = const {};
  Map<String, dynamic>? _latest;
  DateTime? _latestAt;

  /// 拉取最新 release（gh-proxy 优先）。5 分钟内复用缓存，避免进设置页就重复请求。
  Future<Map<String, dynamic>?> latestRelease({bool force = false}) async {
    final cached = _latest;
    final at = _latestAt;
    if (!force &&
        cached != null &&
        at != null &&
        DateTime.now().difference(at) < const Duration(minutes: 5)) {
      return cached;
    }
    final client = http.Client();
    try {
      for (final api in ghProxyCandidates(_api)) {
        try {
          final response = await client.get(
            Uri.parse(api),
            headers: const {
              'User-Agent': 'MisaTV/0.1',
              'Accept': 'application/vnd.github+json',
            },
          );
          if (response.statusCode != 200) continue;
          final decoded = jsonDecode(utf8.decode(response.bodyBytes));
          if (decoded is Map) {
            final data = Map<String, dynamic>.from(decoded);
            _latest = data;
            _latestAt = DateTime.now();
            return data;
          }
        } catch (e) {
          AppLog.w('mpv', '获取版本信息失败（$api）：$e');
        }
      }
    } finally {
      client.close();
    }
    return null;
  }

  /// 已安装版本是否落后于仓库最新 release。
  ///
  /// 只用于设置页显示「更新」按钮；不强制、不弹提醒。mpv-Yaozhi 的 tag 形如
  /// `mpv-Yaozhi（1.1.3-1）`，所以优先抽取其中的数字版本再比较。
  Future<bool> get hasUpdate async {
    if (!Platform.isWindows || !await isInstalled) return false;
    final latest = await latestRelease();
    final latestTag = (latest?['tag_name'] ?? '').toString().trim();
    if (latestTag.isEmpty) return false;
    final installedTag = ((await meta)['tag'] ?? '').trim();
    if (installedTag.isEmpty) return true;
    if (installedTag == latestTag) return false;
    final latestVersion = _versionOf(latestTag);
    final installedVersion = _versionOf(installedTag);
    if (latestVersion.isNotEmpty && installedVersion.isNotEmpty) {
      return UpdateService.compareVersions(latestVersion, installedVersion) > 0;
    }
    return latestTag != installedTag;
  }

  static String _versionOf(String tag) =>
      RegExp(r'\d+(?:\.\d+)+').firstMatch(tag)?.group(0) ?? '';

  Future<String> get _root async {
    final support = await getApplicationSupportDirectory();
    return '${support.path}${Platform.pathSeparator}mpv-yaozhi';
  }

  Future<bool> get isInstalled async => (await executablePath).isNotEmpty;

  Future<Map<String, String>> get meta async {
    if (_meta.isNotEmpty) return _meta;
    try {
      final file = File('${await _root}${Platform.pathSeparator}meta.json');
      if (await file.exists()) {
        final raw = jsonDecode(await file.readAsString());
        if (raw is Map) {
          _meta = raw.map(
            (key, value) => MapEntry(key.toString(), value.toString()),
          );
        }
      }
    } catch (_) {}
    return _meta;
  }

  Future<String> get executablePath async {
    if (_exePath != null && await File(_exePath!).exists()) return _exePath!;
    _exePath = null;
    if (Platform.isWindows) {
      _exePath = await _findExecutable();
    }
    return _exePath ?? '';
  }

  Future<String?> _findExecutable() async => _findExecutableIn(await _root);

  Future<String?> _findExecutableIn(String rootPath) async {
    final root = Directory(rootPath);
    if (!await root.exists()) return null;
    final sep = Platform.pathSeparator;
    // Yaozhi 新版整合包的主程序是 `core-builds/current/Yaoplayer.exe`，
    // `portable_config/experimental/` 里那个 mpv.exe 只是实验内核，不能当播放器用。
    for (final path in [
      '${root.path}${sep}mpv.exe',
      '${root.path}${sep}Yaoplayer.exe',
      '${root.path}${sep}core-builds${sep}current${sep}Yaoplayer.exe',
    ]) {
      final file = File(path);
      if (await file.exists()) return file.path;
    }
    try {
      await for (final entity in root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last.toLowerCase();
        if (name != 'mpv.exe' && name != 'yaoplayer.exe') continue;
        final lower = entity.path.toLowerCase();
        if (lower.contains('${sep}portable_config${sep}experimental$sep')) {
          continue;
        }
        return entity.path;
      }
    } catch (_) {}
    return null;
  }

  /// 下载并解压最新整合包。返回安装后的 mpv.exe 路径。
  Future<String> install({ValueChanged<MpvProgress>? onProgress}) async {
    if (!Platform.isWindows) {
      throw const MpvException('Yaozhi MPV 扩展目前仅支持 Windows');
    }
    final client = http.Client();
    try {
      onProgress?.call(const MpvProgress(0, 0, '正在获取版本信息'));
      final data = await latestRelease(force: true);
      if (data == null) {
        throw const MpvException('获取 MPV 版本失败（gh-proxy / 直连均不可用）');
      }
      final asset = _pickAsset(data);
      if (asset == null) {
        throw const MpvException('未找到可下载的整合包');
      }
      final url = (asset['browser_download_url'] ?? '').toString();
      final name = (asset['name'] ?? 'mpv.7z').toString();
      final total = (asset['size'] as num?)?.toInt() ?? 0;

      final root = Directory(await _root);
      final staging = Directory('${root.path}.new');
      final backup = Directory('${root.path}.old');
      for (final dir in [staging, backup]) {
        try {
          if (await dir.exists()) await dir.delete(recursive: true);
        } catch (_) {}
      }
      final downloadDir = Directory(
        '${staging.path}${Platform.pathSeparator}download',
      );
      await downloadDir.create(recursive: true);
      final archive = File('${downloadDir.path}${Platform.pathSeparator}$name');

      // 支持库下载统一走 gh-proxy：代理优先，直连只作最后兜底。
      final candidates = ghProxyCandidates(url);
      onProgress?.call(MpvProgress(0, total, '正在通过 gh-proxy 下载 $name'));

      var received = 0;
      var length = total;
      var lastError = '';
      for (final mirror in candidates) {
        try {
          onProgress?.call(MpvProgress(0, total, '正在下载 $name'));
          final request = http.Request('GET', Uri.parse(mirror));
          request.headers['User-Agent'] = 'MisaTV/0.1';
          final response = await client.send(request);
          if (response.statusCode != 200) {
            await response.stream.drain<void>();
            throw MpvException('HTTP ${response.statusCode}');
          }
          length = response.contentLength ?? total;
          received = 0;
          final sink = archive.openWrite();
          try {
            await for (final chunk in response.stream) {
              sink.add(chunk);
              received += chunk.length;
              onProgress?.call(MpvProgress(received, length, '正在下载 $name'));
            }
          } finally {
            await sink.close();
          }
          lastError = '';
          break;
        } catch (e) {
          lastError = '$e';
          try {
            if (await archive.exists()) await archive.delete();
          } catch (_) {}
        }
      }
      if (lastError.isNotEmpty) {
        await _cleanupQuietly(staging);
        throw MpvException('下载失败（所有线路）：$lastError');
      }

      onProgress?.call(MpvProgress(received, length, '正在解压整合包'));
      final appDir = Directory('${staging.path}${Platform.pathSeparator}app');
      await appDir.create(recursive: true);
      final ok = await _extract(archive, appDir, onProgress: onProgress);
      if (!ok) {
        await _cleanupQuietly(staging);
        throw const MpvException('解压失败：未能取得 7zr 解压工具，请安装 7-Zip 后重试');
      }
      final stagedExe = await _findExecutableIn(appDir.path);
      if (stagedExe == null) {
        await _cleanupQuietly(staging);
        throw const MpvException('解压完成但未找到 mpv.exe');
      }
      // 更新时先保留旧版本：下载/解压全部成功后再换目录，
      // 中途失败不会把用户已有的播放器删掉。
      final tool = File(
        '${root.path}${Platform.pathSeparator}tools${Platform.pathSeparator}7zr.exe',
      );
      if (await tool.exists()) {
        try {
          final tools = Directory(
            '${staging.path}${Platform.pathSeparator}tools',
          );
          await tools.create(recursive: true);
          await tool.copy('${tools.path}${Platform.pathSeparator}7zr.exe');
        } catch (_) {}
      }
      try {
        await downloadDir.delete(recursive: true);
      } catch (_) {}
      if (await root.exists()) {
        try {
          await root.rename(backup.path);
        } catch (e) {
          await _cleanupQuietly(staging);
          rethrow;
        }
      }
      try {
        await staging.rename(root.path);
      } catch (e) {
        try {
          if (await backup.exists()) await backup.rename(root.path);
        } catch (_) {}
        await _cleanupQuietly(staging);
        rethrow;
      }
      try {
        if (await backup.exists()) await backup.delete(recursive: true);
      } catch (_) {}
      final exe = await _findExecutable();
      if (exe == null) {
        throw const MpvException('安装完成但未找到 mpv.exe');
      }
      await File('${root.path}${Platform.pathSeparator}meta.json')
          .writeAsString(
            jsonEncode({
              'tag': (data['tag_name'] ?? '').toString(),
              'name': (data['name'] ?? '').toString(),
              'installedAt': DateTime.now().millisecondsSinceEpoch,
            }),
          );
      _meta = {
        'tag': (data['tag_name'] ?? '').toString(),
        'name': (data['name'] ?? '').toString(),
      };
      _exePath = exe;
      onProgress?.call(MpvProgress(received, length, '已完成'));
      return exe;
    } finally {
      client.close();
    }
  }

  Map<String, dynamic>? _pickAsset(dynamic data) {
    if (data is! Map) return null;
    final assets = data['assets'];
    if (assets is! List) return null;
    final candidates = assets.whereType<Map>().where((item) {
      final name = (item['name'] ?? '').toString().toLowerCase();
      return name.endsWith('.7z') || name.endsWith('.zip');
    }).toList();
    if (candidates.isEmpty) return null;
    candidates.sort(
      (a, b) => ((b['size'] as num?) ?? 0).compareTo((a['size'] as num?) ?? 0),
    );
    return Map<String, dynamic>.from(candidates.first);
  }

  Future<void> _cleanupQuietly(Directory dir) async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  Future<bool> _extract(
    File archive,
    Directory destination, {
    ValueChanged<MpvProgress>? onProgress,
  }) async {
    // 7zr（官方 LZMA 解压工具，约 600 KB）：Windows 自带 tar 不支持 LZMA 7z。
    final sevenZr = await _ensure7zr(onProgress);
    if (sevenZr != null) {
      try {
        final result = await Process.run(sevenZr, [
          'x',
          '-y',
          '-o${destination.path}',
          archive.path,
        ], runInShell: false);
        if (result.exitCode == 0) return true;
      } catch (_) {}
    }
    for (final candidate in [
      r'C:\Program Files\7-Zip\7z.exe',
      r'C:\Program Files (x86)\7-Zip\7z.exe',
    ]) {
      if (!await File(candidate).exists()) continue;
      try {
        final result = await Process.run(candidate, [
          'x',
          '-y',
          '-o${destination.path}',
          archive.path,
        ], runInShell: false);
        if (result.exitCode == 0) return true;
      } catch (_) {}
    }
    // 最后的兜底：zip 资产可由系统 tar 解压
    final sep = Platform.pathSeparator;
    final tar =
        '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}${sep}System32${sep}tar.exe';
    try {
      final result = await Process.run(tar, [
        '-xf',
        archive.path,
        '-C',
        destination.path,
      ], runInShell: false);
      if (result.exitCode == 0) return true;
    } catch (_) {}
    return false;
  }

  /// 确保 7zr.exe 可用：优先用已下载的，缺失时从 7-zip.org 获取（约 600 KB）。
  Future<String?> _ensure7zr(ValueChanged<MpvProgress>? onProgress) async {
    final root = await _root;
    final tools = Directory('$root${Platform.pathSeparator}tools');
    final target = File('${tools.path}${Platform.pathSeparator}7zr.exe');
    if (await target.exists() && await target.length() > 100 * 1024) {
      return target.path;
    }
    await tools.create(recursive: true);
    final client = http.Client();
    try {
      onProgress?.call(const MpvProgress(0, 0, '正在准备解压工具'));
      for (final url in const ['https://www.7-zip.org/a/7zr.exe']) {
        try {
          final response = await client.get(
            Uri.parse(url),
            headers: const {'User-Agent': 'MisaTV/0.1'},
          );
          if (response.statusCode != 200 ||
              response.bodyBytes.length < 100 * 1024) {
            continue;
          }
          await target.writeAsBytes(response.bodyBytes, flush: true);
          return target.path;
        } catch (_) {
          // 尝试下一个来源
        }
      }
    } finally {
      client.close();
    }
    return null;
  }

  Future<void> remove() async {
    final root = Directory(await _root);
    if (await root.exists()) await root.delete(recursive: true);
    for (final suffix in const ['.new', '.old']) {
      final dir = Directory('${root.path}$suffix');
      if (await dir.exists()) await dir.delete(recursive: true);
    }
    _exePath = null;
    _meta = const {};
    _latest = null;
    _latestAt = null;
  }

  /// 使用整合包内的 mpv.exe 打开链接（独立窗口）。
  Future<void> open(
    String url, {
    Map<String, String> headers = const {},
    int startSeconds = 0,
  }) async {
    final exe = await executablePath;
    if (exe.isEmpty) {
      throw const MpvException('MPV 扩展尚未安装');
    }
    final args = <String>['--force-window=yes', '--title=MisaTV · Yaozhi MPV'];
    if (startSeconds > 0) args.add('--start=$startSeconds');
    if (headers.isNotEmpty) {
      final fields = headers.entries
          .map((e) => '${e.key}: ${e.value}')
          .join(',');
      args.add('--http-header-fields=$fields');
    }
    // MPV 是分离进程，启动失败/播放失败不会回传到应用；留一份日志好定位
    // FFmpeg 的 URL / HLS / 解码错误。
    final support = await getApplicationSupportDirectory();
    final logDir = Directory('${support.path}${Platform.pathSeparator}logs');
    final logFile = File('${logDir.path}${Platform.pathSeparator}mpv-last.log');
    try {
      await logDir.create(recursive: true);
      if (await logFile.exists()) await logFile.delete();
      args.add('--log-file=${logFile.path}');
    } catch (_) {
      // 日志目录不可写时不影响播放
    }
    args.add(url);
    AppLog.i(
      'mpv',
      '启动 exe=$exe url=${redactUrl(url)} urlLen=${url.length} '
          'headers=${headers.length}',
    );
    final process = await Process.start(
      exe,
      args,
      workingDirectory: File(exe).parent.path,
      mode: ProcessStartMode.detached,
    );
    unawaited(_reportMpvLog(logFile, process.pid));
  }

  /// MPV 启动 3 秒后把日志里的错误行回写到应用日志（URL 脱敏）。
  Future<void> _reportMpvLog(File file, int pid) async {
    await Future<void>.delayed(const Duration(seconds: 3));
    try {
      if (!await file.exists()) return;
      final lines = await file.readAsLines();
      final hits = <String>[];
      for (final line in lines) {
        final lower = line.toLowerCase();
        if (lower.contains('error') ||
            lower.contains('failed') ||
            lower.contains('not found') ||
            lower.contains('timeout') ||
            lower.contains('invalid')) {
          hits.add(_redactLogLine(line));
          if (hits.length >= 8) break;
        }
      }
      if (hits.isNotEmpty) {
        AppLog.w('mpv', 'pid=$pid ${hits.join(' | ')}');
      }
    } catch (_) {
      // 日志读取失败忽略
    }
  }

  String _redactLogLine(String line) {
    final raw = line.trim();
    final redacted = raw.replaceAllMapped(
      RegExp(r'https?://[^\s"\]]+'),
      (m) => redactUrl(m.group(0)!),
    );
    return shorten(redacted, 300);
  }

  /// 旧版路径固定为 resources/mpv/mpv.exe，这里保持同构的查找习惯。
  Future<String> get rootPath => _root;
}

class MpvProgress {
  const MpvProgress(this.received, this.total, this.stage);
  final int received;
  final int total;
  final String stage;

  double? get fraction => total > 0 ? (received / total).clamp(0.0, 1.0) : null;
}

class MpvException implements Exception {
  const MpvException(this.message);
  final String message;

  @override
  String toString() => message;
}
