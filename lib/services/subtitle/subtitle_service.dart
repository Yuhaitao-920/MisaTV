/// 多字幕源聚合入口。
///
/// 移植自旧版 `src/main/subtitle/index.ts`：
///   · 逐源并行检索（每源独立 + 超时预算），单源失败不影响其它源；
///   · 中文优先、标题精确命中优先排序；
///   · 下载按候选自带的 providerId 路由回对应源。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/logging/app_log.dart';
import 'assrt_provider.dart';
import 'custom_provider.dart';
import 'normalize_query.dart';
import 'subtitle_http.dart';
import 'subtitle_models.dart';
import 'subtitle_package_store.dart';
import 'subtitlecat_provider.dart';

/// 候选排序（稳定排序）：
///   ① 中文（简/繁/中英）优先；
///   ② 标题精确命中检索标题的优先；
///   ③ 其余保持各源返回顺序。
List<SubtitleCandidate> sortSubtitleCandidates(
  List<SubtitleCandidate> list,
  String title,
) {
  final want = title.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
  int zhOf(SubtitleCandidate c) {
    final s = '${c.language} ${c.detail} ${c.subname}';
    return RegExp(r'简|繁|中文|中英|双语|zh', caseSensitive: false).hasMatch(s) ? 0 : 1;
  }

  int exactOf(SubtitleCandidate c) {
    if (want.isEmpty) return 1;
    final t = c.title.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
    return t.isNotEmpty && t == want ? 0 : 1;
  }

  final rows =
      <({SubtitleCandidate c, int i, int zh, int exact})>[
        for (var i = 0; i < list.length; i++)
          (c: list[i], i: i, zh: zhOf(list[i]), exact: exactOf(list[i])),
      ]..sort((a, b) {
        final byZh = a.zh.compareTo(b.zh);
        if (byZh != 0) return byZh;
        final byExact = a.exact.compareTo(b.exact);
        if (byExact != 0) return byExact;
        return a.i.compareTo(b.i);
      });
  return rows.map((x) => x.c).toList();
}

class SubtitleService {
  SubtitleService({
    Map<String, String> Function()? tokens,
    String Function()? customApis,
    http.Client? client,
    Duration timeout = const Duration(seconds: 15),
  }) : _tokens = tokens ?? (() => const <String, String>{}),
       _customApis = customApis ?? (() => ''),
       _timeout = timeout,
       _http = SubtitleHttp(client: client, timeout: timeout);

  final Map<String, String> Function() _tokens;
  final String Function() _customApis;
  final Duration _timeout;
  final SubtitleHttp _http;

  /// API 源（assrt）超时：实测 0.6-2 秒必回，给 8 秒足够。
  Duration get _assrtTimeout => _timeout < const Duration(seconds: 8)
      ? _timeout
      : const Duration(seconds: 8);

  /// 已解出的字幕候选缓存：`providerId|id` → 包内全部条目。
  ///
  /// 一个 RAR 里常有多条（简中/繁中/eng/SDH）。用户点同一个候选第二次
  /// 只是想「换一条试试」，没必要再下一次包、再解一次压。
  ///
  /// 双层：
  ///   · 内存 Map（本字段）—— 最快，进程内命中
  ///   · 落盘 `<userdata>/subtitles/cache/<key>.json` —— 重启 app 后仍命中
  /// 落盘层走 [_store] 条件导入：io 平台真写文件，Web 退化成空实现。
  final Map<String, List<SubtitleChoice>> _packageCache =
      <String, List<SubtitleChoice>>{};

  /// 取缓存键（provider + 候选 id）。
  String _cacheKeyOf(SubtitleCandidate c) => '${c.providerId}|${c.id}';

  /// 查过但没有落盘缓存的键（避免每次 build 都做一次文件探测）。
  final Set<String> _packageMiss = <String>{};

  /// 已缓存该候选解出的条目（内存优先，其次读盘；都没有返回 null）。
  List<SubtitleChoice>? cachedChoices(SubtitleCandidate c) {
    final key = _cacheKeyOf(c);
    final hit = _packageCache[key];
    if (hit != null && hit.isNotEmpty) return hit;
    if (_packageMiss.contains(key)) return null;

    final raw = readPackageCache(key);
    if (raw == null || raw.isEmpty) {
      // 记下「没有」，list itemBuilder 每帧都调它，别反复碰磁盘。
      _packageMiss.add(key);
      return null;
    }
    final parsed = _decodeChoices(raw);
    if (parsed == null || parsed.isEmpty) {
      _packageMiss.add(key);
      return null;
    }
    _packageCache[key] = parsed;
    _packageMiss.remove(key);
    return parsed;
  }

