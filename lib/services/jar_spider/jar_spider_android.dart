import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/site_config.dart';
import '../../models/vod.dart';
import '../drive/drive_ext.dart';
import '../jvm/jvm_runtime.dart';
import '../movie_parser.dart';
import '../play_result_parser.dart';
import 'jar_spider.dart';
import 'spider_env.dart';

/// 安卓版「jar / DEX 蜘蛛」服务：用 ART 的 `DexClassLoader` 直接加载蜘蛛 DEX，
/// 通过 MethodChannel(`com.kniephos.kniephos/spider`) 调用 CatVod 蜘蛛接口。
///
/// 这是桌面端「JRE17 + dex2jar + 外部 JVM 进程」的安卓等价实现，也是把
/// [dex2jar] 与 [unidbg] 两个能力落到安卓上的方式：
///   · dex2jar 的作用是把 `dex` 变成可运行的 class —— 安卓 ART 原生就能跑 `dex`，
///     所以不再需要 dex2jar，直接用 DexClassLoader 加载即可（见 SpiderHostPlugin）。
///   · unidbg 在桌面用「ARM 模拟器」解加固壳的 `.so` —— 安卓设备本身就是 ARM，
///     直接用 `System.load` 跑壳里的 `.so` 即可（见 SpiderHostPlugin.loadNative）。
///
/// 加固壳（Guard / DexNative）若已拿到解密后的「真实实现 payload jar」，同样用
/// DexClassLoader 加载；壳自带的 127.0.0.1 取流地址由插件内的进程内代理承接。
class JarSpiderAndroidService extends JarSpiderService {
  JarSpiderAndroidService({
    required super.driveTokens,
    required super.driveSeed,
    super.http,
  });

  static const _channel = MethodChannel('com.kniephos.kniephos/spider');

  /// 已加载到插件侧的蜘蛛（按 jar 指纹 + 类名 复用，避免重复加载）。
  final Map<String, _LoadedSpider> _loaded = {};
  final Map<String, Future<String>> _downloading = {};

  // ---------------------------------------------------------------------------
  // jar 取件（精简版：下载并缓存，校验结构）
  // ---------------------------------------------------------------------------

  String _jarUrlOf(SourceBean site) {
    final raw = site.jar.trim().isNotEmpty ? site.jar.trim() : globalJar.trim();
    if (raw.isEmpty) return '';
    return raw.split(';').first.trim();
  }

  String _className(SourceBean site) {
    var api = site.api.trim();
    final q = api.indexOf('?');
    if (q >= 0) api = api.substring(0, q);
    if (api.startsWith('csp_')) return 'com.github.catvod.spider.${api.substring(4)}';
    if (api.contains('.')) return api;
    return 'com.github.catvod.spider.$api';
  }

