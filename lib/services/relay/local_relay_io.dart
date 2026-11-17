import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../core/errors/app_error.dart';
import '../../core/logging/app_log.dart';
import '../../core/logging/log_redact.dart';
import '../drive/baidu_native.dart';
import '../live/live_ua_policy.dart';
import '../drive/drive_descriptor.dart';
import '../drive/quark_native.dart';
import '../drive/uc_native.dart';
import '../spider_debug/spider_debug_service.dart';
import '../torrent/bt_stream.dart';
import 'm3u8_purify.dart';
import 'relay_access.dart';
import 'relay_origin.dart';
import 'stream_cache_io.dart';

/// 本地 9978 中继：`/play` / `/file` / `/pkg` / `/img` / `/bt` / `/proxy?do=live`。
///
/// 与旧版 Electron 版保持同端口、同路由口径。播放时：
///   · 有 header / 防盗链 / 网盘 Cookie / WebDAV 凭据的地址经 `/play` 注入；
///   · m3u8 清单在回给播放器之前做去广告与递归改写（分片、密钥、子清单都指回中继）；
///   · 磁力播放走 `/bt`：按 Range 从 aria2 已校验的分片读盘。
class LocalRelay {
  LocalRelay._();
  static final LocalRelay instance = LocalRelay._();

  static const int preferredPort = 9978;

  /// BT 取流分片大小：每片写回播放器前做一次 piece 门控。
  static const int _btChunk = 512 * 1024;
  static final RegExp _btRoute = RegExp(r'^/bt/([0-9a-fA-F]{40})/(\d{1,6})/?$');

  HttpServer? _server;
  HttpClient? _client;

  /// 兼容模式客户端：个别视频 CDN 的证书链缺中间证书 / 自签，
  /// 严格校验会直接失败；仅在首次请求握手失败后对 GET/HEAD 重试使用。
  HttpClient? _insecureClient;
  int _port = 0;
  String _fileRoot = '';
  Map<String, String> Function() _driveTokens = () => const {};
  List<dynamic> Function() _rules = () => const [];
  bool Function() _purifyEnabled = () => false;
  String Function(String id) _davAuth = (_) => '';
  BtStreamSource? Function() _btSource = () => null;

  /// 当前常驻取流 JVM 的宿主代理端口（`/proxy?do=hmys` 等壳路由要转发给它）。
  int Function() _jvmProxyPort = () => 0;

  /// 边播边缓存的磁盘实现；未启用 / 未配置目录时为 null。
  StreamDiskCache? _streamCache;

  /// `/img` 的封面磁盘缓存：跨启动复用，避免每次打开都重新下载 200KB 图。
  ///
  /// 只缓存 200 状态的图片响应，上限 256MB（超过后按最后修改时间淘汰到 200MB）。
  Directory? _imgCacheDir;
  int? _imgCacheBytes;
  int _imgCacheSeq = 0;

  /// 同一张图正在落盘时，后到的请求等它写完直接读缓存。
  ///
  /// 首屏卡片和 Hero 预取经常同时请求同一张封面，重复回源既慢又浪费流量。
  final Map<String, Future<void>> _imgCacheInflight = {};

  static const int _imgCacheLimitBytes = 256 * 1024 * 1024;
  static const int _imgCacheWaterBytes = 200 * 1024 * 1024;

  /// 外部播放器选集列表的按需解析：`/ext/<token>/<index>` 调到这里，
  /// 返回可直接播放的地址（通常是本机 `/play` 中继地址）。
  Future<String?> Function(String token, int index)? _externalEpisodeResolver;

  /// `/play` 的请求头不写进 URL，而是换成短 token（`hk=h1`）。
  ///
  /// 网盘直链 + Cookie + UA + Referer 一起塞进 query 时，URL 很容易超过
  /// FFmpeg 的 `MAX_URL_SIZE`（4096）。内置 fvp 用 Dart HttpClient 能忍，
  /// 外部 MPV 走 FFmpeg 会直接报「URL too long」打不开。token 只在 JVM /
  /// Dart 进程内存里，URL 保持短小。
  final Map<String, Map<String, String>> _playHeaderSets = {};
  final Map<String, String> _playHeaderTokens = {};
  int _playHeaderSeq = 0;
  static const _playHeaderMax = 400;

  /// 播放期 Cookie 会话：provider → (cookie 名 → `name=value`)。
  ///
  /// 网盘会话中途刷新（夸克 / UC 的 `__puus`）只出现在上游 `Set-Cookie` 里。
  /// 记录后供同一 provider 的后续清单 / 分片请求复用；401 / 403 时先用
  /// 刷新后的 Cookie 重试一次，仍失败才把错误透传给播放器。
  final Map<String, Map<String, String>> _playCookieJar = {};
  static const _playCookieMax = 20;

  /// 最多记忆多少个 provider，避免任意 `ck=` 参数把会话表撑大。
  static const _playCookieProvidersMax = 32;

  /// 超长目标地址同样换成短 token（`p=h1`），避免超过 FFmpeg 的 URL 上限。
  ///
  /// 普通短视频地址仍用 `url=`，日志和排查更直观；只有编码后超过
  /// [_playUrlInlineMax] 的地址才走 `p`。
  final Map<String, String> _playTargets = {};
  final Map<String, String> _playTargetTokens = {};
  int _playTargetSeq = 0;
  static const _playTargetMax = 4000;
  static const _playUrlInlineMax = 3500;

  bool get running => _server != null;
  int get port => _port;
  String get baseUrl => 'http://127.0.0.1:$_port';

  /// 本进程的随机访问令牌。
  ///
  /// 浏览器发起的请求必须带 `?rt=<token>`（见 [RelayAccessPolicy]）；
  /// 原生播放器 / 壳内 JVM 不发 `Origin`/`Sec-Fetch-*`，不受影响。
  /// 令牌只在内存里，不落盘、不写日志。
  final String accessToken = _newAccessToken();

  static String _newAccessToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(18, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// 蜘蛛调试服务：桌面端在 main 里注入；未注入或未开启时 `/debug/spider` 返回 403。
  SpiderDebugService? debugService;

  Future<void> start({
    required String fileRoot,
    required Map<String, String> Function() driveTokens,
    required List<dynamic> Function() rules,
    required bool Function() purifyEnabled,
    String Function(String id)? davAuth,
    BtStreamSource? Function()? btSource,
    int Function()? jvmProxyPort,
    String Function()? cacheDir,
    bool Function()? cacheEnabled,
    int Function()? cacheLimitMb,
    Future<String?> Function(String token, int index)? externalEpisodeResolver,
  }) async {
    if (_server != null) return;
    _fileRoot = fileRoot;
    _driveTokens = driveTokens;
    _rules = rules;
    _purifyEnabled = purifyEnabled;
    _davAuth = davAuth ?? (_) => '';
    _btSource = btSource ?? () => null;
    _jvmProxyPort = jvmProxyPort ?? () => 0;
    final cacheRoot = cacheDir?.call().trim() ?? '';
    _streamCache = cacheRoot.isEmpty
        ? null
        : StreamDiskCache(
            dir: cacheRoot,
            enabled: cacheEnabled ?? () => false,
            limitMb: cacheLimitMb ?? () => 1024,
          );
    // 启动后后台扫一遍缓存目录（设置页统计 / LRU 淘汰都靠它）。
    // 以前这一步压在首个分片请求上，历史缓存多时会把起播拖住。
    if (cacheEnabled?.call() == true) _streamCache?.warmUp();
    _externalEpisodeResolver = externalEpisodeResolver;
    _imgCacheDir = fileRoot.trim().isEmpty
        ? null
        : Directory(p.join(fileRoot, 'cache', 'images'));
    _imgCacheBytes = null;
    _client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      // 封面 / 海报会在浏览时反复回源，连接池多留一会儿：
      // 默认 15 秒空闲就断开，翻两页再回来又要重做一次 TLS 握手。
      ..idleTimeout = const Duration(seconds: 60)
      ..autoUncompress = false;

    HttpServer server;
    try {
      server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        preferredPort,
      );
    } on SocketException {
      // 9978 被旧版或别的程序占用时退回临时端口；生成的中继地址都带真实端口，
      // 不影响自身播放。
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    }
    _server = server;
    _port = server.port;
    server.listen(_handle, onError: (Object _) {});
  }

  /// 边播边缓存当前占用字节数（设置页展示 / 清空前确认用）。
  Future<int> streamCacheBytes() async => await _streamCache?.totalBytes() ?? 0;

  /// 边播缓存的条目数（下载管理页展示用）。
  Future<int> streamCacheEntryCount() async =>
      await _streamCache?.entryCount() ?? 0;

  /// 边播缓存的磁盘目录（播放器「下载视频」复用它，空 = 未启用）。
  String get streamCacheDir => _streamCache?.dir ?? '';

  /// 清空边播缓存目录。
  Future<void> clearStreamCache() async {
    await _streamCache?.clear();
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _port = 0;
    _playHeaderSets.clear();
    _playHeaderTokens.clear();
    _playTargets.clear();
    _playTargetTokens.clear();
    _playCookieJar.clear();
    _streamCache = null;
    _imgCacheDir = null;
    _imgCacheBytes = null;
    _imgCacheInflight.clear();
    try {
      await server?.close(force: true);
    } catch (_) {
      // 退出阶段忽略
    }
    try {
      _client?.close(force: true);
    } catch (_) {
      // 退出阶段忽略
    }
    try {
      _insecureClient?.close(force: true);
    } catch (_) {
      // 退出阶段忽略
    }
    _client = null;
    _insecureClient = null;
  }

  /// 网盘登录态变化时清掉该 provider 的播放期 Cookie。
  ///
  /// 换账号 / 重新扫码后旧账号的 `__puus` 仍在 jar 里，会覆盖新账号刚注入的
  /// Cookie；清掉后由新会话重新学习。
  void clearPlaySession([String? provider]) {
    if (provider == null || provider.isEmpty) {
      _playCookieJar.clear();
    } else {
      _playCookieJar.remove(provider);
    }
  }

  String playUrl(
    String url, {
    Map<String, String> headers = const {},
    String provider = '',
  }) {
    if (!running) return url;
    if (_isRelayUrl(url)) return url;
    final query = <String, String>{};
    if (Uri.encodeComponent(url).length > _playUrlInlineMax) {
      query['p'] = _rememberPlayTarget(url);
    } else {
      query['url'] = url;
    }
    final headerToken = _rememberPlayHeaders(headers);
    if (headerToken.isNotEmpty) query['hk'] = headerToken;
    if (provider.isNotEmpty) query['ck'] = provider;
    return Uri.parse('$baseUrl/play')
        .replace(queryParameters: query)
        .toString();
  }

  String _rememberPlayTarget(String url) {
    final existing = _playTargetTokens[url];
    if (existing != null && _playTargets.containsKey(existing)) return existing;
    final token = 'p${_playTargetSeq++}';
    _playTargetTokens[url] = token;
    _playTargets[token] = url;
    if (_playTargetTokens.length > _playTargetMax) {
      final oldest = _playTargetTokens.keys.first;
      final oldToken = _playTargetTokens.remove(oldest);
      if (oldToken != null) _playTargets.remove(oldToken);
    }
    return token;
  }

