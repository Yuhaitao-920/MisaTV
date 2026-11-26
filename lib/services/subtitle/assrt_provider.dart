/// assrt.net（伪射手开放 API）字幕检索 + 下载。用户自填 token。
///
/// 逐函数移植自旧版 `src/main/subtitle/assrtProvider.ts`：
///   search  GET `/v1/sub/search?q=<kw>&token=<token>`
///   detail  GET `/v1/sub/detail?id=<id>&token=<token>`
library;

import 'dart:convert';

import 'archive.dart';
import 'normalize_query.dart';
import 'pick_entry.dart';
import 'subtitle_from_bytes.dart';
import 'subtitle_http.dart';
import 'subtitle_models.dart';
import 'subtitle_text.dart';

const String assrtApiBase = 'https://api.assrt.net/v1';
const String assrtProviderId = 'assrt';
const String assrtProviderName = 'assrt（伪射手，需 token）';

/// 通过 detail 拿到的下载信息。
class AssrtDetail {
  const AssrtDetail({
    required this.url,
    required this.filename,
    required this.direct,
    required this.directName,
  });

  /// 整包下载地址（assrt 的 sub.url）。
  final String url;

  /// 整包文件名（如 繁花.ass.zip）。
  final String filename;

  /// 包内直链（onthefly，免解压；取不到为空）。
  final String direct;

  /// 包内直链对应的文件名。
  final String directName;
}

const AssrtDetail _emptyDetail = AssrtDetail(
  url: '',
  filename: '',
  direct: '',
  directName: '',
);

/// 退化关键词的结果过滤：只留真能对上剧名的条目。
///
/// 为什么需要：`searchAssrt` 会逐级退化关键词（`人性本兽` → `Animals WEB`
/// → `AnimalsWEB` → `Animals`）。裸词 `Animals` 在 assrt 上能返回 15 条完全
/// 无关的片子（危险动物 / Dangerous Animals / 鈔級布偶 / Big.Sky / 都柏林动物…），
/// 用户看到的是「一堆字幕，但没一个是本片的」。
///
/// 判据分两种：
///   · 中文剧名（≥2 个汉字）：候选标题里必须出现该中文串。
///     `人性本兽` → 只留 `人性本兽 Animals (2026)`。
///   · 只有英文剧名时：**不做过滤**。英文单词（Animals / Animals）太常见，
///     按词过滤要么误杀（`Dangerous Animals` 里就有 Animals）、要么全放过，
///     都不如原样返回让用户自己挑。
List<SubtitleCandidate> _filterRelevant(
  List<SubtitleCandidate> items,
  String targetTitle,
  SubtitleQuery query,
) {
  final cjk = <String>{};
  void collectCjk(String source) {
    for (final m in RegExp(r'[\u4e00-\u9fff]{2,}').allMatches(source)) {
      final t = m.group(0)!.trim();
      if (t.isNotEmpty) cjk.add(t);
    }
  }

  for (final s in <String>[
    targetTitle,
    query.title,
    normalizeTitle(query.rawName),
  ]) {
    if (s.trim().isNotEmpty) collectCjk(s);
  }
  if (cjk.isEmpty) return items;

  final out = <SubtitleCandidate>[];
  for (final c in items) {
    final hay = '${c.title} ${c.subname} ${c.videoName}';
    if (cjk.any(hay.contains)) out.add(c);
  }
  return out;
}

