/// 用户自定义字幕 API。
///
/// 配置格式（每行一个）：
/// `名称@https://example.com/sub?title={title}&ep={episode}`
///
/// 支持占位符：`{title}` `{year}` `{season}` `{episode}` `{rawName}`。
/// 接口可以返回：
///   · JSON 候选列表（数组，或 data/results/subtitles/list 下的数组）；
///   · 直接返回 srt / ass / ssa / vtt / zip / gz 字幕文件。
library;

import 'dart:convert';

import 'archive.dart';
import 'normalize_query.dart';
import 'subtitle_from_bytes.dart';
import 'subtitle_http.dart';
import 'subtitle_models.dart';

class CustomSubtitleApi {
  const CustomSubtitleApi({
    required this.id,
    required this.name,
    required this.urlTemplate,
  });

  final String id;
  final String name;
  final String urlTemplate;
}

/// 解析多行配置；空行 / # 注释 / 非法地址忽略，同地址去重。
List<CustomSubtitleApi> parseCustomSubtitleApis(String text) {
  final out = <CustomSubtitleApi>[];
  final seen = <String>{};
  for (final raw in text.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final at = line.lastIndexOf('@');
    var name = '';
    var template = line;
    if (at > 0) {
      final tail = line.substring(at + 1).trim();
      if (_hasScheme(tail)) {
        name = line.substring(0, at).trim();
        template = tail;
      }
    }
    if (!_validTemplate(template)) continue;
    final key = template.trim();
    if (!seen.add(key)) continue;
    final label = name.isEmpty ? _hostLabel(template) : name;
    out.add(
      CustomSubtitleApi(
        id: 'custom:${out.length}',
        name: label.isEmpty ? '自定义字幕' : label,
        urlTemplate: key,
      ),
    );
  }
  return out;
}

/// 用查询条件展开 URL 模板。
String customSubtitleUrl(String template, SubtitleQuery query) {
  final raw = query.rawName.trim();
  final source = query.title.trim().isNotEmpty ? query.title : raw;
  final title = normalizeTitle(source);
  final ep =
      query.episode?.toString() ?? extractEp(raw.isNotEmpty ? raw : source);
  return template
      .replaceAll('{title}', Uri.encodeComponent(title))
      .replaceAll('{rawName}', Uri.encodeComponent(raw.isEmpty ? source : raw))
      .replaceAll('{year}', query.year?.toString() ?? '')
      .replaceAll('{season}', query.season?.toString() ?? '')
      .replaceAll('{episode}', ep);
}

/// 检索自定义接口；网络失败 / 结构异常返回空列表，不抛整体错误。
Future<List<SubtitleCandidate>> searchCustomSubtitleApi(
  SubtitleHttp http,
  CustomSubtitleApi api,
  SubtitleQuery query,
) async {
  final url = customSubtitleUrl(api.urlTemplate, query);
  final res = await http.getResponse(url);
  if (res == null || res.statusCode != 200) return const [];
  final text = utf8.decode(res.bytes, allowMalformed: true).trim();
  if (text.startsWith('{') || text.startsWith('[')) {
    dynamic json;
    try {
      json = jsonDecode(text);
    } catch (_) {
      return const [];
    }
    return _candidatesFromJson(json, api, url, query);
  }
  if (!_looksLikeSubtitle(res.bytes, text)) return const [];
  final format = _formatOfUrl(url);
  return [
    SubtitleCandidate(
      providerId: api.id,
      providerName: api.name,
      id: url,
      title: api.name,
      language: '自动',
      format: format,
      downloadUrl: url,
      detail: '自定义 API',
      episodeHint: query.episode?.toString() ?? '',
    ),
  ];
}

/// 下载自定义接口候选；直接响应 / 压缩包均交给 [subtitleFromBytes] 解码。
Future<SubtitleFile> downloadCustomSubtitleApi(
  SubtitleHttp http,
  CustomSubtitleApi api,
  SubtitleCandidate candidate, {
  void Function(List<SubtitleChoice> choices)? onChoices,
}) async {
  final url = candidate.downloadUrl.trim().isEmpty
      ? customSubtitleUrl(
          api.urlTemplate,
          SubtitleQuery(title: candidate.title),
        )
      : candidate.downloadUrl;
  final bytes = await http.getBytes(url);
  if (bytes == null) {
    throw const SubtitleException('自定义字幕接口不可达或文件超过大小限制');
  }
  final name = candidate.title.trim().isEmpty
      ? api.name
      : candidate.title.trim();
  final ext = candidate.format.trim().isEmpty
      ? _formatOfUrl(url)
      : candidate.format.trim();
  try {
    return await subtitleFromBytesAsync(
      bytes,
      fileName: ext.isEmpty ? name : '$name.$ext',
      videoName: candidate.videoName,
      ep: candidate.episodeHint,
      pickFirst: false, // 包里多条时抛 SubtitleChoicesException 让用户选
      onChoices: onChoices,
    );
  } on SubtitleChoicesException {
    rethrow;
  } on SubtitleException {
    rethrow;
  } catch (e) {
    throw SubtitleException('自定义字幕解析失败：$e');
  }
}

