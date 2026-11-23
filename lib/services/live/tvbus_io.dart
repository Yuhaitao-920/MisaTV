import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/logging/app_log.dart';
import '../../core/logging/log_redact.dart';
import '../../models/site_config.dart';
import '../../models/vod.dart';
import '../relay/local_relay.dart';

/// Android 端 TVBus（Go P2P 直播引擎）宿主。
///
/// 与 FongMi/TV 的 TVBus 一致：主程序不内置 Go `.so`，直播源的 `core.so`
/// 指向哪个引擎就下载哪个；`System.load` 后由 Go 引擎返回本地 HLS 地址。
/// 因为每个源提供的 `.so` 不同，这里不做独立 APK，只缓存到应用私有目录。
class TvBusService {
  TvBusService._();
  static final TvBusService instance = TvBusService._();

  static const _channel = MethodChannel('com.kniephos.kniephos/tvbus');

  bool _currentRespSet = false;
  String _currentResp = '';
  Future<void> _tail = Future.value();

  bool get supported => !kIsWeb && Platform.isAndroid;

  /// 串行化：同一时间只允许一次引擎启动（切换线路时避免并发 System.load）。
  Future<T> _serialized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, s) {
        completer.completeError(e, s);
      }
    });
    return completer.future;
  }

  Future<String> resolve({
    required String url,
    required TvBusCore core,
    Map<String, String> headers = const {},
    String? baseUrl,
  }) => _serialized(() async {
    if (!supported) {
      throw SourceException('TVBus 仅支持 Android');
    }
    if (!core.hasEngine) {
      throw SourceException('该直播源没有配置 TVBus 引擎（core.so）');
    }
    final soPath = await _ensureEngine(core.so, headers, baseUrl: baseUrl);
    final auth = await _prepareAuth(core, headers);
    final playPort = await _freePort();
    final name = await _maybeFetch(core.name, headers);
    final pass = await _maybeFetch(core.pass, headers);
    final domain = await _maybeFetch(core.domain, headers);
    final args = <String, Object?>{
      'soPath': soPath,
      'url': url,
      'auth': auth,
      'name': name,
      'pass': pass,
      'domain': domain,
      'broker': core.broker,
      'pkg': core.pkg,
      'sign': core.sign,
      'options': jsonEncode([
        for (final option in core.options) option.toJson(),
      ]),
      'playPort': playPort,
      'timeoutMs': 30000,
    };
    try {
      final raw = await _channel
          .invokeMethod<String>('resolve', args)
          .timeout(const Duration(seconds: 45));
      final decoded = jsonDecode(raw ?? '{}');
      if (decoded is! Map || decoded['ok'] != true) {
        final error = decoded is Map ? '${decoded['error'] ?? ''}' : '';
        throw SourceException(error.trim().isEmpty ? 'TVBus 引擎启动失败' : error);
      }
      final hls = '${decoded['hls'] ?? ''}'.trim();
      if (hls.isEmpty) {
        throw SourceException('TVBus 没有返回播放地址');
      }
      if (hls.startsWith('-')) {
        throw SourceException('TVBus 引擎返回错误：$hls');
      }
      AppLog.i(
        'live',
        'TVBus 取流成功 url=${redactUrl(url)} hls=${redactUrl(hls)}',
      );
      return hls;
    } on TimeoutException {
      throw SourceException('TVBus 引擎启动超时');
    } on PlatformException catch (e) {
      throw SourceException(e.message ?? 'TVBus 引擎启动失败');
    } on MissingPluginException {
      throw SourceException('TVBus 宿主未注册（请重新安装 APK）');
    }
  });

  Future<void> stop() => _serialized(() async {
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {
      // 引擎已经退出 / 通道已销毁时忽略
    }
    _clearResp();
  });

  Future<void> shutdown() async {
    try {
      await _channel.invokeMethod('shutdown');
    } catch (_) {
      // 应用退出最后阶段忽略
    }
    _clearResp();
  }

  void _clearResp() {
    if (!_currentRespSet) return;
    _currentRespSet = false;
    _currentResp = '';
    LocalRelay.instance.tvbusConfig = null;
  }

  Future<String> _prepareAuth(
    TvBusCore core,
    Map<String, String> headers,
  ) async {
    final resp = core.resp.trim();
    if (resp.isEmpty) {
      _clearResp();
      return core.auth.trim();
    }
    final text = resp.startsWith('http')
        ? await _fetchText(resp, headers)
        : resp;
    _currentResp = text;
    _currentRespSet = true;
    LocalRelay.instance.tvbusConfig = () => _currentResp;
    if (LocalRelay.instance.port <= 0) {
      throw SourceException('本地中继未启动，无法向 TVBus 提供 core.resp');
    }
    return '${LocalRelay.instance.baseUrl}/tvbus';
  }

  Future<String> _ensureEngine(
    String rawUrl,
    Map<String, String> headers, {
    String? baseUrl,
  }) async {
    var url = rawUrl.trim();
    if ((url.startsWith('./') || url.startsWith('/')) &&
        baseUrl != null &&
        baseUrl.startsWith('http')) {
      url = Uri.parse(baseUrl).resolve(url).toString();
    }
    if (url.isEmpty) {
      throw SourceException('TVBus 引擎地址为空');
    }
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'tvbus'));
    dir.createSync(recursive: true);
    final name = '${md5.convert(utf8.encode(url))}.so';
    final file = File(p.join(dir.path, name));
    if (file.existsSync() && file.lengthSync() > 4096) {
      if (await _isArm64Elf(file)) return file.path;
      try {
        file.deleteSync();
      } catch (_) {
        // 删不掉就让下面的下载覆盖
      }
    }

    if (url.startsWith('assets://')) {
      final key = url.substring('assets://'.length);
      final data = await rootBundle.load(
        key.startsWith('assets/') ? key : 'assets/$key',
      );
      await file.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
      if (!await _isArm64Elf(file)) {
        throw SourceException('TVBus 引擎不是 arm64 ELF：$url');
      }
      return file.path;
    }
    if (url.startsWith('file://')) {
      final local = File(Uri.parse(url).toFilePath());
      if (!local.existsSync()) {
        throw SourceException('TVBus 引擎文件不存在：${local.path}');
      }
      if (!await _isArm64Elf(local)) {
        throw SourceException('TVBus 引擎不是 arm64 ELF：${local.path}');
      }
      return local.path;
    }
    if (!url.startsWith('http')) {
      throw SourceException('TVBus 引擎地址不支持：$url');
    }

    final tmp = File('${file.path}.part');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      AppLog.i('live', 'TVBus 引擎下载 ${redactUrl(url)}');
      final req = await client.getUrl(Uri.parse(url));
      _applyHeaders(req, headers);
      req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final res = await req.close().timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        await res.drain<void>();
        throw SourceException('TVBus 引擎下载失败（HTTP ${res.statusCode}）');
      }
      final sink = tmp.openWrite();
      await res.pipe(sink).timeout(const Duration(seconds: 120));
      if (tmp.lengthSync() < 4096) {
        throw SourceException('TVBus 引擎下载内容过小');
      }
      if (!await _isArm64Elf(tmp)) {
        throw SourceException('TVBus 引擎不是 arm64 ELF');
      }
      if (file.existsSync()) file.deleteSync();
      tmp.renameSync(file.path);
      return file.path;
    } finally {
      client.close(force: true);
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (_) {
        // ignore
      }
    }
  }

  /// FongMi 的 Core.getString：`name` / `pass` / `domain` 写成 http 地址时
  /// 先取回正文；普通字面值原样返回。
  Future<String> _maybeFetch(String value, Map<String, String> headers) async {
    final text = value.trim();
    if (!text.startsWith('http')) return text;
    return (await _fetchText(text, headers)).trim();
  }

  Future<String> _fetchText(String url, Map<String, String> headers) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(Uri.parse(url));
      _applyHeaders(req, headers);
      req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final res = await req.close().timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        await res.drain<void>();
        throw SourceException('TVBus core.resp 下载失败（HTTP ${res.statusCode}）');
      }
      final bytes = await res
          .fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk))
          .timeout(const Duration(seconds: 30));
      if (bytes.length > 4 << 20) {
        throw SourceException('TVBus core.resp 内容过大');
      }
      return utf8.decode(bytes, allowMalformed: true);
    } finally {
      client.close(force: true);
    }
  }

  void _applyHeaders(HttpClientRequest req, Map<String, String> headers) {
    for (final entry in headers.entries) {
      try {
        req.headers.set(entry.key, entry.value);
      } catch (_) {
        // Host / Content-Length 这类保留头不让写，忽略
      }
    }
    final hasUa = headers.keys.any(
      (key) => key.toLowerCase() == HttpHeaders.userAgentHeader,
    );
    if (!hasUa) req.headers.set(HttpHeaders.userAgentHeader, 'okhttp/4.12.0');
  }

  Future<bool> _isArm64Elf(File file) async {
    if (file.lengthSync() < 20) return false;
    final raf = await file.open();
    try {
      final bytes = await raf.read(20);
      if (bytes.length < 20) return false;
      final isElf =
          bytes[0] == 0x7f &&
          bytes[1] == 0x45 &&
          bytes[2] == 0x4c &&
          bytes[3] == 0x46;
      final machine = bytes[18] | (bytes[19] << 8);
      return isElf && bytes[4] == 2 && machine == 183; // ELF64 + AArch64
    } finally {
      await raf.close();
    }
  }

  Future<int> _freePort() async {
    for (final port in const [8902, 0]) {
      try {
        final server = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          port,
        );
        final actual = server.port;
        await server.close();
        return actual;
      } catch (_) {
        // 8902 被占用时让系统分配
      }
    }
    throw SourceException('没有可用的 TVBus 播放端口');
  }
}
