import 'dart:convert';

import 'package:html/dom.dart';
import 'package:json_path/json_path.dart';
import 'package:xpath_selector/xpath_selector.dart';
import 'package:xpath_selector_html_parser/xpath_selector_html_parser.dart';

import '../../core/logging/app_log.dart';
import '../../core/logging/log_redact.dart';
import '../../core/net/app_http.dart';
import '../../models/site_config.dart';
import '../../models/vod.dart';
import 'kazumi_http.dart';
import 'kazumi_rule.dart';

/// Kazumi 官方规则仓库（AppHttp 对 raw.githubusercontent 有镜像回退）。
const String kazumiRulesRepo =
    'https://raw.githubusercontent.com/Predidit/KazumiRules/main';

const String _desktopUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

const Duration _httpTimeout = Duration(seconds: 20);

/// Kazumi 规则的执行器：搜索 → 详情/选集 → 交给播放器的页面地址。
///
/// 规则只负责把播放器带到最终播放页；真正的媒体地址由现有网页嗅探
/// （`sniffWebMedia`）在播放页里抓取，这与 Kazumi 自身的视频嗅探思路一致。
class KazumiSource {
  KazumiSource(this.http)
    : _insecureHttp = AppHttp(client: createKazumiHttpClient());

  final AppHttp http;

  /// 证书异常时的兼容客户端（动漫站自签 / 过期证书很常见）。
  final AppHttp _insecureHttp;

