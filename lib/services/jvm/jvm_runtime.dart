import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/net/download_mirrors.dart';
import '../../core/platform/archive_extract.dart';

/// JVM 运行时安装进度。
class JvmProgress {
  const JvmProgress(this.message, {this.value});
  final String message;
  final double? value;
}

/// 按需安装的 JVM 运行时（JAR / DEX 蜘蛛源依赖）。
///
/// 只从公开镜像分件取件，应用不内置大文件：
///   · JRE 17（Adoptium，清华镜像，华为云兜底）
///   · dex2jar 2.4（GitHub Release，走加速站）
///   · okhttp / okio / gson / jsoup / json / slf4j / bcprov / sqlite-jdbc（Maven 阿里云）
/// Android 兼容层（stubs / shims，约 300 KB）随应用内置。
///
/// JRE 必须是 17：内置 stubs 与 SpiderRunner 的 class 文件版本为 61（Java 17）。
class JvmRuntime {
  JvmRuntime._();
  static final instance = JvmRuntime._();

  static const version = '17.0.20.1';

  /// JAR / DEX 蜘蛛运行时是否就绪。
  ///
  /// 安卓端不需要下载 JVM 运行时：`jar_spider_android.dart` +
  /// `SpiderHostPlugin.kt` 用 ART / DexClassLoader 直接加载 DEX，原生等价于
  /// 桌面端的「JRE 17 + dex2jar」。只有桌面端才要求 JRE + dex2jar 已安装。
  static Future<bool> jarSpiderReady() async {
    if (Platform.isAndroid) return true;
    return instance.installed();
  }

  /// JRE 压缩包；解压后取「含 bin/java.exe」的那层目录。
  /// 多个镜像 + GitHub 加速代理，下载前并发测速取最快（国内直连 GitHub 常超时）。
  static const _jreUrls = <String>[
    'https://mirrors.huaweicloud.com/openjdk/17.0.2/openjdk-17.0.2_windows-x64_bin.zip',
    'https://mirrors.tuna.tsinghua.edu.cn/Adoptium/17/jre/x64/windows/'
        'OpenJDK17U-jre_x64_windows_hotspot_17.0.20.1_1.zip',
    'https://ghfast.top/https://github.com/adoptium/temurin17-binaries/releases/download/'
        'jdk-17.0.20.1%2B1/OpenJDK17U-jre_x64_windows_hotspot_17.0.20.1_1.zip',
    'https://gh-proxy.com/https://github.com/adoptium/temurin17-binaries/releases/download/'
        'jdk-17.0.20.1%2B1/OpenJDK17U-jre_x64_windows_hotspot_17.0.20.1_1.zip',
    'https://github.com/adoptium/temurin17-binaries/releases/download/'
        'jdk-17.0.20.1%2B1/OpenJDK17U-jre_x64_windows_hotspot_17.0.20.1_1.zip',
  ];

  /// dex2jar 整合包；解压后取 lib 目录下的 jar。
  static const _dexToolsUrls = <String>[
    'https://ghfast.top/https://github.com/pxb1988/dex2jar/releases/download/v2.4/dex-tools-v2.4.zip',
    'https://gh-proxy.com/https://github.com/pxb1988/dex2jar/releases/download/v2.4/dex-tools-v2.4.zip',
    'https://github.com/pxb1988/dex2jar/releases/download/v2.4/dex-tools-v2.4.zip',
    'https://ghproxy.net/https://github.com/pxb1988/dex2jar/releases/download/v2.4/dex-tools-v2.4.zip',
  ];

  /// Maven 相对路径（阿里云镜像优先，回退 Maven Central）。
  static const _libPaths = <String>[
    'com/squareup/okhttp3/okhttp/3.14.9/okhttp-3.14.9.jar',
    'com/squareup/okio/okio/1.17.5/okio-1.17.5.jar',
    'com/google/code/gson/gson/2.10.1/gson-2.10.1.jar',
    'org/jsoup/jsoup/1.17.2/jsoup-1.17.2.jar',
    'org/json/json/20180813/json-20180813.jar',
    'org/slf4j/slf4j-api/2.0.16/slf4j-api-2.0.16.jar',
    'org/slf4j/slf4j-simple/2.0.16/slf4j-simple-2.0.16.jar',
    'org/bouncycastle/bcprov-jdk18on/1.78.1/bcprov-jdk18on-1.78.1.jar',
    'org/xerial/sqlite-jdbc/3.46.1.0/sqlite-jdbc-3.46.1.0.jar',
  ];

  static const _mavenBases = <String>[
    'https://maven.aliyun.com/repository/public/',
    'https://mirrors.huaweicloud.com/repository/maven/',
    'https://mirrors.cloud.tencent.com/nexus/repository/maven-public/',
    'https://repo1.maven.org/maven2/',
  ];

