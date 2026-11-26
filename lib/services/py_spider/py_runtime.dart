import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;

import '../bundled_runtime.dart';

import 'package:path_provider/path_provider.dart';

import '../../core/logging/app_log.dart';
import '../../core/net/download_mirrors.dart';
import '../../core/net/runtime_fetch.dart';
import '../../core/platform/archive_extract.dart';

class PyRuntimeProgress {
  const PyRuntimeProgress(this.message, {this.value});
  final String message;
  final double? value;
}

/// TVBox .py 蜘蛛的 Python 运行时。
///
/// - Windows：按需下载 python-3.11.6-embed-amd64.zip，并把 requests 等
///   wheel 解压进 `Lib/site-packages`（embed 包 _pth 隔离由 runner.py 手动注入 sys.path）。
/// - Android：CPython 由 Chaquopy 随 APK 内置（Android 10+ 禁止执行应用数据目录
///   里下载的可执行文件，不能照搬 Windows 的 python.exe）。这里只负责把
///   runner.py / base/spider.py 落到私有目录，供进程内 `import runner` 使用。
class PyRuntime {
  PyRuntime._();
  static final instance = PyRuntime._();

  static const version = '3.11.6';

  /// runner.py / base/spider.py 的资源版本：升级后强制重写旧运行时里的这两个文件。
  static const assetsVersion = 9;
  static const _embedUrls = <String>[
    'https://mirrors.huaweicloud.com/python/$version/python-$version-embed-amd64.zip',
    'https://mirrors.aliyun.com/python-release/windows/python-$version-embed-amd64.zip',
    'https://registry.npmmirror.com/-/binary/python/$version/python-$version-embed-amd64.zip',
    'https://www.python.org/ftp/python/$version/python-$version-embed-amd64.zip',
    'https://mirrors.tuna.tsinghua.edu.cn/python/$version/python-$version-embed-amd64.zip',
  ];
  static const _simpleBases = <String>[
    'https://mirrors.aliyun.com/pypi/simple/',
    'https://mirrors.huaweicloud.com/repository/pypi/simple/',
    'https://mirrors.cloud.tencent.com/pypi/simple/',
    'https://pypi.tuna.tsinghua.edu.cn/simple/',
  ];

  /// 项目名 / 导入名 / 平台标签 / 是否必需
  static const _wheels = <_WheelSpec>[
    _WheelSpec('requests', 'requests', ['py3-none-any'], true),
    _WheelSpec('urllib3', 'urllib3', [
      'py3-none-any',
      'py2.py3-none-any',
    ], true),
    _WheelSpec('certifi', 'certifi', ['py3-none-any'], true),
    _WheelSpec('charset_normalizer', 'charset_normalizer', [
      'py3-none-any',
    ], true),
    _WheelSpec('idna', 'idna', ['py3-none-any'], true),
    _WheelSpec('lxml', 'lxml', ['cp311-cp311-win_amd64'], false),
    _WheelSpec('beautifulsoup4', 'bs4', ['py3-none-any'], false),
    _WheelSpec('soupsieve', 'soupsieve', ['py3-none-any'], false),
    _WheelSpec('pycryptodome', 'Crypto', [
      'cp311-cp311-win_amd64',
      'cp35-abi3-win_amd64',
    ], false),
    _WheelSpec('pyquery', 'pyquery', ['py3-none-any'], false),
    _WheelSpec('cssselect', 'cssselect', [
      'py3-none-any',
      'py2.py3-none-any',
    ], false),
    _WheelSpec('chardet', 'chardet', ['py3-none-any'], false),
    _WheelSpec('requests-toolbelt', 'requests_toolbelt', [
      'py3-none-any',
    ], false),
    _WheelSpec('typing_extensions', 'typing_extensions', [
      'py3-none-any',
    ], false),
    // 央視頻等新版蜘蛛用 net.ws() 换 WS 节点。
    _WheelSpec('websocket-client', 'websocket', [
      'py3-none-any',
      'py2.py3-none-any',
    ], false),
    // 央視頻的播放签名 keygen_bg.wasm：必须用 1.x 之前的 execution API，
    // 且 1.0.0 起会额外拖入 numpy，因此锁在无依赖的 0.4.8。
    _WheelSpec(
      'pywasm',
      'pywasm',
      ['py2.py3-none-any', 'py3-none-any'],
      false,
      '0.4.8',
    ),
  ];

