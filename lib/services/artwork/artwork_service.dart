import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../core/logging/app_log.dart';
import '../../core/net/app_http.dart';
import '../../core/net/proxy_runtime.dart';
import '../../models/user_data.dart';
import '../discover/discover_models.dart';
import '../discover/discover_service.dart';
import '../local_store.dart';
import 'tmdb_auth.dart';
import 'tmdb_network.dart';

/// 沉浸观影的横图封面来源：豆瓣 / TMDB / IMDb。
///
/// 统一返回可直接显示的网络地址：
///   · 豆瓣：走本地 `/img` 中继（图床校验 Referer）；
///   · TMDB / IMDb / TVmaze：同样走中继，由中继做跨启动的磁盘缓存。
class ArtworkService {
  ArtworkService(this.http, this.config, {this.store}) {
    _restoreCache();
  }

  final AppHttp http;

  /// 读取当前封面设置（优先级 / TMDB Key）。
  final PlayerSettings Function() config;

  /// 解析结果的持久化缓存（可为空，测试 / 无存储场景直接跳过）。
  final LocalStore? store;

  late final DiscoverService _douban = DiscoverService(http);

  final Map<String, _CachedBackdrop> _cache = {};
  final Map<String, Future<String?>> _inflight = {};
  final Map<String, List<String?>> _stillCache = {};
  final Map<String, Future<List<String?>>> _stillInflight = {};
  String? _biliCookie;
  DateTime? _biliCookieAt;
  String? _wbiMixinKey;
  DateTime? _wbiKeyAt;
  final List<Completer<void>> _waiters = [];
  int _active = 0;

  static const int _maxConcurrent = 4;
  static const Duration _spacing = Duration(milliseconds: 50);
  static const Duration _successTtl = Duration(days: 7);
  /// 没找到图时只负缓存 1 分钟：源站补图 / 新源上线后能很快重试。
  static const Duration _failureTtl = Duration(minutes: 1);
  static const Duration _sourceTimeout = Duration(seconds: 4);

  /// 首选源没有合格横图时，最多再等其它来源这么久。
  ///
  /// 以前要等所有来源都返回或超时（最长 7 秒）才仲裁；弱网下一张封面
  /// 卡住会连带整屏卡片排队。1.8 秒内出现「够用」的图就先上屏。
  static const Duration _fallbackWait = Duration(milliseconds: 1800);

  /// 封面缓存版本：解析逻辑变化（新增来源 / 收紧比例）时递增，
  /// 旧的错误匹配与低清地址会在下一次启动时自动失效。
  static const String _cacheVersion = 'v9';
  static const String _desktopUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  /// 按片名解析一张横图封面；没有则返回 null（调用方回落到竖版海报）。
  ///
  /// 固定优先 TMDB（配置了凭据时），未命中再并发回落豆瓣 / B站 / IMDb / 360。
  /// [altTitle] 是豆瓣等元数据提供的**英文/日文原名**：资源站常写中文译名，
  /// 而 TMDB 条目只有英文原名时，单靠中文片名会漏匹配。
  Future<String?> backdrop(
    String name, {
    String year = '',
    String altTitle = '',
  }) {
    final rawTitle = name.trim();
    if (rawTitle.isEmpty) return Future.value(null);
    final title = dramaTitle(rawTitle);
    final artworkTitle = title.isEmpty ? rawTitle : title;
    final alias = altTitle.trim();
    final settings = config();
    final effectiveYear = year.trim().isEmpty
        ? metadataYear(rawTitle)
        : year.trim();
    final key =
        '$_cacheVersion|${settings.tmdbReadToken}|${settings.tmdbApiKey}|'
        '$artworkTitle|${alias.isEmpty ? '' : '|$alias'}|$effectiveYear';
    final cached = _cache[key];
    if (cached != null) {
      final ttl = cached.found ? _successTtl : _failureTtl;
      if (DateTime.now().difference(cached.at) < ttl) {
        return Future.value(cached.value.isEmpty ? null : cached.value);
      }
    }
    final pending = _inflight[key];
    if (pending != null) return pending;
    final future = _run(
      key,
      artworkTitle,
      effectiveYear,
      altTitle: alias,
    );
    _inflight[key] = future;
    return future.whenComplete(() => _inflight.remove(key));
  }

  /// 设置页「测试封面源」：逐个来源探测，返回每个来源的结果或错误。
  Future<List<ArtworkProbeResult>> probe(
    String name, {
    String year = '',
  }) async {
    final rawTitle = name.trim();
    final title = dramaTitle(rawTitle);
    final artworkTitle = title.isEmpty ? rawTitle : title;
    final results = <ArtworkProbeResult>[];
    final effectiveYear = year.trim().isEmpty
        ? metadataYear(rawTitle)
        : year.trim();
    for (final source in const ['douban', 'tmdb', 'imdb']) {
      try {
        final artwork = await _trySource(source, artworkTitle, effectiveYear);
        final url = (artwork?.url ?? '').trim();
        results.add(
          ArtworkProbeResult(
            source: source,
            url: url,
            error: url.isEmpty ? '没有找到横图' : '',
          ),
        );
      } catch (e) {
        results.add(ArtworkProbeResult(source: source, url: '', error: '$e'));
      }
    }
    return results;
  }

  /// TMDB 分集封面：按剧名/年份找到剧集，再按季/集号取 `still_path`。
  ///
  /// 先试 B 站番剧（无需 Key、国内可直连），没有结果且配置了 TMDB Key 时再走
  /// TMDB。返回值长度固定为 [episodeCount]，没有封面的集用 null 占位。
  Future<List<String?>> episodeStills(
    String name, {
    String year = '',
    int episodeCount = 0,
    int? seasonHint,
    List<int> episodeNumbers = const [],
  }) {
    final rawTitle = name.trim();
    if (rawTitle.isEmpty || episodeCount <= 0) {
      return Future.value(const <String?>[]);
    }
    final title = dramaTitle(rawTitle);
    final artworkTitle = title.isEmpty ? rawTitle : title;
    final settings = config();
    final effectiveYear = year.trim().isEmpty
        ? metadataYear(rawTitle)
        : year.trim();
    final hint = seasonHint ?? seasonHintOf(rawTitle, trailingSequel: true);
    final numbers =
        episodeNumbers.length == episodeCount &&
            episodeNumbers.every((number) => number > 0)
        ? episodeNumbers
        : const <int>[];
    final key =
        'still|${settings.tmdbReadToken}|${settings.tmdbApiKey}|$artworkTitle|$effectiveYear|'
        '$episodeCount|${hint ?? 0}|${numbers.join(',')}';
    final cached = _stillCache[key];
    if (cached != null) return Future.value(cached);
    final pending = _stillInflight[key];
    if (pending != null) return pending;
    final future = _runEpisodeStills(
      artworkTitle,
      effectiveYear,
      episodeCount,
      hint,
      numbers,
    );
    _stillInflight[key] = future;
    return future
        .then((value) {
          // 全空通常是风控 / 网络抖动：不要负缓存，否则本次运行不再重试。
          if (value.any((still) => still != null && still.isNotEmpty)) {
            _rememberStills(key, value);
          }
          return value;
        })
        .whenComplete(() => _stillInflight.remove(key));
  }

  void _rememberStills(String key, List<String?> value) {
    if (_stillCache.length >= 500) _stillCache.remove(_stillCache.keys.first);
    _stillCache[key] = value;
  }

  Future<String?> _run(
    String key,
    String name,
    String year, {
    String altTitle = '',
  }) async {
    await _acquire();
    try {
      if (_spacing > Duration.zero) await Future<void>.delayed(_spacing);
      // 固定来源顺序：TMDB（已配置时）→ 豆瓣 → IMDb；其它兜底源并发补位。
      // 未配置 TMDB 时直接从豆瓣开始，不会空等一个不可用的来源。
      final lead = _tmdbConfigured ? 'tmdb' : 'douban';
      final order = <String>[
        lead,
        ...const ['douban', 'tmdb', 'imdb'].where((s) => s != lead),
      ];
      final sources = <String>[
        for (final source in order)
          if (source != 'tmdb' || _tmdbConfigured) source,
      ];
      // 所有来源并发取：串行时要等前一个来源超时才轮到下一个，
      // 「豆瓣没有横图 → IMDb」会白白多等一倍时间。
      // 记录每个来源的完成结果，后面对未完成的来源只做限时等待。
      final settled = <String, _Artwork?>{};
      final futures = <String, Future<_Artwork?>>{
        for (final source in sources)
          source: _trySourceSafe(
            source,
            name,
            year,
            altTitle: source == 'tmdb' ? altTitle : '',
          ).then((artwork) {
            settled[source] = artwork;
            return artwork;
          }),
      };
      final first = await futures[lead]!;
      // 首选源拿到「够用」的封面才直接返回；如果只是剧照，继续等兜底
      // 来源，看看有没有横版封面可用。
      if (first != null && first.good && !first.isStill) {
        AppLog.i(
          'artwork',
          '$name（$year）封面来源：${first.source.isEmpty ? lead : first.source} '
              '${first.width}x${first.height}'
              '${lead == 'tmdb' ? '（TMDB 优先）' : ''}',
        );
        _remember(key, first.url);
        return first.url;
      }
      // 首选源没有合格横图时补一条 B 站官方横图：番剧 / 国产剧的条目背景图
      // 或第一集封面，hdslb CDN 国内很快。
      if (!futures.containsKey('bilibili')) {
        futures['bilibili'] = _trySourceSafe('bilibili', name, year).then((
          artwork,
        ) {
          settled['bilibili'] = artwork;
          return artwork;
        });
      }
      // 豆瓣搜索接口（suggest / HTML / rexxar）2026-11 起要求登录，
      // 直接用必应站内搜索找豆瓣条目 ID，再按 ID 取免登录的剧照。
      if (!futures.containsKey('douban-bing')) {
        futures['douban-bing'] = _trySourceSafe(
          'douban-bing',
          name,
          year,
        ).then((artwork) {
          settled['douban-bing'] = artwork;
          return artwork;
        });
      }
      // 360 图片搜索兜底（Win-box 同款）：豆瓣 / B 站都没有条目时，
      // 中文横图搜索往往还能找到官方剧照或壁纸。
      if (!futures.containsKey('360')) {
        futures['360'] = _trySourceSafe('360', name, year).then((artwork) {
          settled['360'] = artwork;
          return artwork;
        });
      }
      final rest = <Future<_Artwork?>>[
        for (final entry in futures.entries)
          if (entry.key != lead) entry.value,
      ];
      // 任何来源先拿到「够用」的横图就立刻采用，不再等最慢的那个。
      final goodSignal = Completer<_Artwork?>();
      for (final future in rest) {
        unawaited(
          future.then((artwork) {
            if (artwork != null &&
                artwork.good &&
                !artwork.isStill &&
                !goodSignal.isCompleted) {
              goodSignal.complete(artwork);
            }
          }),
        );
      }
      final early = await goodSignal.future.timeout(
        _fallbackWait,
        onTimeout: () => null,
      );
      if (early != null) {
        AppLog.i(
          'artwork',
          '$name（$year）封面来源：${early.source} '
              '${early.width}x${early.height}（快速命中）',
        );
        _remember(key, early.url);
        return early.url;
      }
      // 到这里说明 1.8 秒内没有来源给出「够用」的横图。再给剩余来源
      // 1.8 秒，手头已完成的结果都拿出来仲裁。
      await Future.any<void>([
        Future.wait<_Artwork?>(rest),
        Future<void>.delayed(_fallbackWait),
      ]);
      var found = _usableArtworks(settled);
      if (found.isEmpty) {
        // 一张都还没有时不能放弃：宁可多等几秒也不要「明明有图却显示无封面」，
        // 而且负缓存会挂 10 分钟。
        await Future.wait<_Artwork?>(rest);
        found = _usableArtworks(settled);
      }
      if (found.isEmpty) {
        AppLog.i('artwork', '$name（$year）没有找到可用横图');
        _remember(key, '');
        return null;
      }
      // 多来源都有图时先分「封面 / 剧照」两池：只要存在封面，剧照就
      // 不参与最终选择；两边都没有时才是无图。
      final covers = found.where((artwork) => !artwork.isStill).toList();
      final pool = covers.isNotEmpty ? covers : found;
      _Artwork best = pool.first;
      for (final artwork in pool.skip(1)) {
        if (artwork.score > best.score) best = artwork;
      }
      AppLog.i(
        'artwork',
        '$name（$year）封面来源：${best.source} '
            '${best.width}x${best.height}'
            '${covers.isEmpty ? '（剧照兜底）' : ''}'
            '（候选 ${found.length}）',
      );
      _remember(key, best.url);
      return best.url;
    } finally {
      _release();
    }
  }

  /// 只保留能直接铺 16:9 的图：2.35:1 之类超宽图裁到卡片里会「异形」。
  static List<_Artwork> _usableArtworks(Map<String, _Artwork?> settled) => [
    for (final artwork in settled.values)
      if (artwork != null &&
          artwork.url.trim().isNotEmpty &&
          artwork.usable)
        artwork,
  ];

  Future<_Artwork?> _trySourceSafe(
    String source,
    String name,
    String year, {
    String altTitle = '',
  }) async {
    try {
      // 搜索类来源要多打一两次接口，4 秒容易在中途被截断，单独放宽；
      // 其它来源保持原时限。
      final timeout = switch (source) {
        'douban-bing' => const Duration(seconds: 8),
        '360' => const Duration(seconds: 7),
        _ => _sourceTimeout,
      };
      return await _trySource(
        source,
        name,
        year,
        altTitle: altTitle,
      ).timeout(timeout, onTimeout: () => null);
    } catch (e) {
      AppLog.w('artwork', '$name 的 $source 封面获取失败：$e');
      return null;
    }
  }

  void _remember(String key, String value) {
    if (_cache.length >= 800) _cache.remove(_cache.keys.first);
    _cache[key] = _CachedBackdrop(
      value,
      DateTime.now(),
      found: value.trim().isNotEmpty,
    );
    if (value.trim().isNotEmpty) _schedulePersist();
  }

  Timer? _persistTimer;

