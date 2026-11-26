// 外部弹幕数据层（对齐旧版 src/main/danmaku/logvarProvider.ts + SpiderHost 弹幕编排）。
//
// 协议：{base}/api/v2/search/anime?keyword= → {base}/api/v2/bangumi/{animeId}
//      → {base}/api/v2/comment/{episodeId}?format=xml（B 站格式）。
// 失败源记**会话级冷却**（内存 Map），后续搜索直接跳过；并发上限 4，超时 8s/8s/40s。
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'danmaku_endpoints.dart';
import 'danmaku_models.dart';
import 'danmaku_query.dart';
import 'danmaku_settings.dart';
import 'danmaku_xml.dart';

const String danmakuUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Win-Box/0.98';
const Duration danmakuSearchTimeout = Duration(seconds: 8);
const Duration danmakuBangumiTimeout = Duration(seconds: 8);
const Duration danmakuCommentTimeout = Duration(seconds: 40);
const int danmakuMaxRedirects = 3;
const int danmakuMaxConcurrent = 4;

/// 最多展开前 4 部命中番剧的剧集列表（跨来源优先）。
const int danmakuMaxAnimeExpand = 4;

/// 单来源候选上限（避免一个聚合源刷满全局上限）。
const int danmakuMaxPerSource = 15;

/// 全局番剧上限。
const int danmakuMaxAnimes = 60;

/// 弹幕 XML 内存缓存上限。
const int danmakuMaxCache = 200;

class _HttpText {
  _HttpText(this.status, this.body);

  final int status;
  final String body;
}

/// 限并发映射。
Future<List<R>> mapLimit<T, R>(
  List<T> items,
  int limit,
  Future<R> Function(T item) fn,
) async {
  if (items.isEmpty) return const [];
  final out = List<R?>.filled(items.length, null);
  var next = 0;
  Future<void> worker() async {
    while (true) {
      final i = next++;
      if (i >= items.length) return;
      out[i] = await fn(items[i]);
    }
  }

  final count = limit < 1 ? 1 : (limit > items.length ? items.length : limit);
  await Future.wait([for (var i = 0; i < count; i++) worker()]);
  return [for (final v in out) v as R];
}

/// 接口健康（会话级）：失败 → 冷却跳过；首次失败 2 分钟，重复失败 10 分钟；成功后清零。
class DanmakuEndpointHealth {
  DanmakuEndpointHealth({
    this.firstCool = const Duration(minutes: 2),
    this.repeatCool = const Duration(minutes: 10),
  });

  final Duration firstCool;
  final Duration repeatCool;
  final Map<String, _EndpointFail> _fails = {};

  bool isCooling(String url, {DateTime? now}) {
    final f = _fails[url];
    if (f == null) return false;
    return f.until.isAfter(now ?? DateTime.now());
  }

  void markFail(String url, {DateTime? now}) {
    if (url.isEmpty) return;
    final n = (_fails[url]?.count ?? 0) + 1;
    final cool = n <= 1 ? firstCool : repeatCool;
    _fails[url] = _EndpointFail(n, (now ?? DateTime.now()).add(cool));
  }

  void markOk(String url) {
    _fails.remove(url);
  }

  /// 当前冷却中的接口数。
  int coolingCount({DateTime? now}) =>
      _fails.keys.where((url) => isCooling(url, now: now)).length;
}

class _EndpointFail {
  _EndpointFail(this.count, this.until);

  final int count;
  final DateTime until;
}

class DanmakuService {
  DanmakuService({this.settingsJson, http.Client? client})
    : _client = client ?? http.Client();

  /// 外部注入的弹幕设置 JSON（key → JSON 文本；`danmaku` / `settings` / 唯一值）。
  final Map<String, String> Function()? settingsJson;
  final http.Client _client;

  /// 会话级接口健康表（与旧版同一口径）。
  final DanmakuEndpointHealth health = DanmakuEndpointHealth();

  final Map<String, String> _cache = {};

