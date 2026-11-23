import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/net/url_utils.dart';
import '../../core/utils/file_url.dart';
import '../../models/site_config.dart';
import '../../models/vod.dart';
import '../movie_parser.dart';
import '../play_result_parser.dart';
import '../drive/drive_ext.dart';
import 'js_spider_worker.dart';
import 'js_asset_key.dart';

/// TVBox JS 蜘蛛（type=3，api 以 .js 结尾）的宿主。
///
/// QuickJS 在独立 isolate 中执行；`req()` 由 curl 子进程提供同步语义，
/// 与 TVBox 安卓沙箱保持一致。站点脚本、第三方库与模块依赖都按需缓存。
class JsSpiderService {
  JsSpiderService({this.driveTokens, this.localSeed});

  final Map<String, String> Function()? driveTokens;

  /// 注入 `local` 的种子键（如 UC TV Token 的 `Wex_ucpan_token`）。
  final Map<String, String> Function()? localSeed;

  final Map<String, _CachedScript> _scripts = {};
  final Map<String, String> _libs = {};
  bool _libsLoaded = false;
  Future<void>? _libsLoading;
  final List<_JsWorkerHandle> _workers = [];
  int _workerCount = 1;
  int _requestSeq = 0;

  /// 是否启用多个 JS 执行器。默认 1（和旧版一致），由设置页显式开启。
  void setWorkerCount(int count) {
    final next = count < 1 ? 1 : (count > 3 ? 3 : count);
    if (next == _workerCount) return;
    _workerCount = next;
    _disposeWorkers();
  }