  /// 成功结果落盘（防抖）：下次启动直接复用地址，不再重新搜索。
  void _schedulePersist() {
    if (store == null) return;
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 900), _persistCache);
  }

  void _persistCache() {
    final target = store;
    if (target == null) return;
    final now = DateTime.now();
    final rows = <MapEntry<String, _CachedBackdrop>>[
      for (final entry in _cache.entries)
        if (entry.value.found &&
            now.difference(entry.value.at) < _successTtl &&
            entry.value.value.trim().isNotEmpty)
          entry,
    ]..sort((a, b) => b.value.at.compareTo(a.value.at));
    final data = <String, Object?>{
      for (final entry in rows.take(600))
        entry.key: {
          'u': entry.value.value,
          't': entry.value.at.millisecondsSinceEpoch,
        },
    };
    target.saveArtworkCacheJson(jsonEncode(data)).catchError((Object _) {});
  }

  void _restoreCache() {
    final raw = store?.artworkCacheJson ?? '';
    if (raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final now = DateTime.now();
      for (final entry in decoded.entries) {
        // 旧版本的键不带版本前缀：那时可能缓存了错误的 IMDb 匹配或
        // 低清剧照，不能继续沿用。
        final cacheKey = entry.key.toString();
        if (!cacheKey.startsWith('$_cacheVersion|')) continue;
        final value = entry.value;
        if (value is! Map) continue;
        final url = (value['u'] ?? '').toString().trim();
        final atMs = (value['t'] as num?)?.toInt() ?? 0;
        if (url.isEmpty || atMs <= 0) continue;
        final at = DateTime.fromMillisecondsSinceEpoch(atMs);
        if (now.difference(at) >= _successTtl) continue;
        _cache[cacheKey] = _CachedBackdrop(url, at, found: true);
      }
    } catch (_) {
      // 坏缓存不能挡住启动，直接忽略
    }
  }

  Future<_Artwork?> _trySource(
    String source,
    String name,
    String year, {
    String altTitle = '',
  }) {
    return switch (source) {
      'tmdb' => _tmdbBackdrop(name, year, altTitle: altTitle),
      'imdb' => _imdbBackdrop(name, year),
      'bilibili' => _biliBackdrop(name, year),
      'douban-bing' => _doubanBackdropViaBing(name, year),
      '360' => _so360Backdrop(name, year),
      _ => _doubanBackdrop(name, year),
    };
  }

  Future<void> _acquire() {
    if (_active < _maxConcurrent) {
      _active++;
      return Future.value();
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    return waiter.future;
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _active--;
    }
  }

  // ------------------------------------------------------------------ 豆瓣

  Future<_Artwork?> _doubanBackdrop(String name, String year) async {
    final seen = <String>{};
    for (final candidate in titleCandidates(name)) {
      // findSubject 内部：subject_suggest（常被限流）→ HTML 搜索兜底。
      final subject = await _douban.findSubject(candidate, year: year);
      if (subject == null) continue;
      // 同一个条目换个候选片名还会再命中，别重复拉照片。
      if (!seen.add('${subject.mediaType}|${subject.id}')) continue;
      // 先取预告片封面（官方 16:9 物料），没有再退回剧照横图；
      // 不用竖版海报裁切铺底（低分辨率竖图放大后非常模糊）。
      final trailer = await _doubanTrailerCover(
        subject.mediaType,
        subject.id,
      ).timeout(const Duration(seconds: 2), onTimeout: () => null);
      if (trailer != null && trailer.url.trim().isNotEmpty) return trailer;
      final photo = await _widestDoubanPhoto(subject.mediaType, subject.id);
      if (photo != null && photo.url.trim().isNotEmpty) return photo;
    }
    return null;
  }

  /// 用搜索引擎补豆瓣条目：豆瓣自己的搜索接口已要求登录（`need_login`），
  /// 但按条目 ID 取剧照的接口仍然免登录。先用必应站内搜索找到
  /// `movie.douban.com/subject/<id>`，再照常取剧照 / 预告片封面。
  Future<_Artwork?> _doubanBackdropViaBing(String name, String year) async {
    final ids = <String>[];
    for (final candidate in titleCandidates(name).take(2)) {
      for (final id in await _doubanIdsViaBing(candidate, year)) {
        if (ids.contains(id)) continue;
        ids.add(id);
        if (ids.length >= 2) break;
      }
      if (ids.length >= 2) break;
    }
    if (ids.isEmpty) return null;
    // 站内搜索只给 subject id，不带 movie / tv 类型，也可能搜到同名不同片。
    // 先读条目详情核对片名 / 年份，确认是同一部片后再取剧照。
    final subjects = <(String, String)>[];
    for (final id in ids) {
      for (final type in const ['movie', 'tv']) {
        final subject = await _doubanSubject(type, id);
        if (subject == null) continue;
        if (!_doubanSubjectMatches(subject, name, year)) break;
        subjects.add((type, id));
        break;
      }
      if (subjects.length >= 2) break;
    }
    // 预告片封面优先；没有封面再退回剧照横图。
    for (final subject in subjects) {
      final trailer = await _doubanTrailerCover(
        subject.$1,
        subject.$2,
      ).timeout(const Duration(seconds: 2), onTimeout: () => null);
      if (trailer != null) {
        AppLog.i('artwork', '$name 豆瓣补搜命中 ${subject.$1}/${subject.$2}');
        return trailer;
      }
    }
    for (final subject in subjects) {
      final photos = await _doubanPhotoPage(subject.$1, subject.$2, 0);
      if (photos.isEmpty) continue;
      final artwork = _pickDoubanPhotos([photos]);
      if (artwork != null) {
        AppLog.i('artwork', '$name 豆瓣补搜命中 ${subject.$1}/${subject.$2}');
        return artwork;
      }
    }
    return null;
  }

  /// 豆瓣条目详情（免登录）：用来核对搜索结果确实是这部片。
  Future<Map?> _doubanSubject(String type, String id) async {
    try {
      final res = await http.getText(
        'https://m.douban.com/rexxar/api/v2/$type/$id?for_mobile=1',
        headers: {
          'User-Agent': _desktopUa,
          'Accept': 'application/json',
          'Referer': 'https://m.douban.com/$type/subject/$id/',
        },
        timeout: const Duration(seconds: 5),
      );
      final decoded = jsonDecode(res.body);
      return decoded is Map ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// 条目片名（含原名 / 别名）与年份是否都对得上。
  static bool _doubanSubjectMatches(Map subject, String title, String year) {
    final names = <String>[
      (subject['title'] ?? '').toString(),
      (subject['original_title'] ?? '').toString(),
      if (subject['aka'] is List)
        for (final aka in subject['aka'] as List) aka.toString(),
    ];
    final key = titleMatchKey(title);
    // 两个字的通用片名只认完全同名：搜「爸爸」时，必应会给出
    // 《爸爸去哪儿》这类前缀相同的条目，取了就是错片。
    final matched = key.length <= 2
        ? names.any(
            (name) => name.trim().isNotEmpty && titleMatchKey(name) == key,
          )
        : names.any(
            (name) => name.trim().isNotEmpty && _titleMatches(name, title),
          );
    if (!matched) return false;
    final wanted = year.trim();
    final actual = (subject['year'] ?? '').toString().trim();
    if (wanted.isNotEmpty && actual.isNotEmpty && wanted != actual) {
      return false;
    }
    return true;
  }

  /// 必应站内搜索豆瓣条目 ID：结果标题必须能对上片名，
  /// 避免把「相关影片 / 影评」页面里的 ID 当成这部片。
  Future<List<String>> _doubanIdsViaBing(String title, String year) async {
    final key = titleMatchKey(title);
    if (key.length < 2) return const [];
    final query = [
      'site:movie.douban.com/subject',
      title,
      if (year.trim().isNotEmpty) year.trim(),
    ].join(' ');
    final uri = Uri.https('cn.bing.com', '/search', {
      'q': query,
      'count': '20',
      'setlang': 'zh-CN',
    });
    try {
      final res = await http.getText(
        uri.toString(),
        headers: const {
          'User-Agent': _desktopUa,
          'Accept-Language': 'zh-CN,zh;q=0.9',
        },
        timeout: const Duration(seconds: 6),
      );
      final ids = <String>[];
      for (final match in RegExp(
        r'movie\.douban\.com/subject/(\d+)/?[^"]*"[^>]*>(.*?)</a>',
        dotAll: true,
      ).allMatches(res.body)) {
        final id = match.group(1) ?? '';
        if (id.isEmpty || ids.contains(id)) continue;
        final text = _htmlUnescape(
          (match.group(2) ?? '').replaceAll(RegExp(r'<[^>]+>'), ''),
        );
        if (!_titleMatches(text, title)) continue;
        ids.add(id);
        if (ids.length >= 2) break;
      }
      if (ids.isNotEmpty) {
        AppLog.i('artwork', '豆瓣补搜 $title → ${ids.join(',')}');
      }
      return ids;
    } catch (e) {
      AppLog.w('artwork', '豆瓣补搜失败（$title）：$e');
      return const [];
    }
  }

  /// 豆瓣剧照里挑一张最宽、分辨率最高、最接近 16:9 的图。
  ///
  /// 先翻第一页；第一页就有 1280 宽以上的标准横图时直接返回，避免每部片
  /// 都固定打 4 个照片请求。电视剧横图少且排得靠后，才继续翻后面几页。
  Future<_Artwork?> _widestDoubanPhoto(String mediaType, String id) async {
    final type = mediaType == 'tv' ? 'tv' : 'movie';
    final firstPage = await _doubanPhotoPage(type, id, 0);
    final first = _pickDoubanPhotos([firstPage]);
    if (first != null && first.width >= 1280 && first.usable) return first;
    if (type != 'tv') return first;
    // 第一页不满 50 张说明已经是全部剧照，再翻只是三次空请求。
    if (firstPage.length < 50) return first;
    final pages = await Future.wait([
      for (final start in const [50, 100, 150])
        _doubanPhotoPage(type, id, start),
    ]);
    return _pickDoubanPhotos([firstPage, ...pages]) ?? first;
  }

  static _Artwork? _pickDoubanPhotos(Iterable<List> pages) {
    _Artwork? best;
    var bestScore = 0.0;
    for (final photos in pages) {
      for (final item in photos) {
        if (item is! Map) continue;
        final image = item['image'];
        if (image is! Map) continue;
        final large = image['large'] is Map ? image['large'] as Map : image;
        var url = (large['url'] ?? '').toString().trim();
        final width = (large['width'] as num?)?.toDouble() ?? 0;
        final height = (large['height'] as num?)?.toDouble() ?? 0;
        if (url.isEmpty || width <= 0 || height <= 0) continue;
        final ratio = width / height;
        // 竖图 / 4:3 / 2.35:1 超宽图裁进 16:9 卡片都会「异形」或糊，
        // 只接受接近 16:9 且足够宽的剧照。
        if (width < 1200 || ratio < 1.45 || ratio > 2.0) continue;
        url = _fullDoubanPhotoUrl(url);
        var score = width;
        if (ratio >= 1.6 && ratio <= 1.9) {
          score += 600;
        } else if (ratio >= 1.5) {
          score += 250;
        }
        if (score > bestScore) {
          bestScore = score;
          best = _Artwork(
            relayImageUrl(url, referer: 'https://m.douban.com/'),
            width: width.round(),
            height: height.round(),
            source: 'douban',
            isStill: true,
          );
        }
      }
      final cover = (pick?['cover_url'] ?? '').toString().trim();
      if (cover.isEmpty) return null;
      return _Artwork(
        relayImageUrl(cover, referer: 'https://movie.douban.com/'),
        width: 720,
        height: 405,
        source: 'douban-trailer',
      );
    } catch (_) {
      return null;
    }
    return best;
  }

  /// 豆瓣预告片封面：720×405 的 16:9 官方截图。
  ///
  /// 分辨率不如剧照，但胜在「一定有、且一定对应该条目」——国产剧的剧照
  /// 列表经常 200 张全是竖版海报，这时它就是最快的合格兜底。
  Future<_Artwork?> _doubanTrailerCover(
    String mediaType,
    String id,
  ) async {
    try {
      final type = mediaType == 'tv' ? 'tv' : 'movie';
      final res = await http.getText(
        'https://m.douban.com/rexxar/api/v2/$type/$id/trailers?for_mobile=1',
        headers: {
          'User-Agent': _desktopUa,
          'Referer': 'https://m.douban.com/$type/subject/$id/',
        },
        timeout: const Duration(seconds: 5),
      );
      final decoded = jsonDecode(res.body);
      final trailers = decoded is Map ? decoded['trailers'] : null;
      if (trailers is! List) return null;
      // 优先「预告片」而不是花絮 / MV：正片物料更接近海报视觉。
      Map? pick;
      for (final item in trailers) {
        if (item is! Map) continue;
        final cover = (item['cover_url'] ?? '').toString().trim();
        if (cover.isEmpty) continue;
        pick ??= item;
        final title = (item['title'] ?? '').toString();
        if (title.contains('预告')) {
          pick = item;
          break;
        }
      }
      final cover = (pick?['cover_url'] ?? '').toString().trim();
      if (cover.isEmpty) return null;
      return _Artwork(
        relayImageUrl(cover, referer: 'https://movie.douban.com/'),
        width: 720,
        height: 405,
        source: 'douban-trailer',
      );
    } catch (_) {
      return null;
    }
  }

  Future<List> _doubanPhotoPage(String type, String id, int start) async {
    try {
      final res = await http.getText(
        'https://m.douban.com/rexxar/api/v2/$type/$id/photos'
        '?start=$start&count=50&for_mobile=1',
        headers: {
          'User-Agent': _desktopUa,
          'Referer': 'https://m.douban.com/$type/subject/$id/',
        },
        timeout: const Duration(seconds: 8),
      );
      final decoded = jsonDecode(res.body);
      final photos = decoded is Map ? decoded['photos'] : null;
      return photos is List ? photos : const [];
    } catch (_) {
      return const [];
    }
  }

  /// 豆瓣照片地址还原成原图：
  /// `…/view/photo/large/public/p2890906384.jpg?…w/600…`（600px 签名缩略图）
  /// → `https://img3.doubanio.com/view/photo/l/public/p2890906384.jpg`。
  static String _fullDoubanPhotoUrl(String raw) {
    final match = RegExp(r'/public/(p\d+)\.jpg').firstMatch(raw);
    if (match == null) return raw;
    return 'https://img3.doubanio.com/view/photo/l/public/'
        '${match.group(1)}.jpg';
  }

  // ------------------------------------------------------------------ B 站

  /// B 站番剧 / 影视的官方横图。
  ///
  /// 优先 `bkg_cover`（条目背景横图），没有就用第一集的 16:9 封面。
  /// hdslb CDN 国内直连很快，而且标题是 B 站自己匹配好的，准确率比
  /// 中文片名去 IMDb 撞运气高得多。
  Future<_Artwork?> _biliBackdrop(String name, String year) async {
    final cookie = await _biliCookieValue();
    if (cookie.isEmpty) return null;
    final seen = <int>{};
    for (final candidate in titleCandidates(name)) {
      try {
        final hit = await _biliSearch(candidate, year, cookie, 0, null);
        if (hit == null) continue;
        final seasonId = (hit['season_id'] as num?)?.toInt() ?? 0;
        if (seasonId <= 0 || !seen.add(seasonId)) continue;
        final result = await _biliSeason(seasonId, cookie);
        if (result == null) continue;
        // 条目背景图通常是 1920×1080；分集封面实测常为 960×600，
        // 不能按 1600×900 冒充高清图，否则会提前压过更高清的豆瓣 / TMDB。
        final background = (result['bkg_cover'] ?? '').toString().trim();
        if (background.isNotEmpty) {
          return _Artwork(
            relayImageUrl(
              _biliHttpsUrl(background),
              referer: 'https://www.bilibili.com/',
            ),
            width: 1600,
            height: 900,
            source: 'bilibili',
          );
        }
        for (final episode in result['episodes'] is List
            ? result['episodes'] as List
            : const <Object>[]) {
          if (episode is! Map) continue;
          final raw = (episode['cover'] ?? episode['ep_cover'] ?? '')
              .toString()
              .trim();
          if (raw.isEmpty) continue;
          return _Artwork(
            relayImageUrl(
              _biliHttpsUrl(raw),
              referer: 'https://www.bilibili.com/',
            ),
            // 保守估值：分集封面多为 960×600，只作为兜底候选参与仲裁。
            width: 960,
            height: 600,
            source: 'bilibili',
            isStill: true,
          );
        }
      } catch (e) {
        AppLog.w('artwork', 'B 站横图获取失败（$candidate）：$e');
        return null;
      }
    }
    return null;
  }

  /// B 站番剧分集封面：无需 Key，国内可直连。
  Future<List<String?>> _biliEpisodeStills(
    String name,
    String year,
    int episodeCount,
    List<int> episodeNumbers,
    int? seasonHint,
  ) async {
    var cookie = await _biliCookieValue();
    if (cookie.isEmpty) return const <String?>[];
    for (final candidate in episodeTitleCandidates(name)) {
      try {
        final stills = await _biliStillsForCandidate(
          candidate,
          cookie,
          year,
          episodeCount,
          episodeNumbers,
          seasonHint,
        );
        if (stills != null) return stills;
      } on AppHttpException catch (e) {
        // 412/403 基本是 Cookie 失效或风控：清缓存、重新取首页 Cookie，
        // 当前候选重试一次；其它错误交给上层转 TMDB。
        if (e.statusCode != 412 && e.statusCode != 403) rethrow;
        AppLog.w('artwork', 'B 站搜索被拦截（HTTP ${e.statusCode}），刷新 Cookie 后重试');
        _biliCookie = null;
        _biliCookieAt = null;
        _wbiMixinKey = null;
        _wbiKeyAt = null;
        cookie = await _biliCookieValue();
        if (cookie.isEmpty) rethrow;
        final stills = await _biliStillsForCandidate(
          candidate,
          cookie,
          year,
          episodeCount,
          episodeNumbers,
          seasonHint,
        );
        if (stills != null) return stills;
      }
    }
    return const <String?>[];
  }

  Future<List<String?>?> _biliStillsForCandidate(
    String candidate,
    String cookie,
    String year,
    int episodeCount,
    List<int> episodeNumbers,
    int? seasonHint,
  ) async {
    final hit = await _biliSearch(
      candidate,
      year,
      cookie,
      episodeCount,
      seasonHint,
    );
    if (hit == null) return null;
    final seasonId = (hit['season_id'] as num?)?.toInt() ?? 0;
    if (seasonId <= 0) return null;
    final result = await _biliSeason(seasonId, cookie);
    final stills = _biliStillsFromSeason(result, episodeCount, episodeNumbers);
    return stills.any((still) => still != null) ? stills : null;
  }

  static List<String?> _biliStillsFromSeason(
    Object? result,
    int episodeCount,
    List<int> episodeNumbers,
  ) {
    final episodes = result is Map ? result['episodes'] : null;
    if (episodes is! List) return const <String?>[];
    final numbered = <(int, String)>[];
    final unnumbered = <String>[];
    for (final raw in episodes) {
      if (raw is! Map) continue;
      final cover = (raw['cover'] ?? raw['ep_cover'] ?? '').toString().trim();
      if (cover.isEmpty) continue;
      final url = cover.startsWith('http://')
          ? 'https://${cover.substring(7)}'
          : cover;
      final number = episodeNumber((raw['title'] ?? '').toString());
      if (number > 0) {
        numbered.add((number, url));
      } else {
        unnumbered.add(url);
      }
    }
    if (numbered.isEmpty && unnumbered.isEmpty) return const <String?>[];
    numbered.sort((a, b) => a.$1.compareTo(b.$1));
    final byNumber = <int, String>{
      for (final entry in numbered) entry.$1: entry.$2,
    };
    final max = numbered.isEmpty ? 0 : numbered.last.$1;
    final stills = List<String?>.filled(episodeCount, null);
    if (episodeNumbers.length == episodeCount &&
        episodeNumbers.toSet().length == episodeCount &&
        max > 0) {
      final valid = episodeNumbers.every(
        (number) => number > 0 && number <= max && byNumber.containsKey(number),
      );
      if (valid) {
        for (var i = 0; i < episodeCount; i++) {
          stills[i] = byNumber[episodeNumbers[i]];
        }
        return stills;
      }
    }
    // 集号对不上时按集号顺序回填。预告 / 花絮没有集号，不能混进正片序列，
    // 否则会把「预告」封面当成第一集，后面全部错位。
    final ordered = numbered.isNotEmpty
        ? [for (final entry in numbered) entry.$2]
        : unnumbered;
    for (var i = 0; i < episodeCount && i < ordered.length; i++) {
      stills[i] = ordered[i];
    }
    return stills;
  }

  Future<String> _biliCookieValue() async {
    final now = DateTime.now();
    final cached = _biliCookie;
    final at = _biliCookieAt;
    if (cached != null &&
        at != null &&
        now.difference(at) < const Duration(hours: 6)) {
      return cached;
    }
    // 搜索风控只认首页下发的 buvid3 + b_nut。finger/spi 的 b_3/b_4
    // 单独使用会稳定 412（2026-11 实测），所以首页优先、SPI 兜底。
    try {
      await http.probeText(
        'https://www.bilibili.com/',
        headers: {
          'User-Agent': _desktopUa,
          'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'zh-CN,zh;q=0.9',
        },
        timeout: const Duration(seconds: 12),
        maxBytes: 4096,
      );
      final warm = http.cookiesFor('https://www.bilibili.com/');
      if (warm.isNotEmpty) {
        _biliCookie = warm;
        _biliCookieAt = now;
        return warm;
      }
    } catch (e) {
      AppLog.w('artwork', 'B 站首页 Cookie 获取失败：$e');
    }
    // 兜底：首页不可用时再用 finger/spi（部分网络下仍可能被搜索风控拦）。
    try {
      final res = await http.getText(
        'https://api.bilibili.com/x/frontend/finger/spi',
        headers: {
          'User-Agent': _desktopUa,
          'Referer': 'https://www.bilibili.com/',
          'Accept': 'application/json',
        },
        timeout: const Duration(seconds: 12),
      );
      final decoded = jsonDecode(res.body);
      final data = decoded is Map ? decoded['data'] : null;
      final b3 = data is Map ? (data['b_3'] ?? '').toString().trim() : '';
      final b4 = data is Map ? (data['b_4'] ?? '').toString().trim() : '';
      final cookie = [
        if (b3.isNotEmpty) 'buvid3=$b3',
        if (b4.isNotEmpty) 'buvid4=$b4',
      ].join('; ');
      if (cookie.isNotEmpty) {
        _biliCookie = cookie;
        _biliCookieAt = now;
      }
      return cookie;
    } catch (e) {
      AppLog.w('artwork', 'B 站指纹获取失败：$e');
      return '';
    }
  }

  Future<Map<String, dynamic>?> _biliSearch(
    String name,
    String year,
    String cookie,
    int episodeCount,
    int? seasonHint,
  ) async {
    final query = _titleInfo(name, trailingSequel: true);
    if (query.key.isEmpty) return null;
    // 显式季号优先；否则用片名里的季号（`第二季` / `2`）。
    final wantedSeason =
        seasonHint ?? (query.explicitSeason ? query.season : null);
    Map<String, dynamic>? best;
    var bestScore = 0;
    var bestYear = '';
    var bestType = '';
    var confident = false;
    // 番剧和影视（国产剧 / 自制剧）属于两个分类：只搜 media_bangumi 会漏掉
    // 大量真人剧。先搜番剧；如果已经按季号 + 集数精确命中，就不再多打一次
    // 接口，减少触发风控的概率。
    for (final searchType in const ['media_bangumi', 'media_ft']) {
      final List results;
      try {
        results = await _biliSearchResults(searchType, name, cookie);
      } catch (e) {
        // 412/403 要交给上层刷新 Cookie 后重试；media_ft 失败只跳过该分类。
        if (searchType == 'media_bangumi') rethrow;
        AppLog.w('artwork', 'B 站 $searchType 搜索失败，跳过：$e');
        continue;
      }
      for (final item in results) {
        if (item is! Map) continue;
        final title = _cleanBiliText((item['title'] ?? '').toString());
        final original = _cleanBiliText((item['org_title'] ?? '').toString());
        final titleInfo = _titleInfo(title, trailingSequel: true);
        final originalInfo = _titleInfo(original, trailingSequel: true);
        // 只认归一后完全一致的片名。以前用 contains 通配，
        // 「鬼灭之刃 柱训练篇」「鬼灭之刃 第二季」都会被当成「鬼灭之刃」，
        // 再按集数决胜就会刮到完全错误的季。
        final hitInfo = _biliTitleHit(query, titleInfo)
            ? titleInfo
            : (_biliTitleHit(query, originalInfo) ? originalInfo : null);
        if (hitInfo == null) continue;
        final hitSeason = titleInfo.explicitSeason
            ? titleInfo.season
            : (originalInfo.explicitSeason ? originalInfo.season : null);
        var seasonPenalty = 0;
        if (wantedSeason != null) {
          // 没有季号标记的条目按第一季处理：搜第二季时不能拿第一季来顶。
          if ((hitSeason ?? 1) != wantedSeason) continue;
        } else if (hitSeason != null && hitSeason > 1) {
          // 片名没写季号时不直接丢弃续作：资源站常把「某某 第二季」写成
          // 普通片名，直接排除会一个候选都命中不了。这里只降权，
          // 有第一季时仍然优先第一季。
          seasonPenalty = -20;
        }
        final epSize = (item['ep_size'] as num?)?.toInt() ?? 0;
        var score = 100 + seasonPenalty;
        if (wantedSeason == null && hitSeason == null) score += 10;
        final pubYear = _yearFromBiliTime(item['pubtime']);
        if (year.isNotEmpty && pubYear == year) score += 10;
        if (episodeCount > 0 && epSize > 0) {
          final diff = (epSize - episodeCount).abs();
          if (diff == 0) {
            score += 8;
          } else if (diff <= 2) {
            score += 3;
          } else if (diff > 6) {
            score -= 6;
          }
        }
        // 同一部番的中配/粤配封面相同：没有指定配音时优先原版条目。
        final hitDub = titleInfo.dub || originalInfo.dub;
        if (hitDub) score += query.dub ? 2 : -2;
        if (score > bestScore) {
          bestScore = score;
          bestYear = pubYear;
          best = Map<String, dynamic>.from(item);
          bestType = searchType;
          confident =
              epSize > 0 &&
              epSize == episodeCount &&
              (wantedSeason == null
                  ? hitSeason == null
                  : (hitSeason ?? 1) == wantedSeason);
        }
      }
      if (best != null && confident) break;
    }
    final picked = best == null
        ? '无结果'
        : '选中 ${_cleanBiliText((best['title'] ?? '').toString())} '
              '[$bestType] ep=${best['ep_size']} 年份=$bestYear';
    AppLog.i(
      'artwork',
      'B 站匹配 $name → key=${query.key} 季=${wantedSeason ?? 1} $picked',
    );
    return best;
  }

  /// B 站命中判定：完全一致优先；「主标题 + 副标题」允许前缀命中，
  /// 但续作 / 篇章 / 剧场版必须排除。
  ///
  /// 例：「复仇者联盟4 加码臻享版」清洗成「复仇者联盟4」后，B 站条目是
  /// 「复仇者联盟4：终局之战」，属于同一部片；而「鬼灭之刃」不能命中
  /// 「鬼灭之刃 柱训练篇」。
  static bool _biliTitleHit(_TitleInfo query, _TitleInfo hit) {
    if (query.key == hit.key) return true;
    final short = query.key.length <= hit.key.length ? query.key : hit.key;
    final long = query.key.length <= hit.key.length ? hit.key : query.key;
    if (short.length < 4 || !long.startsWith(short)) return false;
    final suffix = long.substring(short.length);
    return !RegExp(
      r'(第|篇|季|章|剧场版|ova|oad|special|final|最终|完结|前传|后传|外传|特别|上篇|下篇|中篇|part|[0-9])',
      caseSensitive: false,
    ).hasMatch(suffix);
  }

  Future<List> _biliSearchResults(
    String searchType,
    String keyword,
    String cookie,
  ) async {
    final params = <String, String>{
      'search_type': searchType,
      'keyword': keyword,
      // 默认只返回 10 条，正片（第一季）常被续作/中配版挤出列表；
      // 放宽到 30 条才能看到全部候选。
      'page_size': '30',
    };
    // WBI 签名：搜索接口对未签名的请求风控更严，带上 `w_rid` + `wts`
    // 能明显降低 412。取不到密钥时退回普通接口，不让签名故障挡住刮削。
    var endpoint = 'https://api.bilibili.com/x/web-interface/search/type';
    final mixinKey = await _wbiMixinKeyValue(cookie);
    if (mixinKey.isNotEmpty) {
      params.addAll(_wbiSign(params, mixinKey));
      endpoint = 'https://api.bilibili.com/x/web-interface/wbi/search/type';
    }
    final res = await http.getText(
      Uri.parse(endpoint).replace(queryParameters: params).toString(),
      headers: {
        'User-Agent': _desktopUa,
        'Referer': 'https://www.bilibili.com/',
        'Accept': 'application/json',
        'Cookie': cookie,
      },
      timeout: const Duration(seconds: 15),
    );
    final decoded = jsonDecode(res.body);
    if (decoded is! Map) return const [];
    final code = decoded['code'];
    if (code is num && code.toInt() != 0) return const [];
    final data = decoded['data'];
    final results = data is Map ? data['result'] : null;
    return results is List ? results : const [];
  }

  /// WBI mixinKey 的固定重排表（B 站前端常量）。
  static const List<int> _wbiMixinKeyEncTab = [
    46,
    47,
    18,
    2,
    53,
    8,
    23,
    32,
    15,
    50,
    10,
    31,
    58,
    3,
    45,
    35,
    27,
    43,
    5,
    49,
    33,
    9,
    42,
    19,
    29,
    28,
    14,
    39,
    12,
    38,
    41,
    13,
    37,
    48,
    7,
    16,
    24,
    55,
    40,
    61,
    26,
    17,
    0,
    1,
    60,
    51,
    30,
    4,
    22,
    25,
    54,
    21,
    56,
    59,
    6,
    63,
    57,
    62,
    11,
    36,
    20,
    34,
    44,
    52,
  ];

  /// 取 WBI 的 mixinKey：`nav` 接口不需要登录，未登录也会返回 `wbi_img`。
  Future<String> _wbiMixinKeyValue(String cookie) async {
    final now = DateTime.now();
    final cached = _wbiMixinKey;
    final at = _wbiKeyAt;
    if (cached != null &&
        at != null &&
        now.difference(at) < const Duration(hours: 6)) {
      return cached;
    }
    try {
      final res = await http.getText(
        'https://api.bilibili.com/x/web-interface/nav',
        headers: {
          'User-Agent': _desktopUa,
          'Referer': 'https://www.bilibili.com/',
          'Accept': 'application/json',
          'Cookie': cookie,
        },
        timeout: const Duration(seconds: 12),
      );
      final decoded = jsonDecode(res.body);
      // 未登录时 code=-101，但 data.wbi_img 仍然存在，不能按 code 判断。
      final data = decoded is Map ? decoded['data'] : null;
      final wbi = data is Map ? data['wbi_img'] : null;
      final imgKey = _wbiKeyFromUrl(
        wbi is Map ? (wbi['img_url'] ?? '').toString() : '',
      );
      final subKey = _wbiKeyFromUrl(
        wbi is Map ? (wbi['sub_url'] ?? '').toString() : '',
      );
      if (imgKey.isEmpty || subKey.isEmpty) return '';
      final orig = imgKey + subKey;
      final mixin = StringBuffer();
      for (final index in _wbiMixinKeyEncTab) {
        if (index >= orig.length || mixin.length >= 32) break;
        mixin.write(orig[index]);
      }
      final key = mixin.toString();
      if (key.length != 32) return '';
      _wbiMixinKey = key;
      _wbiKeyAt = now;
      return key;
    } catch (e) {
      AppLog.w('artwork', 'B 站 WBI 密钥获取失败：$e');
      return '';
    }
  }

  /// 从 `https://i0.hdslb.com/bfs/wbi/<key>.png` 里取出 `<key>`。
  static String _wbiKeyFromUrl(String url) {
    final name = url.split('/').last.trim();
    if (name.isEmpty) return '';
    final dot = name.indexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// 生成 `wts` / `w_rid`：按 key 排序 → 过滤 `!'()*` → RFC 3986 编码
  /// → 拼 mixinKey 后取 MD5。
  static Map<String, String> _wbiSign(
    Map<String, String> params,
    String mixinKey,
  ) {
    final wts = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
    final all = <String, String>{...params, 'wts': wts};
    final keys = all.keys.toList()..sort();
    final query = keys
        .map((key) {
          final value = all[key]!.replaceAll(RegExp(r"[!'()*]"), '');
          return '${_wbiEncode(key)}=${_wbiEncode(value)}';
        })
        .join('&');
    return {
      'wts': wts,
      'w_rid': md5.convert(utf8.encode('$query$mixinKey')).toString(),
    };
  }

  /// `encodeURIComponent` 口径：空格编码成 %20，而不是 `+`。
  static String _wbiEncode(String input) {
    final out = StringBuffer();
    for (final byte in utf8.encode(input)) {
      final plain =
          (byte >= 0x30 && byte <= 0x39) || // 0-9
          (byte >= 0x41 && byte <= 0x5A) || // A-Z
          (byte >= 0x61 && byte <= 0x7A) || // a-z
          byte == 0x2D || // -
          byte == 0x2E || // .
          byte == 0x5F || // _
          byte == 0x7E; // ~
      if (plain) {
        out.writeCharCode(byte);
      } else {
        out.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return out.toString();
  }

  static String _yearFromBiliTime(Object? raw) {
    if (raw is num && raw > 0) {
      final value = raw.toInt();
      final millis = value > 1000000000000 ? value : value * 1000;
      return '${DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true).year}';
    }
    final text = raw?.toString().trim() ?? '';
    final match = RegExp(r'(19|20)\d{2}').firstMatch(text);
    return match?.group(0) ?? '';
  }

  Future<Map<String, dynamic>?> _biliSeason(int seasonId, String cookie) async {
    final res = await http.getText(
      Uri.parse('https://api.bilibili.com/pgc/view/web/season')
          .replace(queryParameters: {'season_id': '$seasonId'})
          .toString(),
      headers: {
        'User-Agent': _desktopUa,
        'Referer': 'https://www.bilibili.com/',
        'Accept': 'application/json',
        'Cookie': cookie,
      },
      timeout: const Duration(seconds: 15),
    );
    final decoded = jsonDecode(res.body);
    if (decoded is! Map) return null;
    final code = decoded['code'];
    if (code is num && code.toInt() != 0) return null;
    final result = decoded['result'];
    return result is Map ? Map<String, dynamic>.from(result) : null;
  }

  static String _biliHttpsUrl(String raw) =>
      raw.startsWith('http://') ? 'https://${raw.substring(7)}' : raw;

  static String _cleanBiliText(String raw) {
    var text = raw.replaceAll(RegExp('<[^>]*>'), '');
    text = text
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>');
    return text.trim();
  }

  // ------------------------------------------------------------------ TMDB

  Future<Map<String, dynamic>?> _tmdbFind(
    String name,
    String year, {
    bool preferTv = false,
    bool trailingSequel = false,
    String altTitle = '',
  }) async {
    final credential = _tmdbCredential();
    if (!credential.isConfigured) return null;
    // 资源站常写中文译名，TMDB 条目却只有英文原名；把两者都当「自己」，
    // 搜索时也都试一遍（参数 `altTitle` 可由豆瓣原名提供）。
    final aliases = <String>[
      for (final raw in [name, altTitle])
        if (raw.trim().isNotEmpty) raw.trim(),
    ];
    final aliasKeys = <String>{};
    for (final alias in aliases) {
      final key = _titleInfo(alias, trailingSequel: trailingSequel).key;
      if (key.isNotEmpty) aliasKeys.add(key);
    }
    if (aliasKeys.isEmpty) return null;
    final queries = <String>{...aliases}.toList();

    Map<String, dynamic>? best;
    var bestScore = -1.0;
    var bestPopularity = -1.0;
    // 没能在片名上直接命中时，用别名 / 译名兜底：
    // TMDB 的 zh-CN 标题与资源站的中文译名经常不一致（尤其韩剧 / 冷门片），
    // 只认 title/original_title 会直接判「无结果」。
    final plausible = <({Map<String, dynamic> item, bool yearMatch})>[];
    final plausibleIds = <String>{};
    for (final queryText in queries) {
      // 中文查询先按 zh-CN 找；没有完全命中的再按 en-US 兜底一次。
      // 一旦拿到 120 分（片名完全相等）就停止，避免重复请求。
      for (final language in const ['zh-CN', 'en-US']) {
        final params = <String, String>{
          'language': language,
          'query': queryText,
          'include_adult': 'false',
          ...credential.queryParams,
        };
        final res = await _tmdbGet(
          'search/multi',
          query: params,
          headers: credential.headers,
        );
        final decoded = jsonDecode(res.body);
        final results = decoded is Map ? decoded['results'] : null;
        if (results is! List) continue;
        for (final item in results) {
          if (item is! Map) continue;
          final mediaType = (item['media_type'] ?? '').toString();
          if (mediaType != 'movie' && mediaType != 'tv') continue;
          // 分集剧照只接受剧集条目，同名电影不能拿来配电视剧的某一集。
          if (preferTv && mediaType != 'tv') continue;
          final title = (item['title'] ?? item['name'] ?? '').toString();
          final original =
              (item['original_title'] ?? item['original_name'] ?? '')
                  .toString();
          final titleKey = _titleInfo(
            title,
            trailingSequel: trailingSequel,
          ).key;
          final originalKey = _titleInfo(
            original,
            trailingSequel: trailingSequel,
          ).key;
          // 完全相等优先；续作 / 副标题差异允许「包含」但降权，
          // 否则《流浪地球2》这类片名会把第一部的封面刮过来。
          var matchScore = 0.0;
          if (aliasKeys.contains(titleKey) || aliasKeys.contains(originalKey)) {
            matchScore = 120;
          } else {
            for (final key in [titleKey, originalKey]) {
              if (key.isEmpty) continue;
              for (final alias in aliasKeys) {
                if (key.contains(alias) || alias.contains(key)) {
                  final shorter = key.length < alias.length
                      ? key.length
                      : alias.length;
                  final longer = key.length < alias.length
                      ? alias.length
                      : key.length;
                  final ratio = longer == 0 ? 0.0 : shorter / longer;
                  if (ratio >= 0.62) matchScore = 55;
                }
              }
            }
          }
          final date = (item['release_date'] ?? item['first_air_date'] ?? '')
              .toString();
          final yearMatch = year.isNotEmpty && date.startsWith(year);
          final popularity = (item['popularity'] as num?)?.toDouble() ?? 0;
          // 片名对不上也要留下年份对得上的候选：译名差异很大的条目
          // 只能靠「唯一 + 年份」或别名库确认。同一 id 在多语言查询里
          // 会重复返回，先去重，否则「年份唯一」永远不成立。
          final idKey = '$mediaType:${item['id']}';
          if (plausibleIds.add(idKey)) {
            plausible.add((
              item: Map<String, dynamic>.from(item),
              yearMatch: yearMatch,
            ));
          }
          if (matchScore <= 0) continue;
          var score = matchScore;
          if (yearMatch) score += 35;
          if (preferTv) score += mediaType == 'tv' ? 10 : 0;
          if (score > bestScore ||
              (score == bestScore && popularity > bestPopularity)) {
            bestScore = score;
            bestPopularity = popularity;
            best = Map<String, dynamic>.from(item);
          }
        }
        if (bestScore >= 120) break;
      }
      if (bestScore >= 120) break;
    }
    // 年份对得上的候选优先，其次按人气；别名库只查最靠前的几个。
    plausible.sort((a, b) {
      if (a.yearMatch != b.yearMatch) return a.yearMatch ? -1 : 1;
      final ap = (a.item['popularity'] as num?)?.toDouble() ?? 0;
      final bp = (b.item['popularity'] as num?)?.toDouble() ?? 0;
      return bp.compareTo(ap);
    });
    // 年份唯一对得上时直接接受：译名完全不同的情况（如中文名 vs 英文原名）
    // 也能拿到图，不必再打两轮别名接口。
    if (best == null) {
      final byYear = plausible.where((row) => row.yearMatch).toList();
      if (byYear.length == 1) {
        best = byYear.first.item;
        bestScore = 120;
      }
    }
    // 仍有多个候选时，查 TMDB 别名库 / 各语言译名确认。
    if (bestScore < 120) {
      for (final row in plausible.take(3)) {
        final mediaType = (row.item['media_type'] ?? '').toString();
        final id = (row.item['id'] ?? '').toString();
        if (mediaType.isEmpty || id.isEmpty) continue;
        final aliases = await _tmdbAliasKeys(mediaType, id);
        if (aliases.isEmpty) continue;
        if (aliases.any(aliasKeys.contains)) {
          best = row.item;
          bestScore = 120;
          break;
        }
      }
    }
    // 没有年份时只在搜索结果唯一时接受，避免把同名不同片凑上来。
    if (best == null && year.isEmpty && plausible.length == 1) {
      best = plausible.first.item;
    }
    AppLog.i(
      'artwork',
      'TMDB 匹配 $name${altTitle.trim().isEmpty ? '' : ' / $altTitle'} '
          '→ 别名=${aliasKeys.join(',')} '
          '${best == null ? '无结果' : '选中 ${best['name'] ?? best['title']} '
                    '(${best['media_type']}) id=${best['id']}'}',
    );
    return best;
  }

  /// TMDB 别名 / 各语言译名里的片名集合（已归一成匹配键）。
  ///
  /// 中文资源站的译名经常和 TMDB 的 zh-CN 标题不同；只要别名库里出现
  /// 同一个片名，就仍能确认是同一条目，而不是直接判「匹配不到」。
  Future<Set<String>> _tmdbAliasKeys(String mediaType, String id) async {
    Future<Map<String, dynamic>?> safe(String path) async {
      try {
        return await _tmdbJson(path, const {});
      } catch (_) {
        return null;
      }
    }

    final results = await Future.wait([
      safe('$mediaType/$id/alternative_titles'),
      safe('$mediaType/$id/translations'),
    ]);
    final keys = <String>{};
    void add(Object? raw) {
      final title = (raw ?? '').toString().trim();
      if (title.isEmpty) return;
      final key = _titleInfo(title).key;
      if (key.isNotEmpty) keys.add(key);
    }

    for (final json in results) {
      if (json == null) continue;
      final titles = json['titles'];
      if (titles is List) {
        for (final raw in titles) {
          if (raw is! Map) continue;
          add(raw['title']);
        }
      }
      final translations = json['translations'];
      if (translations is List) {
        for (final raw in translations) {
          if (raw is! Map) continue;
          final data = raw['data'];
          if (data is! Map) continue;
          add(data['title']);
          add(data['name']);
        }
      }
    }
    return keys;
  }

  Future<Map<String, dynamic>?> _tmdbJson(
    String path,
    Map<String, String> query,
  ) async {
    final credential = _tmdbCredential();
    if (!credential.isConfigured) return null;
    final res = await _tmdbGet(
      path,
      query: {...query, ...credential.queryParams},
      headers: credential.headers,
    );
    final decoded = jsonDecode(res.body);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
  }

  Future<_Artwork?> _tmdbBackdrop(
    String name,
    String year, {
    String altTitle = '',
  }) async {
    for (final candidate in titleCandidates(name)) {
      // 「… 2」可能是第二季，也可能是《玩具总动员2》这种片名的一部分：
      // 先按完整片名找，找不到再把结尾数字当季号剥掉重试。
      final trailingSequel =
          seasonHintOf(candidate, trailingSequel: true) != null &&
          seasonHintOf(candidate) == null;
      for (final stripSequel in [false, if (trailingSequel) true]) {
        final best = await _tmdbFind(
          candidate,
          year,
          trailingSequel: stripSequel,
          altTitle: altTitle,
        );
        if (best == null) continue;
        final mediaType = (best['media_type'] ?? '').toString();
        final id = (best['id'] ?? '').toString();
        // 先取条目主 backdrop：这是 TMDB 自己选定的主视觉 / 封面。
        final backdrop = (best['backdrop_path'] ?? '').toString().trim();
        if (backdrop.isNotEmpty) {
          return _Artwork(
            relayImageUrl(
              _tmdbImage(backdrop),
              referer: 'https://www.themoviedb.org/',
            ),
            // backdrop_path 固定是 16:9 原图，给一个保守尺寸参与仲裁。
            width: 1600,
            height: 900,
            source: 'tmdb',
          );
        }
        if (id.isNotEmpty) {
          // 主 backdrop 缺失时再从图库挑：带语言的封面优先，无文字剧照兜底。
          // 不带语言过滤：韩剧 / 日影的横图常被标成 `ko` / `ja` / `xx`。
          final imagesJson = await _tmdbJson('$mediaType/$id/images', const {});
          final artwork = _pickTmdbBackdrop(imagesJson?['backdrops']);
          if (artwork != null) return artwork;
        }
        // 没有任何横图时，用剧集的分集剧照兜底（TMDB 电影没有独立剧照接口）。
        if (mediaType == 'tv' && id.isNotEmpty) {
          final still = await _tmdbEpisodeStillBackdrop(id, year);
          if (still != null) return still;
        }
      }
    }
    return null;
  }

  /// TMDB 剧照兜底：取剧集第一张有效的分集 `still_path`（16:9 原图）。
  ///
  /// 只在 `images.backdrops` 与搜索结果都没有横图时调用。季选择优先
  /// 「年份对得上的季」，其次按季号升序，跳过特典季（season_number 0）。
  Future<_Artwork?> _tmdbEpisodeStillBackdrop(String id, String year) async {
    final detail = await _tmdbJson('tv/$id', {'language': 'zh-CN'});
    final seasons = detail?['seasons'];
    if (seasons is! List) return null;
    final rows = <({int number, bool yearMatch})>[];
    for (final raw in seasons) {
      if (raw is! Map) continue;
      final number = (raw['season_number'] as num?)?.toInt() ?? 0;
      final count = (raw['episode_count'] as num?)?.toInt() ?? 0;
      if (number <= 0 || count <= 0) continue;
      final airDate = (raw['air_date'] ?? '').toString().trim();
      final airYear =
          RegExp(r'^(19|20)\d{2}').firstMatch(airDate)?.group(0) ?? '';
      rows.add((
        number: number,
        yearMatch: year.isNotEmpty && airYear == year,
      ));
    }
    rows.sort((a, b) {
      if (a.yearMatch != b.yearMatch) return a.yearMatch ? -1 : 1;
      return a.number.compareTo(b.number);
    });
    for (final row in rows.take(3)) {
      final season = await _tmdbJson('tv/$id/season/${row.number}', {
        'language': 'zh-CN',
      });
      final path = _firstStillPath(season);
      if (path.isEmpty) continue;
      return _Artwork(
        relayImageUrl(
          _tmdbImage(path),
          referer: 'https://www.themoviedb.org/',
        ),
        // 分集剧照原图通常是 1920×1080；给足尺寸，避免在仲裁里被低清图压过。
        width: 1920,
        height: 1080,
        source: 'tmdb-still',
        isStill: true,
      );
    }
    return null;
  }

  /// 从季详情里取第一张可用剧照：优先第 1 集，其次任意一集。
  static String _firstStillPath(Object? season) {
    final episodes = season is Map ? season['episodes'] : null;
    if (episodes is! List) return '';
    var fallback = '';
    for (final raw in episodes) {
      if (raw is! Map) continue;
      final path = (raw['still_path'] ?? '').toString().trim();
      if (path.isEmpty) continue;
      final number = (raw['episode_number'] as num?)?.toInt() ?? 0;
      if (number == 1) return path;
      if (fallback.isEmpty) fallback = path;
    }
    return fallback;
  }

  /// 从 TMDB `images.backdrops` 里挑官方横图。
  ///
  /// 先选「封面」：带 `iso_639_1` 的 backdrop 通常带片名 logo / 主视觉；
  /// 没有封面时才退回 `null` / `xx` 的无文字剧照。两池分开，避免一张
  /// 4K 剧照仅凭分辨率压过 1080p 的官方封面。
  static _Artwork? _pickTmdbBackdrop(Object? backdrops) {
    if (backdrops is! List) return null;
    _Artwork? bestCover;
    var bestCoverScore = 0.0;
    _Artwork? bestStill;
    var bestStillScore = 0.0;
    for (final item in backdrops) {
      if (item is! Map) continue;
      final path = (item['file_path'] ?? '').toString().trim();
      if (path.isEmpty) continue;
      final width = (item['width'] as num?)?.toInt() ?? 0;
      final height = (item['height'] as num?)?.toInt() ?? 0;
      if (width < 1200 || height <= 0) continue;
      final ratio = width / height;
      if (ratio < 1.45 || ratio > 2.0) continue;
      final language = (item['iso_639_1'] ?? '').toString().toLowerCase();
      // `xx` / `none` 与空一样表示「无文字」，这类更可能是剧照。
      final isStill = language.isEmpty || language == 'xx' || language == 'none';
      var score = width.toDouble();
      if (ratio >= 1.6 && ratio <= 1.9) score += 400;
      final vote = (item['vote_average'] as num?)?.toDouble() ?? 0;
      score += vote * 12;
      if (!isStill) {
        // 有语言标签的 backdrop 更像官方封面 / 主视觉。
        score += (language == 'zh' ||
                language == 'en' ||
                language == 'ko' ||
                language == 'ja')
            ? 400
            : 120;
      }
      final artwork = _Artwork(
        relayImageUrl(
          _tmdbImage(path),
          referer: 'https://www.themoviedb.org/',
        ),
        width: width,
        height: height,
        source: 'tmdb',
        isStill: isStill,
      );
      if (isStill) {
        if (score > bestStillScore) {
          bestStillScore = score;
          bestStill = artwork;
        }
      } else if (score > bestCoverScore) {
        bestCoverScore = score;
        bestCover = artwork;
      }
    }
    return bestCover ?? bestStill;
  }

  Future<List<String?>> _runEpisodeStills(
    String name,
    String year,
    int episodeCount,
    int? seasonHint,
    List<int> episodeNumbers,
  ) async {
    await _acquire();
    try {
      if (_spacing > Duration.zero) await Future<void>.delayed(_spacing);
      var bili = const <String?>[];
      try {
        bili = await _biliEpisodeStills(
          name,
          year,
          episodeCount,
          episodeNumbers,
          seasonHint,
        );
      } catch (e) {
        // B 站风控 / 网络失败只影响 B 站，不能挡住 TMDB 兜底。
        AppLog.w('artwork', '$name 的 B 站分集封面失败，转 TMDB：$e');
      }
      if (bili.any((still) => still != null)) {
        AppLog.i(
          'artwork',
          '$name 的分集封面来源：B 站 '
              '${bili.whereType<String>().length}/$episodeCount 集',
        );
        return bili;
      }
      if (!_tmdbConfigured) {
        AppLog.i('artwork', '$name 没有分集封面：B 站无结果且未配置 TMDB');
        return const <String?>[];
      }
      for (final candidate in episodeTitleCandidates(name)) {
        try {
          final stills = await _tmdbEpisodeStillsForName(
            candidate,
            year,
            episodeCount,
            seasonHint,
            episodeNumbers,
          );
          if (stills.any((still) => still != null)) {
            AppLog.i(
              'artwork',
              '$name 的分集封面来源：TMDB '
                  '${stills.whereType<String>().length}/$episodeCount 集',
            );
            return stills;
          }
        } catch (e) {
          AppLog.w('artwork', '$name 的 TMDB 分集封面失败：$e');
        }
      }
      AppLog.i('artwork', '$name 没有分集封面：B 站与 TMDB 都无结果');
      return const <String?>[];
    } catch (e) {
      AppLog.w('artwork', '$name 的分集封面获取失败：$e');
      return const <String?>[];
    } finally {
      _release();
    }
  }

  Future<List<String?>> _tmdbEpisodeStillsForName(
    String name,
    String year,
    int episodeCount,
    int? seasonHint,
    List<int> episodeNumbers,
  ) async {
    final best = await _tmdbFind(
      name,
      year,
      preferTv: true,
      trailingSequel: true,
    );
    if (best == null) return const <String?>[];
    if ((best['media_type'] ?? '').toString() != 'tv') {
      return const <String?>[];
    }
    final id = (best['id'] as num?)?.toInt() ?? 0;
    if (id <= 0) return const <String?>[];
    final detail = await _tmdbJson('tv/$id', {'language': 'zh-CN'});
    if (detail == null) return const <String?>[];
    final seasonNumbers = pickSeasons(
      detail['seasons'],
      episodeCount,
      seasonHint,
      year: year,
    );
    if (seasonNumbers.isEmpty) return const <String?>[];
    final seasonEpisodes = <int, List<String?>>{};
    for (final number in seasonNumbers) {
      final season = await _tmdbJson('tv/$id/season/$number', {
        'language': 'zh-CN',
      });
      seasonEpisodes[number] = _seasonStills(season);
    }
    return _alignEpisodeStills(seasonEpisodes, episodeCount, episodeNumbers);
  }

  /// 选出与站点集数对应的 TMDB 季：季号提示 → 集数完全一致 → 单季取前 N 集
  /// → 多季集数之和一致 → 年份对得上的季 → 最近一季兜底。
  /// 与 Kazumi/AVBox 的 mapEpisodes 口径一致。
  static List<int> pickSeasons(
    Object? seasons,
    int episodeCount,
    int? seasonHint, {
    String year = '',
  }) {
    if (seasons is! List || episodeCount <= 0) return const [];
    final parsed = <({int number, int count, String airYear})>[];
    for (final raw in seasons) {
      if (raw is! Map) continue;
      final number = (raw['season_number'] as num?)?.toInt() ?? 0;
      final count = (raw['episode_count'] as num?)?.toInt() ?? 0;
      if (number <= 0 || count <= 0) continue;
      final airDate = (raw['air_date'] ?? '').toString().trim();
      final airYear =
          RegExp(r'^(19|20)\d{2}').firstMatch(airDate)?.group(0) ?? '';
      parsed.add((number: number, count: count, airYear: airYear));
    }
    parsed.sort((a, b) => a.number.compareTo(b.number));
    if (parsed.isEmpty) return const [];
    if (seasonHint != null) {
      final hintedIndex = parsed.indexWhere(
        (season) => season.number == seasonHint,
      );
      if (hintedIndex >= 0) {
        final hinted = parsed[hintedIndex];
        // 站点集数不超过该季（更新中 / 缺集）→ 直接用该季。
        if (episodeCount <= hinted.count + 1) return [hinted.number];
        // 站点把连续两季合并编号（第二季 12 集 + 第三季 12 集，
        // 资源站按 24 集排）→ 合并相邻季。
        var total = hinted.count;
        final numbers = <int>[hinted.number];
        for (
          var i = hintedIndex + 1;
          i < parsed.length && numbers.length < 3;
          i++
        ) {
          if (parsed[i].number != numbers.last + 1) break;
          total += parsed[i].count;
          numbers.add(parsed[i].number);
          if (total >= episodeCount) return numbers;
        }
      }
    }
    final exact = parsed
        .where((season) => season.count == episodeCount)
        .toList();
    if (exact.length == 1) return [exact.first.number];
    if (parsed.length == 1 && episodeCount <= parsed.first.count) {
      return [parsed.first.number];
    }
    final total = parsed.fold<int>(0, (sum, season) => sum + season.count);
    if (total == episodeCount) {
      return [for (final season in parsed) season.number];
    }
    // 续作常常只靠年份区分：片名带年份时，优先选该年播出的季。
    if (seasonHint == null && year.isNotEmpty) {
      final byYear = parsed.where((season) => season.airYear == year).toList();
      if (byYear.length == 1) return [byYear.first.number];
    }
    // 多季集数相同（常见 12/12）时集数无法区分，资源站通常列的是当前
    // 正在播的那一季：取最近一季，否则会完全不给封面。
    if (exact.length > 1) return [exact.last.number];
    // 最后兜底：站点集数比最近季少（更新中 / 预告占位），用最近一季补齐。
    if (seasonHint == null && episodeCount <= parsed.last.count) {
      return [parsed.last.number];
    }
    return const [];
  }

  static List<String?> _seasonStills(Object? json) {
    final episodes = json is Map ? json['episodes'] : null;
    if (episodes is! List) return const <String?>[];
    final pairs = <(int, String)>[];
    var max = 0;
    for (final raw in episodes) {
      if (raw is! Map) continue;
      final number = (raw['episode_number'] as num?)?.toInt() ?? 0;
      if (number <= 0) continue;
      final path = (raw['still_path'] ?? '').toString().trim();
      if (path.isEmpty) continue;
      pairs.add((number, _tmdbStill(path)));
      if (number > max) max = number;
    }
    if (max == 0) return const <String?>[];
    final out = List<String?>.filled(max, null);
    for (final pair in pairs) {
      out[pair.$1 - 1] = pair.$2;
    }
    return out;
  }

  static List<String?> _alignEpisodeStills(
    Map<int, List<String?>> seasonEpisodes,
    int episodeCount,
    List<int> episodeNumbers,
  ) {
    final stills = List<String?>.filled(episodeCount, null);
    if (episodeNumbers.length == episodeCount &&
        episodeNumbers.toSet().length == episodeCount) {
      if (seasonEpisodes.length == 1) {
        final list = seasonEpisodes.values.first;
        final max = episodeNumbers.reduce((a, b) => a > b ? a : b);
        if (max <= list.length) {
          for (var i = 0; i < episodeCount; i++) {
            stills[i] = list[episodeNumbers[i] - 1];
          }
          return stills;
        }
      }
    }
    var index = 0;
    final numbers = seasonEpisodes.keys.toList()..sort();
    for (final season in numbers) {
      for (final still in seasonEpisodes[season]!) {
        if (index >= episodeCount) return stills;
        stills[index++] = still;
      }
    }
    return stills;
  }

  /// 从标题识别季号：`第2季` / `Season 2` / `S02`。
  ///
  /// [trailingSequel] 为 true 时，额外把结尾的 ` 2` / ` II` / ` 2nd` 当成
  /// 第二季（动漫站常见「赛博朋克：边缘行者 2」这种写法）。只在分集刮削
  /// 里开启；电影片名（如《玩具总动员2》）仍按完整片名匹配。
  static int? seasonHintOf(String text, {bool trailingSequel = false}) {
    final value = _toHalfWidth(text.trim());
    if (value.isEmpty) return null;
    final zh = RegExp(r'第\s*([0-9]+|[一二三四五六七八九十百零两]+)\s*[季部]')
        .firstMatch(value);
    if (zh != null) {
      final number = _cnNumber(zh.group(1)!);
      if (number != null && number > 0) return number;
    }
    final en = RegExp(
      r'(?:season|series)\s*([0-9]{1,2})',
      caseSensitive: false,
    ).firstMatch(value);
    if (en != null) return int.tryParse(en.group(1)!);
    final ordinal = RegExp(
      r'([0-9]{1,2})(?:st|nd|rd|th)\s+season',
      caseSensitive: false,
    ).firstMatch(value);
    if (ordinal != null) return int.tryParse(ordinal.group(1)!);
    final short = RegExp(
      r'(?:^|[\s._\-:：])S(?:eason)?\s*([0-9]{1,2})(?:[\s._\-]|$)',
      caseSensitive: false,
    ).firstMatch(value);
    if (short != null) return int.tryParse(short.group(1)!);
    if (!trailingSequel) return null;
    final tail = RegExp(
      r'[\s：:\-–—_]\s*(?:第\s*)?'
      r'([2-9]|1[0-9]|II|III|IV|V|VI|VII|VIII|IX|X|2nd|3rd|4th|5th)\s*$',
      caseSensitive: false,
    ).firstMatch(value);
    if (tail == null) return null;
    final token = tail.group(1)!;
    final numeric = int.tryParse(token);
    if (numeric != null) return numeric;
    final ordinalNumber = int.tryParse(
      RegExp(r'^[0-9]+').firstMatch(token)?.group(0) ?? '',
    );
    if (ordinalNumber != null) return ordinalNumber;
    return _romanNumber(token);
  }

  static int? _romanNumber(String raw) {
    const values = {
      'I': 1,
      'II': 2,
      'III': 3,
      'IV': 4,
      'V': 5,
      'VI': 6,
      'VII': 7,
      'VIII': 8,
      'IX': 9,
      'X': 10,
    };
    return values[raw.toUpperCase()];
  }

  static int? _cnNumber(String raw) {
    final direct = int.tryParse(raw);
    if (direct != null) return direct;
    const digits = {
      '零': 0,
      '一': 1,
      '二': 2,
      '两': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
    };
    if (raw == '十') return 10;
    final ten = raw.indexOf('十');
    if (ten >= 0) {
      final tens = ten == 0 ? 1 : digits[raw[0]];
      final ones = ten == raw.length - 1 ? 0 : digits[raw[ten + 1]];
      if (tens == null || ones == null) return null;
      return tens * 10 + ones;
    }
    return digits[raw];
  }

  /// 从站点剧集名提取集号（`第3集` / `EP03` / `03`），与 AVBox 同口径。
  static int episodeNumber(String raw) {
    var text = raw.replaceAll(RegExp(r'\[.*?\]|\(.*?\)|【.*?】'), '');
    text = text.replaceAll(
      RegExp(r'\d+(?:\.\d+)?\s*(?:gb|mb|gib|mib)\b', caseSensitive: false),
      '',
    );
    text = text.replaceAll(RegExp(r'\b(19|20)\d{2}\b'), '');
    text = text.toLowerCase().replaceAll(
      RegExp(
        r'2160p|1080p|720p|480p|4k|h26[45]|x26[45]|hevc|avc|'
        r'\b\d{3,4}[pi]\b|mp4|mkv',
      ),
      '',
    );
    final strong = RegExp(r'(?:ep|第|e)\s?(\d{1,4})').firstMatch(text);
    if (strong != null) return int.tryParse(strong.group(1)!) ?? -1;
    // `Show - 03` 这类用分隔符接集号的形态只接受 1~2 位且必须完整，
    // 避免把 `The.Covenant.2006.108...` 里的 108 当成集号。
    final weak = RegExp(r'[\-.\s]\s?(\d{1,2})(?![0-9])').firstMatch(text);
    if (weak != null) return int.tryParse(weak.group(1)!) ?? -1;
    // 没有 EP/第/Sxx 这类标记时，只接受纯数字集名。
    if (RegExp(r'[a-z\u4e00-\u9fa5]').hasMatch(text)) return -1;
    final digits = text.replaceAll(RegExp(r'\D+'), '');
    if (digits.isEmpty) return -1;
    return int.tryParse(digits) ?? -1;
  }

  /// 从资源名里提取真正的剧名，用于封面匹配。
  ///
  /// `XXX【甄彩】` → `XXX`；`20261026【玉置秋】直播…` → `玉置秋`；
  /// `《玉置秋》尺度…` → `玉置秋`。取不到时保留原片名。
  static String dramaTitle(String raw) {
    final extracted = _extractDramaTitle(raw);
    final cleaned = cleanMetadataTitle(extracted);
    return cleaned.isEmpty ? extracted.trim() : cleaned;
  }

  static String _extractDramaTitle(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return '';
    // 前缀日期：20261026 / 2026-10-26 / [2026-10-26]
    text = text.replaceAll(RegExp(r'^\s*\d{8}\s*'), ' ');
    text = text.replaceAll(
      RegExp(r'^\s*(?:19|20)\d{2}[-./年]\d{1,2}[-./月]\d{1,2}日?\s*'),
      ' ',
    );
    // 前缀演员/频道标签，只去「…」，保留【…】给剧名判断。
    text = text.replaceAll(RegExp(r'^\s*「[^」]{1,30}」\s*'), ' ').trim();
    // 《标题》优先
    final book = RegExp(r'《([^》]{1,80})》').firstMatch(text);
    if (book != null) {
      final inner = book.group(1)!.trim();
      if (inner.isNotEmpty && !_isGenericResourceText(inner)) return inner;
    }
    // 结尾资源标签：XXX【甄彩】/ [HD] / （国语）
    for (var i = 0; i < 3; i++) {
      final before = text;
      text = text
          .replaceAll(
            RegExp(
              r'\s*(?:【[^】]{1,40}】|\[[^\]]{1,40}\]|（[^）]{1,40}）|\([^)]{1,40}\))\s*$',
            ),
            ' ',
          )
          .trim();
      if (text == before) break;
    }
    // 日期后面跟【剧名】直播…：括号里才是剧名
    final bracket = RegExp(r'【([^】]{1,60})】').firstMatch(text);
    if (bracket != null) {
      final inner = bracket.group(1)!.trim();
      final outside = text.replaceAll(RegExp(r'【[^】]*】'), ' ').trim();
      if (inner.isNotEmpty && _isGenericResourceText(outside)) return inner;
    }
    // 演员标签 + 多名字用 / 分隔时取第一个
    text = text
        .replaceAll(RegExp(r'^\s*(?:「[^」]{1,30}」|【[^】]{1,30}】)\s*'), ' ')
        .trim();
    final parts = text.split(RegExp(r'\s*/\s*'));
    if (parts.length > 1 && parts.first.trim().length <= 24) {
      text = parts.first.trim();
    }
    // 开头的直播/回顾等泛词与秒数
    text = text
        .replaceAll(RegExp(r'^\s*(?:直播|回看|回顾|解说|剪辑|花絮|片段|正片片段|二创|混剪)\s*'), ' ')
        .trim();
    text = text.replaceAll(RegExp(r'^\s*\d+秒\s*'), ' ').trim();
    return text;
  }

  static bool _isGenericResourceText(String text) {
    final value = text.trim();
    if (value.isEmpty) return true;
    const words = [
      '直播',
      '回看',
      '回顾',
      '解说',
      '剪辑',
      '花絮',
      '完整版',
      '加长版',
      '抢先版',
      '片段',
      '正片',
      '预告',
      '二创',
      '混剪',
      '第',
    ];
    for (final word in words) {
      if (value.startsWith(word)) return true;
    }
    return value
        .replaceAll(RegExp(r'[\d\s\p{P}\p{S}]', unicode: true), '')
        .isEmpty;
  }

  static const List<String> _metadataTags = [
    '2160p',
    '1080p',
    '720p',
    '480p',
    '4k',
    'hdr',
    'hdr10',
    'dolby',
    'bluray',
    'blu-ray',
    'web-dl',
    'webrip',
    'remux',
    'proper',
    'x265',
    'x264',
    'h264',
    'h265',
    'hevc',
    'avc',
    'aac',
    'dts',
    'atmos',
    '10bit',
    '8bit',
    '国语',
    '粤语',
    '中字',
    '中英',
    '双语',
    '无删减',
    '完整版',
    '加长版',
    '导演剪辑版',
    '加码臻享版',
    '臻享版',
    '加码版',
    '尊享版',
    '特别版',
    '重映版',
    '院线版',
    'imax版',
    'imax',
    '杜比版',
    '点映版',
    '公映版',
    '修复版',
    '高清版',
    '超清版',
    '蓝光版',
    '未删减版',
    '无删减版',
    '抢先版',
    '尝鲜版',
    '会员版',
    '网络版',
    'tv版',
    '普通话版',
    '原声版',
    '双语版',
    '中字版',
    '国粤双语',
    '国英双语',
    '中配版',
    '日语版',
    '国语版',
    '粤语版',
  ];

  /// 版本标签一次替换：按长度倒序，让「中字版」先于「中字」命中，
  /// 避免只删掉词根留下一个孤零零的「版」。
  static final RegExp _metadataTagRegex = RegExp(
    ([..._metadataTags]..sort((a, b) => b.length.compareTo(a.length)))
        .map(RegExp.escape)
        .join('|'),
    caseSensitive: false,
  );

  /// 片名归一：去掉括号里的版本说明、清晰度/压制/语言标签和结尾年份。
  static String cleanMetadataTitle(String raw) {
    var text = raw.replaceAll(
      RegExp(r'\[[^\]]*\]|\([^)]*\)|【[^】]*】|（[^）]*）'),
      ' ',
    );
    text = text.replaceAll(_metadataTagRegex, ' ');
    text = text.replaceAll(
      RegExp(r'\d+(?:\.\d+)?\s*(?:gb|mb|gib|mib)\b', caseSensitive: false),
      ' ',
    );
    text = text.replaceAll(
      RegExp(
        r'\.(mkv|mp4|avi|ts|rmvb|flv|m2ts|mov|wmv)\b',
        caseSensitive: false,
      ),
      ' ',
    );
    text = text.replaceAll(RegExp(r'\b(19|20)\d{2}\b'), ' ');
    text = text.replaceAll(RegExp(r'[_\.]+'), ' ');
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.replaceAll(RegExp(r'^[-–—]+|[-–—]+$'), '').trim();
  }

  /// 去掉季号后缀，得到适合元数据搜索的主标题。
  static String stripSeasonSuffix(String value, {bool trailingSequel = false}) {
    var text = value.replaceAll(RegExp(r'第\s*[0-9一二三四五六七八九十两]+\s*[季部]'), ' ');
    text = text.replaceAll(
      RegExp(r'season\s*[0-9]{1,2}', caseSensitive: false),
      ' ',
    );
    text = text.replaceAll(
      RegExp(r'([0-9]{1,2})(?:st|nd|rd|th)\s+season', caseSensitive: false),
      ' ',
    );
    text = text.replaceAll(
      RegExp(r'(?:^|[\s._-])S[0-9]{1,2}(?:[\s._-]|$)', caseSensitive: false),
      ' ',
    );
    if (trailingSequel) {
      text = text.replaceAll(
        RegExp(
          r'[\s：:\-–—_]\s*(?:第\s*)?'
          r'(?:[2-9]|1[0-9]|II|III|IV|V|VI|VII|VIII|IX|X|2nd|3rd|4th|5th)\s*$',
          caseSensitive: false,
        ),
        ' ',
      );
    }
    return text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// 片名归一后的比较键：只用于「是不是同一部片」的判断。
  ///
  /// 去掉标点 / 符号 / 空白 / 配音版本标记，保留文字与数字。
  /// 「鬼灭之刃 柱训练篇」和「鬼灭之刃」会得到不同的键，避免跨季串片。
  static String titleMatchKey(String raw) {
    var text = _toHalfWidth(dramaTitle(raw));
    if (text.isEmpty) text = _toHalfWidth(raw.trim());
    text = text.replaceAll(RegExp('<[^>]*>'), ' ');
    final book = RegExp(r'《([^》]{1,80})》').firstMatch(text);
    if (book != null) text = book.group(1)!;
    text = text.toLowerCase();
    // 配音版本不是片名身份的一部分；同一部番的中配/粤配封面相同。
    text = text.replaceAll(RegExp(r'(中配版|粤配版|国语版|日语版|台配版|中配|粤配|国语|日语|台配)'), '');
    // 「：」「·」「×」「（）」等标点在两边都折叠掉，避免同片不同键。
    return text.replaceAll(RegExp(r'[\s\p{P}\p{S}]', unicode: true), '');
  }

  static _TitleInfo _titleInfo(String raw, {bool trailingSequel = false}) {
    var text = dramaTitle(raw);
    if (text.isEmpty) text = raw.trim();
    final hint = seasonHintOf(text, trailingSequel: trailingSequel);
    final base = hint == null
        ? text
        : stripSeasonSuffix(text, trailingSequel: trailingSequel);
    return _TitleInfo(
      key: titleMatchKey(base.isEmpty ? text : base),
      season: hint ?? 1,
      explicitSeason: hint != null,
      dub: RegExp(r'中配|粤配|国语|日语|台配').hasMatch(raw),
    );
  }

  static String _toHalfWidth(String text) {
    final buffer = StringBuffer();
    for (final rune in text.runes) {
      if (rune == 0x3000) {
        buffer.write(' ');
      } else if (rune >= 0xFF01 && rune <= 0xFF5E) {
        buffer.writeCharCode(rune - 0xFEE0);
      } else {
        buffer.writeCharCode(rune);
      }
    }
    return buffer.toString();
  }

  /// 元数据搜索候选：原名 → 去版本标签 → 去季号。
  static List<String> titleCandidates(String raw) {
    final original = raw.trim();
    if (original.isEmpty) return const [];
    final cleaned = cleanMetadataTitle(original);
    final base = stripSeasonSuffix(cleaned);
    final list = <String>[];
    void add(String value) {
      final text = value.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isEmpty || list.contains(text)) return;
      list.add(text);
    }

    // 先搜最干净的片名：原始资源名里的集数 / 清晰度标签会把搜索结果带偏。
    add(cleaned);
    add(base);
    add(original);
    return list;
  }

  /// 分集刮削候选：常规候选之外，把结尾的 ` 2` 当季号剥掉再搜一次。
  ///
  /// 例如「赛博朋克：边缘行者 2」→「赛博朋克：边缘行者」，配合
  /// `seasonHint = 2` 定位到第二季；第一季不会被误选。
  static List<String> episodeTitleCandidates(String raw) {
    final list = <String>[...titleCandidates(raw)];
    final stripped = stripSeasonSuffix(
      dramaTitle(raw),
      trailingSequel: true,
    ).trim();
    if (stripped.isNotEmpty && !list.contains(stripped)) list.add(stripped);
    return list;
  }

  /// 从片名里取年份（用于补全调用方没传 year 的场景）。
  static String metadataYear(String raw) {
    final matches = RegExp(r'(19|20)\d{2}').allMatches(raw);
    if (matches.isEmpty) return '';
    return matches.last.group(0)!;
  }

  /// TMDB 请求统一出口：传输失败时把「域名被污染 / 需要代理」讲清楚。
  Future<HttpResponseText> _tmdbGet(
    String path, {
    Map<String, String> query = const {},
    Map<String, String> headers = const {},
  }) async {
    final url = Uri.parse('https://api.themoviedb.org/3/$path')
        .replace(queryParameters: query)
        .toString();
    try {
      return await http.getText(
        url,
        headers: headers,
        timeout: const Duration(seconds: 15),
      );
    } on AppHttpException catch (e) {
      // 401 / 404 这类是凭据或数据问题，原样抛出，别用代理提示盖住。
      if (e.statusCode != null) rethrow;
      throw AppHttpException(
        '连不上 api.themoviedb.org：${await _tmdbFailureReason(e)}',
      );
    }
  }

  /// 传输层失败时给一句能照着做的原因：很多时候是域名被 DNS 污染，不是配置错。
  Future<String> _tmdbFailureReason(AppHttpException error) async {
    final proxyActive = ProxyRuntime.instance.enabled;
    var addresses = const <String>[];
    try {
      final resolved = await InternetAddress.lookup('api.themoviedb.org')
          .timeout(const Duration(seconds: 5));
      addresses = [for (final item in resolved) item.address];
    } catch (_) {
      // 解析失败按「没有可用地址」处理
    }
    final diagnosis = describeTmdbDns(
      addresses: addresses,
      proxyActive: proxyActive,
    );
    return '${error.message}。$diagnosis';
  }

  /// TMDB 是否已配置（v3 Key 或 v4 Token 任一可用）。
  bool get _tmdbConfigured => _tmdbCredential().isConfigured;

  /// 读取并归一 TMDB 凭据（v3 Key / v4 Token，见 [TmdbCredential]）。
  ///
  /// 填了但格式不对时只记一条脱敏日志，然后按「未配置」处理，
  /// 免得把一份错配置当成能用的来源反复请求。
  TmdbCredential _tmdbCredential() {
    final settings = config();
    final credential = TmdbCredential.resolve(
      apiKey: settings.tmdbApiKey,
      readToken: settings.tmdbReadToken,
    );
    if (!credential.isConfigured && credential.problem.isNotEmpty) {
      AppLog.w('artwork', 'TMDB 凭据无法识别：${credential.problem}');
    }
    return credential;
  }

  static String _tmdbImage(String path) => tmdbImageUrl(path);

  static String _tmdbStill(String path) => tmdbImageUrl(path, size: 'w780');

  // ------------------------------------------------------------------ IMDb

  /// IMDb 公开建议接口找条目 → GraphQL 取剧照（无需账号或 Key）。
  ///
  /// 剧集还会并发查 TVmaze（按 IMDb id 映射）：TVmaze 的分集剧照通常是
  /// 1920×1080 的官方图，比豆瓣竖版海报裁切清晰得多。
  Future<_Artwork?> _imdbBackdrop(String name, String year) async {
    for (final candidate in titleCandidates(name)) {
      final match = await _imdbFind(candidate, year);
      if (match == null) continue;
      final id = (match['id'] ?? '').toString();
      if (id.isEmpty) continue;
      final kind = (match['qid'] ?? '').toString();
      final isTv = kind.startsWith('tv');
      final englishTitle = (match['l'] ?? '').toString().trim();
      final itemYear = (match['y'] as num?)?.toInt().toString().trim() ?? year;
      final results = await Future.wait([
        _imdbImages(id),
        if (isTv)
          _tvmazeStill(id, title: englishTitle, year: itemYear)
        else
          Future<_Artwork?>.value(),
      ]);
      _Artwork? best;
      for (final artwork in results) {
        if (artwork == null) continue;
        if (best == null || artwork.score > best.score) best = artwork;
      }
      if (best != null) return best;
    }
    return null;
  }

  Future<Map<String, dynamic>?> _imdbFind(String name, String year) async {
    final queryKey = titleMatchKey(name);
    if (queryKey.isEmpty) return null;
    final res = await http.getText(
      'https://v3.sg.media-imdb.com/suggestion/x/'
      '${Uri.encodeComponent(name)}.json',
      headers: {'User-Agent': _desktopUa},
      timeout: const Duration(seconds: 8),
    );
    final decoded = jsonDecode(res.body);
    final list = decoded is Map ? decoded['d'] : null;
    if (list is! List) return null;
    Map? best;
    var bestScore = -1000.0;
    var bestTitleMatched = false;
    Map? firstYear;
    var index = 0;
    for (final item in list) {
      if (item is! Map) continue;
      final id = (item['id'] ?? '').toString();
      final title = (item['l'] ?? '').toString();
      final kind = (item['qid'] ?? '').toString();
      final itemYear = (item['y'] as num?)?.toInt();
      if (id.isEmpty || !id.startsWith('tt')) continue;
      if (kind != 'movie' &&
          kind != 'tvSeries' &&
          kind != 'tvMiniSeries' &&
          kind != 'tvMovie') {
        continue;
      }
      if (year.isNotEmpty && '$itemYear' == year) firstYear ??= item;
      final itemKey = titleMatchKey(title);
      var titleScore = 0.0;
      if (itemKey == queryKey) {
        titleScore = 120;
      } else if (itemKey.contains(queryKey) || queryKey.contains(itemKey)) {
        final shorter = itemKey.length < queryKey.length
            ? itemKey.length
            : queryKey.length;
        final longer = itemKey.length < queryKey.length
            ? queryKey.length
            : itemKey.length;
        final ratio = longer == 0 ? 0.0 : shorter / longer;
        titleScore = ratio >= 0.6 ? 50 : 8;
      }
      var score = titleScore;
      if (year.isNotEmpty) {
        if ('$itemYear' == year) {
          score += 40;
        } else if (itemYear != null) {
          score -= 12;
        }
      }
      // 建议接口按相关度排序，越靠前越可能是同一部。
      score += (10 - index.clamp(0, 10)) * 0.6;
      if (score > bestScore) {
        bestScore = score;
        bestTitleMatched = titleScore > 0;
        best = item;
      }
      index++;
    }
    // 中文片名对应的 IMDb 条目名是英文（《漫长的季节》→ The Long Season），
    // 标题永远匹配不上。以前直接信任接口第一条，结果《黑球》《生日快乐》
    // 这类通用词会匹配到完全无关的片子（《黑球》→ La bola negra）。
    // 年份加分会让「只有年份相同」的条目也拿到 40 分，所以判断要看标题本身
    // 有没有匹配上，而不是看总分：标题完全不匹配时只接受「年份一致 + 片名
    // 足够长」的同年条目，其余交给豆瓣 / B 站 / 必应，宁缺毋滥。
    if (RegExp(r'[\u3400-\u9fff]').hasMatch(name) && !bestTitleMatched) {
      if (year.isNotEmpty && firstYear != null && queryKey.length >= 4) {
        return Map<String, dynamic>.from(firstYear);
      }
      return null;
    }
    return best == null ? null : Map<String, dynamic>.from(best);
  }

  Future<_Artwork?> _imdbImages(String imdbId) async {
    final query =
        'query { title(id: "$imdbId") { id images(first: 50) '
        '{ edges { node { url width height } } } } }';
    final res = await http.postJson(
      'https://api.graphql.imdb.com/',
      body: {'query': query},
      headers: {
        'User-Agent': _desktopUa,
        'Origin': 'https://www.imdb.com',
        'Referer': 'https://www.imdb.com/',
      },
      timeout: const Duration(seconds: 10),
    );
    final decoded = jsonDecode(res.body);
    final data = decoded is Map ? decoded['data'] : null;
    final title = data is Map ? data['title'] : null;
    final images = title is Map ? title['images'] : null;
    final edges = images is Map ? images['edges'] : null;
    if (edges is! List) return null;
    _Artwork? best;
    var bestScore = 0.0;
    // IMDb 图库混有竖版海报和低分辨率剧照：只挑横图，按宽度 + 16:9 接近度排序。
    for (final edge in edges) {
      if (edge is! Map) continue;
      final node = edge['node'];
      if (node is! Map) continue;
      final url = (node['url'] ?? '').toString().trim();
      final width = (node['width'] as num?)?.toInt() ?? 0;
      final height = (node['height'] as num?)?.toInt() ?? 0;
      if (url.isEmpty || width < 1200 || height <= 0) continue;
      final ratio = width / height;
      // 2.35:1 超宽图裁进 16:9 会切掉主体，4:3 则上下留黑边，直接排除。
      if (ratio < 1.45 || ratio > 2.0) continue;
      var score = width.toDouble();
      if (ratio >= 1.6 && ratio <= 1.9) {
        score += 500;
      } else if (ratio >= 1.5) {
        score += 200;
      }
      if (score > bestScore) {
        bestScore = score;
        // 超过 1920 的 Amazon 图会被裁成 1920×1080，按实际尺寸计分。
        final cropped = width > 1920 && url.contains('media-amazon.com/images/');
        final shownWidth = cropped ? 1920 : width;
        final shownHeight = cropped ? 1080 : height;
        best = _Artwork(
          relayImageUrl(
            _imdbDisplayUrl(url, width),
            referer: 'https://www.imdb.com/',
          ),
          width: shownWidth,
          height: shownHeight,
          source: 'imdb',
          isStill: true,
        );
      }
    }
    return best;
  }

  /// IMDb 图库常见 4000~8000 宽的原图（单张 2~5MB），Hero 只需要 1920。
  ///
  /// Amazon 图床支持在 URL 里裁剪 / 缩放：统一换成 1920×1080 中心裁切版，
  /// 体积从几 MB 降到 ~200KB，加载速度和内存占用都会明显改善。
  static String _imdbDisplayUrl(String url, int width) {
    if (width < 1920) return url;
    if (!url.contains('media-amazon.com/images/')) return url;
    final index = url.lastIndexOf('._V1_');
    if (index < 0) return url;
    final dot = url.lastIndexOf('.');
    final ext = dot > index ? url.substring(dot + 1) : 'jpg';
    return '${url.substring(0, index)}'
        '._V1_QL75_UX1920_CR0,0,1920,1080_.$ext';
  }

  /// 搜索结果标题是否在「讲这部片」：忽略空白 / 标点后要求完整包含片名，
  /// 查询带季号时结果必须出现同一个季号。
  ///
  /// 比「必须《片名》或片名开头」宽松：像「2025 年电影《深度安静》首映」
  /// 这种标题也能命中；但「电影《独一无二》」不会命中「独一无二的浪漫」。
  static bool _titleMatches(String text, String title) {
    final haystack = _relevanceKey(text);
    final needle = _relevanceKey(title);
    if (haystack.isEmpty || needle.isEmpty) return false;
    final season = so360SeasonNo(title);
    if (season > 0 && so360SeasonNo(text) != season) return false;
    return haystack.contains(needle);
  }

  /// 标题里带「封面 / 海报 / 横版」的图更像官方主视觉，优先于剧照。
  static bool _looksLikeCover(String title) => RegExp(
    r'封面|海报|横版|cover|poster',
    caseSensitive: false,
  ).hasMatch(title);

  /// 自媒体解说 / 混剪 / 盘点 / 花絮类标题，封面通常糊着大字，
  /// 或者只是拍摄现场，不适合做背景图。
  static bool _junkCoverTitle(String title) => RegExp(
    r'(解析|解说|拉片|混剪|剪辑|逐帧|盘点|影评|剧评|速看|一口气|图解|吐槽|'
    r'花絮|预告|片段|特辑|采访|发布会|路透|饭拍|生图)',
  ).hasMatch(title);

  // ------------------------------------------------------------------- 360

  /// 360 图片搜索兜底（Win-box 同款）：无 Key、无鉴权，中文影视物料最全。
  ///
  /// 接口：`https://image.so.com/j?q=<关键词>&src=srp&sn=0&pn=10`
  /// 关键词先用「横版 封面 / 海报」，没有封面再退「横版 剧照 / 壁纸」。
  Future<_Artwork?> _so360Backdrop(String name, String year) async {
    final title = dramaTitle(name).isEmpty ? name.trim() : dramaTitle(name);
    // 两个字的通用片名（如《爸爸》）会搜到《爸爸去哪儿》，宁可不补。
    if (titleMatchKey(title).length < 3) return null;
    final prefix = year.trim().isEmpty ? title : '$title ${year.trim()}';
    for (final suffix in const ['横版 封面', '横版 剧照', '高清 壁纸']) {
      final candidates = await _fetchSo360('$prefix $suffix');
      final best = pickSo360Backdrop(candidates, title, year: year);
      if (best != null) {
        AppLog.i(
          'artwork',
          '$name 360 补图命中 ${best.width}x${best.height}',
        );
        return _Artwork(
          relayImageUrl(best.url, referer: 'https://image.so.com/'),
          width: best.width,
          height: best.height,
          source: '360',
          isStill: !_looksLikeCover(best.title),
        );
      }
    }
    return null;
  }

  Future<List<So360Image>> _fetchSo360(String keyword) async {
    try {
      final uri = Uri.https('image.so.com', '/j', {
        'q': keyword,
        'src': 'srp',
        'correct': keyword,
        'sn': '0',
        'pn': '10',
      });
      final res = await http.getText(
        uri.toString(),
        headers: const {
          'Accept': 'application/json',
          'User-Agent': _desktopUa,
          'Referer': 'https://image.so.com/',
        },
        timeout: const Duration(seconds: 6),
      );
      return parseSo360(jsonDecode(res.body));
    } catch (e) {
      AppLog.w('artwork', '360 图片搜索失败（$keyword）：$e');
      return const [];
    }
  }

  /// 解析 360 图片搜索结果（纯函数，供单测）。
  static List<So360Image> parseSo360(Object? json) {
    if (json is! Map) return const [];
    final list = json['list'];
    if (list is! List) return const [];
    final out = <So360Image>[];
    for (final raw in list) {
      if (raw is! Map) continue;
      final url = (raw['img'] ?? raw['thumb'] ?? '').toString().trim();
      if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(url)) continue;
      final title = (raw['title'] ?? raw['litetitle'] ?? '').toString().trim();
      final width = int.tryParse((raw['width'] ?? '').toString()) ?? 0;
      final height = int.tryParse((raw['height'] ?? '').toString()) ?? 0;
      out.add(So360Image(title: title, url: url, width: width, height: height));
    }
    return out;
  }

  static final RegExp _relevanceNoise = RegExp(
    r'''[\s·・\-—_.,，。:：;；!！?？'"“”‘’()（）\[\]【】<>《》/\\|]+''',
  );

  /// 相关性比较键：小写 + 去空白 / 常见标点。
  static String _relevanceKey(String raw) =>
      _toHalfWidth(raw).toLowerCase().replaceAll(_relevanceNoise, '');

  static int _cn2num(String token) {
    const digits = {
      '一': 1,
      '二': 2,
      '两': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
    };
    if (RegExp(r'^\d+$').hasMatch(token)) return int.tryParse(token) ?? 0;
    final match = RegExp(
      r'^([一二三四五六七八九]?)(十?)([一二三四五六七八九]?)$',
    ).firstMatch(token);
    if (match == null) return 0;
    final head = match.group(1) ?? '';
    final ten = match.group(2) ?? '';
    final tail = match.group(3) ?? '';
    if (head.isEmpty && ten.isEmpty && tail.isEmpty) return 0;
    final tens = ten.isNotEmpty
        ? (head.isEmpty ? 10 : (digits[head] ?? 0) * 10)
        : 0;
    final ones = tail.isEmpty ? 0 : (digits[tail] ?? 0);
    final value = tens + ones;
    return value > 0 ? value : (digits[head] ?? 0);
  }

  /// 「第4季 / 第四季 / 第十二部」→ 季号；没有季号返回 0。
  static int so360SeasonNo(String raw) {
    final match = RegExp(
      r'第\s*(\d+|[一二两三四五六七八九十]+)\s*[季部]',
    ).firstMatch(raw);
    if (match == null) return 0;
    return _cn2num(match.group(1)!);
  }

  /// 360 结果相关性（Win-box 同款）：结果标题与查询词要有足够长的共同子串
  /// （中文 ≥4 字 / 拉丁 ≥6 字符）；查询带季号时结果必须是同一季。
  ///
  /// 长剧情式片名直接搜会撞上无关图，宁可不出封面也不给错图。
  static bool so360RelevantHit(String query, String title) {
    final q = _relevanceKey(query);
    final t = _relevanceKey(title);
    if (q.isEmpty || t.isEmpty) return false;
    final season = so360SeasonNo(query);
    if (season > 0 && so360SeasonNo(title) != season) return false;
    if (t.contains(q) || q.contains(t)) return true;
    final min = RegExp(r'[\u3400-\u9fff]').hasMatch(q) ? 4 : 6;
    final shorter = q.length <= t.length ? q : t;
    final longer = q.length <= t.length ? t : q;
    for (var length = shorter.length; length >= min; length--) {
      for (var i = 0; i + length <= shorter.length; i++) {
        if (longer.contains(shorter.substring(i, i + length))) return true;
      }
    }
    return false;
  }

  /// 从 360 结果里挑一张可用的横图（纯函数，供单测）。
  ///
  /// 过滤：竖图 / 缩略图 / 年份冲突 / 自媒体解说 / 网盘下载文 / B 站与百度
  /// 缩略图 CDN；排序：剧照关键词加分，越接近 16:9 越优先，同分取面积大的。
  static So360Image? pickSo360Backdrop(
    List<So360Image> candidates,
    String name, {
    String year = '',
  }) {
    final wanted = _relevanceKey(name);
    if (wanted.isEmpty) return null;
    final picked = <So360Image>[];
    for (final candidate in candidates) {
      final ratio = candidate.height > 0
          ? candidate.width / candidate.height
          : 0.0;
      if (candidate.width < 800 ||
          candidate.height < 400 ||
          ratio < 1.4 ||
          ratio > 2.4) {
        continue;
      }
      if (!_relevanceKey(candidate.title).contains(wanted)) continue;
      if (!so360RelevantHit(name, candidate.title)) continue;
      if (_junkCoverTitle(candidate.title)) continue;
      if (RegExp(
        r'(游戏|攻略|下载|百度云|网盘|资源)',
        caseSensitive: false,
      ).hasMatch(candidate.title)) {
        continue;
      }
      final host = (Uri.tryParse(candidate.url)?.host ?? '').toLowerCase();
      if (host.contains('hdslb.com') || host.contains('bilibili')) continue;
      if (host.contains('baidu.com') || host.contains('bdstatic.com')) {
        continue;
      }
      final years = RegExp(r'(?:19|20)\d{2}')
          .allMatches(candidate.title)
          .map((match) => match.group(0)!)
          .toSet();
      final wantedYear = year.trim();
      if (wantedYear.isNotEmpty &&
          years.isNotEmpty &&
          !years.contains(wantedYear)) {
        continue;
      }
      if (picked.any((item) => item.url == candidate.url)) continue;
      picked.add(candidate);
    }
    if (picked.isEmpty) return null;
    double score(So360Image candidate) {
      var value = 0.0;
      if (_looksLikeCover(candidate.title)) {
        value += 25;
      } else if (RegExp(
        r'剧照|横版|壁纸|still|backdrop',
        caseSensitive: false,
      ).hasMatch(candidate.title)) {
        value += 10;
      }
      if (RegExp(r'下载|百度云|网盘|资源').hasMatch(candidate.title)) {
        value -= 20;
      }
      value -= ((candidate.width / candidate.height) - 16 / 9).abs();
      return value;
    }

    picked.sort((a, b) {
      final byScore = score(b).compareTo(score(a));
      if (byScore != 0) return byScore;
      return (b.width * b.height).compareTo(a.width * a.height);
    });
    return picked.first;
  }

  /// 只处理必应 `m="..."` 属性里用到的 HTML 实体。
  static String _htmlUnescape(String raw) => raw
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');

  /// TVmaze 分集剧照：先按 IMDb id 映射，映射不到再用英文片名 + 年份搜索。
  ///
  /// 日韩 / 国产剧在 TVmaze 上常常没有 IMDb 映射，但用英文名能搜到
  /// （《漫长的季节》→ The Long Season），剧照通常是 1920×1080。
  ///
  /// 接口不返回尺寸；`original_untouched` 对主流剧集通常是 1920×1080，
  /// 这里按 1600×900 保守估值参与仲裁（不会压过真正的 1920 宽豆瓣剧照）。
  Future<_Artwork?> _tvmazeStill(
    String imdbId, {
    String title = '',
    String year = '',
  }) async {
    try {
      var showId = 0;
      final lookup = await http.getText(
        'https://api.tvmaze.com/lookup/shows?imdb=$imdbId',
        headers: const {'Accept': 'application/json'},
        timeout: const Duration(seconds: 5),
      );
      if (lookup.statusCode == 200) {
        final show = jsonDecode(lookup.body);
        showId = (show is Map ? show['id'] as num? : null)?.toInt() ?? 0;
      }
      if (showId <= 0 && title.isNotEmpty) {
        final search = await http.getText(
          'https://api.tvmaze.com/search/shows'
          '?q=${Uri.encodeQueryComponent(title)}',
          headers: const {'Accept': 'application/json'},
          timeout: const Duration(seconds: 6),
        );
        if (search.statusCode != 200) return null;
        final rows = jsonDecode(search.body);
        if (rows is! List) return null;
        var fallbackId = 0;
        for (final row in rows) {
          if (row is! Map) continue;
          final show = row['show'];
          if (show is! Map) continue;
          final id = (show['id'] as num?)?.toInt() ?? 0;
          if (id <= 0) continue;
          if (fallbackId == 0) fallbackId = id;
          final premiered = (show['premiered'] ?? '').toString();
          if (year.isNotEmpty && premiered.startsWith(year)) {
            showId = id;
            break;
          }
        }
        if (showId <= 0) showId = fallbackId;
      }
      if (showId <= 0) return null;
      final res = await http.getText(
        'https://api.tvmaze.com/shows/$showId/episodes',
        headers: const {'Accept': 'application/json'},
        timeout: const Duration(seconds: 6),
      );
      if (res.statusCode != 200) return null;
      final episodes = jsonDecode(res.body);
      if (episodes is! List) return null;
      for (final episode in episodes) {
        if (episode is! Map) continue;
        final image = episode['image'];
        if (image is! Map) continue;
        final url = (image['original'] ?? image['medium'] ?? '')
            .toString()
            .trim();
        if (url.isEmpty) continue;
        return _Artwork(
          relayImageUrl(url, referer: 'https://www.tvmaze.com/'),
          width: 1600,
          height: 900,
          source: 'tvmaze',
          isStill: true,
        );
      }
    } catch (_) {
      // TVmaze 只是补充来源，失败不影响 IMDb 主链路。
    }
    return null;
  }
}

/// 片名归一后的季号信息：`key` 判断是否同一部片，`season` 区分第几季。
class _TitleInfo {
  const _TitleInfo({
    required this.key,
    required this.season,
    required this.explicitSeason,
    required this.dub,
  });

  final String key;
  final int season;

  /// 标题里是否明确写了季号；没有写的按第一季处理。
  final bool explicitSeason;

  /// 中配 / 粤配 / 国语版等配音版本。
  final bool dub;
}

class ArtworkProbeResult {
  const ArtworkProbeResult({
    required this.source,
    required this.url,
    required this.error,
  });

  final String source;
  final String url;
  final String error;

  bool get ok => url.isNotEmpty;
}

/// 一张候选横图：URL + 真实尺寸 + 来源，用于多来源之间的质量仲裁。
/// 360 图片搜索的一条结果（供单测直接构造）。
class So360Image {
  const So360Image({
    required this.title,
    required this.url,
    this.width = 0,
    this.height = 0,
  });

  final String title;
  final String url;
  final int width;
  final int height;
}

class _Artwork {
  const _Artwork(
    this.url, {
    this.width = 0,
    this.height = 0,
    this.source = '',
    this.isStill = false,
  });

  final String url;
  final int width;
  final int height;
  final String source;

  /// 剧照 / 分集截图。横版封面优先，只有没有任何封面时才用剧照。
  final bool isStill;

  double get ratio => height > 0 ? width / height : 0;

  /// 尺寸未知（如 TMDB 搜索结果只给 backdrop_path）时按最低分参与兜底。
  bool get hasSize => width > 0 && height > 0 && ratio >= 1.15;

  /// 能直接铺 16:9：竖图、4:3 和 2.35:1 超宽图都会裁出「异形」，不参与仲裁。
  bool get usable => hasSize && ratio >= 1.45 && ratio <= 2.0;

  /// 「够用」：≥1280 宽的标准横图，先上屏再说。
  bool get good => usable && width >= 1280;

  double get score {
    if (!hasSize) return 1;
    var value = width.toDouble();
    final deviation = (ratio - 16 / 9).abs();
    value += (1 - deviation.clamp(0.0, 1.0)) * 300;
    if (ratio >= 1.5 && ratio <= 1.95) {
      value += 500;
    } else if (ratio > 2.2) {
      value -= 400;
    }
    // 官方/无水印横图优先：TMDB 的 backdrop 最干净，其次分集剧照；
    // 豆瓣剧照有字幕和综艺花字的情况更多。
    if (source == 'tmdb') {
      value += 350;
    } else if (source == 'tmdb-still') {
      value += 320;
    } else if (source == 'imdb') {
      value += 120;
    }
    // B 站横图是条目自己的官方物料，中文片名匹配由 B 站完成，准确率高，
    // 且 hdslb CDN 国内直连很快。
    if (source == 'bilibili') {
      value += 900;
    }
    // 国内网络下豆瓣图床（img*.doubanio.com）实测 32~128ms，
    // Amazon / TVmaze 要 600ms~2.5s；1600 宽已经足够铺满 1080p Hero，
    // 同等分辨率优先用豆瓣，避免为了多 300px 白等一两秒。
    if (source.startsWith('douban')) {
      value += width >= 1400 ? 800 : 300;
    }
    return value;
  }
}

class _CachedBackdrop {
  const _CachedBackdrop(this.value, this.at, {required this.found});

  final String value;
  final DateTime at;
  final bool found;
}
