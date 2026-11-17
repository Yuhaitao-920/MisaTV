/// 从播放文件名 / 资源名提取「剧名 + 集号」作为字幕检索关键词。
///
/// 逐函数移植自旧版 `src/engine/subtitle/normalizeQuery.ts`。
/// 例：`繁花.2023.第11集.1080p.WEB-DL.x264-ABC` → `title: 繁花, ep: 11`
library;

/// 归一化后的检索词。
class NormalizedSubtitleQuery {
  const NormalizedSubtitleQuery({required this.title, required this.ep});

  final String title;
  final String ep;
}

final RegExp _noise = RegExp(
  r'(1080[pPiI]?|2160[pPiI]?|720[pPiI]?|4k|web[-_.]?dl|web[-_.]?rip|bd[-_.]?(rip|720|1080)?|blu[-_.]?ray|h\.?264|x264|h\.?265|x265|hevc|10[-_.]?bit|hdr(10\+?)?|dolby[-_.]?vision|dv|dts[-_.]?hd?|dd[+p]?|ac3|aac(2\.?0)?|atmos|mkv|mp4|mp4b|srt|ass|uniqp|yysubs|fnf|dmhy|简体|简体中文|繁体|繁体中文|中字|国语|粤语|双语|中英|国粤|英语|日语|韩语|[/_#].*)',
  caseSensitive: false,
);

/// 集号模式（顺序有讲究：先 S01E10 再 E10）。
final List<RegExp> _epPatterns = <RegExp>[
  RegExp(r'\b[Ss](\d{1,3})[Ee](\d{1,3})\b'),
  RegExp(r'\b[Ee](\d{1,3})\b'),
  RegExp(r'第\s*(\d{1,3})\s*[集话季](?:\s*[-~]\s*第?\s*(\d{1,3})\s*[集话季])?'),
  RegExp(r'[（(\[]\s*第?\s*(\d{1,3})\s*[集话][）)\] ]'),
];

final RegExp _tailNumber = RegExp(r'(?<![0-9A-Za-z])(\d{1,3})(?![0-9])');

/// 提取集号（优先中文“第N集”；其次 E/如；再退化为末尾数字）。
String extractEp(String name) {
  for (final re in _epPatterns) {
    for (final m in re.allMatches(name)) {
      final raw = m.groupCount >= 2 ? (m.group(2) ?? m.group(1)) : m.group(1);
      if (raw != null && raw.isNotEmpty) {
        return raw.replaceFirst(RegExp(r'^0+'), '');
      }
    }
  }
  final tail = _tailNumber.firstMatch(name);
  return tail == null ? '' : tail.group(1)!.replaceFirst(RegExp(r'^0+'), '');
}

/// 从资源名（常形如“剧名 - 第N集”或“剧名 第N集”）提取查询词。
NormalizedSubtitleQuery normalizeSubtitleQuery(String name) =>
    NormalizedSubtitleQuery(title: normalizeTitle(name), ep: extractEp(name));

