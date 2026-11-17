import 'dart:convert';

import '../../core/net/app_http.dart';
import 'discover_models.dart';

/// 豆瓣自带的选项表（[parseDoubanVocab] 拉取失败时用）。
const List<String> movieGenres = [
  '喜剧',
  '爱情',
  '动作',
  '科幻',
  '动画',
  '悬疑',
  '犯罪',
  '惊悚',
  '冒险',
  '音乐',
  '历史',
  '奇幻',
  '恐怖',
  '战争',
  '传记',
  '歌舞',
  '武侠',
  '灾难',
  '西部',
  '纪录片',
  '短片',
];
const List<String> movieRegions = [
  '华语',
  '欧美',
  '韩国',
  '日本',
  '中国大陆',
  '美国',
  '中国香港',
  '中国台湾',
  '英国',
  '法国',
  '德国',
  '意大利',
  '西班牙',
  '印度',
  '泰国',
  '俄罗斯',
  '加拿大',
  '澳大利亚',
  '爱尔兰',
  '瑞典',
  '巴西',
  '丹麦',
];
const List<String> tvRegions = [
  '华语',
  '欧美',
  '国外',
  '韩国',
  '日本',
  '中国大陆',
  '中国香港',
  '美国',
  '英国',
  '泰国',
  '中国台湾',
  '意大利',
  '法国',
  '德国',
  '西班牙',
  '俄罗斯',
  '瑞典',
  '巴西',
  '丹麦',
  '印度',
  '加拿大',
  '爱尔兰',
  '澳大利亚',
];
const List<String> tvSubtypes = [
  '美剧',
  '英剧',
  '韩剧',
  '日剧',
  '国产剧',
  '港剧',
  '日本动画',
  '纪录片',
];
const List<ExploreSort> doubanSorts = [
  ExploreSort(id: 'T', label: '综合排序'),
  ExploreSort(id: 'U', label: '近期热度'),
  ExploreSort(id: 'R', label: '按时间'),
  ExploreSort(id: 'S', label: '高分优先'),
];

const List<DiscoverSection> _sectionDefs = [
  DiscoverSection(id: 'movie_hot_gaia', title: '豆瓣热门电影', items: []),
  DiscoverSection(id: 'movie_showing', title: '正在上映', items: []),
  DiscoverSection(id: 'movie_top250', title: '豆瓣高分电影', items: []),
  DiscoverSection(id: 'tv_hot', title: '豆瓣热门剧集', items: []),
  DiscoverSection(id: 'tv_chinese_best_weekly', title: '华语剧集口碑榜', items: []),
];

class _Cached<T> {
  _Cached(this.at, this.value);
  final DateTime at;
  final T value;
}

class _RexxarResp {
  const _RexxarResp(this.status, this.text);
  final int status;
  final String text;
}

/// 豆瓣数据层：详情元数据补全（封面 / 简介 / 评分 / 演职员 / 相关推荐）与卡片封面兜底。
///
/// 豆瓣接口有风控：连续 3 次 403/429 后本会话暂停 10 分钟，避免把整页拖死。
/// 所有失败都返回空结果，不向界面抛错。
class DiscoverService {
  DiscoverService(this._http);

  final AppHttp _http;

  static const _base = 'https://m.douban.com/rexxar/api/v2';
  static const _pageSize = 20;
  static const _maxTotal = 500;
  static const _sectionsTtl = Duration(hours: 6);
  static const _vocabTtl = Duration(hours: 24);
  static const _cooldown = Duration(minutes: 10);

  final Map<String, _Cached<ExplorePage>> _pages = {};
  final Map<String, _Cached<List<DiscoverItem>>> _sectionCache = {};
  final Map<String, _Cached<DoubanSubject?>> _subjectCache = {};
  final Map<String, _Cached<DoubanInfo?>> _infoCache = {};
  final Map<String, _Cached<DoubanDetailExtra?>> _extraCache = {};
  final Map<String, _Cached<List<String>>> _suggestCache = {};
  _Cached<ExploreVocabulary>? _vocabCache;

  int _blockedStreak = 0;
  DateTime? _breakerUntil;

  /// `subject_suggest` 被限流（稳定返回空数组）后，短时间内直接跳过它，
  /// 省掉一次必然失败的请求，让 HTML 搜索兜底更快出结果。
  DateTime? _suggestEmptyUntil;

  /// 联想 / HTML 搜索被 403 风控后同样短路 10 分钟。
  ///
  /// 2026-11 起这两个接口对无登录态的固定 IP 基本恒定 403，每次请求还要
  /// 白等 0.3~0.8 秒；不短路的话一屏 20 张卡片光 403 就要排好几秒。
  DateTime? _suggestBlockedUntil;
  DateTime? _htmlSearchBlockedUntil;

  static const _headers = {
    'Accept': 'application/json',
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0 Safari/537.36',
    'Referer': 'https://m.douban.com/',
  };

