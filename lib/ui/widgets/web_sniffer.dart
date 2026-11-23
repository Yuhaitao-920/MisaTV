import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/logging/app_log.dart';
import '../../core/logging/log_redact.dart';
import '../../services/parse/parse_service.dart';

const _desktopUserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

/// 最多进入几层播放器 iframe：外壳页 → 播放器页 → 播放器内嵌页。
const _maxFrameHops = 2;

bool _sniffing = false;

/// 打开一个隐藏的 WebView 嗅探页面里的媒体地址（m3u8 / mp4 / flv）。
///
/// 优先 m3u8；命中 mp4/flv 会再等 1.5 秒收集更好候选。最多同时一个嗅探窗口。
/// 动漫站（Kazumi）常见「外壳页 + 播放器 iframe」结构：顶层没抓到媒体时，
/// 会自动进入最大的播放器 iframe，避免跨域 iframe 里的清单完全看不到。
/// [headers] 用于 Kazumi 等需要特定 UA / Referer 的动漫站。
Future<SniffHit?> sniffWebMedia(
  BuildContext context,
  String url, {
  String click = '',
  Duration timeout = const Duration(seconds: 15),
  Map<String, String> headers = const {},
}) async {
  if (_sniffing) {
    AppLog.w('sniff', '已有嗅探窗口，忽略并发请求 ${redactUrl(url)}');
    return null;
  }
  _sniffing = true;
  final sw = Stopwatch()..start();
  AppLog.i(
    'sniff',
    '开始 ${redactUrl(url)} timeout=${timeout.inSeconds}s '
        'headers=${headers.keys.join(',')}',
  );
  try {
    final hit = await showGeneralDialog<SniffHit>(
      context: context,
      barrierDismissible: false,
      barrierLabel: '网页嗅探',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (ctx, _, _) =>
          _SniffDialog(url: url, click: click, timeout: timeout, headers: headers),
      transitionBuilder: (ctx, animation, _, child) =>
          FadeTransition(opacity: animation, child: child),
    );
    AppLog.i(
      'sniff',
      '结束 ${sw.elapsedMilliseconds}ms '
          '${hit == null ? '没有找到播放地址' : '命中 ${redactUrl(hit.url)}'}',
    );
    return hit;
  } catch (e) {
    AppLog.w('sniff', '嗅探窗口异常 ${redactUrl(url)}', e);
    return null;
  } finally {
    _sniffing = false;
  }
}

class _SniffDialog extends StatefulWidget {
  const _SniffDialog({
    required this.url,
    required this.click,
    required this.timeout,
    required this.headers,
  });

  final String url;
  final String click;
  final Duration timeout;
  final Map<String, String> headers;

  @override
  State<_SniffDialog> createState() => _SniffDialogState();
}

class _SniffDialogState extends State<_SniffDialog> {
  Timer? _deadline;
  Timer? _settle;
  Timer? _poll;
  bool _done = false;
  bool _scanning = false;
  bool _showWeb = false;
  String _status = '正在打开解析页…';
  String _best = '';
  int _bestRank = 0;
  String _pageUrl = '';
  bool _clicked = false;
  int _frameHops = 0;
  String _lastHoppedFrame = '';
  int _loadLogs = 0;
  final Stopwatch _elapsed = Stopwatch();
  DateTime? _deadlineAt;
  Duration _pausedRemaining = Duration.zero;
  late final Map<String, String> _requestHeaders;

  String get _userAgent => _requestHeaders['User-Agent'] ?? _desktopUserAgent;

  @override
  void initState() {
    super.initState();
    _pageUrl = widget.url;
    _elapsed.start();
    _requestHeaders = {...widget.headers};
    _requestHeaders.putIfAbsent('User-Agent', () => _desktopUserAgent);
    _startDeadline(widget.timeout);
  }

  void _startDeadline(Duration duration) {
    _deadline?.cancel();
    final safe = duration <= Duration.zero
        ? const Duration(seconds: 1)
        : duration;
    _deadlineAt = DateTime.now().add(safe);
    _deadline = Timer(safe, () {
      unawaited(_finish('超时 ${safe.inSeconds}s'));
    });
  }