  final ValueNotifier<PyRuntimeProgress?> progress = ValueNotifier(null);
  Future<Directory>? _installing;
  Future<void>? _patching;
  Directory? _cachedDir;
  bool? _cachedInstalled;

  /// Android 端的 CPython 由 Chaquopy 内置，不走下载安装。
  static bool get _isAndroid => !kIsWeb && Platform.isAndroid;

  Future<Directory> _dir() async {
    final cached = _cachedDir;
    if (cached != null) return cached;
    final support = await getApplicationSupportDirectory();
    final dir = Directory(
      p.join(support.path, 'python', _isAndroid ? 'android' : version),
    );
    _cachedDir = dir;
    return dir;
  }

  /// 已确认安装后取运行时目录（不触发安装；供每次调用复用）。
  Future<Directory> directory() => _dir();

  /// 是否正在下载 / 安装（源调用据此避免重复弹窗）。
  bool get installing => _installing != null;

  Future<bool> installed() async {
    // Android 的 CPython 由 Chaquopy 随 APK 内置：只要 APK 装好就可用。
    // runner.py 是懒落盘的，不能拿它的存在与否判断运行时是否可用。
    if (_isAndroid) return true;
    final cached = _cachedInstalled;
    if (cached != null) return cached;
    final dir = await _dir();
    final ok =
        File(p.join(dir.path, 'python.exe')).existsSync() &&
        File(p.join(dir.path, 'runner.py')).existsSync() &&
        Directory(p.join(dir.path, 'Lib', 'site-packages', 'requests'))
            .existsSync();
    _cachedInstalled = ok;
    return ok;
  }

  /// runner / 基类资源是否是当前版本（老版本安装的运行时需要原地升级）。
  Future<bool> assetsCurrent() async {
    final dir = await _dir();
    return File(p.join(dir.path, 'base', '.kniephos-assets-v$assetsVersion'))
        .existsSync();
  }

  /// 已安装运行时的原地补齐：重写 runner.py / base/spider.py 并补装新增依赖。
  ///
  /// 只在资源版本变化时执行一次；旧版运行时缺少 `self.net`、`typing_extensions`
  /// 时，这些源会在升级后第一次调用时自动修好，不需要用户重新安装。
  Future<void> ensurePatched() async {
    final dir = await _dir();
    if (_isAndroid) {
      // 没有 python.exe 可补；只需要把随包 runner.py / base/spider.py 落到私有目录，
      // Kotlin 侧会把这个目录加进 sys.path 后 `import runner`。
      if (await assetsCurrent()) return;
      final running = _patching;
      if (running != null) return running;
      final task = _writeRunner(dir);
      _patching = task;
      return task.whenComplete(() => _patching = null);
    }
    if (!File(p.join(dir.path, 'python.exe')).existsSync()) return;
    if (await assetsCurrent()) return;
    await ensureInstalled();
  }

  String? get installPath => _cachedDir?.path;

  /// 安装/补齐运行时；并发调用共享同一个任务。
  Future<Directory> ensureInstalled({bool force = false}) async {
    if (_isAndroid) {
      final dir = await _dir();
      if (force) {
        await _writeRunner(dir);
      } else {
        await ensurePatched();
      }
      return dir;
    }
    if (force) {
      _cachedInstalled = null;
      _installing = null;
    }
    final running = _installing;
    if (running != null) return running;
    final task = _install();
    _installing = task;
    return task.whenComplete(() {
      _installing = null;
    });
  }

  Future<void> remove() async {
    final dir = await _dir();
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {
      // 删除失败（文件被占用）时保留原状，下次启动可重试
    }
    _cachedInstalled = null;
  }