  bool get breakerOpen {
    final until = _breakerUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  Future<_RexxarResp> _get(
    String url, {
    Duration timeout = const Duration(seconds: 12),
    Map<String, String> headers = const {},
  }) async {
    try {
      final res = await _http.getText(
        url,
        headers: headers.isEmpty ? _headers : {..._headers, ...headers},
        timeout: timeout,
      );
      return _RexxarResp(res.statusCode, res.body);
    } on AppHttpException catch (e) {
      return _RexxarResp(e.statusCode ?? 0, e.message);
    } catch (_) {
      return const _RexxarResp(0, '');
    }
  }

  void _noteStatus(int status) {
    if (status == 200) {
      _blockedStreak = 0;
      _breakerUntil = null;
      return;
    }
    if (status != 403 && status != 429) return;
    _blockedStreak++;
    if (_blockedStreak >= 3) _breakerUntil = DateTime.now().add(_cooldown);
  }

  /// 首页榜单（5 个豆瓣榜单，顺序请求，单片失败跳过）。
  Future<List<DiscoverSection>> loadSections({bool refresh = false}) async {
    final fresh = <DiscoverSection>[];
    for (final def in _sectionDefs) {
      final cached = _sectionCache[def.id];
      final mediaType = def.id.startsWith('tv') ? 'tv' : 'movie';
      if (!refresh &&
          cached != null &&
          DateTime.now().difference(cached.at) < _sectionsTtl) {
        fresh.add(
          DiscoverSection(id: def.id, title: def.title, items: cached.value),
        );
        continue;
      }
      if (breakerOpen) {
        if (cached != null) {
          fresh.add(
            DiscoverSection(id: def.id, title: def.title, items: cached.value),
          );
        }
        continue;
      }
      final resp = await _get(
        '$_base/subject_collection/${def.id}/items?start=0&count=$_pageSize',
      );
      _noteStatus(resp.status);
      if (resp.status != 200) {
        if (cached != null) {
          fresh.add(
            DiscoverSection(id: def.id, title: def.title, items: cached.value),
          );
        }
        continue;
      }
      final items = parseDoubanCollectionItems(_decode(resp.text), mediaType);
      if (items.isEmpty) {
        if (cached != null) {
          fresh.add(
            DiscoverSection(id: def.id, title: def.title, items: cached.value),
          );
        }
        continue;
      }
      _sectionCache[def.id] = _Cached(DateTime.now(), items);
      fresh.add(DiscoverSection(id: def.id, title: def.title, items: items));
    }
    return fresh;
  }

  /// 在线词表（类型 / 地区 / 排序）；任一失败回退内置快照。
  Future<ExploreVocabulary> loadVocabulary() async {
    final cached = _vocabCache;
    if (cached != null && DateTime.now().difference(cached.at) < _vocabTtl) {
      return cached.value;
    }
    if (breakerOpen) return _builtinVocabulary;

    final results = await Future.wait([
      _loadOneVocab('movie'),
      _loadOneVocab('tv'),
    ]);
    final movie = results[0];
    final tv = results[1];
    if (movie == null || tv == null) return _builtinVocabulary;
    final vocab = ExploreVocabulary(movie: movie, tv: tv, source: 'douban');
    _vocabCache = _Cached(DateTime.now(), vocab);
    return vocab;
  }

  Future<ExploreVocab?> _loadOneVocab(String mediaType) async {
    final resp = await _get(
      buildExploreUrl(mediaType, ExploreQuery(mediaType: mediaType, count: 1)),
      timeout: const Duration(seconds: 10),
    );
    _noteStatus(resp.status);
    if (resp.status != 200) return null;
    try {
      return parseDoubanVocab(_decode(resp.text), mediaType);
    } catch (_) {
      return null;
    }
  }

  /// 分类浏览一页。失败 / 风控中返回空页。
  Future<ExplorePage> loadCategory(ExploreQuery query) async {
    final mediaType = query.mediaType == 'tv' ? 'tv' : 'movie';
    final start = query.start.clamp(0, _maxTotal);
    final empty = ExplorePage(start: start);
    if (breakerOpen) return empty;
    final url = buildExploreUrl(mediaType, query);
    final cached = _pages[url];
    if (cached != null && DateTime.now().difference(cached.at) < _sectionsTtl) {
      return cached.value;
    }
    final resp = await _get(url);
    _noteStatus(resp.status);
    if (resp.status != 200) return empty;
    final Object? json;
    try {
      json = _decode(resp.text);
    } catch (_) {
      return empty;
    }
    final items = parseDoubanExploreItems(json, mediaType);
    final map = json is Map ? json : const <String, dynamic>{};
    final respStart = _asInt(map['start']) ?? start;
    final total = _asInt(map['total']) ?? 0;
    final page = ExplorePage(
      items: items,
      start: respStart,
      total: total,
      hasMore:
          items.isNotEmpty &&
          respStart + items.length < (total > _maxTotal ? _maxTotal : total),
    );
    if (_pages.length >= 200) _pages.remove(_pages.keys.first);
    _pages[url] = _Cached(DateTime.now(), page);
    return page;
  }

  Object? _decode(String text) => jsonDecode(text);

  Object? _decodeOrNull(String text) {
    try {
      return jsonDecode(text);
    } catch (_) {
      return null;
    }
  }

  /// 搜索框联想：`subject_suggest` 一次返回多条影视标题（未登录可用）。
  ///
  /// 只做 best-effort：风控中或无网络时返回空数组，调用方继续用本地联想。
  Future<List<String>> suggestTitles(String query, {int limit = 8}) async {
    final q = query.trim();
    if (q.isEmpty || breakerOpen) return const [];
    final key = 'suggest|$q';
    final cached = _suggestCache[key];
    if (cached != null &&
        DateTime.now().difference(cached.at) < const Duration(hours: 24)) {
      return cached.value;
    }
    final resp = await _get(
      'https://movie.douban.com/j/subject_suggest'
      '?q=${Uri.encodeQueryComponent(q)}',
      timeout: const Duration(seconds: 5),
    );
    // 同上：联想接口的固定 403 不参与熔断。
    if (resp.status != 200) return const [];
    final rows = _decodeOrNull(resp.text);
    if (rows is! List) return const [];
    final out = <String>[];
    for (final row in rows) {
      if (row is! Map) continue;
      final type = (row['type'] ?? '').toString();
      final id = (row['id'] ?? '').toString();
      if ((type != 'movie' && type != 'tv') ||
          !RegExp(r'^\d{5,}$').hasMatch(id)) {
        continue;
      }
      final title = (row['title'] ?? '').toString().trim();
      if (title.isEmpty || out.contains(title)) continue;
      out.add(title);
      if (out.length >= limit) break;
    }
    if (out.isNotEmpty) {
      if (_suggestCache.length >= 300) {
        _suggestCache.remove(_suggestCache.keys.first);
      }
      _suggestCache[key] = _Cached(DateTime.now(), out);
    }
    return out;
  }

  /// 按片名找豆瓣条目（`subject_suggest`，未登录可用）。
  ///
  /// `subject_suggest` 现在对无 Cookie 的请求经常返回空数组（限流），
  /// 因此空结果时自动回退到 `search.douban.com` 的 HTML 搜索。
  Future<DoubanSubject?> findSubject(String name, {String year = ''}) async {
    final n = name.trim();
    if (n.isEmpty) return null;
    final key = '$n|$year';
    final cached = _subjectCache[key];
    if (cached != null &&
        DateTime.now().difference(cached.at) < const Duration(hours: 24)) {
      return cached.value;
    }
    final skipSuggest =
        (_suggestEmptyUntil != null &&
            DateTime.now().isBefore(_suggestEmptyUntil!)) ||
        (_suggestBlockedUntil != null &&
            DateTime.now().isBefore(_suggestBlockedUntil!));
    if (!skipSuggest && !breakerOpen) {
      final resp = await _get(
        'https://movie.douban.com/j/subject_suggest'
        '?q=${Uri.encodeQueryComponent(n)}',
        timeout: const Duration(seconds: 8),
      );
      // 这个接口的 403 是固定风控，不代表 Rexxar 也不可用，不参与熔断。
      if (resp.status == 200) {
        final rows = _decodeOrNull(resp.text);
        final subject = pickDoubanSubject(rows, n, year);
        if (subject != null) {
          _subjectCache[key] = _Cached(DateTime.now(), subject);
          return subject;
        }
        if (rows is List && rows.isEmpty) {
          _suggestEmptyUntil = DateTime.now().add(const Duration(minutes: 10));
        }
      } else if (resp.status == 403 || resp.status == 429) {
        _suggestBlockedUntil = DateTime.now().add(const Duration(minutes: 10));
      }
    }
    final subject = await htmlSearchSubject(n, year: year);
    if (subject != null) {
      _subjectCache[key] = _Cached(DateTime.now(), subject);
      return subject;
    }
    // 联想和 HTML 搜索都被 403 风控时（2026-11 起很常见），
    // Rexxar 搜索接口仍可用，是最后一条免 Key 的检索链路。
    final rexxar = await searchSubject(n, year: year);
    if (rexxar != null) _subjectCache[key] = _Cached(DateTime.now(), rexxar);
    return rexxar;
  }

  /// HTML 搜索兜底：`search.douban.com/movie/subject_search` 未登录可用。
  ///
  /// 页面里带 `window.__DATA__`，一次返回 10~20 条影视条目，包含
  /// 条目 id / 类型 / 年份 / 封面，比被限流的联想接口稳定得多。
  Future<DoubanSubject?> htmlSearchSubject(
    String name, {
    String year = '',
  }) async {
    final n = name.trim();
    if (n.isEmpty || breakerOpen) return null;
    if (_htmlSearchBlockedUntil != null &&
        DateTime.now().isBefore(_htmlSearchBlockedUntil!)) {
      return null;
    }
    final key = '$n|$year|html';
    final cached = _subjectCache[key];
    if (cached != null &&
        DateTime.now().difference(cached.at) < const Duration(hours: 24)) {
      return cached.value;
    }
    final resp = await _get(
      'https://search.douban.com/movie/subject_search'
      '?search_text=${Uri.encodeQueryComponent(n)}&cat=1002',
      timeout: const Duration(seconds: 10),
      headers: const {
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Referer': 'https://search.douban.com/movie/',
      },
    );
    if (resp.status == 403 || resp.status == 429) {
      // 同 subject_suggest：HTML 搜索的 403 是固定风控，不参与熔断，
      // 只短路自己，避免把仍然可用的 Rexxar 接口一起停掉。
      _htmlSearchBlockedUntil = DateTime.now().add(const Duration(minutes: 10));
    }
    if (resp.status != 200) return null;
    final subject = pickDoubanSubject(
      parseDoubanSearchHtml(resp.text),
      n,
      year,
    );
    if (subject != null) {
      _subjectCache[key] = _Cached(DateTime.now(), subject);
    }
    return subject;
  }

  /// Rexxar 搜索：`subject_suggest` 被限流（连续几次后返回空数组）时补封面用。
  ///
  /// `cover_url` 默认是横版图床地址，这里换成竖版海报参数。
  Future<DoubanSubject?> searchSubject(String name, {String year = ''}) async {
    final n = name.trim();
    if (n.isEmpty || breakerOpen) return null;
    final key = '$n|$year|rexxar';
    final cached = _subjectCache[key];
    if (cached != null &&
        DateTime.now().difference(cached.at) < const Duration(hours: 24)) {
      return cached.value;
    }
    final resp = await _get(
      '$_base/search/subjects?q=${Uri.encodeQueryComponent(n)}&for_mobile=1',
      timeout: const Duration(seconds: 10),
      // 这个接口只认移动端 UA：桌面 UA 会直接 500，带 type/start/count
      // 参数也会 500，只能传 q + for_mobile。
      headers: const {
        'Accept': 'application/json',
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
        'Referer': 'https://m.douban.com/search/',
      },
    );
    _noteStatus(resp.status);
    if (resp.status != 200) return null;
    final decoded = _decodeOrNull(resp.text);
    final subjects = decoded is Map ? decoded['subjects'] : null;
    final items = subjects is Map ? subjects['items'] : null;
    final rows = <Map<String, dynamic>>[];
    if (items is List) {
      for (final item in items) {
        if (item is! Map) continue;
        final target = item['target'];
        if (target is! Map) continue;
        final uri = (target['uri'] ?? '').toString();
        rows.add({
          'id': (target['id'] ?? '').toString(),
          'type': uri.contains('/tv/') ? 'tv' : 'movie',
          'title': (target['title'] ?? '').toString(),
          'year': (target['year'] ?? '').toString(),
          'img': _posterCoverUrl((target['cover_url'] ?? '').toString()),
        });
      }
    }
    final subject = pickDoubanSubject(rows, n, year);
    if (subject != null) _subjectCache[key] = _Cached(DateTime.now(), subject);
    return subject;
  }

  static String _posterCoverUrl(String raw) {
    final url = raw.trim();
    if (url.isEmpty) return '';
    return url.replaceFirst(
      RegExp(r'imageView2/0/q/\d+/w/\d+/h/\d+/format/jpg'),
      'imageView2/0/q/80/w/420/h/600/format/jpg',
    );
  }

  /// 详情页元数据补全：封面 / 简介 / 评分 / 类型 / 演职员。
  Future<DoubanInfo?> loadInfo(String name, {String year = ''}) async {
    final n = name.trim();
    if (n.isEmpty) return null;
    final key = '$n|$year';
    final cached = _infoCache[key];
    if (cached != null && DateTime.now().difference(cached.at) < _sectionsTtl) {
      return cached.value;
    }
    if (breakerOpen) return null;
    final subject = await findSubject(n, year: year);
    if (subject == null) return null;
    for (final mediaType in _mediaTypesOf(subject)) {
      final resp = await _get(
        '$_base/$mediaType/${subject.id}?for_mobile=1',
        timeout: const Duration(seconds: 10),
      );
      _noteStatus(resp.status);
      if (resp.status == 200) {
        // 详情接口只给演员名字，头像要另取 credits；失败时保留名字占位。
        final credits = await _loadCredits(mediaType, subject.id);
        final info = parseDoubanInfo(
          _decodeOrNull(resp.text),
          mediaType,
          credits: credits,
        );
        if (info != null) _infoCache[key] = _Cached(DateTime.now(), info);
        return info;
      }
      if (resp.status != 400 && resp.status != 404) return null;
    }
    return null;
  }

  /// 演职员头像与角色（详情接口只返回名字，头像/饰演关系在 celebrities 里）。
  ///
  /// `celebrities` 返回完整演员表（含每个演员的 `avatar` 与 `character`）；
  /// 个别媒体类型没有这个接口时退回 `credits`（只有前几条）。
  Future<List<DoubanCastMember>> _loadCredits(
    String mediaType,
    String id,
  ) async {
    if (breakerOpen) return const [];
    final resp = await _get(
      '$_base/$mediaType/$id/celebrities?for_mobile=1',
      timeout: const Duration(seconds: 8),
    );
    _noteStatus(resp.status);
    if (resp.status == 200) {
      return parseDoubanCredits(_decodeOrNull(resp.text));
    }
    if (resp.status != 400 && resp.status != 404) return const [];
    final fallback = await _get(
      '$_base/$mediaType/$id/credits?for_mobile=1',
      timeout: const Duration(seconds: 8),
    );
    _noteStatus(fallback.status);
    if (fallback.status != 200) return const [];
    return parseDoubanCredits(_decodeOrNull(fallback.text));
  }

  /// 相关推荐 + 豆瓣影评（无命中 / 风控中返回 null）。
  Future<DoubanDetailExtra?> loadDetailExtra(
    String name, {
    String year = '',
  }) async {
    final n = name.trim();
    if (n.isEmpty) return null;
    final key = '$n|$year';
    final cached = _extraCache[key];
    if (cached != null && DateTime.now().difference(cached.at) < _sectionsTtl) {
      return cached.value;
    }
    if (breakerOpen) return null;
    final subject = await findSubject(n, year: year);
    if (subject == null) return null;
    for (final mediaType in _mediaTypesOf(subject)) {
      final recResp = await _get(
        '$_base/$mediaType/${subject.id}/recommendations?start=0&count=12&for_mobile=1',
      );
      _noteStatus(recResp.status);
      if (recResp.status == 400 || recResp.status == 404) continue;
      final rvResp = await _get(
        '$_base/$mediaType/${subject.id}/reviews?start=0&count=6&order=hot&for_mobile=1',
      );
      _noteStatus(rvResp.status);
      final recommendations = recResp.status == 200
          ? parseDoubanRecommendations(_decodeOrNull(recResp.text))
          : const <DoubanExtraItem>[];
      final reviews = rvResp.status == 200
          ? parseDoubanReviews(_decodeOrNull(rvResp.text))
          : const <DoubanReviewItem>[];
      if (recommendations.isEmpty && reviews.isEmpty) return null;
      final data = DoubanDetailExtra(
        id: subject.id,
        recommendations: recommendations,
        reviews: reviews,
      );
      _extraCache[key] = _Cached(DateTime.now(), data);
      return data;
    }
    return null;
  }

  List<String> _mediaTypesOf(DoubanSubject subject) => [
    subject.mediaType,
    if (subject.mediaType == 'movie') 'tv' else 'movie',
  ];
}

/// 豆瓣 `recommend` 查询串（`全部` 不下发；tags 逗号连接）。
String buildExploreUrl(String mediaType, ExploreQuery query) {
  final tags = query.tags
      .map((t) => t.trim())
      .where((t) => t.isNotEmpty && t != allTag)
      .toList();
  final count = query.count.clamp(1, 50);
  final start = query.start.clamp(0, 500);
  final params = <String, String>{
    'start': '$start',
    'count': '$count',
    'tags': tags.join(','),
  };
  if (query.sort.trim().isNotEmpty) params['sort'] = query.sort.trim();
  final qs = params.entries
      .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
      .join('&');
  return 'https://m.douban.com/rexxar/api/v2/$mediaType/recommend?$qs';
}

/// 卡片副标题首段拿年份（「2018 / 文牧野 徐峥…」→ 2018）。
int? yearFromCardSubtitle(String subtitle) {
  final m = RegExp(r'(19|20)\d{2}').firstMatch(subtitle);
  return m != null ? int.tryParse(m.group(0)!) : null;
}

/// `{mediaType}/recommend` 响应 → 影片条目（丢弃榜单 / 豆列条目）。
List<DiscoverItem> parseDoubanExploreItems(Object? json, String mediaType) {
  final items = json is Map ? json['items'] : null;
  if (items is! List) return const [];
  final out = <DiscoverItem>[];
  final seen = <String>{};
  for (final raw in items) {
    if (raw is! Map) continue;
    if (raw['type'] != mediaType) continue;
    final title = (raw['title'] ?? '').toString().trim();
    final id = (raw['id'] ?? '').toString().trim();
    final pic = raw['pic'];
    var cover = pic is Map
        ? (pic['large'] ?? pic['normal'] ?? '').toString()
        : '';
    if (cover.trim().isEmpty) cover = (raw['cover_url'] ?? '').toString();
    cover = cover.trim();
    if (title.isEmpty ||
        !RegExp(r'^https?://', caseSensitive: false).hasMatch(cover)) {
      continue;
    }
    if (id.isNotEmpty && !seen.add(id)) continue;
    out.add(
      DiscoverItem(
        title: title,
        year: yearFromCardSubtitle((raw['card_subtitle'] ?? '').toString()),
        poster: cover,
        mediaType: mediaType,
        doubanId: RegExp(r'^\d+$').hasMatch(id) ? id : '',
      ),
    );
  }
  return out;
}

/// `subject_collection/{id}/items` 响应 → 影片条目。
List<DiscoverItem> parseDoubanCollectionItems(Object? json, String mediaType) {
  final list = json is Map
      ? (json['subject_collection_items'] ?? json['items'])
      : null;
  if (list is! List) return const [];
  final out = <DiscoverItem>[];
  final seen = <String>{};
  for (final raw in list) {
    if (raw is! Map) continue;
    final type = (raw['type'] ?? '').toString();
    if (type.isNotEmpty && type != mediaType) continue;
    final title = (raw['title'] ?? '').toString().trim();
    if (title.isEmpty) continue;
    final id = (raw['id'] ?? '').toString().trim();
    if (!seen.add(id.isNotEmpty ? id : title)) continue;
    final pic = raw['pic'];
    var cover = pic is Map
        ? (pic['large'] ?? pic['normal'] ?? '').toString()
        : '';
    if (cover.trim().isEmpty) {
      final coverObj = raw['cover'];
      cover = coverObj is Map
          ? (coverObj['url'] ?? '').toString()
          : (raw['cover_url'] ?? '').toString();
    }
    cover = cover.trim();
    final yearText = (raw['year'] ?? '').toString();
    final year =
        RegExp(r'(19|20)\d{2}').firstMatch(yearText)?.group(0) ??
        RegExp(r'(19|20)\d{2}')
            .firstMatch((raw['card_subtitle'] ?? '').toString())
            ?.group(0);
    out.add(
      DiscoverItem(
        title: title,
        year: year != null ? int.tryParse(year) : null,
        poster: RegExp(r'^https?://', caseSensitive: false).hasMatch(cover)
            ? cover
            : '',
        mediaType: mediaType,
        doubanId: RegExp(r'^\d+$').hasMatch(id) ? id : '',
      ),
    );
  }
  return out;
}

/// 豆瓣自带的选项表（`recommend_categories` + `sorts`）→ 级联词表。
ExploreVocab parseDoubanVocab(Object? json, String mediaType) {
  final map = json is Map ? json : const <String, dynamic>{};
  final cats = map['recommend_categories'];
  List<String> pick(String name) {
    if (cats is! List) return const [];
    for (final c in cats) {
      if (c is! Map || (c['type'] ?? '').toString() != name) continue;
      final data = c['data'];
      if (data is! List) return const [];
      return data
          .map((d) => d is Map ? (d['text'] ?? '').toString().trim() : '')
          .where((t) => t.isNotEmpty && t != '类型')
          .toList();
    }
    return const [];
  }

  List<String> merge(List<String> list) {
    final out = <String>[allTag];
    for (final v in list) {
      if (v == allTag || out.contains(v)) continue;
      out.add(v);
    }
    return out;
  }

  final dimensions = <ExploreDimension>[];
  if (mediaType == 'movie') {
    final genres = pick('类型');
    dimensions.add(
      ExploreDimension(
        key: '类型',
        label: '类型',
        values: merge(genres.isNotEmpty ? genres : movieGenres),
      ),
    );
  } else {
    dimensions.add(
      const ExploreDimension(
        key: '类型',
        label: '类型',
        values: [allTag, ...tvSubtypes],
      ),
    );
  }
  final regions = pick('地区');
  dimensions.add(
    ExploreDimension(
      key: '地区',
      label: '地区',
      values: merge(
        regions.isNotEmpty
            ? regions
            : (mediaType == 'movie' ? movieRegions : tvRegions),
      ),
    ),
  );
  dimensions.add(
    ExploreDimension(key: '年代', label: '年代', values: discoverYearValues()),
  );

  final sortsRaw = map['sorts'];
  final sorts = <ExploreSort>[];
  var defaultSort = '';
  if (sortsRaw is List) {
    for (final s in sortsRaw) {
      if (s is! Map) continue;
      final id = (s['name'] ?? '').toString().trim();
      final label = (s['text'] ?? '').toString().trim();
      if (id.isEmpty || label.isEmpty) continue;
      sorts.add(ExploreSort(id: id, label: label));
      if (defaultSort.isEmpty && s['checked'] == true) defaultSort = id;
    }
  }
  if (defaultSort.isEmpty) {
    defaultSort = sorts.isNotEmpty ? sorts.first.id : 'T';
  }
  return ExploreVocab(
    dimensions: dimensions,
    sorts: sorts.isNotEmpty ? sorts : doubanSorts,
    defaultSort: defaultSort,
  );
}

/// 片名归一：小写 + 去空白 / 标点（与豆瓣条目匹配同口径）。
String normalizeDoubanTitle(String value) => value.toLowerCase().replaceAll(
  RegExp(r'[\s\p{P}\p{S}]', unicode: true),
  '',
);

/// 匹配用的片名：去掉方向标记、年份与季号后缀。
///
/// 豆瓣联想把剧集写作「庆余年 第一季」，资源站通常只写「庆余年」；
/// 不剥掉季号会直接匹配失败（表现为详情页和横图都刮不到）。
String doubanMatchTitle(String raw) {
  var text = cleanDoubanSearchTitle(raw);
  text = text.replaceAll(RegExp(r'\s*第\s*[0-9一二三四五六七八九十两]+\s*[季部]\s*$'), '');
  text = text.replaceAll(
    RegExp(r'\s*(?:season|series)\s*[0-9]{1,2}\s*$', caseSensitive: false),
    '',
  );
  text = text.replaceAll(
    RegExp(r'\s*S[0-9]{1,2}\s*$', caseSensitive: false),
    '',
  );
  return text.trim();
}

/// 豆瓣联想条目的真实类型。
///
/// `subject_suggest` 会把电视剧的 `type` 也写成 `movie`，真正的类型
/// 藏在 `episode`（集数）里；不识别会让剧集走电影的详情 / 剧照接口。
bool doubanRowIsTv(Map row) {
  if ((row['type'] ?? '').toString() == 'tv') return true;
  final episode = (row['episode'] ?? '').toString().trim();
  if (episode.isNotEmpty && episode != '0') return true;
  final uri = (row['uri'] ?? row['url'] ?? '').toString();
  return uri.contains('/tv/');
}

/// 解析 `search.douban.com/movie/subject_search` 页面里的 `window.__DATA__`。
///
/// 返回的每一行与 `subject_suggest` 同口径（id / type / title / year / img），
/// 方便复用 [pickDoubanSubject]。
List<Map<String, dynamic>> parseDoubanSearchHtml(String html) {
  final marker = html.indexOf('window.__DATA__');
  if (marker < 0) return const [];
  final start = html.indexOf('{', marker);
  if (start < 0) return const [];
  final end = _jsonObjectEnd(html, start);
  if (end < 0) return const [];
  Object? decoded;
  try {
    decoded = jsonDecode(html.substring(start, end));
  } catch (_) {
    return const [];
  }
  final items = decoded is Map ? decoded['items'] : null;
  if (items is! List) return const [];
  final out = <Map<String, dynamic>>[];
  for (final raw in items) {
    if (raw is! Map) continue;
    final url = (raw['url'] ?? '').toString();
    var id = (raw['id'] ?? '').toString().trim();
    if (!RegExp(r'^\d{5,}$').hasMatch(id)) {
      final match = RegExp(r'/subject/(\d+)').firstMatch(url);
      id = match?.group(1) ?? '';
    }
    if (!RegExp(r'^\d{5,}$').hasMatch(id)) continue;
    final rawTitle = (raw['title'] ?? '').toString();
    final title = cleanDoubanSearchTitle(rawTitle);
    if (title.isEmpty) continue;
    final more = (raw['more_url'] ?? '').toString();
    final labels = raw['labels'];
    var isTv = more.contains("is_tv:'1'") || more.contains('is_tv: "1"');
    if (!isTv && labels is List) {
      isTv = labels.any((label) {
        if (label is! Map) return false;
        final text = (label['text'] ?? '').toString();
        return text.contains('剧集') || text.contains('综艺');
      });
    }
    final year = RegExp(r'((?:19|20)\d{2})\s*\)\s*$')
        .firstMatch(rawTitle)
        ?.group(1);
    out.add({
      'id': id,
      'type': isTv ? 'tv' : 'movie',
      'title': title,
      'year': year ?? '',
      'img': largeDoubanPoster((raw['cover_url'] ?? '').toString()),
    });
  }
  return out;
}

/// 从 `window.__DATA__ = {…}` 里找出 JSON 对象的右花括号（跳过字符串）。
int _jsonObjectEnd(String text, int start) {
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var i = start; i < text.length; i++) {
    final code = text.codeUnitAt(i);
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (code == 0x5C) {
        escaped = true;
      } else if (code == 0x22) {
        inString = false;
      }
      continue;
    }
    if (code == 0x22) {
      inString = true;
    } else if (code == 0x7B) {
      depth++;
    } else if (code == 0x7D) {
      depth--;
      if (depth == 0) return i + 1;
    }
  }
  return -1;
}

