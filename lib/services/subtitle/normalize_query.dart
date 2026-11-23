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
  r'(1080[pPiI]?|2160[pPiI]?|720[pPiI]?|4k|web[-_.]?dl|web[-_.]?rip|bd[-_.]?(rip|720|1080)?|blu[-_.]?ray|remux|uhd|bdmv|hdtv|h\.?264|x264|h\.?265|x265|hevc|avc|10[-_.]?bit|8[-_.]?bit|hdr(10\+?)?|dolby[-_.]?vision|dv|dts[-_.]?hd?|truehd|atmos|dd[+p]?|eac3|ac3|aac(2\.?0)?|flac|opus|mkv|mp4b?|srt|ass|ssa|vtt|uniqp|yysubs|fnf|dmhy|简体|简体中文|繁体|繁体中文|中字|国语|粤语|双语|中英|国粤|英语|日语|韩语|[/_#].*)',
  caseSensitive: false,
);

/// 方括号 / 中文方括号整段：`[1.9GB]`、`[82.2GB]`、`【L-兰香如故】`、`【噢/澳·嘚·噻】`。
///
/// ★ 必须在 [normalizeTitle] 的最前面切掉，理由有三：
///   ① `【噢/澳·嘚·噻】` 里的 `/` 会被 [_noise] 的 `[/_#].*` 当发布组吃掉，
///      结果只剩 `【噢` —— 实测奥德赛就是这样搜出一堆残片关键词；
///   ② `【L-兰香如故】` 里的 `-` 会被「去集名」的 `X - Y` 规则当成副标题切开，
///      把 `兰香如故` 整段扔掉，只剩 `【L`；
///   ③ 这一段本来就是站点的线路别名 / 体积说明，不是片名。
final RegExp _blockRe = RegExp(r'\[[^\]]*\]|【[^】]*】');

