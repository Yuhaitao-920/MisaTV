/// SubtitleCat（subtitlecat.com）字幕源 —— 免 token 的网页源。
///
/// 移植自旧版 `src/main/subtitle/subtitlecatProvider.ts`，用 RegExp 代替 cheerio：
///   search  GET `/index.php?search=<kw>` → 结果表格，每行 `subs/<id>/<name>.html` 链接
///   detail  GET `/subs/<id>/<name>.html` → 语言表格，部分语言提供 `.srt` 直链
library;

import 'normalize_query.dart';
import 'subtitle_from_bytes.dart';
import 'subtitle_http.dart';
import 'subtitle_models.dart';

const String catBase = 'https://www.subtitlecat.com';
const String catProviderId = 'subtitlecat';
const String catProviderName = 'SubtitleCat（免 token）';

/// 搜索页的一行结果。
class CatRow {
  const CatRow({
    required this.url,
    required this.name,
    this.size = '',
    this.downloads = 0,
    this.languages = 0,
  });

  /// 详情页绝对地址。
  final String url;

  /// 片源 / 影片名。
  final String name;
  final String size;
  final int downloads;
  final int languages;
}

/// 详情页里一条「语言 → 直链」。
class CatLangRow {
  const CatLangRow({required this.lang, required this.url});

  final String lang;
  final String url;
}

/// 按语言优先级挑出的一条可下载直链。
class CatPick {
  const CatPick({required this.lang, required this.url, required this.label});

  final String lang;
  final String url;
  final String label;
}

String _abs(String href) {
  if (href.startsWith('http')) return href;
  return '$catBase${href.startsWith('/') ? '' : '/'}$href';
}

String _decodeEntities(String s) {
  var out = s
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'");
  out = out.replaceAllMapped(RegExp(r'&#(x?[0-9a-fA-F]+);'), (m) {
    final raw = m.group(1)!;
    final code = raw.startsWith('x') || raw.startsWith('X')
        ? int.tryParse(raw.substring(1), radix: 16)
        : int.tryParse(raw);
    return code == null ? m.group(0)! : String.fromCharCode(code);
  });
  return out;
}