  Duration get _remaining {
    final at = _deadlineAt;
    if (at == null) return _pausedRemaining;
    final left = at.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  /// 显示网页时暂停自动关闭：用户可能正在点「已满 18 岁」「Agree TOS」，
  /// 15 秒的固定窗口会在操作途中把嗅探关掉。
  void _pauseDeadline() {
    _pausedRemaining = _remaining;
    _deadline?.cancel();
    _deadline = null;
    _deadlineAt = null;
  }

  void _resumeDeadline({Duration extra = Duration.zero}) {
    final remaining =
        (_deadlineAt == null ? _pausedRemaining : _remaining) + extra;
    _pausedRemaining = Duration.zero;
    _startDeadline(remaining <= Duration.zero ? widget.timeout : remaining);
  }

  void _extendTimeout([Duration extra = const Duration(seconds: 30)]) {
    if (_showWeb) {
      _pausedRemaining += extra;
    } else {
      _startDeadline(_remaining + extra);
    }
    if (mounted) {
      setState(() => _status = '已延长 ${extra.inSeconds} 秒，继续嗅探…');
    }
    AppLog.i(
      'sniff',
      '延长超时 ${extra.inSeconds}s'
          '${_showWeb ? '（网页可见，自动关闭已暂停）' : '，剩余 ${_remaining.inSeconds}s'}',
    );
  }

  void _toggleWeb() {
    final show = !_showWeb;
    if (show) {
      _pauseDeadline();
    } else {
      _resumeDeadline(extra: const Duration(seconds: 30));
    }
    setState(() {
      _showWeb = show;
      _status = show ? '网页已打开，可手动完成页面上的确认' : '继续嗅探中…';
    });
    AppLog.i(
      'sniff',
      show ? '显示网页（暂停自动关闭）' : '隐藏网页（延长 30 秒）',
    );
  }

  @override
  void dispose() {
    _deadline?.cancel();
    _settle?.cancel();
    _poll?.cancel();
    super.dispose();
  }

  void _consider(String raw, {String source = '网络'}) {
    if (_done) return;
    final url = raw.trim();
    if (url.isEmpty || url.startsWith('blob:') || url.startsWith('data:')) return;
    if (_isJunkUrl(url)) return;
    final rank = _rank(url);
    if (rank <= 0 || rank <= _bestRank) return;
    _best = url;
    _bestRank = rank;
    AppLog.i(
      'sniff',
      '候选 rank=$rank 来源=$source ${redactUrl(url)}',
    );
    if (mounted) {
      setState(
        () => _status = rank >= 3
            ? '找到播放地址，正在确认…'
            : '找到候选地址，继续等待更高清线路…',
      );
    }
    if (rank >= 3) {
      _settle?.cancel();
      unawaited(_finish('命中 m3u8'));
      return;
    }
    // .ts / .m4s 多半是 HLS 分片，不能拿它当成品地址提前结束；
    // 只有完整的 mp4/flv 才进入 1.5 秒的确认等待。
    if (rank == 2) {
      _settle?.cancel();
      _settle = Timer(const Duration(milliseconds: 1500), () {
        unawaited(_finish('候选 mp4/flv'));
      });
    }
  }

  int _rank(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('.m3u8')) return 3;
    if (lower.contains('.mp4') || lower.contains('.flv')) return 2;
    if (lower.contains('.ts') || lower.contains('.m4s')) return 1;
    return 0;
  }

  /// 广告占位视频（agedm 这类站的播放页 HTML 里就有 adposter.mp4）不能当候选。
  bool _isJunkUrl(String url) {
    final lower = url.toLowerCase();
    const junk = <String>[
      'adposter',
      'advert',
      'adserver',
      '/ads/',
      'ad_',
      'banner',
      'poster',
      'placeholder',
      'loading',
      'logo',
      'sprite',
      'thumb',
      'hm.js',
      'google-analytics',
      'googletagmanager',
      'doubleclick',
    ];
    return junk.any(lower.contains);
  }

  bool _looksLikePlayerFrame(String url) {
    final lower = url.toLowerCase();
    const hints = <String>[
      'player',
      'play',
      '/vip',
      'cloudplay',
      'jx.',
      '/jx/',
      'parse',
      'embed',
      'iframe',
      'm3u8',
      'video',
    ];
    return hints.any(lower.contains);
  }