  /// 相同请求头复用同一个 token：m3u8 的每个分片都会调用 [playUrl]，
  /// 不能为每个分片生成新 token，否则内存会被几百个相同的头集合撑大。
  String _rememberPlayHeaders(Map<String, String> headers) {
    if (headers.isEmpty) return '';
    final signature = headers.entries
        .map((e) => '${e.key.toLowerCase()}\u0001${e.value}')
        .join('\u0002');
    final existing = _playHeaderTokens[signature];
    if (existing != null && _playHeaderSets.containsKey(existing)) {
      return existing;
    }
    final token = 'h${_playHeaderSeq++}';
    _playHeaderTokens[signature] = token;
    _playHeaderSets[token] = Map<String, String>.from(headers);
    if (_playHeaderTokens.length > _playHeaderMax) {
      final oldest = _playHeaderTokens.keys.first;
      final oldToken = _playHeaderTokens.remove(oldest);
      if (oldToken != null) _playHeaderSets.remove(oldToken);
    }
    return token;
  }

  bool _isRelayUrl(String url) =>
      url.startsWith(baseUrl) || url.startsWith('http://127.0.0.1:9978/');

  Future<void> _handle(HttpRequest request) async {
    final res = request.response;
    final path = request.uri.path;
    // 浏览器跨站访问只对媒体路由开口子：`/file` 与 `/pkg` 能读应用数据目录
    // （网盘 Cookie 落盘文件在其中），`/proxy` 能借中继的凭据代取任意地址，
    // 这两类不能靠 `Access-Control-Allow-Origin: *` 暴露给任意网页。
    final originHeader = request.headers.value('origin');
    final secFetchSite = request.headers.value('sec-fetch-site');
    final secFetchMode = request.headers.value('sec-fetch-mode');
    // 浏览器请求先过令牌：DNS rebinding 能让「Origin == Host」成立，
    // 只靠 CORS 同源判断挡不住敏感路由。令牌在内存里，原生客户端不需要。
    final browserRequest = RelayAccessPolicy.isBrowserRequest(
      origin: originHeader,
      secFetchSite: secFetchSite,
      secFetchMode: secFetchMode,
    );
    if (browserRequest) {
      final provided = request.uri.queryParameters['rt'];
      if (!RelayAccessPolicy.tokenMatches(accessToken, provided)) {
        AppLog.w(
          'relay',
          '拒绝未授权浏览器请求 ${request.method} $path origin=$originHeader',
        );
        res.headers.set('Vary', 'Origin');
        return _text(res, 403, '需要访问令牌');
      }
    }
    final verdict = RelayOriginPolicy.evaluate(
      path: path,
      origin: originHeader,
      host: request.headers.value(HttpHeaders.hostHeader),
      secFetchSite: secFetchSite,
    );
    if (verdict == RelayOriginVerdict.crossSiteDenied) {
      AppLog.w('relay', '拒绝跨站访问 ${request.method} $path origin=$originHeader');
      res.headers.set('Vary', 'Origin');
      return _text(res, 403, '跨站访问被拒绝');
    }
    // 只对确实带 Origin 的请求回写 CORS：逐条回显来源而不是 `*`，
    // 这样第三方页面读不到响应体，同源页面（含 Web 版界面）不受影响。
    final self = RelayOriginPolicy.normalizeOrigin(originHeader);
    if (self != null) {
      res.headers.set('Access-Control-Allow-Origin', originHeader!.trim());
      res.headers.set('Vary', 'Origin');
      res.headers.set('Access-Control-Allow-Headers', '*');
      res.headers.set('Access-Control-Allow-Methods', kRelayAllowMethods);
    } else if (verdict == RelayOriginVerdict.allow) {
      // 原生客户端不需要 CORS 头；中继自己的 Web 版界面走不到这里（Web 版 baseUrl 为空）。
      res.headers.set('Access-Control-Allow-Methods', kRelayAllowMethods);
    }
    if (request.method == 'OPTIONS') {
      res.statusCode = 204;
      await res.close();
      return;
    }
    try {
      // /play、/proxy 的分片请求量很大，只在清单/失败时记录；其余路由逐条记。
      if (path != '/play' && path != '/proxy' && !path.startsWith('/proxy/')) {
        AppLog.i('relay', '${request.method} $path');
      }
      if (path == '/play') {
        return await _handlePlay(request, guardPrivate: browserRequest);
      }
      if (path == '/file' || path.startsWith('/file/')) {
        return await _handleFile(request);
      }
      // 本地媒体库：按绝对路径取文件。只允许原生客户端（浏览器请求一律拒绝，
      // 否则任意网页都能借中继读取本机磁盘上的视频/文件）。
      if (path == '/media') {
        if (browserRequest) {
          return await _text(res, 403, '媒体文件只允许本机播放器访问');
        }
        return await _handleMedia(request);
      }
      if (path == '/pkg' || path.startsWith('/pkg/')) {
        return await _handlePkg(request);
      }
      if (path == '/img') {
        return await _handleImg(request, guardPrivate: browserRequest);
      }
      if (path.startsWith('/ext/')) {
        return await _handleExternalEpisode(request);
      }
      if (path.startsWith('/bt/')) return await _handleBt(request);
      if (path == '/debug/spider' || path.startsWith('/debug/spider/')) {
        return await _handleSpiderDebug(request);
      }
      if (path == '/proxy') {
        return await _handleLiveProxy(request, guardPrivate: browserRequest);
      }
      if (path.startsWith('/proxy/')) {
        return await _handleJvmProxyPath(request);
      }
      if (path == '/') return await _text(res, 200, 'MisaTV local relay');
      return await _text(res, 404, 'not found');
    } catch (e, s) {
      AppLog.e('relay', '$path 处理失败', e, s);
      try {
        return await _text(res, 502, '中继失败：${describeAppError(e).title}');
      } catch (_) {
        try {
          await res.close();
        } catch (_) {}
      }
    }
  }

  Future<void> _handlePlay(
    HttpRequest request, {
    bool guardPrivate = false,
  }) async {
    final res = request.response;
    final query = request.uri.queryParameters;
    var target = (query['url'] ?? query['u'] ?? '').trim();
    if (target.isEmpty) {
      final token = (query['p'] ?? '').trim();
      if (token.isNotEmpty) target = _playTargets[token] ?? '';
    }
    if (target.isEmpty) return _text(res, 400, '缺少 url');
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(target)) {
      return _text(res, 400, '只支持 http(s) 播放地址');
    }
    if (guardPrivate && RelayAccessPolicy.isPrivateTarget(target)) {
      return _text(res, 403, '禁止访问本机/内网地址');
    }
    final provider = (query['ck'] ?? '').trim();
    final headers = _headersFromQuery(query, provider);
    // ★ 百度 dlink 的防盗链按 UA 判定：浏览器 UA 恒定 403 31326/user is not authorized
    //   （winbox 真机实证），必须用网盘客户端 UA。jar 有时只给浏览器 UA，这里强制纠正。
    final targetHost = Uri.tryParse(target)?.host.toLowerCase() ?? '';
    final baiduLink =
        provider == 'baidu' ||
        targetHost.contains('baidu.com') ||
        targetHost.contains('baidupcs.com') ||
        targetHost.contains('bcebos.com') ||
        targetHost.contains('bdstatic.com');
    if (baiduLink) {
      final currentUa = _headerValue(headers, HttpHeaders.userAgentHeader);
      if (!currentUa.toLowerCase().contains('netdisk')) {
        headers[HttpHeaders.userAgentHeader] = 'netdisk;P2SP;3.0.0;windows;;;';
      }
      if (_headerValue(headers, HttpHeaders.refererHeader).isEmpty) {
        headers[HttpHeaders.refererHeader] = 'https://pan.baidu.com/';
      }
    } else if (_headerValue(headers, HttpHeaders.userAgentHeader).isEmpty) {
      // 网盘直链有些会拒绝没有 UA 的请求（返回 403 / HTML），播放器只会报
      // “invalid or unsupported media”。调用方没给 UA 时补一个浏览器 UA。
      headers[HttpHeaders.userAgentHeader] =
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
          'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
    }
    // ★ 哔哩 CDN 按 Referer 防盗链：不带 bilibili.com 的 Referer 会回 403，
    //   播放器只报 invalid or unsupported media。未登录（只有 360P / 480P）时
    //   这条同样必需，不能因为「没配 Cookie」就跳过。
    final biliLink =
        provider == 'bili' ||
        targetHost.endsWith('bilibili.com') ||
        targetHost.endsWith('bilivideo.com') ||
        targetHost.endsWith('bilivideo.cn') ||
        targetHost.endsWith('hdslb.com');
    if (biliLink) {
      if (_headerValue(headers, HttpHeaders.refererHeader).isEmpty) {
        headers[HttpHeaders.refererHeader] = 'https://www.bilibili.com/';
      }
      if (_headerValue(headers, HttpHeaders.userAgentHeader).isEmpty) {
        headers[HttpHeaders.userAgentHeader] =
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
            'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
      }
    }
    final davId = (query['dav'] ?? '').trim();
    if (davId.isNotEmpty &&
        !headers.keys.any((k) => k.toLowerCase() == 'authorization')) {
      final auth = _davAuth(davId);
      if (auth.isNotEmpty) headers['Authorization'] = auth;
    }
    // 网盘会话 Cookie：账号 Cookie 在 _headersFromQuery 里注入，这里再叠加
    // 播放期从上游 Set-Cookie 学到的新 Cookie（同名以新值覆盖）。
    if (provider.isNotEmpty) {
      final merged = _applyPlayCookieJar(
        provider,
        _headerValue(headers, HttpHeaders.cookieHeader),
      );
      if (merged.isNotEmpty) {
        _setHeader(headers, HttpHeaders.cookieHeader, merged);
      }
    }
    final range = request.headers.value(HttpHeaders.rangeHeader);
    // 边播边缓存：命中直接读盘，连上游都不碰 —— 拖回看过的位置不再回源。
    final cacheKey = StreamDiskCache.keyOf(target);
    if (range == null &&
        request.method == 'GET' &&
        !target.toLowerCase().contains('.m3u8')) {
      final cached = await _streamCache?.lookup(cacheKey);
      if (cached != null) {
        res.statusCode = 200;
        res.headers.set(HttpHeaders.contentTypeHeader, cached.contentType);
        res.headers.contentLength = cached.length;
        await res.addStream(cached.file.openRead());
        await res.close();
        return;
      }
    }