/// HTML 搜索结果的标题带方向标记与年份后缀：`漫长的季节‎ (2023)` → `漫长的季节`。
String cleanDoubanSearchTitle(String raw) {
  var text = raw
      .replaceAll('\u200e', '')
      .replaceAll('\u200f', '')
      .replaceAll('\u200b', '')
      .trim();
  text = text.replaceAll(RegExp(r'\s*\(\s*(?:19|20)\d{2}\s*\)\s*$'), '');
  return text.trim();
}

/// 豆瓣海报缩略图换大图：`/view/photo/s_ratio_poster/public/p1.jpg`
/// → `/view/photo/l/public/p1.jpg`（同一图床，尺寸更大）。
String largeDoubanPoster(String raw) {
  final url = raw.trim();
  if (url.isEmpty) return '';
  final match = RegExp(r'/view/photo/[^/]+/public/(p\d+\.jpg)').firstMatch(url);
  if (match == null) return url;
  return 'https://img3.doubanio.com/view/photo/l/public/${match.group(1)}';
}

/// 结果里「中文名 + 外文原名」的写法，取前半段做宽松匹配：
/// `漫长的离别 長いお別れ` → `漫长的离别`。
///
/// 只在后半段确实含非中文文字（假名 / 韩文 / 拉丁）时才截断，
/// 避免把「你好 李焕英」这种本身带空格的中文片名截成「你好」。
String doubanLeadCjkTitle(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return '';
  final parts = text.split(RegExp(r'\s+'));
  if (parts.length < 2) return '';
  final lead = parts.first.trim();
  if (lead.length < 2 || !RegExp(r'^[\u3400-\u9fff]').hasMatch(lead)) {
    return '';
  }
  final rest = parts.skip(1).join(' ');
  if (rest.isEmpty) return '';
  if (!RegExp(r'[A-Za-z\u3040-\u30ff\uac00-\ud7af]').hasMatch(rest)) return '';
  return lead;
}