  /// 当前弹幕设置（由调用方注入的 JSON 提供；无则默认值）。
  DanmakuSettings get settings {
    final provider = settingsJson;
    if (provider == null) return DanmakuSettings.defaults();
    final map = provider();
    if (map.isEmpty) return DanmakuSettings.defaults();
    final raw =
        map['danmaku'] ??
        map['settings'] ??
        (map.length == 1 ? map.values.first : null);
    return DanmakuSettings.fromJsonString(raw);
  }

  /// 搜索候选（两级：作品名搜番剧 → 展开剧集列表）。
  ///
  /// `endpoints` 缺省 = 当前设置里已启用的接口。单源失败隔离（记冷却、返回其它源结果）。
  Future<List<DanmakuCandidate>> search(
    String keyword, {
    List<DanmakuEndpoint>? endpoints,
    int? season,
  }) async {
    final baseName = keyword.trim();
    if (baseName.isEmpty) return const [];
    final all = endpoints ?? settings.endpoints;
    final live = [
      for (final e in all)
        if (e.enabled && e.url.trim().isNotEmpty && !health.isCooling(e.url)) e,
    ];
    if (live.isEmpty) return const [];
    for (final q in danmakuQueryCandidates(baseName)) {
      final animes = await _searchAnimes(q, live, season);
      if (animes.isEmpty) continue;
      final picked = pickAnimesForExpand(animes, danmakuMaxAnimeExpand);
      final lists = await mapLimit<DanmakuAnime, List<DanmakuCandidate>>(
        picked,
        danmakuMaxConcurrent,
        _expand,
      );
      final expanded = [for (final l in lists) ...l];
      if (expanded.isEmpty) continue;
      return sortCandidatesByEp(expanded);
    }
    return const [];
  }

  /// 按剧集候选拉弹幕（失败/空 → []；成功 XML 入内存缓存）。
  Future<List<DanmakuItem>> fetch(
    DanmakuCandidate candidate, {
    Duration? timeout,
  }) async {
    if (candidate.episodeId <= 0 || candidate.source.trim().isEmpty) {
      return const [];
    }
    final xml = await _comment(
      candidate.source,
      candidate.episodeId,
      timeout: timeout,
    );
    if (xml.isEmpty) return const [];
    return parseDanmakuResponse(xml);
  }

  /// 纯函数：从搜索关键词 / 剧名推荐候选（RankAnimes + 集号匹配 + 集号升序）。
  ///
  /// `ep` 给定时同集候选优先；返回稳定排序（同档保持原有相对顺序）。
  static List<DanmakuCandidate> rankCandidates(
    List<DanmakuCandidate> candidates,
    String keyword, {
    int? season,
    String? ep,
  }) {
    final k = cleanTitle(keyword);
    final looksForEp = ep != null && ep.trim().isNotEmpty;
    final seen = <String>{};
    final items = <_RankedCandidate>[];
    var index = 0;
    for (final c in candidates) {
      final key =
          '${c.source}::${c.title}::${c.episodeTitle}::${c.episodeNumber}::${c.episodeId}';
      if (!seen.add(key)) continue;
      final t = cleanTitle(c.title);
      final rank = (k.isEmpty || t.isEmpty)
          ? 2
          : t == k
          ? 0
          : (t.contains(k) || k.contains(t) ? 1 : 2);
      final n = epNumberOf(c);
      items.add(
        _RankedCandidate(
          candidate: c,
          rank: rank,
          seasonRank: seasonRankOf(c.title, season),
          epMatch: looksForEp && candidateMatchesEp(c, ep) ? 0 : 1,
          epNumber: n,
          index: index++,
        ),
      );
    }
    items.sort((a, b) {
      var r = a.rank - b.rank;
      if (r != 0) return r;
      r = a.seasonRank - b.seasonRank;
      if (r != 0) return r;
      r = a.epMatch - b.epMatch;
      if (r != 0) return r;
      if (a.epNumber != null && b.epNumber != null) {
        r = a.epNumber! - b.epNumber!;
        if (r != 0) return r;
      } else if (a.epNumber != null) {
        return -1;
      } else if (b.epNumber != null) {
        return 1;
      }
      return a.index - b.index;
    });
    return [for (final x in items) x.candidate];
  }