    // ★ 网盘 CDN 的「跨度限速」：开放区间（`bytes=0-`）与超大跨度会让同一节点
    //   被压到 ~0.1 MB/s，播放器表现为「有画面但极慢」。夹到 32MB 后回到
    //   10~19 MB/s；上游回 206 + 真实 Content-Range，播放器会自然续请求下一段。
    //   只对夸克 / UC / 百度生效，避免影响 WebDAV、B 站等无关线路。
    final opened = await _openPlayWithSession(
      target,
      headers: headers,
      method: request.method,
      range: _shouldClampRange(provider, target) ? clampRange(range) : range,
      provider: provider,
    );
    final upstream = opened.response;
    // 上游可能下发了刷新后的会话 Cookie；清单里的子地址要用最新 Cookie，
    // 否则后续分片仍带旧值，播一会儿就 401 / 403 断流。
    if (provider.isNotEmpty) {
      final merged = _applyPlayCookieJar(
        provider,
        _headerValue(headers, HttpHeaders.cookieHeader),
      );
      if (merged.isNotEmpty) {
        _setHeader(headers, HttpHeaders.cookieHeader, merged);
      }
    }
    final finalUrl = opened.finalUrl;
    if (guardPrivate && RelayAccessPolicy.isPrivateTarget(finalUrl)) {
      // 上游 30x 到内网同样要拦：只检查入口地址绕不过重定向。
      await upstream.drain<void>();
      return _text(res, 403, '禁止访问本机/内网地址');
    }
    final contentType = _responseContentType(upstream);
    final looksM3u8 =
        finalUrl.toLowerCase().contains('.m3u8') ||
        contentType.contains('mpegurl') ||
        contentType.contains('application/vnd.apple');
    // B 站（以及不少 DASH 源）下发的是 DASH 清单：content-type 为
    // application/dash+xml，正文是 <MPD>，分片地址在 <BaseURL> 里且同样受
    // Referer / UA 校验。不识别它时清单会原样透传，播放器拿到的 BaseURL 指向
    // bilivideo CDN、却没有中继注入的 Referer，于是 403 —— 用户侧表现为
    // 「能打开但一直转圈 / invalid or unsupported media」。
    // 实测：wex 系 BiliGuard（高中课堂 / 少儿教育）返回的正是
    // /proxy?do=bili&...&type=mpd 且 format=application/dash+xml。
    final looksDash =
        contentType.contains('dash+xml') ||
        finalUrl.toLowerCase().contains('.mpd');

    if (looksM3u8 || looksDash) {
      AppLog.i(
        'relay',
        '/play ${looksDash ? 'mpd' : 'm3u8'} ${upstream.statusCode} '
            '${redactUrl(target)}',
      );
    }
    if (looksDash && request.method != 'HEAD' && upstream.statusCode < 400) {
      // DASH 不复用 m3u8 的 _rewritePlaylist（它按 #EXT-X-* 行处理），只改写
      // <BaseURL> 与 SegmentTemplate 的 media/initialization 里的绝对地址。
      var bytes = await _readLimited(upstream);
      final encoding = _responseHeader(
        upstream,
        HttpHeaders.contentEncodingHeader,
      ).toLowerCase();
      if (encoding.contains('gzip')) {
        try {
          bytes = gzip.decode(bytes);
        } catch (_) {
          // 解压失败按原文处理
        }
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      final rewritten = _rewriteMpd(text, finalUrl, headers, provider);
      res.statusCode = 200;
      res.headers.set('content-type', 'application/dash+xml');
      final payload = utf8.encode(rewritten);
      res.headers.contentLength = payload.length;
      res.add(payload);
      await res.close();
      return;
    }
    if (looksM3u8 && request.method != 'HEAD' && upstream.statusCode < 400) {
      var bytes = await _readLimited(upstream);
      final encoding = _responseHeader(
        upstream,
        HttpHeaders.contentEncodingHeader,
      ).toLowerCase();
      if (encoding.contains('gzip')) {
        try {
          bytes = gzip.decode(bytes);
        } catch (_) {
          // 解压失败按原文处理
        }
      }
      var text = utf8.decode(bytes, allowMalformed: true);
      if (_purifyEnabled() && text.startsWith('#EXTM3U')) {
        final result = purifyVodM3u8(
          text,
          finalUrl,
          rules: hostRegexFor(finalUrl, _rules()),
        );
        if (result != null && result.removed > 0) text = result.text;
      }
      final rewritten = _rewritePlaylist(text, finalUrl, headers, provider);
      res.statusCode = 200;
      res.headers.set('content-type', 'application/vnd.apple.mpegurl');
      final payload = utf8.encode(rewritten);
      res.headers.contentLength = payload.length;
      res.add(payload);
      await res.close();
      return;
    }

    res.statusCode = upstream.statusCode;
    _copyHeader(upstream, res, HttpHeaders.contentTypeHeader);
    _copyHeader(upstream, res, HttpHeaders.contentLengthHeader);
    _copyHeader(upstream, res, HttpHeaders.contentRangeHeader);
    _copyHeader(upstream, res, HttpHeaders.acceptRangesHeader);
    _copyHeader(upstream, res, HttpHeaders.lastModifiedHeader);
    _copyHeader(upstream, res, HttpHeaders.etagHeader);
    _copyHeader(upstream, res, HttpHeaders.cacheControlHeader);
    _copyHeader(upstream, res, HttpHeaders.contentEncodingHeader);
    if (request.method == 'HEAD') {
      await res.close();
      return;
    }
    // 未命中缓存：一边转发给播放器，一边把分片写进本地。
    // 只缓存「整段 GET 的媒体响应」；Range、gzip、错误页一律透传。
    final cacheable =
        _streamCache != null &&
        range == null &&
        request.method == 'GET' &&
        upstream.statusCode == 200 &&
        _responseHeader(upstream, HttpHeaders.contentEncodingHeader).isEmpty &&
        _cacheableContentType(contentType);
    final writer = cacheable
        ? await _streamCache!.open(
            cacheKey,
            contentType: contentType,
            length: upstream.contentLength,
          )
        : null;
    if (writer == null) {
      await upstream.pipe(res);
      return;
    }
    try {
      // 用 addStream 转发，而不是 res.add 的裸循环：
      // addStream 会把播放器的读取背压一路传回上游，缓存开启时也不会
      // 把整段分片先读进内存再排队（内存抖动会表现成播放卡顿）。
      await res.addStream(
        upstream.transform(
          StreamTransformer<List<int>, List<int>>.fromHandlers(
            handleData: (chunk, sink) {
              writer.add(chunk);
              sink.add(chunk);
            },
          ),
        ),
      );
      await res.close();
      await writer.commit();
    } catch (_) {
      // 播放器提前断开（拖动 / 切集）：半截文件不留在缓存里。
      await writer.abort();
      try {
        await res.close();
      } catch (_) {}
    }
  }

  /// 单次上游请求的 Range 跨度上限（32MB）。
  ///
  /// 实测（夸克 672MB / 2GB 两个直链，同一 cookie、同一节点）：
  ///   · `bytes=0-`（开放）→ 0.1 MB/s
  ///   · 跨度 2GB / 1GB / 512MB → 0.1 MB/s
  ///   · 跨度 400MB / 350MB → 0.1 / 4.6 MB/s（阈值在 ~360MB 附近）
  ///   · 跨度 300MB / 256MB → 5.4 / 7.8 MB/s
  ///   · 跨度 128MB / 64MB / 32MB → 9.8 / 9.6 / 13.0 MB/s
  ///   · 跨度 16MB / 8MB → 8.5 / 19.2 MB/s
  /// 也就是说速度与请求跨度反相关，开放 Range 是最差的一种。
  /// 播放器（尤其 fvp / mpv）开场习惯发 `bytes=0-`，正好踩在这个坑上。
  static const int _maxUpstreamRangeBytes = 32 * 1024 * 1024;

  /// 该线路是否是会出现「跨度限速」的网盘 CDN。
  ///
  /// 只对夸克 / UC / 百度夹取：普通 HTTP 直链、WebDAV、B 站 CDN 没有这个
  /// 问题，没必要把一次长请求拆成几十段。provider 缺失时按 host 兜底
  /// （壳的 `do=pan` 有时不带 `site` 参数）。
  static bool _shouldClampRange(String provider, String target) {
    final p = provider.toLowerCase().trim();
    if (p.startsWith('quark') || p.startsWith('uc') || p.startsWith('baidu')) {
      return true;
    }
    final host = Uri.tryParse(target)?.host.toLowerCase() ?? '';
    if (host.isEmpty) return false;
    return host.contains('quark.cn') ||
        host.contains('uc.cn') ||
        host.contains('ucweb.com') ||
        host.contains('baidupcs.com') ||
        host.contains('bcebos.com') ||
        host.contains('baidu.com');
  }

  /// 把播放器的 Range 夹到安全跨度；无法解析时原样透传（不猜）。
  ///
  /// 只处理单区间 `bytes=<start>-<end|*>`：多区间（带逗号）与 `-<suffix>` 形态
  /// 直接透传 —— 那些在媒体播放里几乎不出现，改动它们风险大于收益。
  static String? clampRange(String? range) {
    if (range == null || range.trim().isEmpty) return range;
    final m = RegExp(
      r'^bytes\s*=\s*(\d+)\s*-\s*(\d*)$',
      caseSensitive: false,
    ).firstMatch(range.trim());
    if (m == null) return range;
    final start = int.tryParse(m.group(1)!);
    if (start == null || start < 0) return range;
    final endText = m.group(2)!.trim();
    if (endText.isEmpty) {
      // 开放区间：夹成固定跨度
      return 'bytes=$start-${start + _maxUpstreamRangeBytes - 1}';
    }
    final end = int.tryParse(endText);
    if (end == null || end < start) return range;
    if (end - start + 1 <= _maxUpstreamRangeBytes) return range;
    return 'bytes=$start-${start + _maxUpstreamRangeBytes - 1}';
  }

  /// 只把音视频 / 图片 / 二进制当作可缓存内容，避免把 HTML 错误页写进缓存。
  static bool _cacheableContentType(String type) {
    final value = type.toLowerCase();
    if (value.isEmpty) return true;
    return value.startsWith('video/') ||
        value.startsWith('audio/') ||
        value.startsWith('image/') ||
        value.contains('octet-stream') ||
        value.contains('mp2t') ||
        value.contains('mp4');
  }

  Future<void> _handleFile(HttpRequest request) async {
    final raw = request.uri.path.substring('/file'.length);
    final relative = _decodeRel(raw);
    await _serveFile(request, _fileRoot, relative);
  }

  /// 本地媒体库直取（绝对路径，仅原生客户端可访问）。
  Future<void> _handleMedia(HttpRequest request) async {
    final res = request.response;
    final raw = (request.uri.queryParameters['path'] ?? '').trim();
    if (raw.isEmpty) return _text(res, 400, '缺少 path 参数');
    if (!p.isAbsolute(raw)) return _text(res, 400, '路径必须是绝对路径');
    final filePath = p.normalize(raw);
    final file = File(filePath);
    if (!file.existsSync()) return _text(res, 404, '文件不存在');
    await _serveFile(request, file.parent.path, p.basename(filePath));
  }

  Future<void> _handlePkg(HttpRequest request) async {
    final rest = request.uri.path.substring('/pkg'.length);
    final parts = rest.split('/').where((e) => e.isNotEmpty).toList();
    if (parts.length < 2) {
      return _text(request.response, 400, 'pkg 路径应为 /pkg/<i>/<file>');
    }
    final index = int.tryParse(parts.first);
    if (index == null) return _text(request.response, 400, 'pkg 序号非法');
    final root = Directory(p.join(_fileRoot, 'local_pkgs'));
    if (!root.existsSync()) return _text(request.response, 404, '没有本地包');
    final dirs = root.listSync().whereType<Directory>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    if (index < 0 || index >= dirs.length) {
      return _text(request.response, 404, '本地包不存在');
    }
    final relative = '/${parts.skip(1).join('/')}';
    await _serveFile(request, dirs[index].path, relative);
  }