  KazumiRule? ruleOf(SourceBean site) {
    if (!site.isKazumi) return null;
    try {
      final decoded = jsonDecode(site.ext);
      if (decoded is Map) {
        return KazumiRule.fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (e) {
      AppLog.w('kazumi', '规则解析失败 ${site.key}', e);
    }
    return null;
  }

  /// 播放页嗅探要带的请求头（UA / Referer）。
  Map<String, String> headersFor(SourceBean site) {
    final rule = ruleOf(site);
    return _headers(rule);
  }

  // --------------------------------------------------------------- 首页新番
  // Kazumi 规则本身没有首页榜单；首页对齐原版 Kazumi：
  //   · 时间表：Bangumi 本季番剧（按星期一分栏）
  //   · 热门：Bangumi trending
  //   · 补充：B 站番剧日历
  // Bangumi 图片走 wsrv.nl 代理（与 Kazumi 的 BangumiImageUrlRewriter 一致）。
  // 点开条目按片名走全源搜索（与豆瓣推荐源同一交互）。

  static const String _kazumiMirror = 'https://api.kazumi.fyi';
  static const String _seasonCalendarPath = '/kazumi/v1/calendar/season';
  static const String _popularPath = '/kazumi/v1/popular/subjects';

  /// `before=0&after=6`：今天起 7 天，每个星期几分栏各一天，不会重复。
  static const String _biliTimelineUrl =
      'https://api.bilibili.com/pgc/web/timeline?types=1&before=0&after=6';

  static const Duration _seasonTtl = Duration(hours: 6);
  static const Duration _trendingTtl = Duration(hours: 1);
  static const Duration _biliTtl = Duration(hours: 1);
  static const List<String> _weekdayNames = [
    '周一',
    '周二',
    '周三',
    '周四',
    '周五',
    '周六',
    '周日',
  ];

  List<Map<String, dynamic>>? _seasonCache;
  DateTime? _seasonFetchedAt;
  List<Object?>? _trendingCache;
  DateTime? _trendingFetchedAt;
  List<Map<String, dynamic>>? _biliCache;
  DateTime? _biliFetchedAt;

  Future<CmsResult> home(SourceBean site) async {
    try {
      // 三路并发：某一路失败不影响其它榜单。
      final seasonFuture = _seasonDaysSafe();
      final biliFuture = _biliDaysSafe();
      final trendingFuture = _trendingRawSafe();
      final seasonDays = await seasonFuture;
      final biliDays = await biliFuture;
      final trending = await trendingFuture;

      final items = _mergeItems([
        ...parseBangumiSubjects(
          trending,
          sourceKey: site.key,
          sourceName: site.displayName,
        ),
        ...parseBangumiSeason(
          seasonDays,
          sourceKey: site.key,
          sourceName: site.displayName,
        ),
        ...parseBiliTimeline(
          biliDays,
          sourceKey: site.key,
          sourceName: site.displayName,
        ),
      ]);
      return CmsResult(
        classes: _weekdayClasses(seasonDays, biliDays),
        items: items,
        page: 1,
        pagecount: 1,
        total: items.length,
      );
    } catch (e, s) {
      AppLog.w('kazumi', '${site.displayName} 首页新番加载失败', e, s);
      return const CmsResult();
    }
  }

  Future<CmsResult> category(SourceBean site, String tid, String pg) async {
    try {
      final seasonDays = await _seasonDaysSafe();
      final biliDays = await _biliDaysSafe();
      final items = _mergeItems([
        ...parseBangumiSeason(
          seasonDays,
          sourceKey: site.key,
          sourceName: site.displayName,
          dayId: tid,
        ),
        ...parseBiliTimeline(
          biliDays,
          sourceKey: site.key,
          sourceName: site.displayName,
          dayId: tid,
        ),
      ]);
      return CmsResult(
        classes: _weekdayClasses(seasonDays, biliDays),
        items: items,
        page: 1,
        pagecount: 1,
        total: items.length,
      );
    } catch (e, s) {
      AppLog.w('kazumi', '${site.displayName} 新番分类加载失败', e, s);
      return const CmsResult();
    }
  }

  /// 同一部番可能同时出现在 trending / 季度表 / B 站日历里，按片名去重。
  static List<VodItem> _mergeItems(List<VodItem> items) {
    final out = <VodItem>[];
    final seen = <String>{};
    for (final item in items) {
      final name = item.name.trim();
      if (name.isEmpty || !seen.add(name)) continue;
      out.add(item);
    }
    return out;
  }

  static List<SortClass> _weekdayClasses(
    List<Map<String, dynamic>> seasonDays,
    List<Map<String, dynamic>> biliDays,
  ) {
    final hasItems = <int>{};
    for (final day in seasonDays) {
      final subjects = day['subjects'];
      if (subjects is List && subjects.isNotEmpty) {
        final weekday = int.tryParse('${day['day_of_week'] ?? ''}') ?? 0;
        if (weekday >= 1 && weekday <= 7) hasItems.add(weekday);
      }
    }
    for (final day in biliDays) {
      final episodes = day['episodes'];
      if (episodes is List && episodes.isNotEmpty) {
        final weekday = int.tryParse('${day['day_of_week'] ?? ''}') ?? 0;
        if (weekday >= 1 && weekday <= 7) hasItems.add(weekday);
      }
    }
    return [
      for (var weekday = 1; weekday <= 7; weekday++)
        if (hasItems.contains(weekday))
          SortClass(id: 'day$weekday', name: _weekdayNames[weekday - 1]),
    ];
  }

  Future<List<Map<String, dynamic>>> _seasonDaysSafe() async {
    try {
      return await _seasonDays();
    } catch (e, s) {
      AppLog.w('kazumi', 'Bangumi 季度表加载失败', e, s);
      return const [];
    }
  }

  Future<List<Map<String, dynamic>>> _biliDaysSafe() async {
    try {
      return await _biliDays();
    } catch (e, s) {
      AppLog.w('kazumi', 'B 站番剧日历加载失败', e, s);
      return const [];
    }
  }

  Future<List<Object?>?> _trendingRawSafe() async {
    try {
      return await _trendingRaw();
    } catch (e, s) {
      AppLog.w('kazumi', 'Bangumi 热门榜加载失败', e, s);
      return null;
    }
  }

  /// Bangumi 本季番剧：镜像返回 `{"1":[{subject:…}], …, "7":[…]}`。
  Future<List<Map<String, dynamic>>> _seasonDays() async {
    final now = DateTime.now();
    final cached = _seasonCache;
    final fetchedAt = _seasonFetchedAt;
    if (cached != null &&
        fetchedAt != null &&
        now.difference(fetchedAt) < _seasonTtl) {
      return cached;
    }
    final range = _seasonRange(now);
    final uri = Uri.parse('$_kazumiMirror$_seasonCalendarPath')
        .replace(queryParameters: {'start': range[0], 'end': range[1]});
    final res = await _get(
      uri.toString(),
      headers: const {
        'User-Agent': _desktopUserAgent,
        'Accept': 'application/json',
      },
      timeout: const Duration(seconds: 20),
    );
    final decoded = jsonDecode(res.body);
    if (decoded is! Map) throw SourceException('Bangumi 季度表格式异常');
    final days = <Map<String, dynamic>>[
      for (var weekday = 1; weekday <= 7; weekday++)
        {
          'day_of_week': weekday,
          'subjects': decoded['$weekday'] is List
              ? decoded['$weekday'] as List
              : const <Object?>[],
        },
    ];
    _seasonCache = days;
    _seasonFetchedAt = now;
    return days;
  }

  /// Bangumi 热门榜：镜像返回 `{"data":[…]}`。
  Future<List<Object?>?> _trendingRaw() async {
    final now = DateTime.now();
    final cached = _trendingCache;
    final fetchedAt = _trendingFetchedAt;
    if (cached != null &&
        fetchedAt != null &&
        now.difference(fetchedAt) < _trendingTtl) {
      return cached;
    }
    final res = await _get(
      '$_kazumiMirror$_popularPath?limit=48&offset=0',
      headers: const {
        'User-Agent': _desktopUserAgent,
        'Accept': 'application/json',
      },
      timeout: const Duration(seconds: 15),
    );
    final decoded = jsonDecode(res.body);
    final data = decoded is Map ? decoded['data'] : decoded;
    if (data is! List) throw SourceException('Bangumi 热门榜格式异常');
    _trendingCache = data;
    _trendingFetchedAt = now;
    return data;
  }

  /// B 站番剧日历：今天起 7 天。
  Future<List<Map<String, dynamic>>> _biliDays() async {
    final now = DateTime.now();
    final cached = _biliCache;
    final fetchedAt = _biliFetchedAt;
    if (cached != null &&
        fetchedAt != null &&
        now.difference(fetchedAt) < _biliTtl) {
      return cached;
    }
    final res = await _get(
      _biliTimelineUrl,
      headers: const {
        'User-Agent': _desktopUserAgent,
        'Accept': 'application/json',
      },
      timeout: const Duration(seconds: 15),
    );
    final decoded = jsonDecode(res.body);
    if (decoded is! Map) throw SourceException('每日新番日历格式异常');
    final result = decoded['result'];
    if (result is! List) throw SourceException('每日新番日历缺少 result');
    final days = <Map<String, dynamic>>[
      for (final item in result)
        if (item is Map) Map<String, dynamic>.from(item),
    ];
    if (days.isEmpty) throw SourceException('每日新番日历为空');
    _biliCache = days;
    _biliFetchedAt = now;
    return days;
  }

  /// 季度区间：1/4/7/10 月为季初，返回 `[start, end)`。
  static List<String> _seasonRange(DateTime now) {
    final startMonth = ((now.month - 1) ~/ 3) * 3 + 1;
    final start = DateTime(now.year, startMonth, 1);
    final end = DateTime(now.year, startMonth + 3, 1);
    String format(DateTime date) =>
        '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
    return [format(start), format(end)];
  }

  Future<List<VodItem>> search(SourceBean site, String keyword) async {
    final rule = _requireRule(site);
    final query = keyword.trim();
    if (query.isEmpty) return const [];
    try {
      if (rule.searchMode == 'api') {
        final api = rule.searchApi;
        if (api == null) throw SourceException('规则缺少搜索接口配置');
        final body = await _request(api.request, {
          'keyword': query,
        }, _headers(rule));
        final decoded = jsonDecode(body);
        return parseSearchJson(
          rule,
          decoded,
          sourceKey: site.key,
          sourceName: site.displayName,
        );
      }
      final target = _fill(rule.searchUrl, {
        'keyword': Uri.encodeComponent(query),
      });
      final res = await _get(target, headers: _headers(rule));
      return parseSearchHtml(
        rule,
        target,
        res.body,
        sourceKey: site.key,
        sourceName: site.displayName,
      );
    } on AppHttpException catch (e) {
      throw SourceException('${rule.name} 搜索失败：${e.message}');
    }
  }

  Future<VodDetail> detail(
    SourceBean site,
    String id, {
    String name = '',
  }) async {
    final rule = _requireRule(site);
    try {
      if (rule.chapterMode == 'api') {
        final api = rule.chapterApi;
        final request = api?.request;
        if (api == null || request == null) {
          throw SourceException('规则缺少选集接口配置');
        }
        final body = await _request(request, {'source': id}, _headers(rule));
        final roads = parseChapterJson(rule, jsonDecode(body));
        if (roads.isEmpty) {
          throw SourceException('${rule.name} 没有返回剧集信息');
        }
        return VodDetail(
          id: id,
          name: name.isNotEmpty ? name : rule.name,
          flags: roads.keys.toList(),
          episodes: roads,
          sourceKey: site.key,
        );
      }
      final pageUrl = _absolute(rule.baseUrl, id);
      if (pageUrl.isEmpty) throw SourceException('详情地址为空');
      final res = await _get(pageUrl, headers: _headers(rule));
      final doc = HtmlXPath.html(res.body);
      final roads = parseChapterHtml(rule, pageUrl, res.body, doc: doc);
      if (roads.isEmpty) {
        throw SourceException('${rule.name} 的详情页没有解析到播放线路');
      }
      return VodDetail(
        id: id,
        name: _pageTitle(doc, rule.name),
        flags: roads.keys.toList(),
        episodes: roads,
        sourceKey: site.key,
      );
    } on AppHttpException catch (e) {
      throw SourceException('${rule.name} 详情加载失败：${e.message}');
    }
  }

  /// 剧集地址 → 播放结果：媒体直链直接播，网页播放页交给网页嗅探。
  PlayResult play(SourceBean site, String rawUrl) {
    final url = rawUrl.trim();
    if (url.isEmpty) return const PlayResult(url: '', message: '播放地址为空');
    final headers = headersFor(site);
    if (_isMediaUrl(url)) {
      return PlayResult(url: url, headers: headers, message: '');
    }
    return PlayResult(
      url: url,
      parse: 1,
      headers: headers,
      message: '动漫播放页，正在网页嗅探',
    );
  }

  // ---------------------------------------------------------------- 官方仓库

  /// 拉取官方规则仓库索引（`index.json`）。
  Future<List<Map<String, dynamic>>> fetchIndex() async {
    final res = await _get(
      '$kazumiRulesRepo/index.json',
      timeout: const Duration(seconds: 30),
    );
    final decoded = jsonDecode(res.body);
    if (decoded is! List) throw SourceException('规则仓库索引格式异常');
    return [
      for (final item in decoded)
        if (item is Map) Map<String, dynamic>.from(item),
    ];
  }

  /// 拉取单条规则 JSON。
  Future<Map<String, dynamic>> fetchRule(String name) async {
    final file = '$kazumiRulesRepo/${Uri.encodeComponent(name)}.json';
    final res = await _get(file, timeout: const Duration(seconds: 30));
    final decoded = jsonDecode(res.body);
    if (decoded is! Map) throw SourceException('规则 $name 格式异常');
    return Map<String, dynamic>.from(decoded);
  }

  // ------------------------------------------------------------- 纯解析函数
  // 以下函数不触网，便于单测。

  static List<VodItem> parseSearchHtml(
    KazumiRule rule,
    String pageUrl,
    String html, {
    required String sourceKey,
    required String sourceName,
  }) {
    final doc = HtmlXPath.html(html);
    final items = <VodItem>[];
    final seen = <String>{};
    for (final node in _nodes(doc, rule.searchList)) {
      final name = _textOf(node, rule.searchName);
      final href = _hrefOf(node, rule.searchResult);
      final url = _absolute(pageUrl, href);
      if (name.isEmpty || url.isEmpty || !seen.add(url)) continue;
      items.add(
        VodItem(
          id: url,
          name: name,
          sourceKey: sourceKey,
          sourceName: sourceName,
          tag: sourceKey,
        ),
      );
    }
    return items;
  }

  static List<VodItem> parseSearchJson(
    KazumiRule rule,
    Object? json, {
    required String sourceKey,
    required String sourceName,
  }) {
    final api = rule.searchApi;
    if (api == null) return const [];
    final items = <VodItem>[];
    final seen = <String>{};
    for (final entry in _jsonItems(json, api.listPath)) {
      final name = _jsonString(entry, api.namePath);
      final source = _jsonString(entry, api.sourcePath);
      final id = api.sourceTemplate.isNotEmpty
          ? api.sourceTemplate.replaceAll('@source', source)
          : source;
      if (name.isEmpty || id.isEmpty || !seen.add(id)) continue;
      items.add(
        VodItem(
          id: id,
          name: name,
          sourceKey: sourceKey,
          sourceName: sourceName,
          tag: sourceKey,
        ),
      );
    }
    return items;
  }

  static Map<String, List<Episode>> parseChapterHtml(
    KazumiRule rule,
    String pageUrl,
    String html, {
    HtmlXPath? doc,
  }) {
    final document = doc ?? HtmlXPath.html(html);
    final roads = <String, List<Episode>>{};
    final roadNodes = _nodes(document, rule.chapterRoads);
    for (var i = 0; i < roadNodes.length; i++) {
      final road = roadNodes[i];
      final episodes = <Episode>[];
      final seen = <String>{};
      for (final link in _nodes(road, rule.chapterResult)) {
        final href = _hrefOf(link, '');
        final url = _absolute(pageUrl, href);
        if (url.isEmpty || !seen.add(url)) continue;
        final name = (link.text ?? '').trim();
        episodes.add(
          Episode(
            name: name.isEmpty ? '第${episodes.length + 1}集' : name,
            url: url,
          ),
        );
      }
      if (episodes.isEmpty) continue;
      var roadName = _roadName(road, i);
      var unique = roadName;
      var suffix = 2;
      while (roads.containsKey(unique)) {
        unique = '$roadName ${suffix++}';
      }
      roads[unique] = episodes;
    }
    return roads;
  }

  /// 选集接口：支持 `delimited`（`$$$` 分线路、`#` 分集、`$` 分名称/地址）以及
  /// 值本身是数组的 JSON 形态。
  static Map<String, List<Episode>> parseChapterJson(
    KazumiRule rule,
    Object? json,
  ) {
    final api = rule.chapterApi;
    if (api == null) return const {};
    final names = _jsonStrings(json, api.roadNamesPath);
    final roadValues = _jsonStrings(json, api.roadEpisodesPath);
    if (roadValues.isEmpty) return const {};

    final nameParts = names
        .expand((name) => name.split(api.roadSeparator))
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty)
        .toList();
    final roads = <String, List<Episode>>{};
    var roadIndex = 0;
    for (final rawRoad in roadValues.expand(
      (value) => value.split(api.roadSeparator),
    )) {
      final episodes = <Episode>[];
      for (final rawEpisode in rawRoad.split(api.episodeSeparator)) {
        final fields = rawEpisode.split(api.fieldSeparator);
        if (fields.length < 2) continue;
        final name = fields.first.trim();
        final url = fields.sublist(1).join(api.fieldSeparator).trim();
        if (url.isEmpty) continue;
        episodes.add(
          Episode(
            name: name.isEmpty ? '第${episodes.length + 1}集' : name,
            url: url,
          ),
        );
      }
      if (episodes.isEmpty) {
        roadIndex++;
        continue;
      }
      final roadName =
          roadIndex < nameParts.length && nameParts[roadIndex].isNotEmpty
          ? nameParts[roadIndex]
          : '线路${roads.length + 1}';
      roads[roadName] = episodes;
      roadIndex++;
    }
    return roads;
  }

  /// B 站番剧日历 → 首页卡片。
  ///
  /// 条目 id 与 name 相同，点击时走首页既有的「标题型条目 → 全源搜索」分支。
  /// [dayId] 为 `day1`~`day7`（周一~周日），为空时返回全部。
  static List<VodItem> parseBiliTimeline(
    Object? json, {
    required String sourceKey,
    required String sourceName,
    String dayId = '',
  }) {
    final days = json is Map ? json['result'] : json;
    if (days is! List) return const [];
    final wanted = dayId.trim().toLowerCase();
    final items = <VodItem>[];
    final seen = <String>{};
    for (final rawDay in days) {
      if (rawDay is! Map) continue;
      final day = Map<String, dynamic>.from(rawDay);
      final dayKey = 'day${int.tryParse('${day['day_of_week'] ?? ''}') ?? 0}';
      if (wanted.isNotEmpty && dayKey != wanted) continue;
      final episodes = day['episodes'];
      if (episodes is! List) continue;
      for (final rawItem in episodes) {
        if (rawItem is! Map) continue;
        final item = Map<String, dynamic>.from(rawItem);
        final name = (item['title'] ?? '').toString().trim();
        if (name.isEmpty || !seen.add(name)) continue;
        final pic = (item['cover'] ?? '').toString().trim();
        final index = (item['pub_index'] ?? '').toString().trim();
        items.add(
          VodItem(
            id: name,
            name: name,
            pic: pic,
            remarks: index,
            type: '动画',
            sourceKey: sourceKey,
            sourceName: sourceName,
            tag: sourceKey,
          ),
        );
      }
    }
    return items;
  }

  /// Bangumi 本季番剧（镜像 `calendar/season`）→ 首页卡片。
  ///
  /// [dayId] 为 `day1`~`day7`（周一~周日），为空时返回全部。
  static List<VodItem> parseBangumiSeason(
    Object? json, {
    required String sourceKey,
    required String sourceName,
    String dayId = '',
  }) {
    if (json is! List) return const [];
    final wanted = dayId.trim().toLowerCase();
    final items = <VodItem>[];
    for (final rawDay in json) {
      if (rawDay is! Map) continue;
      final day = Map<String, dynamic>.from(rawDay);
      final dayKey = 'day${int.tryParse('${day['day_of_week'] ?? ''}') ?? 0}';
      if (wanted.isNotEmpty && dayKey != wanted) continue;
      final subjects = day['subjects'];
      if (subjects is! List) continue;
      for (final raw in subjects) {
        if (raw is! Map) continue;
        final subject = raw['subject'] is Map
            ? Map<String, dynamic>.from(raw['subject'] as Map)
            : Map<String, dynamic>.from(raw);
        final item = _bangumiItem(
          subject,
          sourceKey: sourceKey,
          sourceName: sourceName,
        );
        if (item != null) items.add(item);
      }
    }
    return items;
  }

  /// Bangumi 热门榜（镜像 `popular/subjects`）→ 首页卡片。
  static List<VodItem> parseBangumiSubjects(
    Object? json, {
    required String sourceKey,
    required String sourceName,
  }) {
    final list = json is Map ? json['data'] : json;
    if (list is! List) return const [];
    final items = <VodItem>[];
    for (final raw in list) {
      if (raw is! Map) continue;
      final subject = raw['subject'] is Map
          ? Map<String, dynamic>.from(raw['subject'] as Map)
          : Map<String, dynamic>.from(raw);
      final item = _bangumiItem(
        subject,
        sourceKey: sourceKey,
        sourceName: sourceName,
      );
      if (item != null) items.add(item);
    }
    return items;
  }

  static VodItem? _bangumiItem(
    Map<String, dynamic> subject, {
    required String sourceKey,
    required String sourceName,
  }) {
    final cn = (subject['nameCN'] ?? '').toString().trim();
    final cnLower = (subject['name_cn'] ?? '').toString().trim();
    final original = (subject['name'] ?? '').toString().trim();
    final name = cn.isNotEmpty ? cn : (cnLower.isNotEmpty ? cnLower : original);
    if (name.isEmpty) return null;
    final date = (subject['date'] ?? '').toString().trim();
    final year = date.length >= 4
        ? date.substring(0, 4)
        : _yearFromInfo(subject['info']);
    final rating = subject['rating'];
    final score = rating is Map ? rating['score'] : null;
    final remarks = score is num && score > 0
        ? '${score.toStringAsFixed(1)}分'
        : '';
    return VodItem(
      id: name,
      name: name,
      pic: _bangumiImage(subject['images']),
      remarks: remarks,
      year: year,
      type: '动画',
      sourceKey: sourceKey,
      sourceName: sourceName,
      tag: sourceKey,
    );
  }

  /// Bangumi 图片域名在桌面端直连不通，按 Kazumi 的做法套 wsrv.nl 代理。
  static String _bangumiImage(Object? images) {
    if (images is! Map) return '';
    var url = '';
    for (final key in const ['common', 'large', 'medium', 'grid', 'small']) {
      final value = (images[key] ?? '').toString().trim();
      if (value.isNotEmpty) {
        url = value;
        break;
      }
    }
    if (url.isEmpty) return '';
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    if (uri.host == 'lain.bgm.tv' || uri.host == 'api.bgm.tv') {
      final source =
          '${uri.host}${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
      return Uri.https('wsrv.nl', '/', {'url': source}).toString();
    }
    return url;
  }

  static String _yearFromInfo(Object? info) {
    final text = info?.toString() ?? '';
    final match = RegExp(r'(\d{4})年').firstMatch(text);
    return match?.group(1) ?? '';
  }

  // ------------------------------------------------------------------ 内部

  KazumiRule _requireRule(SourceBean site) {
    final rule = ruleOf(site);
    if (rule == null) {
      throw SourceException('${site.displayName} 的 Kazumi 规则无效');
    }
    return rule;
  }

  Map<String, String> _headers(KazumiRule? rule, {String referer = ''}) {
    final userAgent = rule != null && rule.userAgent.isNotEmpty
        ? rule.userAgent
        : _desktopUserAgent;
    final refererValue = referer.isNotEmpty
        ? referer
        : (rule != null && rule.referer.isNotEmpty
              ? rule.referer
              : (rule?.baseUrl ?? ''));
    return {
      'User-Agent': userAgent,
      'Accept':
          'text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      if (refererValue.isNotEmpty) 'Referer': refererValue,
    };
  }

  Future<String> _request(
    KazumiApiRequest request,
    Map<String, String> vars,
    Map<String, String> headers,
  ) async {
    final url = _fill(request.url, vars);
    final params = <String, String>{
      for (final entry in request.query.entries)
        entry.key: _fill(entry.value, vars),
    };
    if (request.method == 'POST') {
      final res = await _post(url, body: params, headers: headers);
      return res.body;
    }
    final base = Uri.parse(url);
    final uri = base.replace(
      queryParameters: {...base.queryParameters, ...params},
    );
    final res = await _get(uri.toString(), headers: headers);
    return res.body;
  }

  /// GET：证书链异常（自签 / 过期 / 缺中间证书）时回退到兼容客户端。
  Future<HttpResponseText> _get(
    String url, {
    Map<String, String> headers = const {},
    Duration timeout = _httpTimeout,
  }) async {
    try {
      return await http.getText(url, headers: headers, timeout: timeout);
    } on AppHttpException catch (e) {
      if (!_isCertificateError(e.message)) rethrow;
      AppLog.w('kazumi', 'TLS 证书校验失败，改用兼容客户端：${redactUrl(url)}');
      return _insecureHttp.getText(url, headers: headers, timeout: timeout);
    }
  }

  /// POST：与 [_get] 相同的证书回退。
  Future<HttpResponseText> _post(
    String url, {
    required Map<String, String> body,
    Map<String, String> headers = const {},
    Duration timeout = _httpTimeout,
  }) async {
    try {
      return await http.postForm(
        url,
        body: body,
        headers: headers,
        timeout: timeout,
      );
    } on AppHttpException catch (e) {
      if (!_isCertificateError(e.message)) rethrow;
      AppLog.w('kazumi', 'TLS 证书校验失败，改用兼容客户端：${redactUrl(url)}');
      return _insecureHttp.postForm(
        url,
        body: body,
        headers: headers,
        timeout: timeout,
      );
    }
  }

  static bool _isCertificateError(String message) => RegExp(
    'certificate|handshake|CERTIFICATE',
    caseSensitive: false,
  ).hasMatch(message);

  static String _fill(String text, Map<String, String> vars) {
    var out = text;
    for (final entry in vars.entries) {
      out = out.replaceAll('@${entry.key}', entry.value);
    }
    return out;
  }

  static List<XPathNode<Node>> _nodes(Object scope, String selector) {
    final normalized = _normalizeXPath(selector);
    if (normalized.isEmpty) return const [];
    try {
      final result =
          (scope as dynamic).queryXPath(normalized) as XPathResult<Node>;
      return result.nodes;
    } catch (e) {
      AppLog.w('kazumi', 'XPath 解析失败：$selector | $e');
      return const [];
    }
  }

  static String _normalizeXPath(String selector) {
    var value = selector.trim();
    if (value.isEmpty) return '';
    if (value.startsWith('.//')) return value.substring(1);
    if (value.startsWith('./')) return value.substring(1);
    if (!value.startsWith('/')) value = '//$value';
    return value;
  }

  static String _textOf(XPathNode<Node> scope, String selector) {
    final normalized = _normalizeXPath(selector);
    if (normalized.isEmpty) return '';
    try {
      final result = scope.queryXPath(normalized);
      for (final attr in result.attrs) {
        final text = attr?.trim() ?? '';
        if (text.isNotEmpty) return text;
      }
      return (result.node?.text ?? '').trim();
    } catch (e) {
      AppLog.w('kazumi', '取名称失败：$selector | $e');
      return '';
    }
  }

  static String _hrefOf(XPathNode<Node> scope, String selector) {
    final normalized = _normalizeXPath(selector);
    if (normalized.isEmpty) return _nodeHref(scope);
    try {
      final result = scope.queryXPath(normalized);
      for (final attr in result.attrs) {
        final value = attr?.trim() ?? '';
        if (_looksLikeUrl(value)) return value;
      }
      for (final node in result.nodes) {
        final href = _nodeHref(node);
        if (href.isNotEmpty) return href;
      }
    } catch (e) {
      AppLog.w('kazumi', '取链接失败：$selector | $e');
    }
    return '';
  }

  static String _nodeHref(XPathNode<Node> node) {
    for (final key in const ['href', 'data-href', 'data-url', 'src']) {
      final value = node.attributes[key]?.trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  static String _roadName(XPathNode<Node> road, int index) {
    for (final key in const ['data-name', 'name', 'title']) {
      final value = road.attributes[key]?.trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return '线路${index + 1}';
  }

  static String _pageTitle(HtmlXPath doc, String fallback) {
    final title = (doc.query('//title').node?.text ?? '').trim();
    if (title.isNotEmpty) {
      final name = title.split(RegExp(r'\s*[-_|·]\s*')).first.trim();
      if (name.isNotEmpty && name.length <= 80) return name;
    }
    return fallback;
  }

  static bool _looksLikeUrl(String value) {
    if (value.isEmpty) return false;
    if (value.startsWith('//')) return true;
    return RegExp(
      r'^(https?:|magnet:|thunder:|ftp:|ed2k:|/|#|javascript:)',
      caseSensitive: false,
    ).hasMatch(value);
  }

  static bool _isMediaUrl(String url) => RegExp(
    r'\.(m3u8|mp4|flv|mkv|ts|m4v|mpd|webm|mov|avi)(\?|#|$)',
    caseSensitive: false,
  ).hasMatch(url);

  static String _absolute(String base, String href) {
    final value = href.trim();
    if (value.isEmpty) return '';
    final baseUri = Uri.tryParse(base.trim());
    if (baseUri == null) return value;
    try {
      final resolved = baseUri.resolve(value);
      // 站点在 https 下返回 http 绝对地址时，同主机直接升级到 https：
      // 不少动漫站的 80 端口会静默挂住（表现为详情页 20s 超时）。
      if (resolved.scheme == 'http' &&
          baseUri.scheme == 'https' &&
          resolved.host == baseUri.host) {
        return resolved.replace(scheme: 'https').toString();
      }
      return resolved.toString();
    } catch (_) {
      return value;
    }
  }

  static List<Object?> _jsonItems(Object? json, String path) {
    final values = _jsonValues(json, path);
    final out = <Object?>[];
    for (final value in values) {
      if (value is List) {
        out.addAll(value);
      } else {
        out.add(value);
      }
    }
    return out;
  }

  static List<String> _jsonStrings(Object? json, String path) {
    final out = <String>[];
    for (final value in _jsonValues(json, path)) {
      if (value is List) {
        for (final item in value) {
          final text = item?.toString().trim() ?? '';
          if (text.isNotEmpty) out.add(text);
        }
      } else {
        final text = value?.toString().trim() ?? '';
        if (text.isNotEmpty) out.add(text);
      }
    }
    return out;
  }

  static String _jsonString(Object? json, String path) {
    final values = _jsonValues(json, path);
    if (values.isEmpty) return '';
    final value = values.first;
    if (value is Map || value is List) return '';
    return value?.toString().trim() ?? '';
  }

  static List<Object?> _jsonValues(Object? json, String path) {
    final selector = path.trim();
    if (selector.isEmpty || json == null) return const [];
    try {
      return JsonPath(selector).read(json).map((match) => match.value).toList();
    } catch (e) {
      AppLog.w('kazumi', 'JSONPath 解析失败：$path | $e');
      return const [];
    }
  }
}
