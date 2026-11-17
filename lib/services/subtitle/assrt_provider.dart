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

/// 解析 `sub/search` 响应（纯函数，便于离线单测）。
List<SubtitleCandidate> parseAssrtSearch(
  String body, {
  int statusCode = 200,
}) {
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
    final id = raw['id'];
    if (id == null) continue;
    final nativeName = _str(raw['native_name']);
    final videoName = _str(raw['videoname']);
    final lang = raw['lang'];
    final langDesc = lang is Map ? _str(lang['desc']) : '';
    out.add(SubtitleCandidate(
      providerId: assrtProviderId,
      providerName: assrtProviderName,
      id: id.toString(),
      title: nativeName,
      language: langDesc,
      format: _str(raw['subtype']).toLowerCase(),
      downloadUrl: '',
      subname: videoName.isNotEmpty ? videoName : nativeName,
      detail: _str(raw['release_site']),
      // 从发布名里取集号：`...S01E03...` → '3'。
      // 为空说明这是整片/合集包，UI 据此提示「不分集」。
      episodeHint: epOf(videoName.isNotEmpty ? videoName : nativeName),
    ));
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
      if (!RegExp(r'\.(srt|ass|ssa|vtt|sub)$', caseSensitive: false)
          .hasMatch(fName.isNotEmpty ? fName : fUrl)) {
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
  final sourceName = query.title.trim().isNotEmpty ? query.title : query.rawName;
  final normalized = normalizeSubtitleQuery(sourceName);
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
    for (final kw in ordered) {
      final k = kw.trim();
      if (k.isEmpty || !tried.add(k.toLowerCase())) continue;
      final hit = await assrtSearch(http, token, k);
      if (hit.isNotEmpty) return hit;
    }
    return const <SubtitleCandidate>[];
  } catch (e) {
    final msg = e is SubtitleException ? e.message : e.toString();
    if (RegExp(r'token', caseSensitive: false).hasMatch(msg)) {
      throw const SubtitleException(
        'assrt token 无效或已过期，请到「配置 → 外挂字幕」重新填写后重试',
      );
    }
    if (RegExp(r'词|长度|keyword|101', caseSensitive: false).hasMatch(msg)) {
      throw const SubtitleException(
        'assrt 要求搜索词至少 3 个字符，当前剧名过短，可手动补充剧集/全名再搜',
      );
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
      return subtitleFromBytes(
        buf,
        fileName: candidate.subname,
        videoName: hintVideo,
        ep: hintEp,
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
          return SubtitleFile(
            name: detail.directName.isNotEmpty
                ? detail.directName
                : candidate.subname,
            format: extOf(
              detail.directName.isNotEmpty
                  ? detail.directName
                  : candidate.subname,
            ),
            text: text,
          );
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
    return subtitleFromBytes(
      buf,
      fileName: detail.filename.isNotEmpty
          ? detail.filename
          : candidate.subname,
      videoName: hintVideo,
      ep: hintEp,
    );
  } on SubtitleException {
    rethrow;
  } catch (e) {
    throw SubtitleException('字幕下载异常：$e');
  }
}