/// 单行文本：压缩空白并按需截断。
String oneLineText(String text, int max) {
  final s = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return s.length > max ? '${s.substring(0, max)}…' : s;
}

/// 从 `subject_suggest` / HTML 搜索结果里挑出当前片对应的条目（先严后宽）。
///
/// 放宽到最后一级时要求「长度接近 + 年份对得上」：以前只要互相包含就命中，
/// 「庆余年」会拿到「庆余年 第二季」，「流浪地球」会拿到「流浪地球 2」。
DoubanSubject? pickDoubanSubject(Object? rows, String name, String year) {
  if (rows is! List) return null;
  final want = normalizeDoubanTitle(name.trim());
  if (want.isEmpty) return null;
  final wantYear = RegExp(r'^\d{4}$').hasMatch(year.trim()) ? year.trim() : '';
  final usable = <Map>[];
  for (final row in rows) {
    if (row is! Map) continue;
    final type = (row['type'] ?? '').toString();
    final id = (row['id'] ?? '').toString();
    if ((type != 'movie' && type != 'tv') ||
        !RegExp(r'^\d{5,}$').hasMatch(id)) {
      continue;
    }
    usable.add(row);
  }
  if (usable.isEmpty) return null;

  DoubanSubject asSubject(Map row) => DoubanSubject(
    id: (row['id'] ?? '').toString(),
    mediaType: doubanRowIsTv(row) ? 'tv' : 'movie',
    title: (row['title'] ?? '').toString().trim(),
    year: (row['year'] ?? '').toString().trim(),
    img: largeDoubanPoster((row['img'] ?? '').toString()),
  );

  /// HTML 搜索的标题可能是「中文名 外文原名」，多给一个中文名匹配键。
  List<String> titleKeys(Map row) {
    final raw = (row['title'] ?? '').toString();
    final keys = <String>[normalizeDoubanTitle(doubanMatchTitle(raw))];
    final lead = doubanLeadCjkTitle(raw);
    if (lead.isNotEmpty) {
      keys.add(normalizeDoubanTitle(doubanMatchTitle(lead)));
    }
    return keys.where((key) => key.isNotEmpty).toList();
  }

  bool sameTitle(Map row) => titleKeys(row).contains(want);

  if (wantYear.isNotEmpty) {
    for (final row in usable) {
      final rowYear = (row['year'] ?? '').toString().trim();
      if (rowYear == wantYear && sameTitle(row)) return asSubject(row);
    }
  }
  final same = usable.where(sameTitle).toList();
  if (same.isNotEmpty) {
    if (wantYear.isNotEmpty) {
      final want = int.tryParse(wantYear);
      final dated = same.where((row) {
        final value = (row['year'] ?? '').toString().trim();
        return value.isNotEmpty && int.tryParse(value) != null;
      }).toList();
      if (dated.isNotEmpty && dated.length == same.length && want != null) {
        // 同名多季 / 多版本：只接受同年，或发布年与首播年差 1 的条目。
        // 差 5 年那种基本就是另一季，宁可回到竖版海报也不能配错。
        final close = dated.where((row) {
          final year = int.parse((row['year'] ?? '').toString());
          return (year - want).abs() <= 1;
        }).toList();
        if (close.isEmpty) return null;
        close.sort((a, b) {
          final ay = int.parse((a['year'] ?? '').toString());
          final by = int.parse((b['year'] ?? '').toString());
          return (ay - want).abs().compareTo((by - want).abs());
        });
        return asSubject(close.first);
      }
    }
    return asSubject(same.first);
  }
  Map? flexible;
  var flexibleScore = 0.0;
  for (final row in usable) {
    final rowYear = (row['year'] ?? '').toString().trim();
    // 年份已知时，最后一级只接受同年（或源里没年份）的条目。
    if (wantYear.isNotEmpty && rowYear.isNotEmpty && rowYear != wantYear) {
      continue;
    }
    for (final key in titleKeys(row)) {
      if (!key.contains(want) && !want.contains(key)) continue;
      final shorter = key.length < want.length ? key.length : want.length;
      final longer = key.length < want.length ? want.length : key.length;
      final ratio = longer == 0 ? 0.0 : shorter / longer;
      // 长度差太多说明不是同一部；年份完全对得上时放宽到 0.5，
      // 兼容「甄嬛传」→「后宫·甄嬛传」这类带前缀的官方片名。
      final minRatio = rowYear == wantYear && wantYear.isNotEmpty ? 0.5 : 0.62;
      if (ratio < minRatio) continue;
      final score = ratio * 100 + (rowYear == wantYear ? 20 : 0);
      if (score > flexibleScore) {
        flexibleScore = score;
        flexible = row;
      }
    }
  }
  return flexible == null ? null : asSubject(flexible);
}