  /// 纯函数：解析 B 站 XML 弹幕。
  static List<DanmakuItem> parseXml(String xml) => parseDanmakuXml(xml);

  /// 关闭底层 HTTP 客户端。
  void close() => _client.close();

  Future<List<DanmakuAnime>> _searchAnimes(
    String keyword,
    List<DanmakuEndpoint> endpoints,
    int? season,
  ) async {
    final lists = await mapLimit<DanmakuEndpoint, List<DanmakuAnime>>(
      endpoints,
      danmakuMaxConcurrent,
      (e) async {
        try {
          final list = await _searchAnime(e.url, keyword, e.name);
          health.markOk(e.url);
          return list;
        } catch (_) {
          health.markFail(e.url);
          return const <DanmakuAnime>[];
        }
      },
    );
    final merged = <DanmakuAnime>[for (final l in lists) ...l];
    final ranked = rankDanmakuAnimes(merged, keyword, season);
    final perSource = <String, int>{};
    final limited = <DanmakuAnime>[];
    for (final a in ranked) {
      final n = perSource[a.source] ?? 0;
      if (n >= danmakuMaxPerSource) continue;
      perSource[a.source] = n + 1;
      limited.add(a);
    }
    return limited.length > danmakuMaxAnimes
        ? limited.sublist(0, danmakuMaxAnimes)
        : limited;
  }

  Future<List<DanmakuAnime>> _searchAnime(
    String base,
    String keyword,
    String sourceName,
  ) async {
    final url = joinApi(
      base,
      '/api/v2/search/anime?keyword=${Uri.encodeQueryComponent(keyword)}',
    );
    final res = await _getText(url, danmakuSearchTimeout);
    if (res.status != 200) throw StateError('HTTP ${res.status}');
    dynamic json;
    try {
      json = jsonDecode(res.body);
    } catch (_) {
      throw StateError('响应不是 JSON');
    }
    final list = parseEndpointAnimeList(
      json,
      normalizeEndpointBase(base),
      sourceName,
    );
    if (list == null) throw StateError('响应结构异常');
    return list;
  }

  Future<List<DanmakuCandidate>> _bangumi(
    String base,
    int bangumiId,
    String sourceName,
    String animeTitle,
  ) async {
    final url = joinApi(base, '/api/v2/bangumi/$bangumiId');
    final res = await _getText(url, danmakuBangumiTimeout);
    if (res.status != 200) throw StateError('HTTP ${res.status}');
    dynamic json;
    try {
      json = jsonDecode(res.body);
    } catch (_) {
      throw StateError('响应不是 JSON');
    }
    final list = parseEndpointEpisodes(
      json,
      normalizeEndpointBase(base),
      sourceName,
      animeTitle,
    );
    if (list == null) throw StateError('响应结构异常');
    return list;
  }

  Future<List<DanmakuCandidate>> _expand(DanmakuAnime anime) async {
    try {
      final list = await _bangumi(
        anime.source,
        anime.bangumiId,
        anime.sourceName,
        anime.title,
      );
      health.markOk(anime.source);
      return list;
    } catch (_) {
      health.markFail(anime.source);
      return const <DanmakuCandidate>[];
    }
  }

  Future<String> _comment(
    String source,
    int episodeId, {
    Duration? timeout,
  }) async {
    final base = normalizeEndpointBase(source);
    if (base.isEmpty) return '';
    final key = '$base|$episodeId';
    final hit = _cache[key];
    if (hit != null) return hit;
    try {
      final res = await _getText(
        joinApi(base, '/api/v2/comment/$episodeId?format=xml'),
        timeout ?? danmakuCommentTimeout,
      );
      if (res.status != 200) throw StateError('HTTP ${res.status}');
      final text = res.body.trim();
      if (!text.startsWith('<')) throw StateError('响应不是 XML');
      health.markOk(base);
      if (text.isNotEmpty) {
        if (_cache.length >= danmakuMaxCache) _cache.remove(_cache.keys.first);
        _cache[key] = text;
      }
      return text;
    } catch (_) {
      health.markFail(base);
      return '';
    }
  }