  String _pickFrame(Object? raw) {
    if (raw is! List) return '';
    var best = '';
    var bestScore = -1.0;
    for (final item in raw) {
      if (item is! Map) continue;
      final src = (item['src'] ?? '').toString().trim();
      if (src.isEmpty || !src.startsWith('http')) continue;
      if (_isJunkUrl(src)) continue;
      final w = (item['w'] as num?)?.toDouble() ?? 0;
      final h = (item['h'] as num?)?.toDouble() ?? 0;
      final player = _looksLikePlayerFrame(src);
      final area = w * h;
      if (area < 4000 && !player) continue;
      final score = area + (player ? 200000 : 0);
      if (score > bestScore) {
        bestScore = score;
        best = src;
      }
    }
    return best;
  }

  Future<void> _finish(String reason) async {
    if (_done) return;
    _done = true;
    _settle?.cancel();
    _deadline?.cancel();
    _poll?.cancel();
    AppLog.i(
      'sniff',
      '结束($reason) ${_elapsed.elapsedMilliseconds}ms '
          'best=${_best.isEmpty ? '无' : redactUrl(_best)} '
          'page=${redactUrl(_pageUrl)} frameHops=$_frameHops',
    );
    String? cookie;
    try {
      final cookies = await CookieManager.instance()
          .getCookies(url: WebUri(_pageUrl))
          .timeout(const Duration(seconds: 2));
      if (cookies.isNotEmpty) {
        cookie = cookies.map((c) => '${c.name}=${c.value}').join('; ');
      }
    } catch (_) {
      // CookieManager 在部分平台不可用；退回 UA/Referer
    }
    if (!mounted) return;
    Navigator.of(context).pop(
      _best.isEmpty
          ? null
          : SniffHit(
              url: _best,
              headers: {
                ..._requestHeaders,
                'User-Agent': _userAgent,
                'Referer': _pageUrl,
                if (cookie != null && cookie.isNotEmpty) 'Cookie': cookie,
              },
            ),
    );
  }

