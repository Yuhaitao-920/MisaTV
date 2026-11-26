import 'dart:convert';

import '../../core/net/app_http.dart';
import '../../models/site_config.dart';

/// 解析接口（`parses[]`）的纯逻辑与调用链。
///
/// 顺序对齐旧版 Win-Box：
///   ① JSON 型接口（type 1/2）GET → POST 表单；
///   ② 网页型接口（type 0）交给 UI 注入的网页嗅探；
///   ③ 直接嗅探原始地址（无接口时的兜底）。
class ParseResolution {
  const ParseResolution({
    required this.url,
    this.headers = const {},
    this.via = '',
  });
  final String url;
  final Map<String, String> headers;
  final String via;
}

class SniffHit {
  const SniffHit({required this.url, this.headers = const {}});
  final String url;
  final Map<String, String> headers;
}

typedef SniffFn = Future<SniffHit?> Function(String url);

class ParseService {
  ParseService(this.http);
  final AppHttp http;

  static const int _maxJsonParses = 4;
  static const int _maxPageParses = 2;
  static const Duration _jsonTimeout = Duration(seconds: 8);
  static const Duration _budget = Duration(seconds: 45);

  Future<ParseResolution?> resolve(
    List<ParseBean> parses,
    String target, {
    SniffFn? sniff,
  }) async {
    final url = unwrapRelayUrl(target.trim());
    if (url.isEmpty ||
        !RegExp(r'^https?://', caseSensitive: false).hasMatch(url)) {
      return null;
    }
    if (isMediaUrl(url)) return ParseResolution(url: url, via: 'already-media');

    final deadline = DateTime.now().add(_budget);
    bool left() => DateTime.now().isBefore(deadline);

    final list = parses.where((p) {
      if (p.name == '超级解析' || p.type == 4) return false;
      return RegExp(r'^https?://', caseSensitive: false).hasMatch(p.url.trim());
    }).toList();

    for (final p
        in list.where((p) => p.type == 1 || p.type == 2).take(_maxJsonParses)) {
      if (!left()) break;
      final hit = await _tryJsonParse(p, url);
      if (hit != null) return hit;
    }

    if (sniff != null) {
      for (final p in list.where((p) => p.type == 0).take(_maxPageParses)) {
        if (!left()) break;
        final page = buildParseUrl(p.url, url);
        if (page.isEmpty) continue;
        final hit = await sniff(page);
        if (hit != null && !isErrorVideoUrl(hit.url)) {
          return ParseResolution(
            url: hit.url,
            headers: hit.headers,
            via: 'sniff:${p.name}',
          );
        }
      }
      if (left()) {
        final hit = await sniff(url);
        if (hit != null && !isErrorVideoUrl(hit.url)) {
          return ParseResolution(
            url: hit.url,
            headers: hit.headers,
            via: 'sniff:direct',
          );
        }
      }
    }
    return null;
  }

  Future<ParseResolution?> _tryJsonParse(ParseBean parse, String target) async {
    final url = buildParseUrl(parse.url, target);
    if (url.isEmpty) return null;
    try {
      final res = await http.getText(url, timeout: _jsonTimeout);
      final hit = extractParseResult(res.body);
      if (hit != null) {
        return ParseResolution(
          url: hit.url,
          headers: hit.headers,
          via: 'json:${parse.name}',
        );
      }
    } catch (_) {
      // GET 失败继续试 POST
    }
    try {
      final res = await http.postForm(
        parse.url,
        body: {'url': target},
        timeout: _jsonTimeout,
      );
      final hit = extractParseResult(res.body);
      if (hit != null) {
        return ParseResolution(
          url: hit.url,
          headers: hit.headers,
          via: 'json:${parse.name}',
        );
      }
    } catch (_) {
      // 单接口失败不影响其它接口
    }
    return null;
  }

  static String unwrapRelayUrl(String url) {
    if (!RegExp(
      r'^https?://(127\.0\.0\.1|localhost):\d+/play',
      caseSensitive: false,
    ).hasMatch(url)) {
      return url;
    }
    try {
      final uri = Uri.parse(url);
      final inner = uri.queryParameters['url'];
      if (inner != null &&
          RegExp(r'^https?://', caseSensitive: false).hasMatch(inner)) {
        return inner;
      }
    } catch (_) {
      // 非法 query 原样返回
    }
    return url;
  }