  int _slotIndex(String key) {
    var hash = 0;
    for (final unit in key.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return _workerCount <= 0 ? 0 : hash % _workerCount;
  }

  static const _libNames = <String>[
    'cat.js',
    'cheerio.min.js',
    'crypto-js.js',
    'gbk.js',
    'net.js',
    'similarity.js',
    'utils.js',
    '模板.js',
  ];

  /// 脚本落盘缓存的有效期。过期后回源；回源失败继续用旧缓存。
  static const _scriptCacheTtl = Duration(hours: 6);

  bool get available => true;

  Future<CmsResult> home(SourceBean site) async {
    final text = await _invoke(site, 'home', const [true]);
    _throwIfError(text);
    if (text.trim().isEmpty) return const CmsResult();
    final body = MovieParser.parseJson(text);
    var items = MovieParser.toItems(body.movie, site.key);
    final classes = body.classes;
    if (items.isEmpty) {
      final vodText = await _invoke(site, 'homeVod', const []);
      if (vodText.trim().isNotEmpty) {
        final vodBody = MovieParser.parseJson(vodText);
        final vodItems = MovieParser.toItems(vodBody.movie, site.key);
        if (vodItems.isNotEmpty) {
          items = vodItems;
        }
      }
    }
    if (items.isEmpty && classes.isNotEmpty) {
      try {
        final fallback = await category(site, classes.first.id, '1', const {});
        if (fallback.items.isNotEmpty) {
          return CmsResult(
            classes: classes,
            items: fallback.items,
            page: fallback.page,
            pagecount: fallback.pagecount == 0 ? 1 : fallback.pagecount,
            total: fallback.total == 0 ? fallback.items.length : fallback.total,
            homeFallback: true,
          );
        }
      } catch (_) {
        // 回退失败不影响分类浏览
      }
    }
    return CmsResult(
      classes: classes,
      items: items,
      page: body.movie?.page ?? 0,
      pagecount: body.movie?.pagecount ?? 0,
      total: body.movie?.recordcount ?? 0,
    );
  }

  Future<CmsResult> category(
    SourceBean site,
    String tid,
    String pg,
    Map<String, String> filters,
  ) async {
    final text = await _invoke(site, 'category', [tid, pg, true, filters]);
    _throwIfError(text);
    if (text.trim().isEmpty) return const CmsResult();
    final body = MovieParser.parseJson(text);
    return CmsResult(
      items: MovieParser.toItems(body.movie, site.key),
      page: body.movie?.page ?? 0,
      pagecount: body.movie?.pagecount ?? 0,
      total: body.movie?.recordcount ?? 0,
    );
  }

  Future<VodDetail?> detail(SourceBean site, String id) async {
    final text = await _invoke(site, 'detail', [id]);
    _throwIfError(text);
    if (text.trim().isEmpty) return null;
    final body = MovieParser.parseJson(text);
    return MovieParser.toDetail(body.movie, site.key);
  }

  Future<List<VodItem>> search(SourceBean site, String keyword) async {
    var text = await _invoke(site, 'search', [keyword, true, '1']);
    if (text.trim().isEmpty) {
      text = await _invoke(site, 'search', [keyword, true]);
    }
    _throwIfError(text);
    if (text.trim().isEmpty) return const [];
    final body = MovieParser.parseJson(text);
    return MovieParser.toItems(body.movie, site.key);
  }

  /// 调用蜘蛛的 playerContent / play，返回归一化后的播放信息。
  /// 返回 null 表示蜘蛛没有播放方法（调用方回落到通用地址处理）。
  Future<PlayResult?> play(
    SourceBean site,
    String flag,
    String id, {
    List<String> vipFlags = const [],
  }) async {
    final text = await _invoke(site, 'play', [flag, id, vipFlags]);
    if (text.trim().isEmpty) return null;
    return normalizeSpiderPlay(text, flag);
  }

  /// 调用蜘蛛的 liveContent / live，返回直播订阅原文。
  Future<String> live(SourceBean site, String url) async {
    final text = await _invoke(site, 'live', [url]);
    _throwIfError(text);
    return text;
  }

  void _throwIfError(String text) {
    final t = text.trim();
    if (!t.startsWith('{')) return;
    try {
      final decoded = jsonDecode(t);
      if (decoded is Map && decoded['__error'] != null) {
        throw SourceException('蜘蛛返回错误：${decoded['__error']}');
      }
    } on SourceException {
      rethrow;
    } catch (_) {
      // 非 JSON 文本交给上层解析
    }
  }

  // ---------------------------------------------------------------------------
  // worker 生命周期
  // ---------------------------------------------------------------------------
  Future<_JsWorkerHandle> _ensureWorker(int slot) async {
    while (_workers.length <= slot) {
      _workers.add(_JsWorkerHandle());
    }
    final handle = _workers[slot];
    if (handle.port != null) return handle;
    final running = handle.starting;
    if (running != null) {
      await running;
      if (handle.port == null) throw SourceException('JS 执行器启动失败');
      return handle;
    }

    final completer = Completer<void>();
    handle.starting = completer.future;
    final receive = ReceivePort();
    try {
      await _loadLibs();
      final support = await getApplicationSupportDirectory();
      // 每个执行器使用独立的 local 存储文件，避免多个 isolate 同时写同一份
      // 脚本本地状态；slot 0 沿用旧的 js_local.json，保证默认单执行器升级不丢状态。
      final storage = p.join(
        support.path,
        slot == 0 ? 'js_local.json' : 'js_local_w$slot.json',
      );
      final ready = Completer<SendPort>();
      receive.listen((msg) {
        if (msg is Map && msg['op'] == 'ready') {
          if (!ready.isCompleted) ready.complete(msg['port'] as SendPort);
          return;
        }
        if (msg is List && msg.length >= 2) {
          if (!ready.isCompleted) {
            ready.completeError(StateError('JS 执行器启动失败：${msg[0]}'));
          }
        }
      });
      handle.isolate = await Isolate.spawn(
        jsSpiderWorkerMain,
        {'ready': receive.sendPort, 'libs': _libs, 'storage': storage},
        onError: receive.sendPort,
        onExit: receive.sendPort,
        errorsAreFatal: false,
      );
      handle.port = await ready.future.timeout(const Duration(seconds: 20));
      // 启动期间用户切换了执行器数量：这只进程已经不在 _workers 里，
      // 关闭它并让调用方重试，避免留下孤儿 isolate。
      if (_workers.length <= slot || _workers[slot] != handle) {
        final isolate = handle.isolate;
        handle.isolate = null;
        handle.port = null;
        _stopIsolate(isolate);
        throw SourceException('JS 执行器已重置，请重试');
      }
    } finally {
      receive.close();
      if (handle.port == null) {
        final isolate = handle.isolate;
        handle.isolate = null;
        _stopIsolate(isolate);
      }
      handle.starting = null;
      completer.complete();
    }
    return handle;
  }

  Future<void> _loadLibs() async {
    if (_libsLoaded) return;
    final running = _libsLoading;
    if (running != null) return running;
    final task = _readLibs();
    _libsLoading = task;
    try {
      await task;
      _libsLoaded = true;
    } finally {
      _libsLoading = null;
    }
  }

  Future<void> _readLibs() async {
    for (final name in _libNames) {
      try {
        _libs[name] = await rootBundle.loadString('assets/js_lib/$name');
      } catch (_) {
        // 缺失的库按空模块处理
      }
    }
  }

  void _restartWorker(int slot) {
    if (slot < 0 || slot >= _workers.length) return;
    final handle = _workers[slot];
    handle.port = null;
    handle.readySites.clear();
    final isolate = handle.isolate;
    handle.isolate = null;
    _stopIsolate(isolate);
  }

  /// 挂断一个执行器 isolate。
  ///
  /// 超时发生在 JS 仍在 QuickJS 原生代码里执行时，不能用 `Isolate.immediate`
  /// 强杀：原生 runtime 会被拆掉，后续 native 代码访问已释放内存，表现为
  /// `quickjs_c_bridge.dll` 里的 c0000409（栈 cookie 校验失败）直接闪退。
  /// `beforeNextEvent` 会等当前原生调用回到 Dart 事件循环后再终止 isolate。
  static void _stopIsolate(Isolate? isolate) {
    if (isolate == null) return;
    try {
      isolate.kill(priority: Isolate.beforeNextEvent);
    } catch (_) {
      // ignore
    }
  }

  void _disposeWorkers() {
    for (final handle in _workers) {
      try {
        handle.port?.send({'op': 'dispose', 'id': 0, 'reply': null});
      } catch (_) {
        // ignore
      }
      _stopIsolate(handle.isolate);
      handle.port = null;
      handle.isolate = null;
      handle.readySites.clear();
    }
    _workers.clear();
  }

  Future<void> dispose() async => _disposeWorkers();

  Future<_CachedScript> _scriptFor(SourceBean site) async {
    final cached = _scripts[site.api];
    if (cached != null) return cached;

    String text;
    if (site.api.startsWith('file://')) {
      text = await File(filePathOf(site.api.split('?').first)).readAsString();
      text = _validateScript(text, site.api);
    } else if (bundleAssetKeyOf(site.api) != null) {
      // ★ `assets://` 与 `clan://localhost/` 指向**应用内置**的脚本，不是网络地址。
      //   这类源（CatVod 离线包里的 hipy_js 系列最常见）以前被直接丢给
      //   `_httpGet`，而 Dart 的 HttpClient 不认这个 scheme：
      //
      //     Invalid argument(s): Unsupported scheme 'assets' in URI
      //
      //   结果是整个源 8 毫秒就失败，用户只看到「首页加载失败」。
      //
      //   现在先读打包资产；资产里没有就报一句人话，不再让 Uri 解析异常
      //   直接冒到界面上。
      final key = bundleAssetKeyOf(site.api)!;
      try {
        text = _validateScript(await rootBundle.loadString(key), site.api);
      } catch (_) {
        throw Exception(
          '这个源要读取应用内置的脚本 $key，但安装包里没有它。'
          '（`.api` 属于 CatVod 离线包的 assets:// 写法，'
          '本应用不随包分发第三方脚本；换用 http(s) 的源即可。）',
        );
      }
    } else {
      final cacheFile = await _scriptCacheFile(site.api);
      text = '';
      // 先读 6 小时内的磁盘缓存：应用重启后不用再把所有 .js 重新下一遍。
      if (cacheFile.existsSync() &&
          DateTime.now().difference(cacheFile.lastModifiedSync()) <
              _scriptCacheTtl) {
        try {
          text = _validateScript(await cacheFile.readAsString(), site.api);
        } catch (_) {
          text = '';
        }
      }
      if (text.isEmpty) {
        try {
          final downloaded = await _httpGet(site.api, site.timeout);
          text = _validateScript(downloaded, site.api);
          try {
            await cacheFile.writeAsString(text, flush: true);
          } catch (_) {
            // 磁盘写失败只影响下次启动，不影响本次
          }
        } catch (e) {
          // 回源失败（断网 / 源站挂掉）时继续用旧缓存，别让整个源不可用。
          if (cacheFile.existsSync()) {
            try {
              text = _validateScript(await cacheFile.readAsString(), site.api);
            } catch (_) {
              text = '';
            }
          }
          if (text.isEmpty) rethrow;
        }
      }
    }

    final item = _CachedScript(
      text,
      crypto.md5.convert(utf8.encode(text)).toString(),
    );
    _scripts[site.api] = item;
    return item;
  }

  String _validateScript(String raw, String api) {
    final text = raw.replaceFirst('\uFEFF', '').trim();
    if (text.isEmpty) throw SourceException('JS 蜘蛛脚本为空：$api');
    if (text.startsWith('//bb')) {
      throw SourceException('该 JS 蜘蛛是 QuickJS 字节码（//bb），当前内核无法执行');
    }
    if (text.startsWith('<') || text.toLowerCase().startsWith('not found')) {
      throw SourceException('JS 蜘蛛脚本返回了网页而不是脚本：$api');
    }
    return text;
  }

  Future<File> _scriptCacheFile(String api) async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'js_cache'))
      ..createSync(recursive: true);
    final key = crypto.md5.convert(utf8.encode(api.trim())).toString();
    return File(p.join(dir.path, '$key.js'));
  }

  Future<String> _httpGet(String url, int timeoutSeconds) async {
    final candidates = <String>[
      url,
      ...githubMirrorUrls(normalizeHostUrl(url)),
    ];
    Object? lastError;
    for (final candidate in candidates) {
      try {
        return await _httpGetOnce(candidate, timeoutSeconds);
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError ?? SourceException('JS 蜘蛛脚本下载失败');
  }

  Future<String> _httpGetOnce(String url, int timeoutSeconds) async {
    final client = HttpClient();
    try {
      final req = await client
          .getUrl(Uri.parse(normalizeHostUrl(url)))
          .timeout(Duration(seconds: timeoutSeconds));
      req.headers.set('User-Agent', 'okhttp/4.12.0');
      final res = await req.close().timeout(Duration(seconds: timeoutSeconds));
      if (res.statusCode != 200) {
        await res.drain<void>();
        throw SourceException('JS 蜘蛛脚本下载失败（HTTP ${res.statusCode}）');
      }
      final bytes = await res.fold<List<int>>(
        <int>[],
        (acc, chunk) => acc..addAll(chunk),
      );
      return utf8.decode(bytes, allowMalformed: true);
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _invoke(
    SourceBean site,
    String action,
    List<dynamic> args, {
    bool retry = true,
  }) async {
    final slot = _slotIndex(site.key);
    final handle = await _ensureWorker(slot);
    final port = handle.port;
    if (port == null) throw SourceException('JS 执行器未就绪');
    final script = await _scriptFor(site);
    final ext = enrichSpiderExt(site.ext, driveTokens?.call() ?? const {});
    final cacheKey = '${site.key}|${site.api}|${script.hash}|$ext';
    final firstTime = !handle.readySites.contains(cacheKey);
    final id = ++_requestSeq;
    final receive = ReceivePort();
    final completer = Completer<Map<String, dynamic>>();
    receive.listen((msg) {
      if (msg is Map && (msg['id'] as num?)?.toInt() == id) {
        if (!completer.isCompleted) {
          completer.complete(Map<String, dynamic>.from(msg));
        }
      }
    });
    try {
      port.send({
        'op': 'invoke',
        'id': id,
        'key': site.key,
        'api': site.api,
        'ext': ext,
        'script': firstTime ? script.source : null,
        'hash': script.hash,
        'action': action,
        'args': args,
        'seed': localSeed?.call() ?? const <String, String>{},
        'reply': receive.sendPort,
      });
      final reply = await completer.future.timeout(
        Duration(seconds: site.timeout + 20),
      );
      if (reply['ok'] != true) {
        final error = (reply['error'] ?? 'JS 蜘蛛执行失败').toString();
        if (retry && error.contains('脚本未就绪')) {
          handle.readySites.clear();
          return await _invoke(site, action, args, retry: false);
        }
        throw SourceException(error);
      }
      handle.readySites.add(cacheKey);
      return (reply['data'] ?? '').toString();
    } on TimeoutException {
      _restartWorker(slot);
      throw SourceException('JS 蜘蛛执行超时（$action）');
    } finally {
      receive.close();
    }
  }
}

class _CachedScript {
  _CachedScript(this.source, this.hash);
  final String source;
  final String hash;
}

class _JsWorkerHandle {
  Isolate? isolate;
  SendPort? port;
  Future<void>? starting;
  final Set<String> readySites = {};
}