/// `{movie|tv}/{id}?for_mobile=1` 响应 → 详情元数据。
DoubanInfo? parseDoubanInfo(
  Object? json,
  String mediaType, {
  List<DoubanCastMember> credits = const [],
}) {
  if (json is! Map) return null;
  final id = (json['id'] ?? '').toString().trim();
  final title = (json['title'] ?? '').toString().trim();
  if (id.isEmpty || title.isEmpty) return null;
  final pic = json['pic'];
  final ratingObj = json['rating'];
  List<String> names(Object? value) {
    if (value is! List) return const [];
    final out = <String>[];
    for (final row in value) {
      final name = row is Map
          ? (row['name'] ?? '').toString().trim()
          : row.toString().trim();
      if (name.isNotEmpty && !out.contains(name)) out.add(name);
    }
    return out;
  }

  List<String> genres = const [];
  if (json['genres'] is List) {
    genres = (json['genres'] as List)
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }
  final countries = <String>[];
  final rawCountries = json['countries'];
  if (rawCountries is List) {
    for (final row in rawCountries) {
      final name = row is Map
          ? (row['name'] ?? '').toString().trim()
          : row.toString().trim();
      if (name.isNotEmpty && !countries.contains(name)) countries.add(name);
    }
  }
  final actors = names(json['actors']);
  return DoubanInfo(
    id: id,
    mediaType: mediaType,
    title: title,
    year: (json['year'] ?? '').toString().trim(),
    intro: oneLineText((json['intro'] ?? '').toString(), 1200),
    rating: ratingObj is Map ? _asDouble(ratingObj['value']) : null,
    cover: pic is Map
        ? ((pic['large'] ?? pic['normal'] ?? '')).toString().trim()
        : '',
    genres: genres,
    countries: countries,
    originalTitle: (json['original_title'] ?? '').toString().trim(),
    directors: names(json['directors']),
    actors: actors,
    cast: mergeDoubanCast(actors, credits),
  );
}