String _cleanText(String html) {
  final stripped = html.replaceAll(RegExp(r'<[^>]*>'), ' ');
  return _decodeEntities(stripped).replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// `<a href="…">…</a>`：group1/2 为双/单引号 href，group3 为内部 HTML。
final RegExp _anchorRe = RegExp(
  r'''<a\b[^>]*?href\s*=\s*(?:"([^"]*)"|'([^']*)')[^>]*>([\s\S]*?)</a>''',
  caseSensitive: false,
);

final RegExp _rowRe = RegExp(
  r'<tr\b[^>]*>([\s\S]*?)</tr>',
  caseSensitive: false,
);

class _HtmlRange {
  const _HtmlRange(this.start, this.end, this.html);

  final int start;
  final int end;
  final String html;
}

List<_HtmlRange> _rowRanges(String html) {
  return <_HtmlRange>[
    for (final m in _rowRe.allMatches(html))
      _HtmlRange(m.start, m.end, m.group(0) ?? ''),
  ];
}

String _rowHtmlAt(List<_HtmlRange> rows, int offset) {
  for (final r in rows) {
    if (offset >= r.start && offset < r.end) return r.html;
  }
  return '';
}

/// 解析搜索页结果（纯函数，单测用离线 HTML 覆盖）。
List<CatRow> parseCatSearch(String html) {
  if (html.isEmpty) return const <CatRow>[];
  final rows = _rowRanges(html);
  final out = <CatRow>[];
  for (final m in _anchorRe.allMatches(html)) {
    final href = (m.group(1) ?? m.group(2) ?? '').trim();
    final name = _cleanText(m.group(3) ?? '');
    if (href.isEmpty || name.isEmpty) continue;
    if (!href.contains('subs/')) continue;
    // 只要详情页链接（排除 .srt 直链）。
    if (!RegExp(r'\.html?(\?|#|$)', caseSensitive: false).hasMatch(href)) {
      continue;
    }
    final url = _abs(href);
    if (out.any((r) => r.url == url)) continue;
    final rowText = _cleanText(_rowHtmlAt(rows, m.start));
    final dl = RegExp(
      r'Downloads?\s*(\d+)',
      caseSensitive: false,
    ).firstMatch(rowText);
    final lg = RegExp(
      r'Languages?\s*(\d+)',
      caseSensitive: false,
    ).firstMatch(rowText);
    final sz = RegExp(
      r'Size\s*([\d.]+\s*[KMG]B)',
      caseSensitive: false,
    ).firstMatch(rowText);
    out.add(
      CatRow(
        url: url,
        name: name,
        size: sz == null ? '' : sz.group(1)!,
        downloads: dl == null ? 0 : int.tryParse(dl.group(1)!) ?? 0,
        languages: lg == null ? 0 : int.tryParse(lg.group(1)!) ?? 0,
      ),
    );
  }
  return out;
}

/// 解析详情页的语言直链（纯函数）。
List<CatLangRow> parseCatDetail(String html) {
  if (html.isEmpty) return const <CatLangRow>[];
  final rows = _rowRanges(html);
  final out = <CatLangRow>[];
  for (final m in _anchorRe.allMatches(html)) {
    final href = (m.group(1) ?? m.group(2) ?? '').trim();
    if (!RegExp(r'\.srt(\?|$)', caseSensitive: false).hasMatch(href)) continue;
    final url = _abs(href);
    if (out.any((r) => r.url == url)) continue;
    final rowHtml = _rowHtmlAt(rows, m.start);
    final td = RegExp(
      r'<td\b[^>]*>([\s\S]*?)</td>',
      caseSensitive: false,
    ).firstMatch(rowHtml);
    final lang = _cleanText(td == null ? '' : td.group(1) ?? '');
    out.add(
      CatLangRow(
        lang: lang.isEmpty
            ? catFileNameFromUrl(url)
                  .replaceFirst(RegExp(r'\.srt$', caseSensitive: false), '')
            : lang,
        url: url,
      ),
    );
  }
  return out;
}

/// 语言优先级：简中 > 繁中 > 其它中文 > 英文；都没有则取第一条。
final List<({RegExp re, String label})>
_langOrder = <({RegExp re, String label})>[
  (
    re: RegExp(r'zh-cn|chinese \(simplified\)|简体|简中', caseSensitive: false),
    label: '简中',
  ),
  (
    re: RegExp(r'zh-tw|chinese \(traditional\)|繁體|繁体|繁中', caseSensitive: false),
    label: '繁中',
  ),
  (re: RegExp(r'-zh([-_.]|$)|chinese|中文', caseSensitive: false), label: '中文'),
  (re: RegExp(r'-en([-_.]|$)|english|英文', caseSensitive: false), label: '英文'),
];

/// 按语言优先级挑一条可下载直链（纯函数）。
CatPick? pickCatDownload(List<CatLangRow> rows) {
  if (rows.isEmpty) return null;
  for (final item in _langOrder) {
    for (final r in rows) {
      if (item.re.hasMatch(r.url) || item.re.hasMatch(r.lang)) {
        return CatPick(lang: r.lang, url: r.url, label: item.label);
      }
    }
  }
  final first = rows.first;
  return CatPick(
    lang: first.lang,
    url: first.url,
    label: first.lang.isEmpty ? '未知语言' : first.lang,
  );
}

String _normText(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^0-9a-z\u4e00-\u9fff]+'), '');

/// 结果名是否与检索词相关（SubtitleCat 会返回大量模糊命中，必须过滤）。
bool catRelevant(String name, List<String> keywords) {
  final n = _normText(name);
  if (n.isEmpty) return false;
  return keywords.any((k) {
    final kk = _normText(k);
    return kk.length >= 2 && n.contains(kk);
  });
}

/// 过滤 + 排序（精确/前缀命中优先，其次下载量高者）+ 截断（纯函数）。
List<CatRow> rankCatRows(
  List<CatRow> rows,
  List<String> keywords, {
  int limit = 6,
}) {
  final kws = keywords.map(_normText).where((k) => k.length >= 2).toList();
  final scored =
      rows.where((r) => catRelevant(r.name, keywords)).map((row) {
        final n = _normText(row.name);
        final exact = kws.any((k) => n == k)
            ? 0
            : (kws.any((k) => n.startsWith(k)) ? 1 : 2);
        return (row: row, exact: exact, dl: row.downloads);
      }).toList()..sort((a, b) {
        final byExact = a.exact.compareTo(b.exact);
        return byExact != 0 ? byExact : b.dl.compareTo(a.dl);
      });
  return scored.take(limit).map((x) => x.row).toList();
}

/// 从直链 URL 取文件名（最后一段，去掉查询）。
String catFileNameFromUrl(String url) {
  final last = url.split('/').last.split('?').first;
  try {
    return Uri.decodeComponent(last);
  } catch (_) {
    return last;
  }
}

/// 搜索：只取前 3 个关键词（省流），每个关键词最多留 6 条命中。
Future<List<SubtitleCandidate>> searchSubtitleCat({
  required SubtitleHttp http,
  required SubtitleQuery query,
  required List<String> keywords,
}) async {
  final seen = <String, SubtitleCandidate>{};
  final ep = query.episode == null
      ? extractEp(query.rawName)
      : query.episode.toString();
  for (final kw in keywords.take(3)) {
    final html = await http.getText(
      '$catBase/index.php?search=${Uri.encodeQueryComponent(kw)}',
      referer: catBase,
    );
    if (html == null) continue;
    for (final row in rankCatRows(parseCatSearch(html), keywords)) {
      if (seen.containsKey(row.url)) continue;
      final detail = <String>[
        if (row.size.isNotEmpty) row.size,
        if (row.downloads > 0) '${row.downloads} 次下载',
        if (row.languages > 0) '${row.languages} 种语言',
      ].join(' · ');
      seen[row.url] = SubtitleCandidate(
        providerId: catProviderId,
        providerName: catProviderName,
        id: row.url,
        title: row.name,
        language: '多语（下载时优先简中）',
        format: 'srt',
        downloadUrl: row.url,
        subname: row.name,
        detail: detail,
        videoName: row.name,
        episodeHint: ep,
      );
    }
    if (seen.length >= 12) break;
  }
  return seen.values.toList();
}

/// 下载：打开详情页 → 按语言优先级挑直链 → 下载 → 统一解码/解压/挑条目。
Future<SubtitleFile> fetchSubtitleCat(
  SubtitleHttp http,
  SubtitleCandidate candidate, {
  String ep = '',
  void Function(List<SubtitleChoice> choices)? onChoices,
}) async {
  final detailUrl = candidate.downloadUrl.isNotEmpty
      ? candidate.downloadUrl
      : candidate.id;
  if (detailUrl.isEmpty) {
    throw const SubtitleException('SubtitleCat 候选缺少详情页地址');
  }
  final html = await http.getText(detailUrl, referer: catBase);
  if (html == null) {
    throw const SubtitleException('SubtitleCat 详情页打开失败（站点不可达或改版）');
  }
  final picked = pickCatDownload(parseCatDetail(html));
  if (picked == null) {
    throw const SubtitleException('该条目没有可直接下载的字幕（SubtitleCat 仅部分语言提供下载）');
  }
  final buf = await http.getBytes(picked.url, referer: detailUrl);
  if (buf == null) {
    throw const SubtitleException('字幕文件下载失败（地址失效或网络异常）');
  }
  final videoName = candidate.videoName.isNotEmpty
      ? candidate.videoName
      : candidate.subname;
  try {
    return await subtitleFromBytesAsync(
      buf,
      fileName: catFileNameFromUrl(picked.url),
      videoName: videoName,
      ep: ep.isNotEmpty ? ep : candidate.episodeHint,
      pickFirst: false, // 包里多条时抛 SubtitleChoicesException 让用户选
      onChoices: onChoices,
    );
  } on SubtitleChoicesException {
    rethrow;
  } on SubtitleException {
    rethrow;
  } catch (e) {
    throw SubtitleException('字幕下载异常：$e');
  }
}