/// 解析 `sub/search` 响应（纯函数，便于离线单测）。
List<SubtitleCandidate> parseAssrtSearch(String body, {int statusCode = 200}) {
  Map<String, dynamic>? json;
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) json = decoded;
  } catch (_) {
    // 非 JSON：按 HTTP 状态给原因（旧版解析失败直接回空）。
  }
  if (statusCode == 400) {
    throw const SubtitleException('关键词过短（assrt 要求搜索词 ≥3 个字符）');
  }
  if (statusCode != 200) {
    throw SubtitleException('assrt 服务错误 HTTP $statusCode');
  }
  if (json == null) return const <SubtitleCandidate>[];
  final status = json['status'];
  if (status is num && status != 0) {
    throw SubtitleException(_assrtError(json, status.toInt()));
  }
  final sub = json['sub'];
  final subs = sub is Map ? sub['subs'] : null;
  if (subs is! List) return const <SubtitleCandidate>[];

  final out = <SubtitleCandidate>[];
  for (final raw in subs) {
    if (raw is! Map) continue;
    // ★ assrt 的 `sub/search` 会返回**两种 JSON 格式**，同一个接口里有
    //   时按新格式、有时按旧格式，取决于记录怎么入库：
    //
    //   旧（实测 人性本兽 id=733904）：
    //     {"id":733904,"native_name":"人性本兽 Animals (2026)",
    //      "videoname":"不知道","subtype":"Subrip(srt)",
    //      "lang":{"desc":"英 简 繁"}}
    //
    //   新（实测 奥德赛 fileid=669742）：
    //     {"fileid":669742,"m_title":"The Odyssey (2026)/奥德赛 (2026)/…",
    //      "m_title_bot":"The Odyssey (2026)/奥德赛 (2026)",
    //      "m_videoname":"奥德赛….mp4","m_subtype":"Subrip(srt)",
    //      "m_lang":"英&nbsp;简","sub_name":"奥德赛.zip"}
    //
    //   旧代码只认 `id`/`native_name`，新格式条目会被 `id == null` 全部丢掉，
    //   于是「奥德赛」在网页上有 15 条、在 app 里 0 条。
    final id = raw['id'] ?? raw['fileid'];
    if (id == null) continue;

    final nativeName = _str(raw['native_name']);
    final mTitle = _str(raw['m_title']);
    final mTitleBot = _str(raw['m_title_bot']);
    final videoNameRaw = _str(raw['videoname']);
    final mVideoName = _str(raw['m_videoname']);
    final subName = _str(raw['sub_name']);
    final videoName = videoNameRaw.isNotEmpty ? videoNameRaw : mVideoName;

    // 名称兜底：`native_name` → `m_title_bot` → `m_title` → `videoname`
    // → `sub_name`。全空的丢弃（点了也认不出是什么）。
    final displayName = <String>[
      nativeName,
      mTitleBot,
      mTitle,
      videoName,
      subName,
    ].firstWhere((s) => s.isNotEmpty && s != '不知道', orElse: () => '');
    if (displayName.isEmpty) continue;

    final lang = raw['lang'];
    // 新格式的 `m_lang` 带 HTML 实体（`英&nbsp;简`）。
    final mLang = _str(raw['m_lang']).replaceAll('&nbsp;', ' ').trim();
    final langDesc = lang is Map ? _str(lang['desc']) : mLang;

    // 新格式没有 `release_site`，但有 `m_rl_name`（发布站/个人）。
    final site = _str(raw['release_site']).isNotEmpty
        ? _str(raw['release_site'])
        : _str(raw['m_rl_name']);

    // 格式：旧格式 `subtype` 是文字（`Subrip(srt)`）；
    // 新格式 `subtype` 变成了数字代号（`"2"`），文字在 `m_subtype`。
    // 所以「纯数字就当代号、改用 m_subtype」。
    final subType = _str(raw['subtype']);
    final mSubType = _str(raw['m_subtype']);
    final format = RegExp(r'^\d+$').hasMatch(subType)
        ? mSubType
        : (subType.isNotEmpty ? subType : mSubType);

    out.add(
      SubtitleCandidate(
        providerId: assrtProviderId,
        providerName: assrtProviderName,
        id: id.toString(),
        title: displayName,
        language: langDesc,
        format: format.toLowerCase(),
        downloadUrl: '',
        subname: videoName.isNotEmpty ? videoName : displayName,
        detail: site,
        // 从发布名里取集号：`...S01E03...` → '3'。
        // 为空说明这是整片/合集包，UI 据此提示「不分集」。
        episodeHint: epOf(videoName.isNotEmpty ? videoName : displayName),
      ),
    );
  }
  return out;
}