/// 提取剧名主标题（去掉“- 集名”、“第N集”、年份、清晰度、发布组等后缀）。
String normalizeTitle(String name) {
  var title = name;
  // 去掉「标题 - 集名」的后半段（- / — / 空格 + 第N集 或 集名）
  title = title.split(RegExp(r'[-—–]\s*第\s*\d+\s*[集话][^(-—–]*')).first;
  final dash = RegExp(r'^(.*?)[-\s]*(第\s*\d+\s*[集话]).*$').firstMatch(title);
  if (dash != null) {
    title = dash.group(1) ?? '';
  } else {
    final epIdx = title.indexOf(RegExp(r'第\s*\d+\s*[集话]'));
    if (epIdx > 0) title = title.substring(0, epIdx);
  }
  // 去集名（“标题 - 集名”而无数字时）
  final pure = RegExp(r'^(.*?)\s*[-—–]\s*([^-—–]{1,20})$').firstMatch(title.trim());
  if (pure != null && (pure.group(1) ?? '').length >= 2) {
    title = pure.group(1)!;
  }
  // ★ 去站点的「线路标签」括号段：`（臻彩）`、`(4K)`、`（国语版）`、`（48集全）`。
  //
  //   assrt 是按剧名精确匹配的：「枕边杀局（臻彩）」搜不到，
  //   「枕边杀局」立刻命中。而源站普遍在 name 后面挂画质 / 音轨标签。
  //
  //   ★ 必须放在 `_noise` **之前**：`_noise` 会先把「国语」替换成空格，
  //     括号里只剩「（ 版）」，那时就认不出这是标签了。
  //
  //   ★ 也不能无脑剥所有括号段：
  //     · `Legal High (リーガルハイ)` → 括号里是外文原名，剥了反而搜不到
  //     · `三体（腾讯版）`           → 括号里是版本区分，剥了会搜到别的版本
  //   判定标准：纯数字 / 集数说明 / 画质音轨标签词 → 剥；其余原样保留。
  title = title.replaceAllMapped(_bracketRe, (m) {
    final inner = (m.group(1) ?? '').trim();
    if (inner.isEmpty) return ' ';
    final isTag =
        RegExp(r'^\d{1,4}$').hasMatch(inner) || // （2026）
        RegExp(r'^(全\s*)?\d{1,4}\s*[集话季]').hasMatch(inner) || // （48集全）
        _labelRe.hasMatch(inner) || // （臻彩）/（国语版）
        // （4K）/（1080p）/（HDR10）：整个括号内容都是画质/编码词。
        //   判据：把已知画质词全换掉后只剩空白或标点 → 纯画质标签。
        (_qualityRe.hasMatch(inner) &&
            inner
                .replaceAll(_qualityRe, '')
                .replaceAll(RegExp(r'[\s.\-_,/+&]'), '')
                .isEmpty);
    return isTag ? ' ' : m.group(0)!;
  });

  // 去嘈杂后缀（年份 / 清晰度 / 编码 / 发布组 / 标签）
  title = title
      .replaceAll(_noise, ' ')
      .replaceAll(RegExp(r'\s{2,}'), ' ')
      .replaceAll('.', ' ')
      .trim();
  // ★ 年份只剥「独立出现」的那个：`枕边杀局 2026` 剥，`请回答1988` 不能剥。
  //   原来的 `\b(19|20)\d{2}\b` 在 CJK 前也成立（`\b` 按 ASCII 判词边界），
  //   于是《请回答1988》被截成《请回答》，搜不到任何字幕。
  title = title
      .replaceAll(RegExp(r'(?<=[\s\-—–_])(?:19|20)\d{2}(?=\s|$)'), ' ')
      .replaceAll(RegExp(r'[\[【].*?[\]】]'), ' ')
      .replaceAll(_labelRe, ' ')
      .replaceAll(RegExp(r'\s{2,}'), ' ')
      .trim();
  return title;
}

/// 括号段（中文/英文括号各算一对，内容不含括号本身）。
final RegExp _bracketRe = RegExp(r'[（(]([^（()）]*)[)）]');

/// 画质 / 编码 / 音轨词（只看括号段是否为「纯画质标签」时用）。
final RegExp _qualityRe = RegExp(
  r'(8k|4k|2160[pi]?|1080[pi]?|720[pi]?|576[pi]?|480[pi]?|'
  r'web[-_.]?dl|web[-_.]?rip|blu[-_.]?ray|bdrip|hdr10\+?|hdr|sdr|dolby|'
  r'x\.?264|x\.?265|h\.?264|h\.?265|hevc|avc|10bit|8bit|aac|ac3|ddp?|dts|atmos|'
  r'60fps|50fps|hq|hd|fhd|uhd|sd)',
  caseSensitive: false,
);
/// 画质 / 音轨 / 版本标签词：出现在标题里就是噪声。
final RegExp _labelRe = RegExp(
  r'(臻彩|原画|高码率|臻享|蓝光|超清|高清|标清|抢鲜|抢先|杜比视界|杜比|视界|'
  r'HDR10?\+?|SDR|国语版|粤语版|中字版|未删减|完整版|加长版)',
  caseSensitive: false,
);

/// 生成一组剧名关键词候选（主标题 + 常见变体）。
List<String> titleVariants(String title) {
  final t = title.trim();
  if (t.isEmpty) return const <String>[];
  final out = <String>[t];
  final noSpace = t.replaceAll(RegExp(r'\s+'), '').replaceAll(RegExp(r'[·/]'), '');
  if (noSpace.isNotEmpty && noSpace != t) out.add(noSpace);
  final parts = t.split(RegExp(r'\s+'));
  if (parts.length > 1 && parts.last.length > 1) {
    final joined = parts.sublist(0, parts.length - 1).join(' ');
    if (joined.isNotEmpty) out.add(joined);
  }
  return out.toSet().take(4).toList();
}

String buildSearchQuery(String name) {
  final q = normalizeSubtitleQuery(name);
  final kw = q.title + (q.ep.isEmpty ? '' : ' ${q.ep}');
  return kw.trim();
}

/// 统一取「剧名副名」供检索（优先 knownTitle，为空则从资源名截取第一段）。
String animeTitleForQuery(String resourceName, [String? knownTitle]) {
  final t = (knownTitle ?? '').trim();
  if (t.isNotEmpty) return t;
  final seg = resourceName.split(RegExp(r'[-—–~]')).first.trim();
  return seg.isNotEmpty ? seg : resourceName.trim();
}