  Future<void> _serveFile(
    HttpRequest request,
    String root,
    String relative,
  ) async {
    final res = request.response;
    final decoded = _decodeRel(relative);
    if (decoded.isEmpty || decoded.contains('\u0000')) {
      return _text(res, 400, '路径非法');
    }
    final rootPath = p.normalize(p.absolute(root));
    final filePath = p.normalize(
      p.join(rootPath, decoded.replaceFirst(RegExp(r'^/+'), '')),
    );
    if (!p.isWithin(rootPath, filePath) && filePath != rootPath) {
      return _text(res, 403, '路径越界');
    }
    final file = File(filePath);
    if (!file.existsSync()) return _text(res, 404, '文件不存在');
    final length = file.lengthSync();
    final range = request.headers.value(HttpHeaders.rangeHeader);
    if (range != null && range.startsWith('bytes=')) {
      final spec = range.substring('bytes='.length).split('-');
      final start = int.tryParse(spec.first) ?? 0;
      final end = spec.length > 1 && spec[1].isNotEmpty
          ? int.tryParse(spec[1]) ?? length - 1
          : length - 1;
      if (start < 0 || start >= length || end < start) {
        res.statusCode = 416;
        res.headers.set('content-range', 'bytes */$length');
        await res.close();
        return;
      }
      final safeEnd = end >= length ? length - 1 : end;
      res.statusCode = 206;
      res.headers.set('content-range', 'bytes $start-$safeEnd/$length');
      res.headers.contentLength = safeEnd - start + 1;
      res.headers.set('accept-ranges', 'bytes');
      res.headers.set('content-type', _contentTypeOf(file.path));
      if (request.method == 'HEAD') {
        await res.close();
        return;
      }
      await file.openRead(start, safeEnd + 1).pipe(res);
      return;
    }
    res.statusCode = 200;
    res.headers.contentLength = length;
    res.headers.set('accept-ranges', 'bytes');
    res.headers.set('content-type', _contentTypeOf(file.path));
    if (request.method == 'HEAD') {
      await res.close();
      return;
    }
    await file.openRead().pipe(res);
  }

  /// 外部播放器选集：按需解析后 302 到真正的播放地址。
  ///
  /// 播放器在片单里切集时才会请求这里，所以不用在启动外部播放器之前
  /// 把整季直链全部解析一遍。
  Future<void> _handleExternalEpisode(HttpRequest request) async {
    final res = request.response;
    final segments = request.uri.pathSegments;
    final resolver = _externalEpisodeResolver;
    if (resolver == null || segments.length < 3) {
      return _text(res, 404, 'external playlist unavailable');
    }
    final token = segments[1];
    final index = int.tryParse(segments[2]);
    if (index == null || index < 0) {
      return _text(res, 400, 'bad episode index');
    }
    final target = await resolver(token, index);
    if (target == null || target.isEmpty) {
      return _text(res, 502, '无法解析这一集');
    }
    AppLog.i('relay', '/ext/$index -> ${redactUrl(target)}');
    res.statusCode = HttpStatus.found;
    res.headers.set(HttpHeaders.locationHeader, target);
    await res.close();
  }

  /// BT 取流口：`/bt/<infoHash>/<fileIndex>`。
  ///
  /// 与 `/play` 的差别是数据来自本机正在下载的文件：
  ///   · 必须有 Range（播放器 seek / 起播探测都靠它）；
  ///   · 必须有 piece 门控（未下载区读出来是稀疏零 → 喂零 = 坏流），按 512KB 分片逐段等待；
  ///   · 首片单独门控再写响应头，避免播放器拿到 200 却迟迟无字节。
  Future<void> _handleBt(HttpRequest request) async {
    final res = request.response;
    final match = _btRoute.firstMatch(request.uri.path);
    if (match == null) return _text(res, 404, 'bt 路径非法');
    final infoHash = match.group(1)!.toLowerCase();
    final fileIndex = int.parse(match.group(2)!);
    final source = _btSource();
    if (source == null) return _text(res, 503, 'BT 引擎未运行');
    final info = source.resolveStream(infoHash, fileIndex);
    if (info == null) return _text(res, 404, 'bt 会话不存在或文件序号不匹配');
    final total = info.length;
    if (total <= 0) return _text(res, 503, 'BT 文件为空');
    final file = File(info.absPath);
    if (!file.existsSync()) return _text(res, 503, 'BT 文件尚未落盘');

    final range = request.headers.value(HttpHeaders.rangeHeader);
    var start = 0;
    var end = total - 1;
    final partial = range != null && range.isNotEmpty;
    if (partial) {
      final parsed = _parseByteRange(range, total);
      if (parsed == null) {
        res.statusCode = 416;
        res.headers.set('content-range', 'bytes */$total');
        await res.close();
        return;
      }
      start = parsed.$1;
      end = parsed.$2;
    }

    // 首片门控：只等这一小段（`bytes=0-` 不能变成「等全片」）。
    final firstEnd = start + _btChunk - 1 < end ? start + _btChunk - 1 : end;
    final ready = await source.waitCovered(
      infoHash,
      fileIndex,
      start,
      firstEnd,
    );
    if (!ready) return _text(res, 503, 'BT 数据未就绪（做种者过少或已无进度）');

    res.statusCode = partial ? 206 : 200;
    res.headers.set('content-type', _contentTypeOf(info.absPath));
    res.headers.set('accept-ranges', 'bytes');
    res.headers.contentLength = end - start + 1;
    if (partial) res.headers.set('content-range', 'bytes $start-$end/$total');
    if (request.method == 'HEAD') {
      await res.close();
      return;
    }
    try {
      for (var pos = start; pos <= end; pos += _btChunk) {
        final stop = pos + _btChunk - 1 < end ? pos + _btChunk - 1 : end;
        if (pos > start) {
          final ok = await source.waitCovered(infoHash, fileIndex, pos, stop);
          if (!ok) {
            // 已经发出响应头，无法改状态码：直接断开，让播放器重试。
            await res.close();
            return;
          }
        }
        await res.addStream(file.openRead(pos, stop + 1));
      }
      await res.close();
    } catch (_) {
      // 客户端提前断开（seek/关闭）→ 忽略
      try {
        await res.close();
      } catch (_) {}
    }
  }

  /// 解析 `Range: bytes=`（只取第一段；支持 `a-b` / `a-` / `-n`）。
  (int, int)? _parseByteRange(String raw, int total) {
    final lower = raw.toLowerCase();
    if (!lower.startsWith('bytes=')) return null;
    final spec = lower.substring('bytes='.length).split(',').first.trim();
    final dash = spec.indexOf('-');
    if (dash < 0) return null;
    final left = spec.substring(0, dash).trim();
    final right = spec.substring(dash + 1).trim();
    if (left.isEmpty) {
      final suffix = int.tryParse(right);
      if (suffix == null || suffix <= 0) return null;
      final start = suffix >= total ? 0 : total - suffix;
      return (start, total - 1);
    }
    final start = int.tryParse(left);
    if (start == null || start < 0 || start >= total) return null;
    if (right.isEmpty) return (start, total - 1);
    final end = int.tryParse(right);
    if (end == null || end < start) return null;
    return (start, end >= total ? total - 1 : end);
  }