  Future<_HttpText> _getText(String url, Duration timeout) {
    Future<_HttpText> run() async {
      final uri = Uri.tryParse(url);
      if (uri == null) throw ArgumentError('无效的地址：$url');
      final req = http.Request('GET', uri)
        ..headers.addAll(const {
          'User-Agent': danmakuUserAgent,
          'Accept': '*/*',
        })
        ..followRedirects = true
        ..maxRedirects = danmakuMaxRedirects;
      final res = await _client.send(req);
      final body = await res.stream.bytesToString();
      return _HttpText(res.statusCode, body);
    }

    return run().timeout(
      timeout,
      onTimeout: () => throw TimeoutException('请求超时：$url'),
    );
  }
}

class _RankedCandidate {
  _RankedCandidate({
    required this.candidate,
    required this.rank,
    required this.seasonRank,
    required this.epMatch,
    required this.epNumber,
    required this.index,
  });

  final DanmakuCandidate candidate;
  final int rank;
  final int seasonRank;
  final int epMatch;
  final int? epNumber;
  final int index;
}

/// 宽松解析搜索响应：`{animes:[...]}` 或数组；animeId 必填，bangumiId 缺失用 animeId 兜底。
List<DanmakuAnime>? parseEndpointAnimeList(
  dynamic json,
  String source,
  String sourceName,
) {
  final List<dynamic>? arr;
  if (json is List) {
    arr = json;
  } else if (json is Map && json['animes'] is List) {
    arr = json['animes'] as List;
  } else {
    arr = null;
  }
  if (arr == null) return null; // 响应结构不对 = 该接口不可用（调用方记冷却）
  final out = <DanmakuAnime>[];
  for (final raw in arr) {
    if (raw is! Map) continue;
    final animeId = _toNum(raw['animeId']);
    if (animeId == null) continue;
    final title = (raw['animeTitle'] ?? raw['title'] ?? '').toString().trim();
    if (title.isEmpty) continue;
    final bangumiId = _toNum(raw['bangumiId']);
    final episodeCount = _toNum(raw['episodeCount']);
    out.add(
      DanmakuAnime(
        animeId: animeId.toInt(),
        bangumiId: bangumiId?.toInt(),
        title: title,
        kind: raw['type'] == null ? '' : raw['type'].toString(),
        episodeCount: episodeCount != null && episodeCount > 0
            ? episodeCount.toInt()
            : 0,
        source: source,
        sourceName: sourceName,
      ),
    );
  }
  return out;
}

/// 宽松解析剧集响应：`{bangumi:{episodes:[...]}}`；episodeId 支持数字/数字字符串。
List<DanmakuCandidate>? parseEndpointEpisodes(
  dynamic json,
  String source,
  String sourceName, [
  String animeTitle = '',
]) {
  if (json is! Map) return null;
  final bangumi = json['bangumi'];
  if (bangumi is! Map) return null;
  final eps = bangumi['episodes'];
  if (eps is! List) return null;
  final fallbackTitle = bangumi['animeTitle']?.toString().trim() ?? '';
  final title = animeTitle.trim().isEmpty ? fallbackTitle : animeTitle.trim();
  final out = <DanmakuCandidate>[];
  for (final raw in eps) {
    if (raw is! Map) continue;
    final id = _toNum(raw['episodeId']);
    if (id == null) continue;
    // 接口的集号字段（`episodeNumber`，数字或数字串）——部分条目标题不提集号。
    final epNumRaw = raw['episodeNumber'] ?? raw['episode_number'];
    final epNum = epNumRaw == null ? '' : epNumRaw.toString().trim();
    out.add(
      DanmakuCandidate(
        episodeId: id.toInt(),
        title: title,
        episodeTitle: raw['episodeTitle']?.toString().trim() ?? '',
        episodeNumber: RegExp(r'^\d{1,4}$').hasMatch(epNum) ? epNum : '',
        source: source,
        sourceName: sourceName,
      ),
    );
  }
  return out;
}

num? _toNum(dynamic v) {
  if (v is num) return v;
  if (v is String) return num.tryParse(v.trim());
  return null;
}