/// `celebrities` 的 `actors` 数组（兼容旧 `credits` 的 `items` 数组）。
///
/// 两个接口都带 `avatar`；`celebrities` 用 `character` 给饰演角色，
/// `credits` 用 `simple_character`。
List<DoubanCastMember> parseDoubanCredits(Object? json) {
  final rows = json is Map && json['actors'] is List
      ? json['actors'] as List
      : (json is Map && json['items'] is List
            ? json['items'] as List
            : const []);
  final out = <DoubanCastMember>[];
  final seen = <String>{};
  for (final raw in rows) {
    if (raw is! Map) continue;
    final name = (raw['name'] ?? '').toString().trim();
    if (name.isEmpty || !seen.add(name)) continue;
    final avatarObj = raw['avatar'];
    final avatar = avatarObj is Map
        ? ((avatarObj['large'] ?? avatarObj['normal'] ?? '')).toString().trim()
        : avatarObj is String
        ? avatarObj.trim()
        : '';
    final simple = (raw['simple_character'] ?? '').toString().trim();
    final character = (raw['character'] ?? '').toString().trim();
    var role = simple.isNotEmpty ? simple : character;
    if (role.isNotEmpty && !role.startsWith('饰')) {
      final match = RegExp(r'饰\s*([^)）]+)').firstMatch(role);
      if (match != null) role = '饰 ${match.group(1)!.trim()}';
    }
    final roleList = raw['roles'] is List
        ? (raw['roles'] as List).map((e) => e.toString().trim()).toList()
        : const <String>[];
    var category = (raw['category'] ?? '').toString().trim();
    if (category.isEmpty && roleList.contains('演员')) category = '演员';
    out.add(
      DoubanCastMember(
        name: name,
        avatar: avatar,
        role: role,
        category: category,
      ),
    );
  }
  return out;
}