  void _remember(String key, List<SubtitleChoice> choices) {
    if (choices.isEmpty) return;
    if (_packageCache.length >= 32 && !_packageCache.containsKey(key)) {
      // 简单淘汰：丢掉最早插入的一个（Dart Map 保序）。
      _packageCache.remove(_packageCache.keys.first);
    }
    _packageCache[key] = choices;
    // 落盘：下次启动 app 仍能命中。
    final json = _encodeChoices(choices);
    if (json != null) writePackageCache(key, json);
  }

  /// 编码成 JSON：[{n: name, f: format, t: text}]
  ///
  /// 手写而不是 `jsonEncode` 一个 class —— 只有 3 个字段，少一层依赖，
  /// 也避免给 `SubtitleChoice` 加 `toJson`（它在 UI 层用不到）。
  String? _encodeChoices(List<SubtitleChoice> choices) {
    try {
      final list = <Map<String, String>>[
        for (final c in choices) {'n': c.name, 'f': c.format, 't': c.text},
      ];
      return jsonEncode(list);
    } catch (_) {
      return null;
    }
  }

  List<SubtitleChoice>? _decodeChoices(String raw) {
    try {
      final data = jsonDecode(raw);
      if (data is! List) return null;
      final out = <SubtitleChoice>[];
      for (final e in data) {
        if (e is! Map) continue;
        final name = '${e['n'] ?? ''}';
        final text = '${e['t'] ?? ''}';
        if (text.trim().isEmpty) continue;
        out.add(
          SubtitleChoice(
            name: name.isEmpty ? '字幕' : name,
            format: '${e['f'] ?? ''}',
            text: text,
          ),
        );
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  /// 网页源（subtitlecat / 自定义接口）超时：网页要下 HTML 再解析，给足。
  Duration get _htmlTimeout => _timeout;

  /// 并行检索；单源失败/超时只丢该源，不抛整体失败。
  ///
  /// 无 assrt token 时该源直接跳过（返回空列表）。
  ///
  /// ★ 每个源独立超时：任何一个源慢/不通都只丢它自己，不拖累整体。
  ///   旧实现把多个源塞进 `Future.wait` 且共用同一个 15s 超时 ——
  ///   `subtitlecat.com` 在国内完全不通（连接直接失败后一直重试），
  ///   于是每次搜字幕都白等 15 秒，UI 表现为「点按钮半天没反应」。
  /// 检索结果的进程内缓存：查询键 → 候选列表。
  ///
  /// ★ 面板不该每次打开都重新检索。
  ///
  ///   实测：打开字幕面板 → 检索（assrt ~1s + subtitlecat 15s 超时）
  ///   → 关掉 → 再打开 → 又一整轮。用户只是想「换一条已下载的字幕」，
  ///   却要白等十几秒。
  ///
  ///   所以：同一次播放（同 query）内，只在**用户点刷新**或**首次打开**时检索。
  final Map<String, List<SubtitleCandidate>> _searchCache =
      <String, List<SubtitleCandidate>>{};

  /// 检索缓存键。
  ///
  /// ★ 必须把 `customKeyword` 算进去：面板里用户可以把检索词改掉再搜，
  ///   改完的结果和自动推断的结果是两批不同的东西。旧键只看
  ///   `title|episode|rawName`，于是「改成奥德赛搜出 15 条」会被存到
  ///   「奥德赛2026」的键位上，下次打开面板又拿回那 15 条，而输入框显示的是
  ///   另一个词 —— 用户看到的是「搜的词和结果对不上」。
  String _searchKeyOf(SubtitleQuery q, Set<String> providers) {
    final p = providers.toList()..sort();
    return '${q.title}|${q.episode}|${q.rawName}|${q.customKeyword}|${p.join(",")}';
  }

  /// 已缓存的检索结果（无缓存返回 null）。
  List<SubtitleCandidate>? cachedSearch(
    SubtitleQuery query, {
    Set<String> providers = const <String>{'subtitlecat', 'assrt'},
  }) {
    final hit = _searchCache[_searchKeyOf(query, providers)];
    return (hit == null || hit.isEmpty) ? null : hit;
  }

  Future<List<SubtitleCandidate>> search(
    SubtitleQuery query, {
    Set<String> providers = const <String>{'subtitlecat', 'assrt'},
    bool refresh = false,
  }) async {
    final cacheKey = _searchKeyOf(query, providers);
    if (!refresh) {
      final hit = _searchCache[cacheKey];
      if (hit != null && hit.isNotEmpty) {
        AppLog.i('subtitle', '命中检索缓存（${hit.length} 条），跳过网络');
        return hit;
      }
    }
    final ctx = buildSubtitleContext(query);
    final tokens = _readTokens();
    AppLog.i(
      'subtitle',
      '检索 title=${ctx.title} ep=${ctx.ep} kw=${ctx.keywords} '
          'assrtToken长度=${(tokens['assrt'] ?? '').trim().length} '
          'providers=$providers',
    );
    final pending = <Future<List<SubtitleCandidate>>>[];

    for (final raw in providers) {
      final type = subtitleProviderFromId(raw);
      if (type == null) continue;
      if (type == SubtitleProviderType.assrt) {
        final token = (tokens[assrtProviderId] ?? '').trim();
        if (token.isEmpty) continue;
        pending.add(
          _isolate(
            () => searchAssrt(
              http: _http,
              token: token,
              query: query,
              keywords: ctx.keywords,
            ).timeout(_assrtTimeout),
            name: 'assrt',
          ),
        );
      } else {
        // 网页源：把「探测 → 检索」整条塞进一个 future，让探测与其他源**并行**。
        //   旧写法在组装列表时就 `await _reachable(...)`，探测（连不上要约 2s）
        //   会把 assrt 的请求整个往后推，UI 于是先白等 2 秒再取字幕。
        pending.add(
          _isolate(() async {
            if (!await _reachable(catBase)) return const <SubtitleCandidate>[];
            return searchSubtitleCat(
              http: _http,
              query: query,
              keywords: ctx.keywords,
            ).timeout(_htmlTimeout);
          }, name: 'subtitlecat'),
        );
      }
    }
    for (final api in _readCustomApis()) {
      pending.add(
        _isolate(
          () =>
              searchCustomSubtitleApi(_http, api, query).timeout(_htmlTimeout),
          name: 'custom',
        ),
      );
    }
    if (pending.isEmpty) return const <SubtitleCandidate>[];

    // 谁先回就先攒：慢源不再阻塞已就绪的结果（整体最多等到最长超时）。
    final all = <SubtitleCandidate>[];
    await Future.wait(
      pending.map((f) async {
        all.addAll(await f);
      }),
    );
    final result = sortSubtitleCandidates(all, ctx.title);
    if (result.isNotEmpty) _searchCache[cacheKey] = result;
    return result;
  }

  /// 源站的连通性探测结果缓存（true 可达 / false 本次会话不再试）。
  final Map<String, bool> _reachableCache = {};

  /// 探测源站根地址：3 秒内连得上才算可用。
  ///
  /// 只做一次 TCP/TLS 级别的 GET（`_http` 自身有体积与超时限制），
  /// 结果按 host 缓存，避免每次搜字幕都付一遍失败代价。
  Future<bool> _reachable(String base) async {
    final cached = _reachableCache[base];
    if (cached != null) return cached;
    var ok = false;
    try {
      final res = await _http.getResponse(
        base,
        html: true,
        maxBytes: 64 * 1024,
        headers: const {'Accept': '*/*'},
      );
      // 有响应（哪怕是 4xx）就说明网络通；null 代表超时/连接失败。
      ok = res != null;
    } catch (_) {
      ok = false;
    }
    _reachableCache[base] = ok;
    if (!ok) AppLog.i('subtitle', '源站不可达，本次会话跳过：$base');
    return ok;
  }

  /// 下载并解出字幕；失败抛 [SubtitleException]（中文原因）。
  ///
  /// [videoName] / [ep] 用于在压缩包里挑对集数的条目 —— 旧实现只传了
  /// candidate，`pickEntry` 拿不到集号，多集字幕包只能按扩展名打分，
  /// 于是一律挑到「字母序第一份」。
  Future<SubtitleFile> download(
    SubtitleCandidate candidate, {
    String videoName = '',
    String ep = '',
  }) async {
    if (candidate.providerId.startsWith('custom:')) {
      CustomSubtitleApi? api;
      for (final e in _readCustomApis()) {
        if (e.id == candidate.providerId) {
          api = e;
          break;
        }
      }
      if (api == null) {
        throw SubtitleException('自定义字幕接口已不存在：${candidate.providerName}');
      }
      return downloadCustomSubtitleApi(
        _http,
        api,
        candidate,
        onChoices: (choices) => _remember(_cacheKeyOf(candidate), choices),
      );
    }
    final type = subtitleProviderFromId(candidate.providerId);
    if (type == null) {
      throw SubtitleException('未知的字幕源：${candidate.providerId}');
    }
    if (type == SubtitleProviderType.assrt) {
      final token = (_readTokens()[assrtProviderId] ?? '').trim();
      if (token.isEmpty) {
        throw const SubtitleException('尚未配置 assrt token，请先在「配置 → 外挂字幕」中填写');
      }
      return assrtDownload(
        _http,
        token,
        candidate,
        videoName: videoName,
        ep: ep,
        onChoices: (choices) => _remember(_cacheKeyOf(candidate), choices),
      );
    }
    return fetchSubtitleCat(
      _http,
      candidate,
      ep: ep,
      onChoices: (choices) => _remember(_cacheKeyOf(candidate), choices),
    );
  }

  Map<String, String> _readTokens() {
    try {
      return _tokens();
    } catch (_) {
      return const <String, String>{};
    }
  }

  List<CustomSubtitleApi> _readCustomApis() {
    try {
      return parseCustomSubtitleApis(_customApis());
    } catch (_) {
      return const [];
    }
  }

  Future<List<SubtitleCandidate>> _isolate(
    Future<List<SubtitleCandidate>> Function() run, {
    String name = '',
  }) async {
    try {
      return await run();
    } catch (e) {
      // 单源失败不阻断整体，但必须留痕：历史上这里裸吞异常，
      // 于是「assrt token 无效」「HTTP 509」「关键词过短」全都表现为
      // UI 上的「0 条」，完全没法判断是没资源还是配置错了。
      AppLog.w('subtitle', '字幕源检索失败${name.isEmpty ? '' : '（$name）'}：$e');
      return const <SubtitleCandidate>[];
    }
  }
}

/// 由公开查询构造内部检索上下文（标题 / 集号 / 关键词候选）。
///
/// 公开（非私有）是为了让单测能直接验证「哪些词进了检索队列」——
/// 实测过线上日志里混进 `S01E02 【L`、`UHD Remux MA 5 1 【噢` 这类残片，
/// 每一个都是一次真实 assrt 请求，连打几次就自己触发 509 限流。
({String title, String ep, List<String> keywords}) buildSubtitleContext(
  SubtitleQuery query,
) {
  // ★ 用户手填的检索词优先，且**不再做 normalizeTitle** ——
  //   手填就是「我知道该搜什么」，再剥标签反而会弄坏。
  final custom = query.customKeyword.trim();
  final source = custom.isNotEmpty
      ? custom
      : (query.title.trim().isNotEmpty ? query.title : query.rawName);
  var title = custom.isNotEmpty ? custom : normalizeTitle(source);
  if (title.isEmpty) title = source.trim();
  final ep = query.episode == null
      ? (custom.isNotEmpty
            ? ''
            : extractEp(query.rawName.isNotEmpty ? query.rawName : source))
      : query.episode.toString();

  final keywords = <String>[];
  final seen = <String>{};
  void add(String value) {
    final t = value.trim();
    if (t.isEmpty) return;
    if (isJunkSubtitleKeyword(t)) return;
    final key = t.toLowerCase();
    if (!seen.add(key)) return;
    keywords.add(t);
  }

  final variants = titleVariants(title);
  for (final v in variants) {
    add(v);
  }
  if (query.title.trim().isNotEmpty && query.rawName.trim().isNotEmpty) {
    final fromRaw = normalizeTitle(query.rawName);
    if (fromRaw.isNotEmpty && fromRaw != title) {
      for (final v in titleVariants(fromRaw)) {
        add(v);
      }
    }
  }
  if (ep.isNotEmpty) {
    add('$title $ep');
    for (final v in variants) {
      add('$v $ep');
    }
  }
  return (title: title, ep: ep, keywords: keywords.take(6).toList());
}