/// 解析 `sub/detail` 响应（纯函数）。
AssrtDetail parseAssrtDetail(String body, {int statusCode = 200}) {
  Map<String, dynamic>? json;
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) json = decoded;
  } catch (_) {
    // 解析失败 → 空 detail。
  }
  if (statusCode == 400) {
    throw const SubtitleException('关键词过短（assrt 要求搜索词 ≥3 个字符）');
  }
  if (statusCode != 200) {
    throw SubtitleException('assrt 服务错误 HTTP $statusCode');
  }
  if (json == null) return _emptyDetail;
  final status = json['status'];
  if (status is num && status != 0) {
    throw SubtitleException(_assrtError(json, status.toInt()));
  }
  final sub = json['sub'];
  final subs = sub is Map ? sub['subs'] : null;
  if (subs is! List || subs.isEmpty) return _emptyDetail;
  final first = subs.first;
  if (first is! Map) return _emptyDetail;

  final url = _str(first['url']);
  final filename = _str(first['filename']);
  var direct = '';
  var directName = '';

  final fileList = first['filelist'];
  if (fileList is List) {
    for (final f in fileList) {
      if (f is! Map) continue;
      final fName = _str(f['f']);
      final fUrl = _str(f['url']);
      if (!RegExp(
        r'\.(srt|ass|ssa|vtt|sub)$',
        caseSensitive: false,
      ).hasMatch(fName.isNotEmpty ? fName : fUrl)) {
        continue;
      }
      if (fUrl.isNotEmpty && fUrl != url) {
        direct = fUrl;
        directName = fName.isNotEmpty ? fName : fUrl.split('/').last;
        break;
      }
    }
  }
  return AssrtDetail(
    url: url,
    filename: filename,
    direct: direct,
    directName: directName,
  );
}

String _str(Object? v) => v == null ? '' : v.toString().trim();

String _assrtError(Map<String, dynamic> json, int status) {
  final errmsg = _str(json['errmsg']);
  if (errmsg.isNotEmpty) return errmsg;
  final error = json['error'];
  if (error is Map) {
    final msg = _str(error['msg']);
    if (msg.isNotEmpty) return msg;
  }
  return '错误码 $status';
}

/// 检索字幕（严格按文档解析 search 返回）。
Future<List<SubtitleCandidate>> assrtSearch(
  SubtitleHttp http,
  String token,
  String keyword, {
  bool isFile = false,
}) async {
  final params = <String, String>{'q': keyword, 'token': token};
  if (isFile) params['is_file'] = '1';
  final url = Uri.parse('$assrtApiBase/sub/search')
      .replace(queryParameters: params)
      .toString();
  // ★ 509 = 触发频率限制（assrt 对同一 token 的连续检索限流）。
  //   实测：0.3s 内连发 3 次就会中招；等 1.5s 重试一次即可。
  //   旧实现把它当普通错误抛出去，导致「偶发 0 条」，看起来像搜不到。
  SubtitleHttpResponse? res;
  for (var attempt = 0; attempt < 3; attempt++) {
    res = await http.getResponse(url, maxBytes: 4 * 1024 * 1024);
    if (res == null) {
      throw const SubtitleException('assrt 服务不可达或网络异常');
    }
    if (res.statusCode != 509) break;
    await Future<void>.delayed(Duration(milliseconds: 800 * (attempt + 1)));
  }
  return parseAssrtSearch(
    utf8.decode(res!.bytes, allowMalformed: true),
    statusCode: res.statusCode,
  );
}

/// 取得 detail（下载地址 + 包内清单）。
Future<AssrtDetail> fetchAssrtDetail(
  SubtitleHttp http,
  String token,
  String id,
) async {
  final url = Uri.parse('$assrtApiBase/sub/detail')
      .replace(queryParameters: {'id': id, 'token': token})
      .toString();
  final res = await http.getResponse(url, maxBytes: 4 * 1024 * 1024);
  if (res == null) {
    throw const SubtitleException('assrt 服务不可达或网络异常');
  }
  return parseAssrtDetail(
    utf8.decode(res.bytes, allowMalformed: true),
    statusCode: res.statusCode,
  );
}