/// 集号提取前要抹掉的「非集号数字」。
///
/// 实测漏判（2026-11-17 日志）：
///   · `[82.2GB]2160p…`  → 尾巴数字取到 82（体积）和 160（分辨率前半）
///   · `DTS-HD.MA.5.1…`  → 取到 5（声道）
///   · `…10bit…`         → 取到 10（位深）
/// 这些都不是集号，认成集号会让字幕按「第 82 集」去匹配，必然 0 条。
final RegExp _nonEpisodeNumbers = RegExp(
  r'(\d+(\.\d+)?\s*[GgMm][Bb]|\d{3,4}[pPiI]|\d+\s*[Bb]it|\d+\.\d+|\d+\s*[Ff][Pp][Ss])'
  r'|(dts|truehd|atmos|dd\+?|eac3|ac3|aac|flac|opus)[-_.a-z0-9]*',
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
///
/// ★ 退化路径（末尾数字）必须先抹掉体积 / 分辨率 / 声道 / 位深，否则
///   `[82.2GB]2160p…` 会取到 82、`DTS-HD.MA.5.1` 会取到 5。
String extractEp(String name) {
  for (final re in _epPatterns) {
    for (final m in re.allMatches(name)) {
      final raw = m.groupCount >= 2 ? (m.group(2) ?? m.group(1)) : m.group(1);
      if (raw != null && raw.isNotEmpty) {
        return raw.replaceFirst(RegExp(r'^0+'), '');
      }
    }
  }
  final cleaned = name
      .replaceAll(_blockRe, ' ')
      .replaceAll(_nonEpisodeNumbers, ' ');
  final tail = _tailNumber.firstMatch(cleaned);
  return tail == null ? '' : tail.group(1)!.replaceFirst(RegExp(r'^0+'), '');
}

/// 从资源名（常形如“剧名 - 第N集”或“剧名 第N集”）提取查询词。
NormalizedSubtitleQuery normalizeSubtitleQuery(String name) =>
    NormalizedSubtitleQuery(title: normalizeTitle(name), ep: extractEp(name));

/// 提取剧名主标题（去掉“- 集名”、“第N集”、年份、清晰度、发布组等后缀）。
String normalizeTitle(String name) {
  // ★ 先切掉方括号段（`[1.9GB]`、`【L-兰香如故】`）。
  //
  //   必须最先做：里面的 `/` 会被 `_noise` 的发布组分支吃掉、`-` 会被
  //   「X - Y」副标题规则切断，两条路都会把真剧名连残片一起丢掉。
  //   实测：`[1.9GB]S01E02.mkv【L-兰香如故】` → 旧实现只剩 `S01E02 【L`。
  var title = name.replaceAll(_blockRe, ' ');
  // 去掉「标题 - 集名」的后半段（- — – 空格 + 第N集 或 集名）
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
  // ★ 剧名整段都在方括号里时（`[1.9GB]S01E02.mkv【L-兰香如故】`）上面会把真名
  //   一起扔掉，只剩 `S01E02`。这里回填一次：从方括号内容里取连续汉字段。
  //
  //   只认「连续 ≥2 个汉字」的段落，所以
  //     · `【L-兰香如故】` → `兰香如故` ✓
  //     · `【噢/澳·嘚·噻】` → 没有连续汉字，不回填（那是站点的花体译名，
  //       本来就不是可检索的剧名）✓
  //   且只在当前结果「没有连续汉字」时才回填，正常片名不受影响。
  if (!_hasCjkRun(title)) {
    final fromBlock = _cjkRunInBlocks(name);
    if (fromBlock.isNotEmpty) title = fromBlock;
  }
  return title;
}

/// 是否含连续 ≥2 个汉字。
bool _hasCjkRun(String text) =>
    RegExp(r'[\u4e00-\u9fff]{2,}').hasMatch(text);

/// 从方括号 / 【】段里取最长的连续汉字段（`【L-兰香如故】` → `兰香如故`）。
String _cjkRunInBlocks(String name) {
  var best = '';
  for (final m in _blockRe.allMatches(name)) {
    final inner = m.group(0)!;
    for (final run in RegExp(r'[\u4e00-\u9fff]{2,}').allMatches(inner)) {
      final t = run.group(0)!;
      if (t.length > best.length) best = t;
    }
  }
  return best;
}

/// 括号段（中文/英文括号各算一对，内容不含括号本身）。
final RegExp _bracketRe = RegExp(r'[（(]([^（()）]*)[)）]');

/// 画质 / 编码 / 音轨词（只看括号段是否为「纯画质标签」时用）。
final RegExp _qualityRe = RegExp(
  r'(8k|4k|2160[pi]?|1080[pi]?|720[pi]?|576[pi]?|480[pi]?|'
  r'web[-_.]?dl|web[-_.]?rip|blu[-_.]?ray|remux|bdrip|bdmv|hdtv|hdr10\+?|hdr|sdr|dolby|'
  r'x\.?264|x\.?265|h\.?264|h\.?265|hevc|avc|10bit|8bit|aac|ac3|eac3|ddp?|dts|truehd|atmos|'
  r'flac|opus|60fps|50fps|hq|hd|fhd|uhd|sd)',
  caseSensitive: false,
);
/// 画质 / 音轨 / 版本标签词：出现在标题里就是噪声。
///
/// ★ 「真彩」和「臻彩」是两个不同写法，源站两种都在用：
///   · 玩偶的「奥德赛2026（臻彩）」
///   · 花卷的「人性本兽（真彩）」「消失的爱人（真彩）」
///   只写「臻彩」会漏掉后者 —— 实测「人性本兽（真彩）」剥不掉标签，
///   于是 assrt 按全名精确匹配 → 0 条（真实结果 id=733904，用「人性本兽」能搜到）。
final RegExp _labelRe = RegExp(
  r'(臻彩|真彩|原画|高码率|臻享|蓝光|超清|高清|标清|抢鲜|抢先|杜比视界|杜比|视界|'
  r'HDR10?\+?|SDR|国语版|粤语版|中字版|未删减|完整版|加长版|修复版|修復版|'
  r'国配|台配|国粤|英字|双语|中字)',
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
  // ★ 结尾粘着年份就拆一份「去掉年份」的变体。
  //
  //   实测：`奥德赛2026（臻彩）` → normalizeTitle → `奥德赛2026`，
  //   而 assrt 用 `奥德赛2026` 搜不到（那是把片名和年份连写了一串），
  //   用 `奥德赛` 才能搜到 15 条。反过来 `人性本兽` 没有年份，不受影响。
  //
  //   只在「年份紧贴汉字」时拆 —— `1917`、`2012` 这种纯数字片名不能动。
  final m = RegExp(r'^(.{2,}?)((?:19|20)\d{2})$').firstMatch(t);
  if (m != null) {
    final base = m.group(1)!.trim();
    if (base.isNotEmpty) out.add(base);
  }
  return out.toSet().take(4).toList();
}

String buildSearchQuery(String name) {
  final q = normalizeSubtitleQuery(name);
  final kw = q.title + (q.ep.isEmpty ? '' : ' ${q.ep}');
  return kw.trim();
}

/// 检索词是否是不能拿来搜的残片。
///
/// 判据（实测日志 `兰香如故` / `奥德赛` 两类残片）：
///   · 带未闭合的括号残片（`S01E02 【L`、`UHD Remux MA 5 1 【噢`）；
///   · 只有一个季集号（`S01E02`）；
///   · 剥掉季集号 / 画质 / 音轨 / 标签后，剩下的「片名本体」不足 2 个字
///     —— **前提是真剥掉了东西**，否则纯数字片名（`1917` / `2012`）会被误杀。
///
/// 为什么必须挡：这些词在 assrt 上要么 0 条，要么返回 15 条无关片；
/// 而且每个词都是一次真实请求 —— 连着打 4~5 次就自己触发 509 限流。
bool isJunkSubtitleKeyword(String keyword) {
  final k = keyword.trim();
  if (k.isEmpty) return true;
  // 残片括号：`【L` / `【噢` / 半个 `)` / `[1.9GB]`
  if (RegExp(r'[\[\]【】()（）]').hasMatch(k)) return true;
  // 只有一个季集号
  if (RegExp(r'^[Ss]\d{1,3}([Ee]\d{1,3})?$').hasMatch(k)) return true;
  final stripped = k
      .replaceAll(RegExp(r'[Ss]\d{1,3}[Ee]\d{1,3}'), ' ')
      .replaceAll(RegExp(r'\b[Ee]\d{1,3}\b'), ' ')
      .replaceAll(_qualityRe, ' ')
      .replaceAll(_nonEpisodeNumbers, ' ')
      .replaceAll(_labelRe, ' ')
      .replaceAll(RegExp(r'[\s._\-·/&+,:;|]+'), ' ')
      .trim();
  // 什么都没剥掉 → 本来就是干净片名（含 `1917` / `2012` 这种纯数字片名）。
  if (stripped == k) return false;
  return stripped.replaceAll(RegExp(r'[\d\s._\-·/&+,:;|]+'), '').length < 2;
}

/// 统一取「剧名副名」供检索（优先 knownTitle，为空则从资源名截取第一段）。
String animeTitleForQuery(String resourceName, [String? knownTitle]) {
  final t = (knownTitle ?? '').trim();
  if (t.isNotEmpty) return t;
  final seg = resourceName.split(RegExp(r'[-—–~]')).first.trim();
  return seg.isNotEmpty ? seg : resourceName.trim();
}
