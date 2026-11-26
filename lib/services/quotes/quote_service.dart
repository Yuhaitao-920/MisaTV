import 'dart:convert';

import '../../core/net/app_http.dart';
import '../local_store.dart';
import 'movie_quotes.dart';

/// 在线影视台词服务。
///
/// 数据来自一言（Hitokoto）公开语句包：影视（h.json）+ 动画（a.json）。
/// 解析时只保留中文台词、过滤占位出处与重复项，缓存 7 天后重新拉取；
/// 网络不可用时依次回落到上次缓存、内置精选台词。
class QuoteService {
  QuoteService(
    this._http,
    this._store, {
    this.cacheTtl = const Duration(days: 7),
  });

  final AppHttp _http;
  final LocalStore _store;
  final Duration cacheTtl;

  static const _bundles = ['h.json', 'a.json'];
  static const _bases = [
    'https://sentences-bundle.hitokoto.cn/sentences/',
    'https://cdn.jsdelivr.net/gh/hitokoto-osc/sentences-bundle@latest/sentences/',
    'https://raw.githubusercontent.com/hitokoto-osc/sentences-bundle/master/sentences/',
  ];

  List<MovieQuote> _pool = const [];
  Future<List<MovieQuote>>? _loading;
  bool _poolFresh = false;

  /// 当前内存中的台词池（可能还是内置兜底）。
  List<MovieQuote> get pool => _pool;

  /// 同步读取上次缓存，供界面首帧直接使用。
  List<MovieQuote> get cachedPool {
    if (_pool.isNotEmpty) return _pool;
    final cached = _readCache();
    if (cached != null && cached.quotes.isNotEmpty) {
      _pool = cached.quotes;
      _poolFresh = !cached.stale(cacheTtl);
    }
    return _pool;
  }

  /// 获取台词池：内存 → 有效缓存 → 在线拉取 → 过期缓存 → 内置兜底。
  Future<List<MovieQuote>> load({bool force = false}) {
    if (!force && _poolFresh && _pool.isNotEmpty) return Future.value(_pool);
    return _loading ??= _load(force: force).whenComplete(() => _loading = null);
  }

  Future<List<MovieQuote>> _load({required bool force}) async {
    final cached = _readCache();
    if (cached != null && cached.quotes.isNotEmpty) {
      _pool = cached.quotes;
      if (!force && !cached.stale(cacheTtl)) {
        _poolFresh = true;
        return _pool;
      }
    }
    final online = await _fetchOnline();
    if (online.isNotEmpty) {
      _pool = online;
      _poolFresh = true;
      await _writeCache(online);
      return _pool;
    }
    if (_pool.isNotEmpty) {
      _poolFresh = false;
      return _pool;
    }
    _pool = List<MovieQuote>.unmodifiable(movieQuotes);
    _poolFresh = false;
    return _pool;
  }

  Future<List<MovieQuote>> _fetchOnline() async {
    final lists = await Future.wait([
      for (final bundle in _bundles) _fetchBundle(bundle),
    ]);
    final merged = <MovieQuote>[];
    final seen = <String>{};
    for (final list in lists) {
      for (final quote in list) {
        if (seen.add('${quote.line}|${quote.title}')) merged.add(quote);
      }
    }
    return merged;
  }

  Future<List<MovieQuote>> _fetchBundle(String name) async {
    for (final base in _bases) {
      try {
        final res = await _http.getText(
          '$base$name',
          timeout: const Duration(seconds: 12),
        );
        final quotes = parseQuoteBundle(res.body);
        if (quotes.isNotEmpty) return quotes;
      } catch (_) {
        // 镜像站逐个回退，全部失败时由调用方使用缓存/兜底。
      }
    }
    return const [];
  }

  _CachedQuotes? _readCache() {
    final raw = _store.movieQuotesCacheJson;
    if (raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final list = decoded['quotes'];
      if (list is! List) return null;
      final quotes = <MovieQuote>[];
      for (final item in list) {
        if (item is! List || item.length < 2) continue;
        final line = item[0].toString().trim();
        final title = item[1].toString().trim();
        if (line.isEmpty || title.isEmpty) continue;
        quotes.add(MovieQuote(line: line, title: title));
      }
      if (quotes.isEmpty) return null;
      final fetchedAt = (decoded['fetchedAt'] as num?)?.toInt() ?? 0;
      return _CachedQuotes(fetchedAt: fetchedAt, quotes: quotes);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCache(List<MovieQuote> quotes) async {
    final payload = {
      'fetchedAt': DateTime.now().millisecondsSinceEpoch,
      'quotes': [
        for (final quote in quotes) [quote.line, quote.title],
      ],
    };
    await _store.saveMovieQuotesCacheJson(jsonEncode(payload));
  }
}

class _CachedQuotes {
  const _CachedQuotes({required this.fetchedAt, required this.quotes});

  final int fetchedAt;
  final List<MovieQuote> quotes;

  bool stale(Duration ttl) {
    if (fetchedAt <= 0) return true;
    final age = DateTime.now().millisecondsSinceEpoch - fetchedAt;
    return age >= ttl.inMilliseconds;
  }
}

/// 占位出处，搜索不到具体作品，直接丢弃。
const _genericTitles = <String>{
  '某电影',
  '某电视剧',
  '某动画',
  '某动漫',
  '某综艺',
  '某节目',
  '未知',
  '网络',
  '网友',
  '原创',
  '佚名',
  '无',
};

/// 解析一言语句包（JSON 数组），过滤纯外文、占位出处、超长与重复项。
List<MovieQuote> parseQuoteBundle(String json) {
  dynamic raw;
  try {
    raw = jsonDecode(json);
  } catch (_) {
    return const [];
  }
  if (raw is! List) return const [];
  final quotes = <MovieQuote>[];
  final seen = <String>{};
  for (final item in raw) {
    if (item is! Map) continue;
    final line = _cleanLine((item['hitokoto'] ?? '').toString());
    final title = _cleanTitle((item['from'] ?? '').toString());
    if (line.isEmpty || title.isEmpty) continue;
    if (!containsChinese(line)) continue;
    if (line.length > 60 || title.length > 40) continue;
    if (_genericTitles.contains(title)) continue;
    if (title.toLowerCase().contains('http') || title.contains('www.')) {
      continue;
    }
    if (!seen.add('$line|$title')) continue;
    quotes.add(MovieQuote(line: line, title: title));
  }
  return quotes;
}

String _cleanLine(String raw) {
  var line = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  line = line.replaceAll(RegExp(r'^[“"「『]+'), '');
  line = line.replaceAll(RegExp(r'[”"」』]+$'), '');
  line = line.replaceAll(RegExp(r'[。.]+$'), '');
  return line.trim();
}

String _cleanTitle(String raw) {
  var title = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  while (title.length > 2 && title.startsWith('《') && title.endsWith('》')) {
    title = title.substring(1, title.length - 1).trim();
  }
  return title;
}