/// assrt 检索的 Provider 适配：
/// 主关键词先探一批 → 从结果标题反推同剧别名 → 别名 + 集号一并检索。
Future<List<SubtitleCandidate>> searchAssrt({
  required SubtitleHttp http,
  required String token,
  required SubtitleQuery query,
  required List<String> keywords,
}) async {
  // 用户手填的检索词优先（面板里的输入框）；有它就不再自动推断/剥标签。
  final custom = query.customKeyword.trim();
  final sourceName = custom.isNotEmpty
      ? custom
      : (query.title.trim().isNotEmpty ? query.title : query.rawName);
  final normalized = custom.isNotEmpty
      ? NormalizedSubtitleQuery(title: custom, ep: '')
      : normalizeSubtitleQuery(sourceName);
  final mainKw = keywords.isEmpty ? '' : keywords.first;
  if (mainKw.trim().isEmpty && normalized.title.trim().isEmpty) {
    throw const SubtitleException('无法从该资源名提取剧名');
  }
  try {
    // ★ 按「干净剧名优先」顺序试：`keywords` 里第一个可能是带站点标签的
    //   `枕边杀局（臻彩）`，assrt 精确匹配搜不到；`normalized.title` 已被
    //   normalizeTitle 剥掉括号段与画质标签，是真正的剧名。
    //   实测：`枕边杀局（臻彩）` → 0 条；`枕边杀局` → 1 条。
    final tried = <String>{};
    final ordered = <String>[
      if (normalized.title.isNotEmpty) normalized.title,
      ...keywords,
    ];
    // ★ 拿主关键词的结果做「相关性基准」。
    //
    //   实测问题（2026-11-16，人性本兽）：主关键词 `人性本兽` 偶发返回 0 条
    //   （assrt 对 CJK 精确检索不稳定），于是循环继续试 `Animals WEB`、
    //   `AnimalsWEB`，最后落到裸词 `Animals` —— 返回 15 条完全无关的片子
    //   （危险动物 / 鈔級布偶 / Big.Sky…），用户看到「一堆字幕却没本片的」。
    //   第二次再搜，`人性本兽` 又命中了，于是「第二次才对」。
    //
    //   修法两层：
    //   ① 主关键词空结果时**重试一次**（等 800ms，避开瞬时抖动）；
    //   ② 退化关键词的结果一律做相关性过滤 —— 标题/发布名里必须真能对上
    //      剧名，否则丢弃。宁可给空列表，也不给一屏噪音。
    final primary = normalized.title.isNotEmpty
        ? normalized.title
        : (keywords.isEmpty ? '' : keywords.first.trim());
    var sawEmptyPrimary = false;
    for (final kw in ordered) {
      final k = kw.trim();
      if (k.isEmpty || !tried.add(k.toLowerCase())) continue;
      var hit = await assrtSearch(http, token, k);
      if (hit.isEmpty && k == primary) {
        // 主关键词空：等一拍再试，避免把瞬时抖动当成「没有字幕」。
        sawEmptyPrimary = true;
        await Future<void>.delayed(const Duration(milliseconds: 800));
        hit = await assrtSearch(http, token, k);
      }
      if (hit.isEmpty) continue;
      if (k == primary) return hit;
      // 退化关键词：只保留真能对上剧名的条目。
      final filtered = _filterRelevant(hit, normalized.title, query);
      if (filtered.isNotEmpty) return filtered;
    }
    // 全都没命中。
    //
    // ★ 提示语不能说「接口抖动」—— 实测（2026-11-17，兰香如故）assrt 用
    //   `兰香如故` / `兰香如故 S01E02` / `兰香如故 2` 三个词、隔 1.2 秒各搜一次，
    //   全部返回 `{"sub":{"subs":{}},"status":0}`：接口是好的，就是没这个片。
    //   把「真没有」说成「接口抖动」会让人一直点重试。
    //   反过来，主关键词空过一次时确实可能是抖动，所以两句话都要给。
    if (sawEmptyPrimary) {
      throw SubtitleException(
        'assrt 上没搜到「${normalized.title}」的字幕'
        '（接口有响应，属该片未收录；可换成别的片名再搜一次）',
      );
    }
    return const <SubtitleCandidate>[];
  } catch (e) {
    // 上面主动抛的「没搜到」提示要原样透出，不能被下面重写成
    // 「assrt 检索失败：...」—— 否则用户看不到该换词重搜的指引。
    if (e is SubtitleException && e.message.startsWith('assrt 上没搜到')) {
      rethrow;
    }
    final msg = e is SubtitleException ? e.message : e.toString();
    if (RegExp(r'token', caseSensitive: false).hasMatch(msg)) {
      throw const SubtitleException('assrt token 无效或已过期，请到「配置 → 外挂字幕」重新填写后重试');
    }
    if (RegExp(r'词|长度|keyword|101', caseSensitive: false).hasMatch(msg)) {
      throw const SubtitleException('assrt 要求搜索词至少 3 个字符，当前剧名过短，可手动补充剧集/全名再搜');
    }
    throw SubtitleException('assrt 检索失败：$msg');
  }
}

