import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../bundled_runtime.dart';

import 'package:path_provider/path_provider.dart';

import '../../core/logging/app_log.dart';
import '../../core/net/download_mirrors.dart';
import '../../core/net/runtime_fetch.dart';
import 'jvm_runtime.dart';

/// 加固壳（Guard / DexNative）支持：ARM 原生桥运行期。
///
/// 只用于**首次解包**：unidbg 在 Windows x64 上执行 jar 内的 AArch64 / ARM32 `.so`，
/// 把壳里加密的 payload 解密成普通 jar 并缓存；之后所有调用改走 shell-shim
/// 纯 Java 快路径，不再启动模拟器。
///
/// 运行期 = unidbg 0.9.9 + ASM 等 18 个 Maven 包（约 39 MB），按需下载。
class ArmBridgeRuntime {
  ArmBridgeRuntime._();
  static final instance = ArmBridgeRuntime._();

  static const version = 'unidbg-0.9.9';

  /// 依赖树依据 unidbg 0.9.9 的 POM 实拉核对（含 dynarmic JIT 后端）。
  static const _jarPaths = <String>[
    'com/github/zhkl0228/unidbg-android/0.9.9/unidbg-android-0.9.9.jar',
    'com/github/zhkl0228/unidbg-api/0.9.9/unidbg-api-0.9.9.jar',
    'com/github/zhkl0228/unidbg-unicorn2/0.9.9/unidbg-unicorn2-0.9.9.jar',
    'com/github/zhkl0228/unidbg-dynarmic/0.9.9/unidbg-dynarmic-0.9.9.jar',
    'com/github/zhkl0228/unicorn/1.0.15/unicorn-1.0.15.jar',
    'com/github/zhkl0228/capstone/3.1.8/capstone-3.1.8.jar',
    'com/github/zhkl0228/keystone/0.9.7/keystone-0.9.7.jar',
    'com/github/zhkl0228/demumble/1.0.4/demumble-1.0.4.jar',
    'commons-codec/commons-codec/1.21.0/commons-codec-1.21.0.jar',
    'org/apache/commons/commons-collections4/4.5.0/commons-collections4-4.5.0.jar',
    'commons-io/commons-io/2.21.0/commons-io-2.21.0.jar',
    'com/alibaba/fastjson/1.2.83/fastjson-1.2.83.jar',
    'net/dongliu/apk-parser/2.6.10/apk-parser-2.6.10.jar',
    'net/java/dev/jna/jna/5.10.0/jna-5.10.0.jar',
    'org/scijava/native-lib-loader/2.3.5/native-lib-loader-2.3.5.jar',
    'org/slf4j/slf4j-api/2.0.16/slf4j-api-2.0.16.jar',
    'org/slf4j/slf4j-simple/2.0.16/slf4j-simple-2.0.16.jar',
    'org/ow2/asm/asm/9.7/asm-9.7.jar',
  ];

  static const _mavenBases = <String>[
    'https://maven.aliyun.com/repository/public/',
    'https://mirrors.huaweicloud.com/repository/maven/',
    'https://mirrors.cloud.tencent.com/nexus/repository/maven-public/',
    'https://repo1.maven.org/maven2/',
  ];

  final ValueNotifier<JvmProgress?> progress = ValueNotifier(null);
  Future<Directory>? _installing;
  Directory? _cachedDir;
  bool? _cachedInstalled;