  static bool isMediaUrl(String url) {
    final value = url.trim();
    if (value.isEmpty || isErrorVideoUrl(value)) return false;
    return RegExp(
      r'\.(m3u8|mp4|flv|mkv|mov|m4v|mp2t|ts|m4s)([?#]|$)',
      caseSensitive: false,
    ).hasMatch(value);
  }

  static bool isErrorVideoUrl(String url) =>
      url.toLowerCase().contains('error.mp4') ||
      url.toLowerCase().contains('/mizhicdn/video/error');

  static String buildParseUrl(String parseUrl, String target) {
    final base = parseUrl.trim();
    final value = target.trim();
    if (base.isEmpty || value.isEmpty) return '';
    if (base.contains('{url}')) {
      return base.replaceAll('{url}', Uri.encodeQueryComponent(value));
    }
    if (RegExp(r'[=?&/]$').hasMatch(base)) return '$base$value';
    return '$base${base.contains('?') ? '&' : '?'}url=${Uri.encodeQueryComponent(value)}';
  }

  static ParseResolution? extractParseResult(String text) {
    final s = text.trim();
    if (s.isEmpty) return null;
    if (RegExp(r'^https?://', caseSensitive: false).hasMatch(s) &&
        !RegExp(r'[\s<>]').hasMatch(s) &&
        !isErrorVideoUrl(s)) {
      return ParseResolution(url: s);
    }
    dynamic root;
    try {
      root = jsonDecode(s);
    } catch (_) {
      final match = RegExp(r'\(([\s\S]*)\)\s*;?\s*$').firstMatch(s);
      if (match != null) {
        try {
          root = jsonDecode(match.group(1)!);
        } catch (_) {
          root = null;
        }
      }
    }
    if (root == null) return null;
    final urls = _collectUrls(root);
    if (urls.isEmpty) return null;
    return ParseResolution(url: urls.first, headers: _extractHeaders(root));
  }

  static const _urlKeys = <String>{
    'url',
    'playurl',
    'play_url',
    'videourl',
    'video_url',
    'video',
    'src',
    'source',
    'm3u8',
    'link',
    'path',
    'result',
    'data',
  };

  static List<String> _collectUrls(dynamic root) {
    final hits = <({String url, int score})>[];
    void visit(dynamic value, String key, int depth) {
      if (value == null || depth > 6) return;
      if (value is String) {
        var t = value.trim();
        if (t.startsWith('//')) t = 'https:$t';
        if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(t)) return;
        if (RegExp(r"[\s<>']").hasMatch(t) || isErrorVideoUrl(t)) return;
        var score = 0;
        if (isMediaUrl(t)) score += 4;
        if (_urlKeys.contains(key.toLowerCase())) score += 2;
        if (RegExp(
          r'\.(html?|php|jsp|aspx?)([?#]|$)',
          caseSensitive: false,
        ).hasMatch(t)) {
          score -= 3;
        }
        hits.add((url: t, score: score));
        return;
      }
      if (value is List) {
        for (final item in value) {
          visit(item, key, depth + 1);
        }
        return;
      }
      if (value is Map) {
        for (final entry in value.entries) {
          visit(entry.value, entry.key.toString(), depth + 1);
        }
      }
    }

    visit(root, '', 0);
    hits.sort((a, b) => b.score.compareTo(a.score));
    return hits.where((h) => h.score >= 0).map((h) => h.url).toList();
  }

  static Map<String, String> _extractHeaders(dynamic root) {
    final all = <String, String>{};
    void visit(dynamic value, int depth) {
      if (value == null || value is! Map || depth > 6) return;
      for (final entry in value.entries) {
        final key = entry.key.toString();
        final item = entry.value;
        if ((key == 'header' || key == 'headers') && item is Map) {
          for (final h in item.entries) {
            final hv = h.value?.toString().trim() ?? '';
            if (hv.isNotEmpty) all[h.key.toString()] = hv;
          }
        } else {
          visit(item, depth + 1);
        }
      }
    }

    visit(root, 0);
    final keep = <String, String>{};
    for (final entry in all.entries) {
      if (RegExp(
        r'^(cookie|ua|user-agent|referer)$',
        caseSensitive: false,
      ).hasMatch(entry.key)) {
        keep[entry.key] = entry.value;
      }
    }
    return keep;
  }
}