  /// 随应用内置的兼容层：asset 路径 → 安装目录内的相对路径。
  static const _bundled = <String, String>{
    'assets/jvm/stubs.jar': 'shims/stubs.jar',
    'assets/jvm/shell-shim.jar': 'shims/shell-shim.jar',
    // 嗷呜系壳（AowuShinidie）的 MyCrypto 纯 Java 影子类：只在该壳的类路径上，
    // 别的壳（wex/fty）有各自不同签名的 MyCrypto，不能全局覆盖。
    'assets/jvm/aowu-shim.jar': 'shims/aowu-shim.jar',
    'assets/jvm/prefs-shim.jar': 'shims/prefs-shim.jar',
    'assets/jvm/okhttp4-compat.jar': 'shims/okhttp4-compat.jar',
    'assets/jvm/native-bridge.jar': 'shims/native-bridge.jar',
    'assets/jvm/spider-host.jar': 'shims/spider-host.jar',
    // 宿主代理兜底：载荷只有 ProxyOrigin、没有 spider.Proxy 时（wex / fty 海绵等），
    // 由宿主按需前置到 tvbox.shellShimClasses，把 /proxy 转发给 ProxyOrigin。
    'assets/jvm/proxy-bridge.jar': 'shims/proxy-bridge.jar',
    // 桌面版 GoProxy 影子类：加固壳的 ARM Go 取流 .so 在 unidbg 里被跳过，
    // 但壳初始化会等它的 /health。这个 jar 用纯 Java 同端口应答，数据请求本身走 okhttp。
    'assets/jvm/go-proxy-shim.jar': 'shims/go-proxy-shim.jar',
    // 加固壳的「真实实现」预解包产物（对齐 winbox 的 shell-shim/real/<壳名>.jar）：
    // 拿到对应壳时直接纯 Java 运行，不再依赖 unidbg 模拟器（实测 ftyshinidie 壳
    // 在 x64 上模拟会崩在 toIntPeer(null)）。
    'assets/jvm/shell-real/ftyshinidie.jar': 'shell-shim/real/ftyshinidie.jar',
    'assets/jvm/shell-real/foni-spider.jar': 'shell-shim/real/foni-spider.jar',
  };

  final ValueNotifier<JvmProgress?> progress = ValueNotifier(null);
  Future<Directory>? _installing;
  Directory? _cachedDir;
  bool? _cachedInstalled;