/// 按详情里的演员名单合并豆瓣演员表：名单顺序优先，头像 / 饰演角色从豆瓣补。
///
/// 豆瓣演员表非空时，名单里对不上的条目直接丢弃（源字段常把导演 / 编剧 /
/// 角色说明混进演员列表）；豆瓣表为空时只做保守的人名过滤。
List<DoubanCastMember> mergeDoubanCast(
  List<String> actors,
  List<DoubanCastMember> credits,
) {
  final byName = <String, DoubanCastMember>{};
  for (final member in credits) {
    byName.putIfAbsent(member.name, () => member);
  }
  final out = <DoubanCastMember>[];
  final seen = <String>{};
  for (final raw in actors) {
    final name = raw.trim();
    if (!looksLikeCastName(name) || !seen.add(name)) continue;
    final member = byName[name];
    if (credits.isNotEmpty && member == null) continue;
    out.add(member ?? DoubanCastMember(name: name));
  }
  if (out.isEmpty && credits.isNotEmpty) {
    for (final member in credits) {
      if (!member.looksLikeActor) continue;
      if (seen.add(member.name)) out.add(member);
    }
  }
  return out;
}

/// `{movie|tv}/{id}/recommendations` 响应 → 推荐条目（裸数组与包对象都兼容）。
List<DoubanExtraItem> parseDoubanRecommendations(Object? json) {
  final rows = json is List
      ? json
      : (json is Map && json['recommendations'] is List
            ? json['recommendations'] as List
            : const []);
  final out = <DoubanExtraItem>[];
  final seen = <String>{};
  for (final raw in rows) {
    if (raw is! Map) continue;
    final id = (raw['id'] ?? '').toString().trim();
    final title = (raw['title'] ?? '').toString().trim();
    if (!RegExp(r'^\d{5,}$').hasMatch(id) || title.isEmpty || !seen.add(id)) {
      continue;
    }
    final pic = raw['pic'];
    final poster = pic is Map
        ? ((pic['large'] ?? pic['normal'] ?? '')).toString().trim()
        : '';
    final rating = raw['rating'] is Map
        ? _asDouble((raw['rating'] as Map)['value'])
        : null;
    out.add(
      DoubanExtraItem(
        id: id,
        title: title,
        year: yearFromCardSubtitle((raw['card_subtitle'] ?? '').toString()),
        poster: poster,
        subtitle: oneLineText((raw['card_subtitle'] ?? '').toString(), 80),
        rating: rating,
        mediaType: (raw['type'] ?? '') == 'tv' ? 'tv' : 'movie',
      ),
    );
  }
  return out;
}