/// 下载字幕：包内直链（免解压）→ 整包下载 → 解压挑条目 → 解码。
Future<SubtitleFile> assrtDownload(
  SubtitleHttp http,
  String token,
  SubtitleCandidate candidate, {
  String videoName = '',
  String ep = '',
  void Function(List<SubtitleChoice> choices)? onChoices,
}) async {
  final hintVideo = videoName.isNotEmpty
      ? videoName
      : (candidate.videoName.isNotEmpty
            ? candidate.videoName
            : candidate.subname);
  final hintEp = ep.isNotEmpty
      ? ep
      : (candidate.episodeHint.isNotEmpty
            ? candidate.episodeHint
            : epOf(hintVideo));
  try {
    if (candidate.downloadUrl.isNotEmpty) {
      final buf = await http.getBytes(candidate.downloadUrl);
      if (buf == null) {
        throw const SubtitleException('字幕下载失败（地址失效或网络异常）');
      }
      return await subtitleFromBytesAsync(
        buf,
        fileName: candidate.subname,
        videoName: hintVideo,
        ep: hintEp,
        pickFirst: false, // 包里多条时抛 SubtitleChoicesException 让用户选
        onChoices: onChoices,
      );
    }
    if (candidate.id.isEmpty) {
      throw const SubtitleException('字幕候选缺少下载标识');
    }
    final detail = await fetchAssrtDetail(http, token, candidate.id);

    // ① 包内直链优先：拿到的是文本就直接用（省一次整包下载）。
    if (detail.direct.isNotEmpty) {
      final buf = await http.getBytes(detail.direct);
      if (buf != null && detectArchiveKind(buf) == null) {
        final text = SubtitleText.decode(buf);
        if (looksLikeSubtitle(text)) {
          final name = detail.directName.isNotEmpty
              ? detail.directName
              : candidate.subname;
          final fmt = extOf(name);
          // ★ 这条路径也要记缓存，否则第二次点同一个候选会重新下载。
          //   实测奥德赛（id=669742）走的就是这里：detail.direct 直接给出
          //   单个 srt，`subtitleFromBytesAsync` 根本没被调用，于是
          //   onChoices 不触发、`subtitles/cache/assrt_669742.json` 不存在，
          //   用户第二次点还是转圈下载。
          onChoices?.call(<SubtitleChoice>[
            SubtitleChoice(name: name, format: fmt, text: text),
          ]);
          return SubtitleFile(name: name, format: fmt, text: text);
        }
      }
    }

    // ② 整包下载 → 本地解压挑条目。
    final pkgUrl = detail.url.isNotEmpty ? detail.url : detail.direct;
    if (pkgUrl.isEmpty) {
      throw const SubtitleException('未取得字幕下载地址（assrt detail 为空）');
    }
    final buf = await http.getBytes(pkgUrl);
    if (buf == null) {
      throw const SubtitleException('字幕包下载失败（地址失效或网络异常）');
    }
    return await subtitleFromBytesAsync(
      buf,
      fileName: detail.filename.isNotEmpty
          ? detail.filename
          : candidate.subname,
      videoName: hintVideo,
      ep: hintEp,
      pickFirst: false, // 包里多条时抛 SubtitleChoicesException 让用户选
      onChoices: onChoices,
    );
  } on SubtitleChoicesException {
    // 多选项要冒泡到 UI，别被下面的 SubtitleException 分支当成失败。
    rethrow;
  } on SubtitleException {
    rethrow;
  } catch (e) {
    throw SubtitleException('字幕下载异常：$e');
  }
}
