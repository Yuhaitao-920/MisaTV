/// 字幕包缓存落盘的 io 实现：`<userdata>/subtitles/cache/<key>.json`。
///
/// 用同步 IO：一次读 ~1MB JSON 在本地盘上只要几毫秒，放在字幕面板点击路径
/// 上完全无感；改成异步会把 `cachedChoices()` 一路传染成 Future。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// 缓存目录：`<support>/subtitles/cache`。
///
/// 和 `danmaku_part._applySubtitle` 写 `current-*.srt` 是同一个父目录，
/// 但单独放在 `cache/` 子目录 —— 清「当前字幕」时不会顺手删掉缓存。
Directory? _cacheDir() {
  try {
    final cached = _dirCache ?? _resolveDir();
    _dirCache = cached;
    return cached;
  } catch (_) {
    return null;
  }
}

String? _rootPath;
Directory? _dirCache;

/// 由宿主在启动时注入 support 目录（避免每次同步读 IO 平台通道）。
///
/// 未注入时退化成读环境变量/临时目录兜底 —— 主程序启动时会调用一次
/// [configurePackageStore]。
void configurePackageStore(String supportDirPath) {
  _rootPath = supportDirPath;
  _dirCache = null;
}

Directory? _resolveDir() {
  final root = _rootPath;
  if (root == null || root.isEmpty) {
    // 重启后失效，但不至于崩）。
    try {
      final tmp = Directory.systemTemp;
      return Directory(p.join(tmp.path, 'misatv_subtitle_cache'))
        ..createSync(recursive: true);
    } catch (_) {
      return null;
    }
  }
  final dir = Directory(p.join(root, 'subtitles', 'cache'));
  dir.createSync(recursive: true);
  return dir;
}

/// 键可能含 `|`、`/`、空格 —— 统一转成安全文件名。
String _fileNameOf(String key) {
  final safe = key.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  return '$safe.json';
}

String? readPackageCache(String key) {
  final dir = _cacheDir();
  if (dir == null) return null;
  try {
    final f = File(p.join(dir.path, _fileNameOf(key)));
    if (!f.existsSync()) return null;
    return f.readAsStringSync();
  } catch (_) {
    return null;
  }
}

void writePackageCache(String key, String json) {
  final dir = _cacheDir();
  if (dir == null) return;
  try {
    File(p.join(dir.path, _fileNameOf(key))).writeAsStringSync(json);
  } catch (_) {
    // 落盘失败不影响播放：内存缓存仍然有效。
  }
}

/// 清空缓存目录（供「清除字幕缓存」入口调用）。
void clearPackageCacheFiles() {
  final dir = _cacheDir();
  if (dir == null) return;
  try {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  } catch (_) {}
  _dirCache = null;
}

/// 当前缓存目录（调试 / 日志用）。
String? packageCacheDirPath() => _cacheDir()?.path;