/// `{movie|tv}/{id}/reviews` 响应 → 影评条目（摘要最多 220 字）。
List<DoubanReviewItem> parseDoubanReviews(Object? json) {
  final rows = json is Map ? json['reviews'] : null;
  if (rows is! List) return const [];
  final out = <DoubanReviewItem>[];
  final seen = <String>{};
  for (final raw in rows) {
    if (raw is! Map) continue;
    final id = (raw['id'] ?? '').toString().trim();
    final title = (raw['title'] ?? '').toString().trim();
    if (id.isEmpty || title.isEmpty || !seen.add(id)) continue;
    final rating = raw['rating'] is Map
        ? _asDouble((raw['rating'] as Map)['value'])
        : null;
    final user = raw['user'] is Map ? (raw['user'] as Map)['name'] : null;
    out.add(
      DoubanReviewItem(
        id: id,
        title: title,
        abstract: oneLineText((raw['abstract'] ?? '').toString(), 220),
        rating: rating,
        useful: _asInt(raw['useful_count']) ?? 0,
        comments: _asInt(raw['comments_count']) ?? 0,
        author: (user ?? '').toString().trim(),
        date: (raw['create_time'] ?? '').toString().trim(),
      ),
    );
  }
  return out;
}

ExploreVocabulary get _builtinVocabulary => ExploreVocabulary(
  movie: ExploreVocab(
    dimensions: [
      ExploreDimension(
        key: '类型',
        label: '类型',
        values: [allTag, ...movieGenres],
      ),
      ExploreDimension(
        key: '地区',
        label: '地区',
        values: [allTag, ...movieRegions],
      ),
      ExploreDimension(key: '年代', label: '年代', values: discoverYearValues()),
    ],
    sorts: doubanSorts,
    defaultSort: 'T',
  ),
  tv: ExploreVocab(
    dimensions: [
      const ExploreDimension(
        key: '类型',
        label: '类型',
        values: [allTag, ...tvSubtypes],
      ),
      const ExploreDimension(
        key: '地区',
        label: '地区',
        values: [allTag, ...tvRegions],
      ),
      ExploreDimension(key: '年代', label: '年代', values: discoverYearValues()),
    ],
    sorts: doubanSorts,
    defaultSort: 'T',
  ),
  source: 'builtin',
);

int? _asInt(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

double? _asDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}