  Future<void> _onLoadStop(InAppWebViewController controller, WebUri? url) async {
    if (url != null) _pageUrl = url.toString();
    AppLog.i(
      'sniff',
      '页面加载完成 ${redactUrl(_pageUrl)} '
          '用时=${_elapsed.elapsedMilliseconds}ms',
    );
    await _maybeClick(controller);
    await _scan(controller);
    _poll ??= Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_scan(controller));
    });
  }

  Future<void> _scan(InAppWebViewController controller) async {
    if (_done || _scanning) return;
    _scanning = true;
    try {
      final result = await controller.evaluateJavascript(source: _scanScript);
      dynamic decoded = result;
      if (result is String) {
        if (result.isEmpty) return;
        try {
          decoded = jsonDecode(result);
        } catch (_) {
          return;
        }
      }
      if (decoded is! Map) return;
      final media = decoded['media'];
      if (media is List) {
        for (final item in media) {
          _consider(item.toString(), source: '页面扫描');
        }
      }
      // 播放器自己已经报「资源未同步 / 视频加载失败」：不必再等满超时。
      if (!_done &&
          decoded['failed'] == true &&
          _bestRank == 0 &&
          _elapsed.elapsed > const Duration(seconds: 6)) {
        unawaited(_finish('播放器提示资源不可用'));
        return;
      }
      // 顶层页面没有媒体请求时，进入播放器 iframe 再扫一遍：
      // maccms / 云播放器的 m3u8 都在 iframe 里，跨域时父页面访问不到。
      if (_done || _bestRank >= 2 || _frameHops >= _maxFrameHops) return;
      final frame = _pickFrame(decoded['frames']);
      if (frame.isEmpty || frame == _lastHoppedFrame || frame == _pageUrl) {
        return;
      }
      _lastHoppedFrame = frame;
      _frameHops++;
      _pageUrl = frame;
      AppLog.i(
        'sniff',
        '顶层没有媒体，进入播放器 iframe #$_frameHops ${redactUrl(frame)}',
      );
      if (mounted) setState(() => _status = '正在加载播放器页面…');
      await controller.loadUrl(
        urlRequest: URLRequest(
          url: WebUri(frame),
          headers: {
            ..._requestHeaders,
            'Referer': widget.url,
          },
        ),
      );
    } catch (e) {
      AppLog.w('sniff', '页面扫描失败 ${redactUrl(_pageUrl)}', e);
    } finally {
      _scanning = false;
    }
  }

  Future<void> _maybeClick(InAppWebViewController controller) async {
    if (_clicked || widget.click.trim().isEmpty) return;
    final parts = widget.click.split(';');
    if (parts.length < 2) return;
    final host = parts.first.trim();
    final selector = parts.sublist(1).join(';').trim();
    if (host.isEmpty || selector.isEmpty) return;
    if (!_pageUrl.contains(host)) return;
    _clicked = true;
    try {
      final sel = jsonEncode(selector);
      await controller.evaluateJavascript(
        source: 'document.querySelector($sel)?.click();',
      );
    } catch (_) {
      // 选择器不适用时忽略
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screen = MediaQuery.of(context).size;
    // 显示网页时把面板放大到可操作尺寸；clamp 兜住小屏。
    final panelWidth = _showWeb
        ? (screen.width - 80).clamp(360.0, 960.0).toDouble()
        : 340.0;
    final contentWidth = panelWidth - 44;
    final webHeight = _showWeb
        ? (screen.height - 260).clamp(240.0, 600.0).toDouble()
        : contentWidth * 9 / 16;
    return Center(
      child: Material(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        child: SizedBox(
          width: panelWidth,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 12),
                    Text('正在网页嗅探', style: theme.textTheme.titleMedium),
                  ],
                ),
                const SizedBox(height: 12),
                // 之前用 2x2 的隐藏 WebView，很多播放器 JS 拿不到有效视口，
                // 不会发起清单请求。这里给一个正常的 16:9 视口，并用不透明
                // 遮罩盖住页面内容（广告多，不适合直接展示）。
                //
                // 但部分站点的播放页要求先点「已满 18 岁」「Agree TOS」，
                // 隐藏状态下用户没法操作，只能等满 15 秒超时。所以提供
                // 「显示网页」：放大面板并拿掉遮罩，让页面可以正常点击；
                // 显示期间暂停自动关闭，隐藏后额外补 30 秒。
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    width: contentWidth,
                    height: webHeight,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        InAppWebView(
                          initialUrlRequest: URLRequest(
                            url: WebUri(widget.url),
                            headers: _requestHeaders,
                          ),
                          initialSettings: InAppWebViewSettings(
                            javaScriptEnabled: true,
                            mediaPlaybackRequiresUserGesture: false,
                            transparentBackground: true,
                            userAgent: _userAgent,
                          ),
                          // 动漫站常用 fetch/XHR 拉清单，加载完成后再抓会漏；
                          // 在文档开始时就挂 hook，把请求地址存进页面变量。
                          initialUserScripts: UnmodifiableListView([
                            UserScript(
                              source: _hookScript,
                              injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                            ),
                          ]),
                          // 必须给权限请求一个非空回复：Windows 插件（0.6.0）在
                          // PermissionRequestCallback 里直接 std::get，没有判空，
                          // Dart 返回 null 会让整个进程闪退。
                          onPermissionRequest: (controller, request) async =>
                              PermissionResponse(
                                action: PermissionResponseAction.DENY,
                              ),
                          onLoadStart: (controller, url) {
                            if (url == null) return;
                            if (_loadLogs < 6) {
                              _loadLogs++;
                              AppLog.i(
                                'sniff',
                                '开始加载 ${redactUrl(url.toString())}',
                              );
                            }
                            if (mounted) {
                              setState(() => _status = '正在加载解析页…');
                            }
                          },
                          onLoadStop: _onLoadStop,
                          onLoadResource: (controller, resource) =>
                              _consider(resource.url.toString()),
                          onReceivedError: (controller, request, error) {
                            if (request.isForMainFrame == true) {
                              AppLog.w(
                                'sniff',
                                '页面加载失败 ${redactUrl(request.url.toString())} '
                                    '${error.description}',
                              );
                              if (mounted) {
                                setState(
                                  () => _status =
                                      '解析页加载失败：${error.description}',
                                );
                              }
                            }
                          },
                          onReceivedHttpError: (controller, request, response) {
                            if (request.isForMainFrame == true) {
                              AppLog.w(
                                'sniff',
                                '页面 HTTP ${response.statusCode} '
                                    '${redactUrl(request.url.toString())}',
                              );
                            }
                          },
                        ),
                        if (!_showWeb)
                          Positioned.fill(
                            child: ColoredBox(
                              color: theme.colorScheme.surface,
                              child: Center(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                  ),
                                  child: Text(
                                    _status,
                                    textAlign: TextAlign.center,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.onSurface
                                          .withValues(alpha: 0.76),
                                      height: 1.5,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (_showWeb) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _status,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.72,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 2,
                    children: [
                      TextButton(
                        onPressed: _toggleWeb,
                        child: Text(_showWeb ? '隐藏网页' : '显示网页'),
                      ),
                      TextButton(
                        onPressed: () => _extendTimeout(),
                        child: const Text('延长 30 秒'),
                      ),
                      TextButton(
                        onPressed: () => unawaited(_finish('用户取消')),
                        child: const Text('取消'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static const String _hookScript = r'''
(function () {
  if (window.__kniephosSniff) return;
  window.__kniephosSniff = [];
  function push(u) {
    try {
      if (typeof u === 'string' && u.length > 0 && window.__kniephosSniff.length < 200) {
        window.__kniephosSniff.push(u);
      }
    } catch (e) {}
  }
  try {
    var open = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function (method, url) {
      push(url);
      return open.apply(this, arguments);
    };
  } catch (e) {}
  try {
    var origFetch = window.fetch;
    if (origFetch) {
      window.fetch = function (input) {
        try { push(typeof input === 'string' ? input : (input && input.url)); } catch (e) {}
        return origFetch.apply(this, arguments);
      };
    }
  } catch (e) {}
})();
''';

  static const String _scanScript = r'''
(function () {
  var media = [], frames = [], seen = {};
  function add(u, base) {
    if (!u || typeof u !== 'string') return;
    if (u.indexOf('blob:') === 0 || u.indexOf('data:') === 0) return;
    if (base && u.indexOf('http') !== 0) {
      try { u = new URL(u, base).href; } catch (e) { return; }
    }
    if (seen[u]) return;
    seen[u] = 1;
    if (media.length < 60) media.push(u);
  }
  try {
    var hooked = window.__kniephosSniff || [];
    for (var h = 0; h < hooked.length && h < 50; h++) add(hooked[h], location.href);
  } catch (e) {}
  try {
    performance.getEntriesByType('resource').forEach(function (e) {
      add(e.name, location.href);
    });
  } catch (e) {}
  document.querySelectorAll('video,audio').forEach(function (v) {
    add(v.currentSrc, location.href);
    add(v.src, location.href);
    try { v.muted = true; } catch (e) {}
    try {
      var p = v.play();
      if (p && p.catch) p.catch(function () {});
    } catch (e) {}
  });
  document.querySelectorAll('source').forEach(function (s) {
    add(s.src, location.href);
  });
  document.querySelectorAll('embed,object').forEach(function (o) {
    add(o.src || o.getAttribute('data'), location.href);
  });
  document.querySelectorAll('meta[property="og:video"],meta[property="og:video:url"]').forEach(function (m) {
    add(m.getAttribute('content'), location.href);
  });
  var html = document.documentElement ? document.documentElement.innerHTML : '';
  var m = html.match(/https?:\/\/[^"'\s<>]+\.(?:m3u8|mp4|flv|m4s|ts)[^"'\s<>]*/gi) || [];
  for (var i = 0; i < m.length && i < 30; i++) add(m[i], location.href);
  document.querySelectorAll('iframe').forEach(function (f) {
    var src = f.src || f.getAttribute('data-src') || '';
    if (!src) return;
    var r = null;
    try { r = f.getBoundingClientRect(); } catch (e) {}
    frames.push({
      src: src,
      w: r ? Math.round(r.width) : 0,
      h: r ? Math.round(r.height) : 0
    });
    // 同源 iframe 内部的视频和请求也直接收集（跨域会抛异常，忽略即可）。
    try {
      var d = f.contentDocument;
      if (d) {
        d.querySelectorAll('video,source').forEach(function (v) {
          add(v.currentSrc || v.src, src);
        });
        f.contentWindow.performance.getEntriesByType('resource').forEach(function (e) {
          add(e.name, src);
        });
      }
    } catch (e) {}
  });
  var text = document.body ? (document.body.innerText || '') : '';
  var failed = /视频加载失败|资源未同步|播放失败|无法播放|not found/i.test(text);
  return JSON.stringify({ media: media, frames: frames, failed: failed });
})();
''';
}