  Future<Directory> _dir() async {
    final cached = _cachedDir;
    if (cached != null) return cached;
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'jvm', 'native', version));
    _cachedDir = dir;
    return dir;
  }

  /// 是否正在下载 / 安装（源调用据此避免重复弹窗）。
  bool get installing => _installing != null;

  Future<bool> installed() async {
    final cached = _cachedInstalled;
    if (cached != null) return cached;
    final dir = await _dir();
    final ok =
        dir.existsSync() &&
        _jarPaths.every((rel) {
          final f = File(p.join(dir.path, rel.split('/').last));
          return f.existsSync() && f.lengthSync() > 1024;
        });
    _cachedInstalled = ok;
    return ok;
  }

  /// 已就绪时返回全部 jar 路径（按名字排序，classpath 用）。
  Future<List<String>> jarPaths() async {
    final dir = await _dir();
    if (!dir.existsSync()) return const [];
    final files =
        dir
            .listSync()
            .whereType<File>()
            .where(
              (f) =>
                  f.path.toLowerCase().endsWith('.jar') &&
                  f.lengthSync() > 1024,
            )
            .map((f) => f.path)
            .toList()
          ..sort();
    return files;
  }

  Future<Directory> ensureInstalled() {
    final running = _installing;
    if (running != null) return running;
    final task = _install();
    _installing = task;
    return task.whenComplete(() => _installing = null);
  }

  Future<void> remove() async {
    final dir = await _dir();
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {
      // 被占用时保留，下次删除可重试
    }
    _cachedInstalled = null;
  }

  Future<Directory> _install() async {
    if (!Platform.isWindows) {
      throw StateError('加固壳支持目前仅支持 Windows');
    }
    // 桥本体随 JVM 运行时安装写入 shims；没有它 ARM 运行期没有意义。
    await JvmRuntime.instance.ensureInstalled();
    await JvmRuntime.instance.ensureBridgeJar();
    final dir = await _dir();
    dir.createSync(recursive: true);
    final http = RuntimeFetch.newClient();
    AppLog.i('arm-bridge', '开始安装加固壳运行时 → ${dir.path}');
    try {
      // 随包 unidbg（<exe>/runtime/unidbg）优先；下面的循环本来就会跳过已存在的 jar。
      BundledRuntime.seed('unidbg', dir);
      final bases = await _rankedBases();
      var done = 0;
      for (final rel in _jarPaths) {
        done++;
        final name = rel.split('/').last;
        final file = File(p.join(dir.path, name));
        if (file.existsSync() && file.lengthSync() > 1024) continue;
        _setProgress(
          '下载加固壳运行时 $done/${_jarPaths.length}（$name）…',
          (done - 1) / _jarPaths.length,
        );
        var lastError = '';
        var ok = false;
        for (final base in bases) {
          try {
            await _download(http, '$base$rel', file);
            if (file.lengthSync() < 1024) throw StateError('文件过小');
            ok = true;
            break;
          } catch (e) {
            lastError = '$e';
            AppLog.w('arm-bridge', '$name 线路失败，换下一个镜像', e);
          }
        }
        if (!ok) throw StateError('$name 下载失败：$lastError');
      }
      _cachedInstalled = null;
      if (!await installed()) throw StateError('加固壳运行时安装不完整');
      AppLog.i('arm-bridge', '加固壳运行时安装完成');
      _setProgress('加固壳支持已就绪', 1);
      return dir;
    } catch (e, s) {
      AppLog.e('arm-bridge', '加固壳运行时安装失败', e, s);
      rethrow;
    } finally {
      http.close(force: true);
      Future<void>.delayed(const Duration(seconds: 4), () {
        progress.value = null;
      });
    }
  }

  /// Maven 镜像测速一次，18 个 jar 都按「快 → 慢」顺序回退。
  Future<List<String>> _rankedBases() async {
    _setProgress('测速选择最快的加固壳下载线路…', 0);
    final rel = _jarPaths.first;
    final ranked = await rankMirrors(
      _mavenBases.map((base) => '$base$rel').toList(),
    );
    if (ranked.isEmpty) return _mavenBases;
    return ranked
        .map((url) => url.substring(0, url.length - rel.length))
        .toList();
  }

  Future<void> _download(HttpClient http, String url, File target) async {
    await RuntimeFetch.file(
      http,
      Uri.parse(url),
      target,
      tag: 'arm-bridge',
      userAgent: 'MisaTV/0.1',
      minBytes: 1024,
    );
  }

  void _setProgress(String message, double value) {
    progress.value = JvmProgress(message, value: value.clamp(0, 1));
  }
}