List<SubtitleCandidate> _candidatesFromJson(
  dynamic raw,
  CustomSubtitleApi api,
  String baseUrl,
  SubtitleQuery query,
) {
  final list = _items(raw);
  final out = <SubtitleCandidate>[];
  for (final item in list) {
    if (item is! Map) continue;
    final url = _text(item, [
      'url',
      'downloadUrl',
      'download_url',
      'link',
      'file',
      'src',
    ]);
    if (url.isEmpty) continue;
    final absolute = _absoluteUrl(baseUrl, url);
    if (absolute.isEmpty) continue;
    final title = _text(item, ['title', 'name', 'label']);
    final language = _text(item, ['language', 'lang', 'languageName']);
    final format = _text(item, ['format', 'ext', 'extension', 'type']);
    final id = _text(item, ['id', 'subId', 'sub_id']);
    out.add(
      SubtitleCandidate(
        providerId: api.id,
        providerName: api.name,
        id: id.isEmpty ? absolute : id,
        title: title.isEmpty ? api.name : title,
        language: language.isEmpty ? '自动' : language,
        format: (format.isEmpty ? _formatOfUrl(absolute) : format)
            .toLowerCase(),
        downloadUrl: absolute,
        subname: _text(item, ['subname', 'videoName', 'video_name']),
        detail: _text(item, ['detail', 'desc', 'description']),
        videoName: _text(item, ['videoName', 'video_name', 'subname']),
        episodeHint: query.episode?.toString() ?? '',
      ),
    );
  }
  return out;
}

List<dynamic> _items(dynamic raw) {
  if (raw is List) return raw;
  if (raw is Map) {
    if (_text(raw, ['url', 'downloadUrl', 'download_url', 'link']).isNotEmpty) {
      return [raw];
    }
    for (final key in const ['data', 'results', 'subtitles', 'list', 'items']) {
      final value = raw[key];
      if (value is List) return value;
      if (value is Map) return _items(value);
    }
  }
  return const [];
}

String _text(Map item, List<String> keys) {
  for (final key in keys) {
    final value = item[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
    if (value is num) return '$value';
  }
  return '';
}

String _absoluteUrl(String base, String raw) {
  final direct = Uri.tryParse(raw);
  if (direct != null && direct.hasScheme) return raw;
  final uri = Uri.tryParse(base);
  if (uri == null) return '';
  return uri.resolve(raw).toString();
}

String _formatOfUrl(String url) {
  final uri = Uri.tryParse(url);
  final path = uri?.path ?? url;
  final dot = path.lastIndexOf('.');
  if (dot < 0 || dot == path.length - 1) return 'srt';
  final ext = path.substring(dot + 1).toLowerCase();
  return const {
        'srt',
        'ass',
        'ssa',
        'vtt',
        'sub',
        'txt',
        'zip',
        'gz',
      }.contains(ext)
      ? ext
      : 'srt';
}

bool _looksLikeSubtitle(List<int> bytes, String text) {
  if (detectArchiveKind(bytes) != null) return true;
  final lower = text.toLowerCase();
  if (lower.startsWith('<!doctype') || lower.startsWith('<html')) {
    return false;
  }
  return RegExp(
        r'(?:^|\n)(?:\d{1,2}:\d{2}:\d{2}[,.]\d{2,3}\s*-->|[\[<]?(?:script info|webvtt)\b|dialogue:)',
        caseSensitive: false,
      ).hasMatch(text.trim()) ||
      RegExp(r'-->').hasMatch(text);
}

bool _hasScheme(String s) =>
    RegExp(r'^[a-z][a-z0-9+.\-]*://', caseSensitive: false).hasMatch(s);

bool _validTemplate(String template) {
  if (!_hasScheme(template) ||
      !template.toLowerCase().startsWith(RegExp(r'https?://'))) {
    return false;
  }
  final probe = template
      .replaceAll('{title}', 'x')
      .replaceAll('{rawName}', 'x')
      .replaceAll('{year}', '2024')
      .replaceAll('{season}', '1')
      .replaceAll('{episode}', '1');
  final uri = Uri.tryParse(probe);
  return uri != null && uri.host.isNotEmpty;
}

String _hostLabel(String template) {
  final probe = template
      .replaceAll('{title}', 'x')
      .replaceAll('{rawName}', 'x')
      .replaceAll('{year}', '2024')
      .replaceAll('{season}', '1')
      .replaceAll('{episode}', '1');
  final uri = Uri.tryParse(probe);
  return uri?.host.replaceFirst(RegExp(r'^www\.'), '') ?? '';
}