  Future<void> _handleImg(
    HttpRequest request, {
    bool guardPrivate = false,
  }) async {
    final res = request.response;
    final query = request.uri.queryParameters;
    final target = (query['url'] ?? query['u'] ?? '').trim();
    if (target.isEmpty) return _text(res, 400, '缺少 url');
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(target)) {
      return _text(res, 400, '只支持 http(s) 图片地址');
    }
    if (guardPrivate && RelayAccessPolicy.isPrivateTarget(target)) {
      return _text(res, 403, '禁止访问本机/内网地址');
    }
    final referer = (query['ref'] ?? '').trim();
    // 封面缓存命中时直接读盘：应用重启后也不用再走一遍代理 / 图床。
    final cacheKey = _imgCacheKey(target, referer);
    if (await _serveImgCache(request, cacheKey)) return;
    // 同一张图正在写入磁盘时等它完成：首屏卡片和 Hero 预取经常同时
    // 请求同一张封面，重复回源既慢又浪费流量。
    final inflight = _imgCacheInflight[cacheKey];
    if (inflight != null) {
      try {
        // 上游卡住时不能无限等，超时后自己回源。
        await inflight.timeout(const Duration(seconds: 10), onTimeout: () {});
      } catch (_) {
        // 前一个请求失败时自己再回源一次
      }
      if (await _serveImgCache(request, cacheKey)) return;
    }
    final headers = <String, String>{
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
      if (referer.isNotEmpty) 'Referer': referer,
    };
    // 代理链路抖动时（隧道被对端掐断、节点瞬断）重试一次再放弃：
    // 封面是并发拉取的，偶发失败在界面上就是「有个别封面不出来」。
    ({HttpClientResponse response, String finalUrl}) opened;
    try {
      opened = await _open(target, headers: headers, method: request.method);
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      opened = await _open(target, headers: headers, method: request.method);
    }
    final upstream = opened.response;
    if (guardPrivate && RelayAccessPolicy.isPrivateTarget(opened.finalUrl)) {
      await upstream.drain<void>();
      return _text(res, 403, '禁止访问本机/内网地址');
    }
    res.statusCode = upstream.statusCode;
    _copyHeader(upstream, res, HttpHeaders.contentTypeHeader);
    _copyHeader(upstream, res, HttpHeaders.contentLengthHeader);
    if (request.method == 'HEAD') {
      await res.close();
      return;
    }
    final contentType = _responseHeader(
      upstream,
      HttpHeaders.contentTypeHeader,
    ).toLowerCase();
    // 只缓存正常的图片响应；错误页 / 空响应写进缓存会一直坏到过期。
    if (upstream.statusCode != 200 || !contentType.startsWith('image/')) {
      await upstream.pipe(res);
      return;
    }
    final dir = await _ensureImgCacheDir();
    if (dir == null) {
      await upstream.pipe(res);
      return;
    }
    final finalFile = File(p.join(dir.path, '$cacheKey.img'));
    final temp = File(p.join(dir.path, '$cacheKey.${_imgCacheSeq++}.part'));
    final writeDone = Completer<void>();
    _imgCacheInflight[cacheKey] = writeDone.future;
    IOSink? sink;
    try {
      sink = temp.openWrite();
      final writer = sink;
      // 一边回给 Flutter 一边落盘：首屏不额外等一次下载。
      await res.addStream(
        upstream.transform(
          StreamTransformer<List<int>, List<int>>.fromHandlers(
            handleData: (chunk, out) {
              writer.add(chunk);
              out.add(chunk);
            },
          ),
        ),
      );
      await res.close();
      await writer.close();
      await temp.rename(finalFile.path);
      try {
        await File(p.join(dir.path, '$cacheKey.type'))
            .writeAsString(contentType);
      } catch (_) {
        // 类型信息写失败不影响图片读取（读取时按 jpg 兜底）
      }
      _imgCacheBytes = (_imgCacheBytes ?? 0) + (await finalFile.length());
      _maybePruneImgCache();
    } catch (_) {
      // 播放器 / 图片组件提前断开：半截文件不能留在缓存里。
      try {
        await sink?.close();
      } catch (_) {}
      try {
        if (await temp.exists()) await temp.delete();
      } catch (_) {}
      try {
        await res.close();
      } catch (_) {}
    } finally {
      _imgCacheInflight.remove(cacheKey);
      if (!writeDone.isCompleted) writeDone.complete();
    }
  }

  String _imgCacheKey(String target, String referer) =>
      sha1.convert(utf8.encode('$target\u0001$referer')).toString();

  Future<Directory?> _ensureImgCacheDir() async {
    final dir = _imgCacheDir;
    if (dir == null) return null;
    try {
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    } catch (_) {
      return null;
    }
  }

  /// 命中磁盘缓存时直接返回文件；返回 false 表示需要回源。
  Future<bool> _serveImgCache(HttpRequest request, String key) async {
    final dir = _imgCacheDir;
    if (dir == null) return false;
    final file = File(p.join(dir.path, '$key.img'));
    try {
      if (!await file.exists()) return false;
      final length = await file.length();
      if (length <= 0) {
        await file.delete();
        return false;
      }
      final res = request.response;
      var type = 'image/jpeg';
      try {
        final meta = File(p.join(dir.path, '$key.type'));
        if (await meta.exists()) {
          final value = (await meta.readAsString()).trim();
          if (value.startsWith('image/')) type = value;
        }
      } catch (_) {
        // 类型文件损坏时按 jpg 兜底
      }
      res.statusCode = 200;
      res.headers.set(HttpHeaders.contentTypeHeader, type);
      res.headers.set(HttpHeaders.cacheControlHeader, 'public, max-age=604800');
      res.headers.contentLength = length;
      if (request.method == 'HEAD') {
        await res.close();
        return true;
      }
      await file.openRead().pipe(res);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 缓存超过 256MB 时在后台按最旧优先淘汰到 200MB。
  void _maybePruneImgCache() {
    final bytes = _imgCacheBytes;
    if (bytes == null || bytes < _imgCacheLimitBytes) return;
    unawaited(_pruneImgCache());
  }

  Future<void> _pruneImgCache() async {
    final dir = _imgCacheDir;
    if (dir == null) return;
    final entries = <({File file, int size, DateTime at})>[];
    var total = 0;
    try {
      await for (final entity in dir.list()) {
        if (entity is! File || !entity.path.endsWith('.img')) continue;
        try {
          final stat = await entity.stat();
          total += stat.size;
          entries.add((file: entity, size: stat.size, at: stat.modified));
        } catch (_) {
          // 单个文件读不到就跳过
        }
      }
    } catch (_) {
      return;
    }
    if (total <= _imgCacheWaterBytes) {
      _imgCacheBytes = total;
      return;
    }
    entries.sort((a, b) => a.at.compareTo(b.at));
    for (final entry in entries) {
      if (total <= _imgCacheWaterBytes) break;
      try {
        await entry.file.delete();
        final meta = File(
          '${entry.file.path.substring(0, entry.file.path.length - 4)}.type',
        );
        if (await meta.exists()) await meta.delete();
        total -= entry.size;
      } catch (_) {
        // 被占用的文件下次再删
      }
    }
    _imgCacheBytes = total;
  }

  /// 蜘蛛调试口：`/debug/spider`。
  ///
  /// 默认关闭（[SpiderDebugService.enabled]），关闭时一律 403 —— 这个路由能
  /// 执行任意蜘蛛脚本，不能因为「本机」就默认敞开。跨站请求已在 `_handle`
  /// 里按敏感路由拒绝（HTTPS 页面的跨站请求拦不住，同理任何未授权调用）。
  Future<void> _handleSpiderDebug(HttpRequest request) async {
    final res = request.response;
    final service = debugService;
    if (service == null || !service.enabled) {
      return await _debugJson(res, 403, {'error': '蜘蛛调试未开启'});
    }
    final rest = request.uri.path.substring('/debug/spider'.length);
    try {
      if (request.method == 'POST' && rest == '/session') {
        final session = service.create();
        return await _debugJson(res, 200, {'session': session.id});
      }
      final session = service.find(request.uri.queryParameters['session']);
      if (session == null) {
        return await _debugJson(res, 401, {'error': '调试会话不存在或已过期'});
      }
      if (request.method == 'DELETE') {
        service.remove(session.id);
        return await _debugJson(res, 200, session.snapshot().toJson());
      }
      if (request.method == 'GET') {
        return await _debugJson(res, 200, session.snapshot().toJson());
      }
      if (request.method == 'POST' && rest == '/cancel') {
        return await _debugJson(res, 200, session.cancel().toJson());
      }
      if (request.method == 'POST' && rest.isEmpty) {
        final raw = await utf8.decodeStream(request);
        if (raw.length > 64 * 1024) {
          return await _debugJson(res, 413, {'error': '请求体过大'});
        }
        Map<String, dynamic> body;
        try {
          final decoded = jsonDecode(raw);
          if (decoded is! Map) throw const FormatException('需要 JSON 对象');
          body = Map<String, dynamic>.from(decoded);
        } catch (e) {
          return await _debugJson(res, 400, {'error': '请求体不是有效 JSON：$e'});
        }
        final parsed = parseSpiderDebugRequest(body);
        final runner = _spiderDebugRunner;
        if (runner == null) {
          return await _debugJson(res, 503, {'error': '调试执行器未就绪'});
        }
        final snapshot = await session.run(
          runner: runner,
          method: parsed.method,
          args: parsed.args,
          timeout: parsed.timeout,
        );
        return await _debugJson(res, 200, snapshot.toJson());
      }
      return await _debugJson(res, 404, {'error': '未知的调试路由'});
    } on SpiderDebugException catch (e) {
      return await _debugJson(res, 409, {'error': e.message});
    }
  }

  /// 调试执行器（由 main 注入，实际调用 SourceService）。
  SpiderDebugRunner? _spiderDebugRunner;

  set spiderDebugRunner(SpiderDebugRunner? runner) =>
      _spiderDebugRunner = runner;

  Future<void> _debugJson(
    HttpResponse res,
    int status,
    Map<String, dynamic> body,
  ) async {
    res.statusCode = status;
    res.headers.set('content-type', 'application/json; charset=utf-8');
    res.headers.set('cache-control', 'no-store');
    res.add(utf8.encode(jsonEncode(body)));
    await res.close();
  }

  Future<void> _handleLiveProxy(
    HttpRequest request, {
    bool guardPrivate = false,
  }) async {
    final res = request.response;
    final query = request.uri.queryParameters;
    final doValue = (query['do'] ?? '').trim().toLowerCase();
    // 小白/加固壳启动时会探 9978~9999 的 `/proxy?do=ck`，应答体必须等于 `ok`
    // 才会把本机 9978 当作宿主代理。之前这里回 400，壳拿到的端口是 -1，
    // 它生成的 m3u8 内部分片地址也会带着 `-1`，播放器随后直接报
    // `invalid or unsupported media`（只在顶层地址改端口的兜底救不回来）。
    if (doValue == 'ck') return _text(res, 200, 'ok');
    // 宿主网盘路由：爪/壳常把播放地址指向 App 的 `do=pan`（网盘直链），桌面端补实现。
    if (doValue == 'pan') return _handlePanProxy(request);
    // 通用宿主代理：`do=proxy` / `do=url` / `do=img`（老 TVBox 宿主约定）。
    if (doValue == 'proxy' || doValue == 'url' || doValue == 'img') {
      return _handleUrlProxy(request, guardPrivate: guardPrivate);
    }
    if (doValue != 'live') {
      // 壳自己的宿主路由（如 `do=hmys`）依赖该 JVM 内存里的状态（Cookie / 密钥 /
      // 签名），App 侧无法重放 —— 有常驻取流 JVM 时整条 query 原样转发过去。
      final jvmPort = _jvmProxyPort();
      if (jvmPort > 0 && jvmPort != _port) {
        return _forwardJvmProxy(request, jvmPort);
      }
      // 其它宿主路由（`do=py` / `do=hxq` 等）：只要有可转发的 url 就按通用代理处理，
      // 否则明确报错，避免壳拿到 404/400 后误判成空结果。
      if ((query['url'] ?? query['u'] ?? '').trim().isNotEmpty) {
        return _handleUrlProxy(request, guardPrivate: guardPrivate);
      }
      return _text(res, 400, 'do=$doValue 未实现（可用的 do=live/pan/proxy）');
    }
    final type = (query['type'] ?? 'txt').trim();
    if (type == '3') return _text(res, 501, '直播蜘蛛源当前由 App 直接调用，不经中继');
    final ext = (query['ext'] ?? '').trim();
    if (ext.isEmpty) return _text(res, 400, '缺少 ext');
    final target = _resolveExt(ext);
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(target)) {
      return _text(res, 400, '直播订阅地址无效');
    }
    if (guardPrivate && RelayAccessPolicy.isPrivateTarget(target)) {
      return _text(res, 403, '禁止访问本机/内网地址');
    }
    // 用户为某个直播接口指定的 UA 同样适用于壳/蜘蛛经宿主代理取的这份直播单；
    // 只有**命中的接口规则**才覆盖，全局默认 UA 不动这里 —— 壳系的
    // TVBoxWin/0.1 是上游约定，换成别的可能直接取不到单。
    final ruleUa = LiveUaPolicy.current.matchRule(target);
    final opened = await _open(
      target,
      headers: {'User-Agent': ruleUa ?? 'Mozilla/5.0 TVBoxWin/0.1'},
      method: request.method,
    );
    final upstream = opened.response;
    if (guardPrivate && RelayAccessPolicy.isPrivateTarget(opened.finalUrl)) {
      await upstream.drain<void>();
      return _text(res, 403, '禁止访问本机/内网地址');
    }
    res.statusCode = upstream.statusCode;
    _copyHeader(upstream, res, HttpHeaders.contentTypeHeader);
    _copyHeader(upstream, res, HttpHeaders.contentLengthHeader);
    if (request.method == 'HEAD') {
      await res.close();
      return;
    }
    await upstream.pipe(res);
  }

  /// `/proxy/<jvmPort>?...`：旧宿主入口形态，转发到该 JVM 内的宿主代理。
  Future<void> _handleJvmProxyPath(HttpRequest request) async {
    final port = int.tryParse(request.uri.path.substring('/proxy/'.length));
    // 壳有时会把自己的发现端口（9978）再拼进路径；这种「自引用」按当前
    // 常驻取流 JVM 转发。其余只接管确定性分配段，避免把本机任意端口暴露成上游。
    final jvmPort = port == null || port == _port || port <= 0
        ? _jvmProxyPort()
        : (port >= 19970 && port <= 19999 ? port : 0);
    if (jvmPort <= 0) {
      return _text(request.response, 502, '没有可用的取流 JVM 代理');
    }
    return _forwardJvmProxy(request, jvmPort);
  }

  /// 把壳自己的 `/proxy` 路由整条转发到蜘蛛 JVM 内的宿主代理。
  ///
  /// 加固壳的播放清单（如 `do=hmys`）会在分片地址里继续带同一套 query，
  /// 只有该 JVM 内存里的 Cookie / 密钥 / 签名能解；App 侧不能也不该重放。
  Future<void> _forwardJvmProxy(HttpRequest request, int port) async {
    if (await _tryForwardJvmProxy(request, port, acceptErrorStatus: true)) {
      return;
    }
    await _text(request.response, 502, '取流 JVM 代理不可用');
  }

  /// 把 `/proxy` 转发到 JVM；返回 true 表示响应已交给客户端。
  ///
  /// [acceptErrorStatus] 为 false 时，上游 4xx/5xx 视为「这只 JVM 处理不了」：
  /// 排空响应并返回 false，调用方还能改走本地解链（`do=pan` 的兜底链要用）。
  Future<bool> _tryForwardJvmProxy(
    HttpRequest request,
    int port, {
    bool acceptErrorStatus = false,
  }) async {
    final res = request.response;
    final rawQuery = request.uri.query;
    final target =
        'http://127.0.0.1:$port/proxy'
        '${rawQuery.isEmpty ? '' : '?$rawQuery'}';
    final headers = <String, String>{};
    for (final name in const [
      HttpHeaders.rangeHeader,
      HttpHeaders.userAgentHeader,
      HttpHeaders.refererHeader,
      HttpHeaders.acceptHeader,
      HttpHeaders.cookieHeader,
    ]) {
      final value = request.headers.value(name);
      if (value != null && value.isNotEmpty) headers[name] = value;
    }
    HttpClientResponse upstream;
    try {
      upstream = (await _open(
        target,
        headers: headers,
        method: request.method,
        range: request.headers.value(HttpHeaders.rangeHeader),
      )).response;
    } catch (e) {
      AppLog.w('relay', '转发取流 JVM 失败：$e');
      return false;
    }
    if (!acceptErrorStatus && upstream.statusCode >= 400) {
      await upstream.drain<void>().catchError((Object _) {});
      AppLog.w('relay', '取流 JVM 未能处理该路由（HTTP ${upstream.statusCode}）');
      return false;
    }
    res.statusCode = upstream.statusCode;
    _copyHeader(upstream, res, HttpHeaders.contentTypeHeader);
    _copyHeader(upstream, res, HttpHeaders.contentLengthHeader);
    _copyHeader(upstream, res, HttpHeaders.acceptRangesHeader);
    _copyHeader(upstream, res, HttpHeaders.contentRangeHeader);
    _copyHeader(upstream, res, HttpHeaders.contentEncodingHeader);
    if (request.method == 'HEAD') {
      await res.close();
      return true;
    }
    await upstream.pipe(res);
    return true;
  }

  /// 宿主网盘路由 `do=pan`：把壳/爪返回的网盘分享（百度 / UC / 夸克）解成直链并中继。
  ///
  /// 兼容的入参（按常见宿主约定）：
  ///   · `site` / `provider`：baidu / uc / quark
  ///   · `url` / `u` / `share` / `s` / `target`：分享链接或描述符
  ///   · `pwd` / `code`：提取码
  ///   · `fileId` / `fsid`：本人盘文件 id（百度）
  Future<void> _handlePanProxy(HttpRequest request) async {
    final res = request.response;
    final q = request.uri.queryParameters;
    final provider = (q['site'] ?? q['provider'] ?? q['ck'] ?? '')
        .trim()
        .toLowerCase();
    final text = _panShareText(q, provider);
    final jvmPort = _jvmProxyPort();
    final shareId = (q['shareId'] ?? q['share_id'] ?? q['surl'] ?? '').trim();
    final fileToken = (q['fileToken'] ?? q['token'] ?? '').trim();
    final fileId = (q['fileId'] ?? q['fsid'] ?? '').trim();
    final name = (q['name'] ?? '').trim();
    final onlyFileId =
        shareId.isEmpty && fileToken.isEmpty && fileId.isNotEmpty;
    final tokens = _driveTokens();
    final baiduLike =
        provider.startsWith('baidu') ||
        text.startsWith('baidu@') ||
        text.contains('pan.baidu.com') ||
        text.contains('baidupcs.com');
    final quarkLike =
        provider.startsWith('quark') ||
        provider.contains('夸克') ||
        provider.contains('夸父') ||
        text.startsWith('quark@') ||
        text.contains('pan.quark.cn');
    final ucLike =
        provider.startsWith('uc') ||
        provider.contains('优汐') ||
        text.startsWith('uc@') ||
        text.contains('drive.uc.cn');
    if (text.isEmpty) {
      return _text(res, 400, 'do=pan 缺少分享地址/描述符');
    }

    NativeDriveLink? link;
    // ★ 只有 fileId 的百度请求：fs_id 往往是**分享者**的，不在本账号网盘里，
    //   `api/filemetas?dlink=1` 只会回 errno=0 + 空 info。
    //   宿主代理提供 `do=winbox-baidu-context&fileId=`：从壳内存里的
    //   shareFsIdMap / bdclndMap / ukMap 还原 share_id / uk / seKey。
    //   拿到后拼成百度描述符，走只读分享取链（不查本人盘、不转存）。
    if (onlyFileId && baiduLike && jvmPort > 0 && jvmPort != _port) {
      final ctx = await _baiduShareContext(jvmPort, fileId);
      if (ctx != null) {
        final descriptor = _baiduContextDescriptor(ctx, name: name);
        if (descriptor.isNotEmpty) {
          link = await resolveBaiduDirect(
            descriptor,
            cookie: (tokens['baidu'] ?? '').trim(),
            episodeName: name,
          );
          if (link.ok) {
            AppLog.i('relay', 'do=pan 百度分享上下文命中 shareId=${ctx['share_id']}');
          } else {
            AppLog.w('relay', 'do=pan 百度上下文解链失败：${link.reason}');
            link = null;
          }
        }
      }
    }

    // 常规解链：文本 / 描述符 / 分享链接 / 本人盘 fileId。
    // 只有 fileId 的百度请求已在上面专门处理，不再按本人盘查 filemetas。
    if (link == null && !(onlyFileId && baiduLike)) {
      if (baiduLike) {
        link = await resolveBaiduDirect(
          text,
          cookie: (tokens['baidu'] ?? '').trim(),
          episodeName: name,
        );
      } else if (quarkLike) {
        link = await resolveQuarkDirect(
          text,
          cookie: (tokens['quark'] ?? '').trim(),
          flag: (q['flag'] ?? provider).trim(),
          episodeName: name,
        );
      } else if (ucLike) {
        link = await resolveUcDirect(
          text,
          cookie: (tokens['uc'] ?? '').trim(),
          flag: (q['flag'] ?? provider).trim(),
          episodeName: name,
        );
      }
    }

    if (link == null || !link.ok || link.url.isEmpty) {
      AppLog.w('relay', 'do=pan 解链失败 provider=$provider ${link?.reason ?? ''}');
      // 本地解不了（典型：分享会话只在壳进程内存里）→ 交回 JVM 宿主代理。
      if (jvmPort > 0 && jvmPort != _port) {
        AppLog.i('relay', 'do=pan 改交 JVM 宿主代理 provider=$provider');
        if (await _tryForwardJvmProxy(request, jvmPort)) return;
      }
      // 最后兜底：fileId 确实可能是本人盘文件（不是分享者的 fs_id）。
      if (onlyFileId && baiduLike) {
        link = await resolveBaiduDirect(
          text,
          cookie: (tokens['baidu'] ?? '').trim(),
          episodeName: name,
        );
      }
    }
    if (link == null || !link.ok || link.url.isEmpty) {
      return _text(res, 502, '网盘解链失败：${link?.reason ?? '未识别的网盘'}');
    }
    AppLog.i('relay', 'do=pan 解链成功 ${redactUrl(link.url)}');
    final headers = <String, String>{...link.headers};
    final host = Uri.tryParse(link.url)?.host.toLowerCase() ?? '';
    if (host.contains('baidu') || host.contains('bdstatic')) {
      if (_headerValue(headers, HttpHeaders.userAgentHeader).isEmpty) {
        headers[HttpHeaders.userAgentHeader] = 'netdisk;P2SP;3.0.0;windows;;;';
      }
      if (_headerValue(headers, HttpHeaders.refererHeader).isEmpty) {
        headers[HttpHeaders.refererHeader] = 'https://pan.baidu.com/';
      }
    }
    await _streamTarget(request, link.url, headers, provider: provider);
  }

  /// 通用宿主代理 `do=proxy` / `do=url` / `do=img`：按 `url` 原样转发。
  Future<void> _handleUrlProxy(
    HttpRequest request, {
    bool guardPrivate = false,
  }) async {
    final res = request.response;
    final q = request.uri.queryParameters;
    final target = (q['url'] ?? q['u'] ?? q['target'] ?? '').trim();
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(target)) {
      return _text(res, 400, 'do=${q['do']} 缺少合法的 url');
    }
    if (guardPrivate && RelayAccessPolicy.isPrivateTarget(target)) {
      return _text(res, 403, '禁止访问本机/内网地址');
    }
    final provider = (q['ck'] ?? q['provider'] ?? '').trim();
    final headers = _headersFromQuery(q, provider);
    if (_headerValue(headers, HttpHeaders.userAgentHeader).isEmpty) {
      headers[HttpHeaders.userAgentHeader] =
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
          'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
    }
    await _streamTarget(
      request,
      target,
      headers,
      guardPrivate: guardPrivate,
      provider: provider,
    );
  }

  /// 把目标地址按 Range 透传给播放器（统一补 Content-Type/Length 等）。
  ///
  /// 网盘 CDN 的跨度限速对这条路径同样生效：`do=pan` 解出来的百度 / UC / 夸克
  /// 直链会经这里拉流，所以与 `/play` 用同一套夹取规则（仅限网盘线路）。
  Future<void> _streamTarget(
    HttpRequest request,
    String target,
    Map<String, String> headers, {
    bool guardPrivate = false,
    String provider = '',
  }) async {
    final res = request.response;
    final range = request.headers.value(HttpHeaders.rangeHeader);
    final opened = await _open(
      target,
      headers: headers,
      method: request.method,
      range: _shouldClampRange(provider, target) ? clampRange(range) : range,
    );
    final upstream = opened.response;
    if (guardPrivate && RelayAccessPolicy.isPrivateTarget(opened.finalUrl)) {
      await upstream.drain<void>();
      return _text(res, 403, '禁止访问本机/内网地址');
    }
    res.statusCode = upstream.statusCode;
    _copyHeader(upstream, res, HttpHeaders.contentTypeHeader);
    _copyHeader(upstream, res, HttpHeaders.contentLengthHeader);
    _copyHeader(upstream, res, HttpHeaders.acceptRangesHeader);
    _copyHeader(upstream, res, HttpHeaders.contentRangeHeader);
    if (request.method == 'HEAD') {
      await res.close();
      return;
    }
    await upstream.pipe(res);
  }

  /// 从 `do=pan` 的参数里拼出可解链的文本（分享链接 / 描述符 / 本人盘 fileId / shareId）。
  String _panShareText(Map<String, String> q, String provider) {
    for (final key in const [
      'url',
      'u',
      'share',
      's',
      'target',
      'link',
      'raw',
    ]) {
      final value = (q[key] ?? '').trim();
      if (value.isEmpty) continue;
      if (value.startsWith('baidu@') ||
          value.startsWith('uc@') ||
          value.startsWith('quark@') ||
          RegExp(r'^https?://', caseSensitive: false).hasMatch(value)) {
        final pwd = (q['pwd'] ?? q['code'] ?? '').trim();
        if (pwd.isNotEmpty && !value.contains('pwd=')) {
          final sep = value.contains('?') ? '&' : '?';
          return '$value${sep}pwd=$pwd';
        }
        return value;
      }
    }
    // 爪/壳的宿主约定：`do=pan&site=<网盘>&shareId=<surl>&fileId=<fsid>&fileToken=<sekey>`
    final shareId = (q['shareId'] ?? q['share_id'] ?? q['surl'] ?? '').trim();
    if (shareId.isNotEmpty) {
      if (RegExp(r'^https?://', caseSensitive: false).hasMatch(shareId)) {
        return shareId;
      }
      final pwd = (q['pwd'] ?? q['code'] ?? '').trim();
      if (provider.startsWith('baidu') || provider.isEmpty) {
        return 'https://pan.baidu.com/s/$shareId${pwd.isEmpty ? '' : '?pwd=$pwd'}';
      }
      final fileId = (q['fileId'] ?? q['file_id'] ?? '').trim();
      final token = (q['fileToken'] ?? q['token'] ?? '').trim();
      // 夸克 / UC 的原生解链只认描述符，不认 `do=pan&site=…` 文本；
      // 直接透传会让它们退化成「未识别分享链接」。
      final quarkLike =
          provider.startsWith('quark') ||
          provider.contains('夸克') ||
          provider.contains('夸父');
      final ucLike = provider.startsWith('uc') || provider.contains('优汐');
      if (quarkLike || ucLike) {
        return _panDescriptorText(
          quarkLike ? 'quark' : 'uc',
          shareId: shareId,
          fileId: fileId,
          fileToken: token,
          passcode: pwd,
          name: (q['name'] ?? '').trim(),
        );
      }
      return 'do=pan&site=$provider&shareId=$shareId'
          '&fileId=$fileId&fileToken=$token';
    }
    final fileId = (q['fileId'] ?? q['fsid'] ?? '').trim();
    if (fileId.isNotEmpty) {
      final site = provider.isEmpty ? 'baidu' : provider;
      return 'do=pan&site=$site&fileId=$fileId';
    }
    // 有的壳直接把 `名称[大小]__<fsid>` 描述符放进 name/desc。
    final desc = (q['desc'] ?? q['name'] ?? '').trim();
    if (desc.contains('__')) return desc;
    return '';
  }

  /// 把 `do=pan` 的 shareId / fileId / fileToken 拼成网盘描述符。
  String _panDescriptorText(
    String provider, {
    required String shareId,
    required String fileId,
    required String fileToken,
    required String passcode,
    required String name,
  }) {
    final data = <String, String>{
      'shareId': shareId,
      if (fileId.isNotEmpty) 'fileId': fileId,
      if (fileToken.isNotEmpty) 'share_fid_token': fileToken,
      if (passcode.isNotEmpty) 'passcode': passcode,
      if (name.isNotEmpty) 'name': name,
    };
    final encoded = base64Url
        .encode(utf8.encode(jsonEncode(data)))
        .replaceAll('=', '');
    return '$provider@$encoded';
  }

  /// 向常驻 JVM 的宿主代理要「百度分享上下文」。
  ///
  /// 壳解析分享后会把 `shareId → fsId 列表`、`BDCLND`、`uk` 留在内存里；
  /// 宿主代理的 `do=winbox-baidu-context` 会把它们还原成
  /// `{share_id, uk, fs_id, seKey}`（只读，不转存）。拿不到时返回 null。
  Future<Map<String, dynamic>?> _baiduShareContext(
    int port,
    String fileId,
  ) async {
    if (!RegExp(r'^\d+$').hasMatch(fileId)) return null;
    final target =
        'http://127.0.0.1:$port/proxy?do=winbox-baidu-context'
        '&fileId=${Uri.encodeQueryComponent(fileId)}';
    try {
      final opened = await _open(
        target,
        headers: const <String, String>{},
        method: 'GET',
      ).timeout(const Duration(seconds: 3));
      final upstream = opened.response;
      final bytes = <int>[];
      if (upstream.statusCode == 200) {
        await for (final chunk in upstream) {
          bytes.addAll(chunk);
          if (bytes.length > 64 * 1024) break;
        }
      } else {
        await upstream.drain<void>().catchError((Object _) {});
      }
      if (upstream.statusCode != 200 || bytes.isEmpty) return null;
      final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (e) {
      AppLog.w('relay', '读取百度分享上下文失败：$e');
      return null;
    }
  }

  /// 把 `winbox-baidu-context` 的结果拼成 `baidu@base64` 描述符。
  String _baiduContextDescriptor(
    Map<String, dynamic> ctx, {
    required String name,
  }) {
    String field(String key) => (ctx[key] ?? '').toString().trim();
    final shareId = field('share_id');
    final uk = field('uk');
    final fsid = field('fs_id');
    final sekey = field('seKey');
    if (!RegExp(r'^\d+$').hasMatch(shareId) ||
        !RegExp(r'^\d+$').hasMatch(uk) ||
        !RegExp(r'^\d+$').hasMatch(fsid) ||
        sekey.isEmpty) {
      return '';
    }
    final data = <String, String>{
      'shareId': shareId,
      'uk': uk,
      'fs_id': fsid,
      'seKey': sekey,
      if (name.isNotEmpty) 'name': name,
    };
    final encoded = base64Url
        .encode(utf8.encode(jsonEncode(data)))
        .replaceAll('=', '');
    return 'baidu@$encoded';
  }

  /// 大小写不敏感地取请求头值。
  String _headerValue(Map<String, String> headers, String name) {
    final lower = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == lower) return entry.value;
    }
    return '';
  }

  /// 大小写不敏感地覆盖请求头，避免 `Cookie` / `cookie` 同时存在。
  void _setHeader(Map<String, String> headers, String name, String value) {
    final lower = name.toLowerCase();
    headers.removeWhere((key, _) => key.toLowerCase() == lower);
    headers[name] = value;
  }

  Map<String, String> _headersFromQuery(
    Map<String, String> query,
    String provider,
  ) {
    final headers = <String, String>{};
    final headerToken = (query['hk'] ?? '').trim();
    if (headerToken.isNotEmpty) {
      final stored = _playHeaderSets[headerToken];
      if (stored != null) headers.addAll(stored);
    }
    // 兼容旧格式（ua / referer / cookie / h）直接放在 query 里的地址。
    final ua = (query['ua'] ?? '').trim();
    if (ua.isNotEmpty) headers.putIfAbsent('User-Agent', () => ua);
    final referer = (query['referer'] ?? '').trim();
    if (referer.isNotEmpty) headers.putIfAbsent('Referer', () => referer);
    final raw = (query['h'] ?? '').trim();
    if (raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            headers.putIfAbsent(
              entry.key.toString(),
              () => entry.value.toString(),
            );
          }
        }
      } catch (_) {
        // 非法扩展头忽略
      }
    }
    final cookie = (query['cookie'] ?? '').trim();
    if (cookie.isNotEmpty) headers.putIfAbsent('Cookie', () => cookie);
    if (provider.isNotEmpty) {
      final token = (_driveTokens()[provider] ?? '').trim();
      if (token.isNotEmpty) {
        final old = headers['Cookie'] ?? '';
        if (old.isEmpty) {
          headers['Cookie'] = token;
        } else if (!old.contains(token)) {
          // 蜘蛛已经给了完整 Cookie 时不再重复追加，避免 HLS 多级改写后
          // Cookie 越滚越长、把外部播放器的请求头顶爆。
          headers['Cookie'] = '$old; $token';
        }
      }
    }
    return headers;
  }

  Future<({HttpClientResponse response, String finalUrl})> _open(
    String url, {
    required Map<String, String> headers,
    required String method,
    String? range,
  }) async {
    final client = _client ??= HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..autoUncompress = false;

    Future<({HttpClientResponse response, String finalUrl})> send(
      HttpClient targetClient,
    ) => _openFollow(
      targetClient,
      url: url,
      headers: headers,
      method: method,
      range: range,
    );

    try {
      return await send(client);
    } on HandshakeException catch (e) {
      // 视频 CDN 常见「证书链缺中间证书 / 自签」：浏览器播放器通常放行，
      // Dart 的严格校验会直接拒绝。仅对无副作用的 GET/HEAD 用兼容客户端重试一次。
      if (method != 'GET' && method != 'HEAD') rethrow;
      final host = Uri.tryParse(url)?.host ?? '';
      AppLog.w('relay', 'TLS 证书校验失败，改用兼容模式重试 host=$host | $e');
      final insecure = _insecureClient ??= HttpClient()
        ..connectionTimeout = const Duration(seconds: 15)
        ..autoUncompress = false
        ..badCertificateCallback = (_, _, _) => true;
      return await send(insecure);
    }
  }

  /// 手动跟随重定向，并返回最终落地的 URL。
  ///
  /// ★ 不能依赖 Dart 的 `followRedirects`：它跟随 302 时会新建请求，而新建
  ///   请求已经带了默认 `User-Agent: Dart/x.y`，复制逻辑规定「新请求已有该头
  ///   就不复制」，于是调用方设置的 UA 被静默换掉。百度 dlink 的 302 目标
  ///   （`*.baidupcs.com`）正是按 UA 判防盗链，UA 一丢就恒定 403，播放器侧
  ///   只报 `invalid or unsupported media`。
  ///
  /// 每一跳都保留 User-Agent / Range / Referer（防盗链判定依据）；跨源时
  /// 丢弃 Cookie / Authorization 等账号凭据。最多 5 跳，与原 `maxRedirects` 一致。
  Future<({HttpClientResponse response, String finalUrl})> _openFollow(
    HttpClient targetClient, {
    required String url,
    required Map<String, String> headers,
    required String method,
    String? range,
  }) async {
    final original = Uri.parse(url);
    var current = original;
    for (var hop = 0; hop <= 5; hop++) {
      final req = await targetClient.openUrl(method, current);
      final crossOrigin = !_isSameOrigin(original, current);
      req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      headers.forEach((key, value) {
        if (crossOrigin && _isSensitiveHeaderOnRedirect(key)) return;
        req.headers.set(key, value);
      });
      if (range != null && range.isNotEmpty) {
        req.headers.set(HttpHeaders.rangeHeader, range);
      }
      req.followRedirects = false;
      final response = await req.close();
      final code = response.statusCode;
      final location = response.headers.value(HttpHeaders.locationHeader);
      if (code < 300 || code >= 400 || location == null || location.isEmpty) {
        return (response: response, finalUrl: current.toString());
      }
      // 丢弃这一跳的响应体，避免连接悬挂
      await response.drain<void>().catchError((Object _) {});
      current = current.resolve(location);
      // 只跟随 http(s)；其它协议原样交回（上层按状态码处理）
      if (!current.isScheme('http') && !current.isScheme('https')) {
        throw HttpException('重定向到不支持的协议：${current.scheme}');
      }
    }
    throw HttpException('重定向次数过多：$url');
  }

  static bool _isSameOrigin(Uri a, Uri b) =>
      a.isScheme(b.scheme) && a.host == b.host && a.port == b.port;

  /// 跨源重定向时不能继续携带的敏感头（与 Dart 内置策略同口径）。
  static bool _isSensitiveHeaderOnRedirect(String name) {
    switch (name.toLowerCase()) {
      case 'cookie':
      case 'cookie2':
      case 'authorization':
      case 'proxy-authorization':
      case 'www-authenticate':
      case 'proxy-authenticate':
        return true;
    }
    return false;
  }

  /// `/play` 的会话自愈：记录上游 `Set-Cookie`，401 / 403 时用新 Cookie 重试一次。
  ///
  /// 只对带 provider 的网盘源生效 —— 普通 HLS 源没有统一的 Cookie 作用域，
  /// 按域名/地址盲目共享 Cookie 反而会把 A 站凭据发给 B 站。
  Future<({HttpClientResponse response, String finalUrl})> _openPlayWithSession(
    String url, {
    required Map<String, String> headers,
    required String method,
    String? range,
    required String provider,
  }) async {
    var opened = await _open(
      url,
      headers: headers,
      method: method,
      range: range,
    );
    if (provider.isEmpty) return opened;
    _rememberPlayCookies(provider, opened.response);
    final retryable =
        (opened.response.statusCode == 401 ||
            opened.response.statusCode == 403) &&
        (method == 'GET' || method == 'HEAD');
    if (!retryable) return opened;

    final before = _headerValue(headers, HttpHeaders.cookieHeader);
    final refreshed = _applyPlayCookieJar(provider, before);
    if (refreshed.isEmpty || refreshed == before) {
      AppLog.w(
        'relay',
        '/play ${opened.response.statusCode} 且没有可用的新 Cookie '
            'provider=$provider url=${redactUrl(url)}',
      );
      return opened;
    }
    try {
      await opened.response.drain<void>();
    } catch (_) {
      // 旧响应体丢弃失败不影响重试
    }
    _setHeader(headers, HttpHeaders.cookieHeader, refreshed);
    AppLog.w(
      'relay',
      '/play ${opened.response.statusCode} → 用刷新后的 Cookie 重试一次 '
          'provider=$provider',
    );
    opened = await _open(url, headers: headers, method: method, range: range);
    _rememberPlayCookies(provider, opened.response);
    return opened;
  }

  /// 记录一次上游响应里的 Set-Cookie（同名覆盖、保留最近 N 条）。
  void _rememberPlayCookies(String provider, HttpClientResponse response) {
    final lines = response.headers[HttpHeaders.setCookieHeader];
    if (lines == null || lines.isEmpty) return;
    if (!_playCookieJar.containsKey(provider) &&
        _playCookieJar.length >= _playCookieProvidersMax) {
      _playCookieJar.remove(_playCookieJar.keys.first);
    }
    final jar = _playCookieJar.putIfAbsent(provider, () => <String, String>{});
    for (final line in lines) {
      final pair = _cookiePairOf(line);
      if (pair == null) continue;
      final name = _cookieNameOf(pair);
      if (name.isEmpty) continue;
      final value = pair.substring(pair.indexOf('=') + 1).trim();
      if (value.isEmpty) {
        // 服务端删 Cookie（空值 / Max-Age=0）时同步从会话里移除。
        jar.remove(name);
        continue;
      }
      jar.remove(name);
      jar[name] = pair;
    }
    while (jar.length > _playCookieMax) {
      jar.remove(jar.keys.first);
    }
  }

  /// 把会话 Cookie 合并进请求 Cookie：同名以会话里的新值覆盖。
  String _applyPlayCookieJar(String provider, String cookie) {
    final jar = _playCookieJar[provider];
    if (jar == null || jar.isEmpty) return cookie;
    final merged = <String, String>{};
    for (final part in cookie.split(';')) {
      final pair = _cookiePairOf(part);
      if (pair == null) continue;
      merged[_cookieNameOf(pair)] = pair;
    }
    for (final entry in jar.entries) {
      merged[entry.key] = entry.value;
    }
    return merged.values.join('; ');
  }

  /// 取 `Set-Cookie` 的第一段 `name=value`（忽略 Path / Domain / HttpOnly 等属性）。
  String? _cookiePairOf(String raw) {
    final first = raw.split(';').first.trim();
    if (first.isEmpty) return null;
    final index = first.indexOf('=');
    if (index <= 0) return null;
    return first;
  }

  String _cookieNameOf(String pair) =>
      pair.substring(0, pair.indexOf('=')).trim();

  /// DASH 清单的地址改写：只动**绝对 URL**，不动相对片段名。
  ///
  /// MPD 与 m3u8 的结构完全不同（XML 而非逐行文本），但需求一样：清单里的
  /// 分片地址必须换回中继，才能继续注入 Referer / UA / Cookie。B 站的
  /// `<BaseURL>` 指向 bilivideo CDN，不带 Referer 就 403。
  ///
  /// 只处理三种具体形态，避免误伤 XML 属性：
  ///   · `<BaseURL>https://…</BaseURL>`（B 站 / 常见 DASH 首选）
  ///   · `media="https://…"` / `initialization="https://…"`（SegmentTemplate）
  ///   · `sourceURL="https://…"`（部分封装工具）
  /// 相对地址交给播放器按清单基址解析，改写成中继反而会破坏它。
  String _rewriteMpd(
    String text,
    String baseUrl,
    Map<String, String> headers,
    String provider,
  ) {
    String wrap(String raw) {
      final abs = _resolveRef(baseUrl, raw);
      if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(abs)) {
        return raw;
      }
      return playUrl(abs, headers: headers, provider: provider);
    }

    var out = text.replaceAllMapped(
      RegExp(r'<BaseURL>([^<]+)</BaseURL>'),
      (m) => '<BaseURL>${wrap(m.group(1) ?? '')}</BaseURL>',
    );
    out = out.replaceAllMapped(
      RegExp(r'(media|initialization|sourceURL)="([^"]+)"'),
      (m) => '${m.group(1)}="${wrap(m.group(2) ?? '')}"',
    );
    return out;
  }

  String _rewritePlaylist(
    String text,
    String baseUrl,
    Map<String, String> headers,
    String provider,
  ) {
    final out = <String>[];
    final uriAttr = RegExp(r'URI="([^"]*)"');
    for (final raw in text.replaceAll('\r\n', '\n').split('\n')) {
      final line = raw.trimRight();
      if (line.isEmpty) {
        out.add(line);
        continue;
      }
      if (line.startsWith('#')) {
        out.add(
          line.replaceAllMapped(uriAttr, (m) {
            final abs = _resolveRef(baseUrl, m.group(1) ?? '');
            if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(abs)) {
              return m.group(0)!;
            }
            return 'URI="${playUrl(abs, headers: headers, provider: provider)}"';
          }),
        );
        continue;
      }
      final abs = _resolveRef(baseUrl, line);
      if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(abs)) {
        out.add(line);
      } else {
        out.add(playUrl(abs, headers: headers, provider: provider));
      }
    }
    return out.join('\n');
  }

  String _resolveRef(String base, String ref) {
    final value = ref.trim();
    if (value.isEmpty) return value;
    if (RegExp(
      r'^(https?:|data:|skd:|file:)',
      caseSensitive: false,
    ).hasMatch(value)) {
      return value;
    }
    try {
      return Uri.parse(base).resolve(value).toString();
    } catch (_) {
      return value;
    }
  }

  String _resolveExt(String ext) {
    final raw = ext.trim();
    if (RegExp(r'^https?://', caseSensitive: false).hasMatch(raw)) return raw;
    var s = raw
        .replaceAll(RegExp(r'\s'), '')
        .replaceAll('-', '+')
        .replaceAll('_', '/');
    while (s.length % 4 != 0) {
      s += '=';
    }
    try {
      return utf8.decode(base64.decode(s));
    } catch (_) {
      return raw;
    }
  }

  Future<List<int>> _readLimited(
    HttpClientResponse response, {
    int maxBytes = 8 << 20,
  }) async {
    final out = <int>[];
    await for (final chunk in response) {
      out.addAll(chunk);
      if (out.length >= maxBytes) break;
    }
    return out;
  }

  void _copyHeader(HttpClientResponse from, HttpResponse to, String name) {
    // `HttpHeaders.value()` 在同名头出现多次时直接抛
    // `HttpException: More than one value for header …`（上游 CDN 常重复下发
    // `cache-control: no-cache` / `no-store`），会让整段分片变成 502，播放器
    // 只能反复重试黑屏。这里按列表取：列表型头合并，其余取首个非空值。
    final values = from.headers[name];
    if (values == null || values.isEmpty) return;
    final listValue = name.toLowerCase() == HttpHeaders.cacheControlHeader;
    final value = values.length == 1
        ? values.first
        : (listValue ? values.join(', ') : values.first);
    if (value.isNotEmpty) to.headers.set(name, value);
  }

  /// 上游响应头取首个值（重复头不会抛异常）。
  String _responseHeader(HttpClientResponse response, String name) {
    final values = response.headers[name];
    return (values == null || values.isEmpty) ? '' : values.first;
  }

  /// 上游 `Content-Type` 的安全取值：畸形 / 重复时返回空串而不是中断整段下载。
  String _responseContentType(HttpClientResponse response) {
    try {
      return response.headers.contentType?.mimeType.toLowerCase() ?? '';
    } catch (_) {
      return '';
    }
  }

  String _decodeRel(String raw) {
    try {
      return Uri.decodeComponent(raw);
    } catch (_) {
      return raw;
    }
  }

  String _contentTypeOf(String path) {
    final ext = p.extension(path).toLowerCase();
    return switch (ext) {
      '.m3u8' => 'application/vnd.apple.mpegurl',
      '.ts' => 'video/mp2t',
      '.m4s' => 'video/iso.segment',
      '.mp4' => 'video/mp4',
      '.m4v' => 'video/mp4',
      '.webm' => 'video/webm',
      '.mkv' => 'video/x-matroska',
      '.flv' => 'video/x-flv',
      '.mov' => 'video/quicktime',
      '.mpd' => 'application/dash+xml',
      '.json' => 'application/json',
      '.js' => 'application/javascript',
      '.py' => 'text/plain; charset=utf-8',
      '.html' || '.htm' => 'text/html; charset=utf-8',
      '.css' => 'text/css; charset=utf-8',
      '.png' => 'image/png',
      '.jpg' || '.jpeg' => 'image/jpeg',
      '.gif' => 'image/gif',
      '.webp' => 'image/webp',
      '.xml' => 'application/xml',
      '.txt' || '.log' => 'text/plain; charset=utf-8',
      _ => 'application/octet-stream',
    };
  }

  Future<void> _text(HttpResponse res, int status, String message) async {
    res.statusCode = status;
    res.headers.set('content-type', 'text/plain; charset=utf-8');
    res.add(utf8.encode(message));
    await res.close();
  }
}