  Future<Directory> _dir() async {
    final cached = _cachedDir;
    if (cached != null) return cached;
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'jvm', version));
    _cachedDir = dir;
    return dir;
  }

  /// 已安装时取运行时目录（不触发安装）。
  Future<Directory> directory() => _dir();

  /// 是否正在下载 / 安装（源调用据此避免重复弹窗）。
  bool get installing => _installing != null;

  Future<bool> installed() async {
    final cached = _cachedInstalled;
    if (cached != null) return cached;
    final dir = await _dir();
    final ok =
        File(p.join(dir.path, 'jre', 'bin', 'java.exe')).existsSync() &&
        Directory(p.join(dir.path, 'd2j')).existsSync() &&
        Directory(p.join(dir.path, 'libs')).existsSync() &&
        Directory(p.join(dir.path, 'shims')).existsSync();
    _cachedInstalled = ok;
    return ok;
  }

  String? get installPath => _cachedDir?.path;

  /// java.exe 路径（未安装时为空串）。
  Future<String> javaExecutable() async {
    final dir = await _dir();
    final exe = File(p.join(dir.path, 'jre', 'bin', 'java.exe'));
    return exe.existsSync() ? exe.path : '';
  }

  /// 确保内置的 native-bridge.jar 已写入 shims（旧安装目录可能缺少）。
  Future<File> ensureBridgeJar() =>
      _ensureBundled('assets/jvm/native-bridge.jar', 'shims/native-bridge.jar');

  /// 内置兼容层版本号：改了 assets/jvm 里的 jar（stubs / shell-shim / SpiderHost…）就 +1。
  /// 已安装目录只有在版本号变化时才整体刷新，避免每次启动都读一遍 5MB 资产。
  static const _shimsRev = 11;

  /// 老安装目录升级：把随包内置的兼容层刷新到当前版本（运行中的 JVM 占用时下次再试）。
  Future<void> ensureShims() async {
    final dir = await _dir();
    final shims = Directory(p.join(dir.path, 'shims'));
    final marker = File(p.join(shims.path, '.bundled-rev'));
    if (marker.existsSync()) {
      try {
        if (marker.readAsStringSync().trim() == '$_shimsRev') return;
      } catch (_) {}
    }
    var ok = true;
    for (final entry in _bundled.entries) {
      try {
        final file = await _ensureBundled(entry.key, entry.value);
        if (!file.existsSync()) ok = false;
      } catch (_) {
        ok = false;
      }
    }
    if (!ok) return;
    try {
      shims.createSync(recursive: true);
      marker.writeAsStringSync('$_shimsRev', flush: true);
    } catch (_) {
      // 被占用 → 下次启动再补标记。
    }
  }

  Future<File> _ensureBundled(String asset, String relative) async {
    final dir = await _dir();
    final file = File(p.join(dir.path, relative));
    final data = await rootBundle.load(asset);
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    // 内置 jar 会随应用升级（如 SpiderHost 的类加载器修复）：只看「文件存在」会
    // 让老安装目录永远停在旧版本。大小不同即视为新版本并覆盖。
    if (!file.existsSync() || file.lengthSync() != bytes.length) {
      try {
        file.parent.createSync(recursive: true);
        final tmp = File('${file.path}.tmp');
        tmp.writeAsBytesSync(bytes, flush: true);
        tmp.renameSync(file.path);
      } catch (_) {
        // 被运行中的 JVM 占用 → 下次启动再替换。
      }
    }
    return file;
  }

  /// 安装/补齐运行时；并发调用共享同一个任务。
  Future<Directory> ensureInstalled({bool force = false}) {
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
    if (!Platform.isWindows) {
      throw StateError('JVM 运行时目前仅支持 Windows');
    }
    final dir = await _dir();
    dir.createSync(recursive: true);
    final http = HttpClient();
    http.connectionTimeout = const Duration(seconds: 20);
    try {
      if (!File(p.join(dir.path, 'jre', 'bin', 'java.exe')).existsSync()) {
        await _installJre(dir, http);
      }
      if (!File(p.join(dir.path, 'd2j', 'dex-tools-v2.4.jar')).existsSync()) {
        await _installDexTools(dir, http);
      }
      await _installLibs(dir, http);
      _setProgress('写入兼容层…', 0.98);
      await _writeBundled(dir);
      _cachedInstalled = null;
      if (!await installed()) {
        throw StateError('JVM 运行时安装不完整（缺少 jre 或 dex2jar）');
      }
      _removeOldVersions(dir);
      _setProgress('JVM 运行时已就绪', 1);
      return dir;
    } finally {
      http.close(force: true);
      Future<void>.delayed(const Duration(seconds: 4), () {
        progress.value = null;
      });
    }
  }

  /// 删除旧版本运行时目录（例如已不再使用的 JRE 11）。
  void _removeOldVersions(Directory current) {
    try {
      for (final entity in current.parent.listSync()) {
        if (entity is Directory && p.basename(entity.path) != version) {
          entity.deleteSync(recursive: true);
        }
      }
    } catch (_) {
      // 旧目录被占用时忽略
    }
  }

  Future<void> _installJre(Directory dir, HttpClient http) async {
    var lastError = '';
    final urls = await _ranked(_jreUrls, '测速选择最快的 JRE 下载线路…', 0);
    for (final url in urls) {
      final tmp = File(
        p.join(dir.path, 'jre-${DateTime.now().millisecondsSinceEpoch}.zip'),
      );
      try {
        _setProgress('下载 JRE 17（约 42 MB）…', 0);
        await _download(
          http,
          url,
          tmp,
          (v) => _setProgress('下载 JRE 17（约 42 MB）…', v * 0.45),
        );
        final size = tmp.lengthSync();
        if (size < 1024 * 1024) throw StateError('下载内容过小（$size 字节）');
        _setProgress('解压 JRE…', 0.47);
        final stage = Directory(p.join(dir.path, '.jre-stage'));
        if (stage.existsSync()) stage.deleteSync(recursive: true);
        stage.createSync(recursive: true);
        try {
          await extractZipArchive(tmp.path, stage.path);
        } catch (e) {
          throw StateError('解压失败：$e');
        }
        final jreRoot = _findJavaRoot(stage);
        if (jreRoot == null) throw StateError('解压后未找到 java.exe');
        final target = Directory(p.join(dir.path, 'jre'));
        if (target.existsSync()) target.deleteSync(recursive: true);
        jreRoot.renameSync(target.path);
        stage.deleteSync(recursive: true);
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
    throw StateError('JRE 下载失败：$lastError');
  }

  Future<void> _installDexTools(Directory dir, HttpClient http) async {
    var lastError = '';
    final urls = await _ranked(_dexToolsUrls, '测速选择最快的 dex2jar 下载线路…', 0.48);
    for (final url in urls) {
      final tmp = File(
        p.join(
          dir.path,
          'dex-tools-${DateTime.now().millisecondsSinceEpoch}.zip',
        ),
      );
      try {
        _setProgress('下载 dex2jar（约 18 MB）…', 0.5);
        await _download(
          http,
          url,
          tmp,
          (v) => _setProgress('下载 dex2jar（约 18 MB）…', 0.5 + v * 0.2),
        );
        final size = tmp.lengthSync();
        if (size < 1024 * 1024) throw StateError('下载内容过小（$size 字节）');
        _setProgress('解压 dex2jar…', 0.72);
        final stage = Directory(p.join(dir.path, '.d2j-stage'));
        if (stage.existsSync()) stage.deleteSync(recursive: true);
        stage.createSync(recursive: true);
        try {
          await extractZipArchive(tmp.path, stage.path);
        } catch (e) {
          throw StateError('解压失败：$e');
        }
        final target = Directory(p.join(dir.path, 'd2j'));
        if (target.existsSync()) target.deleteSync(recursive: true);
        target.createSync(recursive: true);
        var copied = 0;
        for (final entity in stage.listSync(recursive: true)) {
          if (entity is File && entity.path.toLowerCase().endsWith('.jar')) {
            entity.copySync(p.join(target.path, p.basename(entity.path)));
            copied++;
          }
        }
        stage.deleteSync(recursive: true);
        if (copied < 10) throw StateError('dex2jar 包内只找到 $copied 个 jar');
        return;
      } catch (e) {
        lastError = '$e';
      } finally {
        try {
          if (tmp.existsSync()) tmp.deleteSync();
        } catch (_) {
          // ignore
        }
      }
    }
    throw StateError('dex2jar 下载失败：$lastError');
  }

  Future<void> _installLibs(Directory dir, HttpClient http) async {
    final target = Directory(p.join(dir.path, 'libs'));
    target.createSync(recursive: true);
    // Maven 镜像测速一次，后面 9 个依赖都按「快 → 慢」顺序回退。
    final bases = await _rankedBases(_libPaths.first, '测速选择最快的依赖库镜像…', 0.73);
    var index = 0;
    for (final rel in _libPaths) {
      index++;
      final name = rel.split('/').last;
      final file = File(p.join(target.path, name));
      if (file.existsSync() && file.lengthSync() > 1024) continue;
      _setProgress(
        '下载依赖库 $index/${_libPaths.length}（$name）…',
        0.74 + 0.22 * index / _libPaths.length,
      );
      var lastError = '';
      var ok = false;
      for (final base in bases) {
        try {
          await _download(http, '$base$rel', file, null);
          if (file.lengthSync() < 1024) throw StateError('文件过小');
          ok = true;
          break;
        } catch (e) {
          lastError = '$e';
        }
      }
      if (!ok) throw StateError('依赖库 $name 下载失败：$lastError');
    }
  }

  Future<void> _writeBundled(Directory dir) async {
    for (final entry in _bundled.entries) {
      final data = await rootBundle.load(entry.key);
      final file = File(p.join(dir.path, entry.value));
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(data.buffer.asUint8List(), flush: true);
    }
    File(p.join(dir.path, 'marker.json')).writeAsStringSync(
      jsonEncode({
        'version': version,
        'installedAt': DateTime.now().millisecondsSinceEpoch,
      }),
    );
  }

  Directory? _findJavaRoot(Directory stage) {
    final direct = File(p.join(stage.path, 'bin', 'java.exe'));
    if (direct.existsSync()) return stage;
    for (final entity in stage.listSync()) {
      if (entity is Directory) {
        if (File(p.join(entity.path, 'bin', 'java.exe')).existsSync()) {
          return entity;
        }
        for (final inner in entity.listSync()) {
          if (inner is Directory &&
              File(p.join(inner.path, 'bin', 'java.exe')).existsSync()) {
            return inner;
          }
        }
      }
    }
    return null;
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

  /// 把 Maven 基地址按「同一相对路径的实测速度」排序，供逐库下载回退。
  Future<List<String>> _rankedBases(
    String rel,
    String message,
    double progress,
  ) async {
    _setProgress(message, progress);
    final ranked = await rankMirrors(
      _mavenBases.map((base) => '$base$rel').toList(),
    );
    if (ranked.isEmpty) return _mavenBases;
    return ranked
        .map((url) => url.substring(0, url.length - rel.length))
        .toList();
  }

  Future<void> _download(
    HttpClient http,
    String url,
    File target,
    ValueChanged<double>? onProgress,
  ) async {
    final req = await http.getUrl(Uri.parse(url));
    req.headers.set('User-Agent', 'MisaTV/0.1');
    final res = await req.close();
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw StateError('HTTP ${res.statusCode}：$url');
    }
    final total = res.contentLength;
    target.parent.createSync(recursive: true);
    final sink = target.openWrite();
    var received = 0;
    try {
      await for (final chunk in res) {
        sink.add(chunk);
        received += chunk.length;
        if (onProgress != null && total > 0) {
          onProgress((received / total).clamp(0, 1));
        }
      }
    } finally {
      await sink.close();
    }
  }

  void _setProgress(String message, double value) {
    progress.value = JvmProgress(message, value: value.clamp(0, 1));
  }
}