  Future<Directory> _install() async {
    final dir = await _dir();
    final pythonExe = File(p.join(dir.path, 'python.exe'));
    dir.createSync(recursive: true);
    final http = RuntimeFetch.newClient();
    AppLog.i('py', '开始安装 Python 运行时 $version → ${dir.path}');
    try {
      if (!pythonExe.existsSync()) {
        // 随包 Python（<exe>/runtime/python）优先，缺失才下载官方 embeddable 包。
        BundledRuntime.seed('python', dir);
      }
      if (!pythonExe.existsSync()) {
        await _installEmbed(dir, http);
      }
      _setProgress('安装依赖库…', 0.65);
      await _installWheels(dir, http);
      _setProgress('写入运行器…', 0.98);
      await _writeRunner(dir);
      _cachedInstalled = null;
      if (!await installed()) {
        throw StateError('Python 运行时安装不完整（缺少 python.exe / requests）');
      }
      AppLog.i('py', 'Python 运行时安装完成');
      _setProgress('Python 运行时已就绪', 1);
      return dir;
    } catch (e, s) {
      AppLog.e('py', 'Python 运行时安装失败', e, s);
      rethrow;
    } finally {
      http.close(force: true);
      Future<void>.delayed(const Duration(seconds: 4), () {
        progress.value = null;
      });
    }
  }

  Future<void> _installEmbed(Directory dir, HttpClient http) async {
    var lastError = '';
    final urls = await _ranked(_embedUrls, '测速选择最快的 Python 下载线路…', 0);
    for (final url in urls) {
      final tmp = File(
        p.join(
          dir.parent.path,
          'python-embed-${DateTime.now().millisecondsSinceEpoch}.zip',
        ),
      );
      try {
        _setProgress('下载 Python 运行时（约 11 MB）…', 0);
        await _download(
          http,
          url,
          tmp,
          (v) => _setProgress('下载 Python 运行时（约 11 MB）…', v * 0.55),
          minBytes: 1024 * 1024,
        );
        final size = tmp.lengthSync();
        if (size < 1024 * 1024) throw StateError('下载内容过小（$size 字节）');
        _setProgress('解压 Python 运行时…', 0.58);
        try {
          await extractZipArchive(tmp.path, dir.path);
        } catch (e) {
          throw StateError('解压失败：$e');
        }
        if (!File(p.join(dir.path, 'python.exe')).existsSync()) {
          throw StateError('解压后未找到 python.exe');
        }
        return;
      } catch (e) {
        lastError = '$e';
      } finally {
        try {
          if (tmp.existsSync()) tmp.deleteSync();
        } catch (_) {
          // 临时文件清理失败忽略
        }
      }
    }
    throw StateError('Python 运行时下载失败：$lastError');
  }