  Future<Directory> _cacheDir() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'jvm_cache', 'jars'));
    dir.createSync(recursive: true);
    return dir;
  }

  Future<File> _acquireJar(SourceBean site) async {
    final url = _jarUrlOf(site);
    if (url.isEmpty) {
      throw SourceException('该源没有配置 JAR 地址（站点 jar 与订阅 spider 都为空）');
    }
    final key = crypto.md5.convert(utf8.encode(url)).toString();
    final dir = await _cacheDir();
    final file = File(p.join(dir.path, '$key.jar'));
    if (file.existsSync() && file.lengthSync() > 1024) return file;

    final pending = _downloading[key];
    if (pending != null) {
      await pending;
      return file;
    }
    final task = _download(url, file);
    _downloading[key] = task;
    try {
      return await task;
    } finally {
      _downloading.remove(key);
    }
  }

  Future<File> _download(String url, File dest) async {
    final targets = <String>[
      url,
      url.replaceFirst(
        RegExp(r'https?://github\.com/'),
        'https://ghfast.top/https://github.com/',
      ),
      url.replaceFirst(
        RegExp(r'https?://github\.com/'),
        'https://gh-proxy.com/https://github.com/',
      ),
    ];
    for (final target in targets.toSet()) {
      try {
        final client = HttpClient();
        final req = await client.getUrl(Uri.parse(target));
        req.headers.set('User-Agent', 'okhttp/4.12.0');
        req.headers.set('Accept', '*/*');
        req.headers.set('Accept-Encoding', 'identity');
        final res = await req.close().timeout(const Duration(seconds: 30));
        if (res.statusCode != 200) {
          await res.drain<void>();
          client.close(force: true);
          continue;
        }
        final tmp = File('${dest.path}.part');
        final sink = tmp.openWrite();
        await for (final chunk in res) {
          sink.add(chunk);
        }
        await sink.close();
        client.close(force: true);
        if (tmp.lengthSync() < 1024) {
          tmp.deleteSync();
          continue;
        }
        if (!isSpiderJarBytes(tmp.readAsBytesSync())) {
          tmp.deleteSync();
          continue;
        }
        if (dest.existsSync()) dest.deleteSync();
        tmp.renameSync(dest.path);
        return dest;
      } catch (_) {
        // 试下一个镜像
      }
    }
    throw SourceException('JAR 下载失败：${Uri.parse(url).host}');
  }

  // ---------------------------------------------------------------------------
  // 加载到 ART（DexClassLoader）
  // ---------------------------------------------------------------------------

  Future<_LoadedSpider> _ensureLoaded(SourceBean site) async {
    final raw = await _acquireJar(site);
    final className = _className(site);
    final cacheKey = '${p.basenameWithoutExtension(raw.path)}|$className';
    final existing = _loaded[cacheKey];
    if (existing != null) return existing;

    // 同步网盘凭据（让 jar 系蜘蛛读到 cookie 文件）
    try {
      final support = await getApplicationSupportDirectory();
      await SpiderEnv.sync(
        spiderCacheDir: p.join(support.path, 'jvm_cache', 'spider'),
        cookies: driveTokens?.call() ?? const {},
        dataDir: support.path,
        ext: site.ext,
      );
    } catch (_) {
      // 凭据同步失败不阻断蜘蛛调用
    }

    final hasDex = await _jarHasDex(raw);
    if (!hasDex) {
      throw SourceException(
        '该蜘蛛是 class 格式，安卓需 dex/APK 格式（请用 TVBox 的 dex 版蜘蛛）',
      );
    }

    final ext = enrichSpiderExt(site.ext, driveTokens?.call() ?? const {});
    final support = await getApplicationSupportDirectory();
    final reply = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'loadSpider',
      {
        'paths': [raw.path],
        'className': className,
        'ext': ext,
        'cacheDir': p.join(support.path, 'jvm_cache', 'spider'),
      },
    );
    final ok = reply?['ok'] == true;
    if (!ok) {
      throw SourceException('蜘蛛加载失败：${reply?['error'] ?? '未知错误'}');
    }
    final loaded = _LoadedSpider(
      key: cacheKey,
      proxyPort: (reply?['proxyPort'] as num?)?.toInt() ?? 0,
    );
    _loaded[cacheKey] = loaded;
    return loaded;
  }

  Future<bool> _jarHasDex(File jar) async {
    try {
      final bytes = jar.readAsBytesSync();
      final text = String.fromCharCodes(bytes);
      return text.contains('classes.dex');
    } catch (_) {
      return false;
    }
  }

  Future<String> _invoke(SourceBean site, String method, List<String> args) async {
    final loaded = await _ensureLoaded(site);
    final reply = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'invoke',
      {'method': method, 'args': args},
    );
    final ok = reply?['ok'] == true;
    if (!ok) {
      throw SourceException(reply?['error'] ?? '蜘蛛调用失败：$method');
    }
    final data = (reply?['data'] as String?) ?? '';
    return data;
  }

  String _rewriteLocalProxy(String url, int proxyPort) {
    if (proxyPort <= 0 || url.isEmpty) return url;
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final host = uri.host.toLowerCase();
    if (host != '127.0.0.1' && host != 'localhost') return url;
    // 把 127.0.0.1 上任意端口的 /proxy、/chunk 路由改写到进程内代理的真实端口。
    if (uri.path == '/proxy' || uri.path == '/chunk') {
      return uri.replace(host: '127.0.0.1', port: proxyPort).toString();
    }
    return url;
  }

  // ---------------------------------------------------------------------------
  // 公开接口（与桌面端 JarSpiderService 同签名，覆盖原 JVM 进程调用）
  // ---------------------------------------------------------------------------

  @override
  Future<CmsResult> home(SourceBean site) async {
    final text = await _invoke(site, 'homeContent', const []);
    final body = MovieParser.parseJson(text);
    var items = MovieParser.toItems(body.movie, site.key);
    final classes = body.classes;
    if (items.isEmpty) {
      final extra = await _invoke(site, 'homeVideoContent', const []);
      if (extra.trim().isNotEmpty) {
        final more = MovieParser.parseJson(extra);
        final extraItems = MovieParser.toItems(more.movie, site.key);
        if (extraItems.isNotEmpty) items = extraItems;
      }
    }
    if (items.isEmpty && classes.isNotEmpty) {
      try {
        return await category(site, classes.first.id, '1', const {});
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

  @override
  Future<CmsResult> category(
    SourceBean site,
    String tid,
    String pg,
    Map<String, String> filters,
  ) async {
    final extend = filters.entries
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&');
    final text = await _invoke(site, 'categoryContent', [tid, pg, extend]);
    if (text.trim().isEmpty) return const CmsResult();
    final body = MovieParser.parseJson(text);
    return CmsResult(
      items: MovieParser.toItems(body.movie, site.key),
      page: body.movie?.page ?? 0,
      pagecount: body.movie?.pagecount ?? 0,
      total: body.movie?.recordcount ?? 0,
    );
  }

  @override
  Future<VodDetail?> detail(SourceBean site, String id) async {
    final text = await _invoke(site, 'detailContent', [id]);
    if (text.trim().isEmpty) return null;
    final body = MovieParser.parseJson(text);
    return MovieParser.toDetail(body.movie, site.key);
  }

  @override
  Future<List<VodItem>> search(SourceBean site, String keyword) async {
    final text = await _invoke(site, 'searchContent', [keyword, '1']);
    if (text.trim().isEmpty) return const [];
    final body = MovieParser.parseJson(text);
    return MovieParser.toItems(body.movie, site.key);
  }

  @override
  Future<String> live(SourceBean site, String url) async {
    return _invoke(site, 'liveContent', [url]);
  }

  @override
  Future<PlayResult?> play(
    SourceBean site,
    String flag,
    String id, {
    List<String> vipFlags = const [],
    bool retryAuth = true,
  }) async {
    final loaded = await _ensureLoaded(site);
    final text = await _invoke(site, 'playerContent', [
      flag,
      id,
      vipFlags.join(','),
    ]);
    if (text.trim().isEmpty) return null;
    var result = normalizeSpiderPlay(text, flag);
    if (result.url.isNotEmpty && result.url.contains('127.0.0.1')) {
      final url = _rewriteLocalProxy(result.url, loaded.proxyPort);
      result = PlayResult(
        url: url,
        parse: result.parse,
        playUrl: result.playUrl,
        flag: result.flag,
        headers: result.headers,
        message: result.message,
      );
    }
    return result;
  }

  /// 应用退出：先走基类的桌面进程清理（安卓侧是安全空操作），再释放插件侧已加载的
  /// 蜘蛛与进程内代理（等价于桌面端 kill spider-host / serve 进程）。
  @override
  Future<void> shutdown() async {
    await super.shutdown();
    await disposeAndroid();
  }

  /// 释放进程内加载的蜘蛛与代理（应用退出 / 源切换时调用）。
  Future<void> disposeAndroid() async {
    _loaded.clear();
    try {
      await _channel.invokeMethod<dynamic>('unload');
    } catch (_) {}
  }
}

class _LoadedSpider {
  _LoadedSpider({required this.key, required this.proxyPort});
  final String key;
  final int proxyPort;
}

/// 按平台创建 jar/DEX 蜘蛛服务：安卓走 ART(DexClassLoader)，其它平台走桌面/网页实现。
JarSpiderService createJarSpiderService({
  JvmRuntime? runtime,
  required Map<String, String> Function() driveTokens,
  required Map<String, String> Function() driveSeed,
  AppHttp? http,
}) {
  if (Platform.isAndroid) {
    return JarSpiderAndroidService(
      driveTokens: driveTokens,
      driveSeed: driveSeed,
      http: http,
    );
  }
  return JarSpiderService(
    runtime: runtime,
    driveTokens: driveTokens,
    driveSeed: driveSeed,
    http: http,
  );
}