  Future<void> _installWheels(Directory dir, HttpClient http) async {
    final sitePackages = Directory(p.join(dir.path, 'Lib', 'site-packages'));
    sitePackages.createSync(recursive: true);
    final marker = File(p.join(sitePackages.path, '.kniephos-libs-v2'));
    if (!marker.existsSync()) {
      // 没有标记视为不完整/来源不明 → 清空重装（自愈旧版本装错 wheel 的目录）
      try {
        if (sitePackages.existsSync()) sitePackages.deleteSync(recursive: true);
      } catch (_) {
        // 删除失败则尽量覆盖安装
      }
      sitePackages.createSync(recursive: true);
    }
    final temp = Directory(p.join(dir.path, '.wheel-tmp'));
    if (temp.existsSync()) temp.deleteSync(recursive: true);
    temp.createSync(recursive: true);
    try {
      final bases = await _rankedBases();
      var index = 0;
      for (final wheel in _wheels) {
        index++;
        if (marker.existsSync() && _wheelInstalled(sitePackages, wheel)) {
          continue;
        }
        // 进度按「这一包的字节」走，下 4 MB 的 lxml 时百分比在动，
        // 用户能看出是在下载而不是卡死。包内 0.3 的区间留给依赖安装。
        final base = 0.65 + 0.3 * (index - 1) / _wheels.length;
        final span = 0.3 / _wheels.length;
        void report(String name, int received, int? total) {
          final ratio = (total != null && total > 0)
              ? (received / total).clamp(0.0, 1.0)
              : 0.0;
          final kb = (received / 1024).toStringAsFixed(0);
          final label = total != null && total > 0
              ? '$kb/${(total / 1024).toStringAsFixed(0)} KB'
              : '$kb KB';
          _setProgress(
            '安装依赖 ${wheel.project}（$index/${_wheels.length} · $label）…',
            base + span * ratio,
          );
        }

        _setProgress('安装依赖 ${wheel.project}（$index/${_wheels.length}）…', base);
        try {
          final url = await _resolveWheel(http, wheel, bases);
          if (url == null) throw StateError('镜像中未找到匹配的 wheel');
          final file = File(p.join(temp.path, '${wheel.project}.whl'));
          AppLog.i('py', '取件 ${wheel.project} → $url');
          await _download(http, url, file, null, onBytes: report);
          try {
            if (wheel.version.isNotEmpty) {
              // 锁定版本时先清掉同名旧版本（例如 pywasm 2.x 的残留文件）。
              final old = Directory(
                p.join(sitePackages.path, wheel.importName),
              );
              if (old.existsSync()) old.deleteSync(recursive: true);
            }
            await extractZipArchive(file.path, sitePackages.path);
            if (wheel.version.isNotEmpty) {
              File(_wheelMarker(sitePackages, wheel))
                  .writeAsStringSync(DateTime.now().toIso8601String());
            }
          } catch (e) {
            throw StateError('解压失败：$e');
          }
        } catch (e) {
          if (wheel.required) rethrow;
          // 可选依赖失败不影响纯 Python 源
          AppLog.w('py', '可选依赖 ${wheel.project} 未安装', e);
        }
      }
      // 标记只在这一轮所有必需依赖都确实落地后写：中途失败（用户关窗口、断网）
      // 不会留下「已装完」的假象，下次进来会继续补装而不是全部跳过。
      final missing = _wheels
          .where((w) => w.required && !_wheelInstalled(sitePackages, w))
          .map((w) => w.project)
          .toList();
      if (missing.isNotEmpty) {
        throw StateError('必需依赖缺失：${missing.join(', ')}');
      }
      marker.writeAsStringSync(DateTime.now().toIso8601String());
      AppLog.i('py', '依赖库安装完成（${_wheels.length} 个）');
    } finally {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      } catch (_) {
        // ignore
      }
    }
  }

  /// 判断某个 wheel 是否已装好。
  ///
  /// 锁版本的包必须「标记文件 + 实际内容」都在才算装上：只认标记会让解压到一半
  /// 被中断的目录看起来是完整的，之后每次启动都跳过它，蜘蛛一 import 就崩。
  /// 同理，标记文件本身也不能当作「整批装完」的证据——见 _installWheels 末尾。
  bool _wheelInstalled(Directory sitePackages, _WheelSpec wheel) {
    final base = p.join(sitePackages.path, wheel.importName);
    final present =
        Directory(base).existsSync() || File('$base.py').existsSync();
    if (!present) return false;
    if (wheel.version.isEmpty) return true;
    return File(_wheelMarker(sitePackages, wheel)).existsSync();
  }

  String _wheelMarker(Directory sitePackages, _WheelSpec wheel) => p.join(
    sitePackages.path,
    '.kniephos-wheel-${wheel.project}-${wheel.version}',
  );

  Future<String?> _resolveWheel(
    HttpClient http,
    _WheelSpec wheel,
    List<String> bases,
  ) async {
    for (final base in bases) {
      final uri = Uri.parse('$base${wheel.project}/');
      // 带超时取索引页：镜像排队时不能让整个安装在第一步就无限期挂着。
      final html = await RuntimeFetch.text(
        http,
        uri,
        tag: 'py',
        userAgent: 'kniephos/0.1',
      );
      if (html == null) continue;
      try {
        final hrefs = RegExp(r'href="([^"]+\.whl[^"]*)"')
            .allMatches(html)
            .map((m) => m.group(1)!.replaceAll('&amp;', '&'))
            .toList();
        for (final tag in wheel.tags) {
          final candidates = <String>[];
          for (final href in hrefs) {
            if (!href.contains(tag)) continue;
            if (href.contains('macosx') ||
                href.contains('manylinux') ||
                href.contains('musllinux')) {
              continue;
            }
            if (wheel.version.isNotEmpty &&
                _wheelVersion(href) != wheel.version) {
              continue;
            }
            candidates.add(href);
          }
          if (candidates.isEmpty) continue;
          candidates.sort(
            (a, b) => _compareVersion(_wheelVersion(a), _wheelVersion(b)),
          );
          final stable = candidates
              .where((h) => !_isPrerelease(_wheelVersion(h)))
              .toList();
          final pick = (stable.isNotEmpty ? stable : candidates).last;
          return uri.resolve(pick).toString();
        }
        AppLog.w(
          'py',
          '${wheel.project}：索引里没有匹配 ${wheel.tags.join(" / ")} 的 wheel',
        );
      } catch (e) {
        AppLog.w('py', '${wheel.project}：解析索引失败 $base', e);
      }
    }
    return null;
  }

  /// wheel 文件名第二段就是版本号（`requests-2.32.3-py3-none-any.whl`）。
  String _wheelVersion(String href) {
    final file = href.split('/').last.split('#').first;
    final parts = file.split('-');
    return parts.length > 1 ? parts[1] : '0';
  }

  bool _isPrerelease(String version) {
    final v = version.toLowerCase();
    return RegExp(r'(^|[0-9])(a|b|rc|dev)[0-9]').hasMatch(v);
  }

  int _compareVersion(String a, String b) {
    final pa = a.split('.');
    final pb = b.split('.');
    final n = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < n; i++) {
      final x = i < pa.length ? _leadingInt(pa[i]) : 0;
      final y = i < pb.length ? _leadingInt(pb[i]) : 0;
      if (x != y) return x.compareTo(y);
    }
    return a.compareTo(b);
  }

  int _leadingInt(String part) {
    final m = RegExp(r'^\d+').firstMatch(part);
    return m == null ? 0 : int.tryParse(m.group(0)!) ?? 0;
  }

  Future<void> _writeRunner(Directory dir) async {
    dir.createSync(recursive: true);
    final runner = await rootBundle.loadString(
      'assets/python_runner/runner.py',
    );
    final spider = await rootBundle.loadString(
      'assets/python_runner/base/spider.py',
    );
    File(p.join(dir.path, 'runner.py')).writeAsStringSync(runner);
    final base = Directory(p.join(dir.path, 'base'));
    base.createSync(recursive: true);
    File(p.join(base.path, 'spider.py')).writeAsStringSync(spider);
    File(p.join(base.path, '__init__.py')).writeAsStringSync('');
    File(p.join(base.path, '.kniephos-assets-v$assetsVersion'))
        .writeAsStringSync(DateTime.now().toIso8601String());
  }

  /// 下载前并发测速：返回可用线路（快 → 慢）；全不通则保留原顺序逐个试。
  Future<List<String>> _ranked(
    List<String> urls,
    String message,
    double progress,
  ) async {
    _setProgress(message, progress);
    final ranked = await rankMirrors(urls);
    return ranked.isEmpty ? urls : ranked;
  }

  /// PyPI 镜像测速一次，所有 wheel 都按「快 → 慢」顺序查。
  Future<List<String>> _rankedBases() async {
    _setProgress('测速选择最快的 PyPI 镜像…', 0.64);
    final rel = '${_wheels.first.project}/';
    final ranked = await rankMirrors(
      _simpleBases.map((base) => '$base$rel').toList(),
    );
    if (ranked.isEmpty) return _simpleBases;
    return ranked
        .map((url) => url.substring(0, url.length - rel.length))
        .toList();
  }

  /// 下载单个文件。
  ///
  /// 超时、重试、日志都在 [RuntimeFetch] 里统一处理——这里只做进度换算。
  /// [onBytes] 给需要按字节显示百分比的调用方（wheel 列表用），
  /// [onProgress] 给只要 0~1 的调用方（embed 包用）。
  Future<void> _download(
    HttpClient http,
    String url,
    File target,
    ValueChanged<double>? onProgress, {
    int minBytes = 1,
    void Function(String url, int received, int? total)? onBytes,
  }) async {
    await RuntimeFetch.file(
      http,
      Uri.parse(url),
      target,
      tag: 'py',
      userAgent: 'kniephos/0.1',
      minBytes: minBytes,
      onProgress: (received, total) {
        if (onProgress != null && total != null && total > 0) {
          onProgress((received / total).clamp(0, 1));
        }
        onBytes?.call(url, received, total);
      },
    );
  }

  void _setProgress(String message, double value) {
    progress.value = PyRuntimeProgress(message, value: value.clamp(0, 1));
  }
}

class _WheelSpec {
  const _WheelSpec(
    this.project,
    this.importName,
    this.tags,
    this.required, [
    this.version = '',
  ]);
  final String project;
  final String importName;
  final List<String> tags;
  final bool required;

  /// 锁定版本（空 = 取镜像里最新稳定版）。
  final String version;
}
