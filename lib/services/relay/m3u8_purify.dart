// lib/services/relay/m3u8_purify.dart
// m3u8 去广告 —— 逐函数移植 TVBox `util/M3u8.java` 的 `purify()` 链（958 行，作者 asdfgh/FongMi）。
// 对应 TypeScript 权威实现：src/engine/util/m3u8Purify.ts（注释标「对位 M3u8.java:行号」）。
//
// 为什么需要它：这类站点的正片与广告切在同一个播放列表里，靠 `#EXT-X-DISCONTINUITY` 分段；
//   播放器直连会把广告一起播完（进度条莫名变长 / 中间插一段不相干画面）。TVBox 的做法是播放前
//   把播放列表文本洗一遍；接线点是 `/play` 中继取到清单之后、回给播放器之前。
//
// 五级流程（与 M3u8.java 逐级对齐）：
//   ① `removeMinorityUrl`（:107）按「切片路径前缀」或「域名」统计主导者，删少数派；
//   ② `clean`（:513）用订阅 `rules[].regex` 里带 DISCONTINUITY/EXTINF 的规则整段删（`scan`/`scanAd`）；
//   ③ `cleanCommonAdMarkers`（:522）删 SCTE-35 / CUE-OUT~CUE-IN / DATERANGE 广告块与 URL/域名特征段；
//   ④ `cleanDecimalPrecisionGroups`（:249）与 ⑤ `cleanFrameRateGroups`（:329）按 EXTINF 小数精度/
//      帧率特征删短不连续块；最后 `cleanDiscontinuityGroups`（:658）删非主导短组。
//
// 回退保护（三道，任一触发就放弃本次清洗、回原文并把计数归零）：
//   · 单级删除超过总段数 30% → 该级作废（①:224、④:290）；
//   · 累计删除超过总段数 50% → 整体回退（purify:78）；
//   · 洗完不满足 `isPlayableMediaPlaylist`（须有段、不得连续两个 EXTINF、不得 EXTINF 紧跟 ENDLIST）
//     → 整体回退（:83）。
//
// 调用口径照抄 TVBox VodController.java:1962-1974：**只有 removed > 0 才用清洗结果**，
// 否则播原文（未删到段时清洗结果与原文等价，不必替换）。
import 'dart:math' as math;

// ── 标签常量（与 M3u8.java:24-31 同名同值）──
const String _tagDiscontinuity = '#EXT-X-DISCONTINUITY';
const String _tagMediaDuration = '#EXTINF';
const String _tagEndList = '#EXT-X-ENDLIST';
const String _tagKey = '#EXT-X-KEY';
const String _tagMap = '#EXT-X-MAP';
const String _tagCueOut = '#EXT-X-CUE-OUT';
const String _tagCueIn = '#EXT-X-CUE-IN';
const String _tagDateRange = '#EXT-X-DATERANGE';

// ── 正则（M3u8.java:33-38；`g` 版每次现取新实例，对位 Java 每次新建 Matcher 的语义）──
RegExp _reXDiscontinuity() =>
    RegExp(r'#EXT-X-DISCONTINUITY[\s\S]*?(?=#EXT-X-DISCONTINUITY|$)');

RegExp _reMediaDuration() => RegExp(r'#EXTINF:([\d\.]+)\b');

final RegExp _reUriAttr = RegExp(r'URI="(.+?)"');

/// 广告切片 URL 特征（M3u8.java:38 增强项；非全局匹配，`.hasMatch()` 无 lastIndex 副作用）
final RegExp _reAdSegmentUri = RegExp(
  r'(^|[/?&=_.-])(ads?|adv|advert(ise(ment)?)?|commercial|preroll|pre-roll|midroll|mid-roll|postroll|post-roll|sponsor|scte|vast|vmap|interstitial|bumper)([/?&=_.-]|$)',
  caseSensitive: false,
);

/// 常见广告 CDN 域名特征（M3u8.java:41-44 原表，10 项）
const List<String> _adDomainKeywords = <String>[
  'adservice',
  'adserver',
  'adsystem',
  'doubleclick',
  'googlesyndication',
  'advertising',
  '2mdn.net',
  'moatads',
  'scorecardresearch',
  'quantserve',
];

const int _maxFrameRateAdBlockSize = 12; // M3u8.java:46
const int _timesNoAd = 15; // M3u8.java:106

/// 清洗结果。
class PurifyResult {
  const PurifyResult({
    required this.text,
    required this.removed,
    required this.total,
  });

  /// 清洗后的清单文本（`removed == 0` 时调用方仍应用原文）
  final String text;

  /// 本轮删掉的段数（对位 M3u8.currentAdCount）
  final int removed;

  /// 原文总段数（日志/诊断用）
  final int total;
}

class _PurifyState {
  int adCount = 0;
}

// ───────────────────────── 十进制（对位 BigDecimal） ─────────────────────────
// 时长比较/求和必须精确：Java 用 BigDecimal，这里用「大整数 + 小数位数」等价表达，
// 避免 0.1+0.2 这类浮点误差改变启发式判定。

class _Dec {
  const _Dec(this.v, this.s);

  /// 值 = v / 10^s（可负）
  final BigInt v;

  /// 小数位数
  final int s;
}

BigInt _pow10(int n) => BigInt.from(10).pow(n);

_Dec? _parseDec(String s) {
  final t = s.trim();
  final m = RegExp(r'^([+-]?)(\d*)(?:\.(\d*))?$').firstMatch(t);
  if (m == null) return null;
  final intPart = m.group(2) ?? '';
  final frac = m.group(3) ?? '';
  if (intPart.isEmpty && frac.isEmpty) return null;
  final digits = '${intPart.isEmpty ? '0' : intPart}$frac';
  var v = BigInt.parse(digits);
  if (m.group(1) == '-') v = -v;
  return _Dec(v, frac.length);
}

_Dec _decAdd(_Dec a, _Dec b) {
  final s = math.max(a.s, b.s);
  return _Dec(a.v * _pow10(s - a.s) + b.v * _pow10(s - b.s), s);
}

/// BigDecimal.toString 的常见形态：去尾零（0.200 → 0.2）
String _decToString(_Dec d) {
  final neg = d.v < BigInt.zero;
  final abs = (neg ? -d.v : d.v).toString().padLeft(d.s + 1, '0');
  final intPart = abs.substring(0, abs.length - d.s);
  final fracRaw = d.s > 0 ? abs.substring(abs.length - d.s) : '';
  final frac = fracRaw.replaceAll(RegExp(r'0+$'), '');
  return '${neg ? '-' : ''}${intPart.isEmpty ? '0' : intPart}'
      '${frac.isEmpty ? '' : '.$frac'}';
}

/// 小数部分绝对值（对位 `duration.remainder(ONE).abs().stripTrailingZeros()`；整数返回 "0"）
String _decFraction(_Dec d) {
  if (d.s == 0) return '0';
  final mod = _pow10(d.s);
  final f = ((d.v % mod) + mod) % mod;
  if (f == BigInt.zero) return '0';
  final frac = f.toString().padLeft(d.s, '0').replaceAll(RegExp(r'0+$'), '');
  return frac.isEmpty ? '0' : '0.$frac';
}

// ───────────────────────── 帧率特征表（M3u8.java:415-439） ─────────────────────────

final Map<int, Set<String>> _frameRateFeatures = _prepareFrameRateFeatures();

/// 把 `x` 四舍五入到 `scale` 位小数并去尾零（对位 `setScale(scale, HALF_UP).stripTrailingZeros()`）
String _fixedStrip(double x, int scale) {
  var t = x.toStringAsFixed(scale);
  if (t.contains('.')) {
    t = t.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  }
  return t.isEmpty ? '0' : t;
}

void _addFrameRateFeatures(
  Set<String> features,
  double frameRate,
  int maxFrames,
) {
  for (var frame = 1; frame <= maxFrames; frame++) {
    // Java：divide(rate, 10, HALF_UP) → remainder(ONE)
    final q = (((frame / frameRate) * 1e10).round() / 1e10);
    final frac = q - q.floorToDouble();
    for (var scale = 3; scale <= 6; scale++) {
      final v = _fixedStrip(frac, scale);
      if (v != '0') features.add(v);
    }
  }
}

Set<String> _createFrameRateFeatures(double frameRate, bool includeNtsc) {
  final set = <String>{};
  _addFrameRateFeatures(set, frameRate, frameRate.round());
  if (includeNtsc) {
    _addFrameRateFeatures(set, frameRate / 1.001, (frameRate * 10).round());
  }
  return set;
}

Map<int, Set<String>> _prepareFrameRateFeatures() {
  return <int, Set<String>>{
    30: _createFrameRateFeatures(30, true),
    25: _createFrameRateFeatures(25, false),
    24: _createFrameRateFeatures(24, true),
  };
}

// ───────────────────────── 小工具 ─────────────────────────

/// Java `String.replace(CharSequence, CharSequence)` 是**全量**替换（Dart `replaceAll` 同义）
String _replaceAllLiteral(String s, String find, String repl) =>
    find.isEmpty ? s : s.replaceAll(find, repl);

/// 对位 JS `Number(x)`（返回 null 表示 NaN / Infinity）；空串按 0 处理
double? _jsNumber(String s) {
  final t = s.trim();
  if (t.isEmpty) return 0;
  final v = double.tryParse(t);
  if (v == null || !v.isFinite) return null;
  return v;
}

int _countSegments(String content) {
  var n = 0;
  for (final line in content.split(content.contains('\r\n') ? '\r\n' : '\n')) {
    if (line.isNotEmpty && !line.startsWith('#')) n++;
  }
  return n;
}

bool _isMediaUriLine(String line) => line.isNotEmpty && !line.startsWith('#');

bool _isDiscontinuityTag(String line) =>
    line.startsWith(_tagDiscontinuity) &&
    !line.startsWith('#EXT-X-DISCONTINUITY-SEQUENCE');

bool _hasEndList(String content) {
  if (content.isEmpty) return false;
  for (final raw in content.replaceAll('\r\n', '\n').split('\n')) {
    if (raw.trim().startsWith(_tagEndList)) return true;
  }
  return false;
}

/// 相对地址 → 绝对（对位 `UriUtil.resolve`；Dart `Uri.resolve` 语义等价）
String _resolveRef(String base, String ref) {
  final r = ref.trim();
  if (r.isEmpty || RegExp(r'^https?://', caseSensitive: false).hasMatch(r)) {
    return r;
  }
  try {
    return Uri.parse(base).resolve(r).toString();
  } catch (_) {
    return r;
  }
}

String _toAbsoluteUrl(String base, String url) {
  final line = url.trim();
  if (line.isEmpty ||
      RegExp(r'^https?://', caseSensitive: false).hasMatch(line)) {
    return line;
  }
  return _resolveRef(base, line);
}

bool _hasUriAttribute(String line) =>
    line.startsWith(_tagKey) || line.startsWith(_tagMap);

String _resolveUriLine(String base, String line) {
  final m = _reUriAttr.firstMatch(line);
  final value = m?.group(1);
  if (value == null) return line;
  return _replaceAllLiteral(line, value, _resolveRef(base, value));
}

bool _shouldResolve(String line) {
  final item = line.trim();
  if (item.isEmpty) return false;
  return (!item.startsWith('#') && !item.startsWith('http')) ||
      _hasUriAttribute(item);
}

String _shouldResolveLine(String base, String line) => _hasUriAttribute(line)
    ? _resolveUriLine(base, line)
    : _resolveRef(base, line);

/// 逐行把相对地址补成绝对（M3u8.java:492-499，CRLF 归一为 LF、每行结尾补 \n）
String _resolveContent(String tsUrlPre, String content) {
  final out = StringBuffer();
  for (final line in content.replaceAll('\r\n', '\n').split('\n')) {
    out.write(
      '${_shouldResolve(line) ? _shouldResolveLine(tsUrlPre, line.trim()) : line}\n',
    );
  }
  return out.toString();
}

// ───────────────────────── 广告判据（M3u8.java:600-656） ─────────────────────────

bool _isAdBreakStart(String line) => line.startsWith(_tagCueOut);

bool _isAdSignalTag(String line) {
  if (line.startsWith('#EXT-OATCLS-SCTE35')) return true;
  if (line.startsWith('#EXT-X-SCTE35')) return true;
  if (line.startsWith('#EXT-X-SPLICEPOINT-SCTE35')) return true;
  if (line.startsWith('#EXT-X-CUE')) return true;
  if (line.startsWith('#EXT-X-ASSET')) return true;
  if (line.startsWith('#EXT-X-VMAP-AD-BREAK')) return true;
  if (line.startsWith('#EXT-X-AD')) return true;
  if (line.startsWith('#EXT-X-DISCONTINUITY-SEQUENCE')) return false;
  return false;
}

bool _isSegmentTag(String line) {
  if (line.startsWith('#EXT-X-DISCONTINUITY-SEQUENCE')) return false;
  return line.startsWith(_tagMediaDuration) ||
      line.startsWith('#EXT-X-BYTERANGE') ||
      line.startsWith('#EXT-X-PROGRAM-DATE-TIME') ||
      line.startsWith(_tagDiscontinuity) ||
      line.startsWith('#EXT-X-PART') ||
      line.startsWith('#EXT-X-PRELOAD-HINT');
}

bool _isAdLikeText(String line) {
  final lower = line.toLowerCase();
  return lower.contains('scte') ||
      lower.contains('cue') ||
      lower.contains('interstitial') ||
      lower.contains('vmap') ||
      lower.contains('vast') ||
      lower.contains('advert') ||
      lower.contains('commercial') ||
      lower.contains('ad-') ||
      lower.contains('ad_') ||
      lower.contains('ad.') ||
      lower.contains('preroll') ||
      lower.contains('midroll') ||
      lower.contains('postroll') ||
      lower.contains('bumper');
}

bool _isStandaloneAdTag(String line) {
  if (!line.startsWith(_tagDateRange)) return false;
  return _isAdLikeText(line) ||
      line.contains('X-ASSET-URI') ||
      line.contains('X-ASSET-LIST');
}

bool _isAdSegmentUri(String line) => _reAdSegmentUri.hasMatch(line);

bool _hasAdDomain(String url) {
  final lower = url.toLowerCase();
  return _adDomainKeywords.any(lower.contains);
}

/// 数字型规则（对位 `M3u8.isDouble`：能解析成非零 double）
bool _isDouble(String ad) {
  final v = _jsNumber(ad);
  return v != null && v != 0;
}

/// 订阅 `rules[].regex` 是否属于「广告段规则」（M3u8.java:51-53；ApiConfig 收集规则时用）
bool isAd(String regex) {
  return regex.contains(_tagDiscontinuity) ||
      regex.contains(_tagMediaDuration) ||
      regex.contains(_tagEndList) ||
      regex.contains(_tagKey) ||
      regex.contains(_tagCueOut) ||
      regex.contains(_tagCueIn) ||
      regex.contains(_tagDateRange) ||
      _isDouble(regex);
}

// ───────────────────────── EXTINF 取值（M3u8.java:441-470） ─────────────────────────

int _getExtInfValueStart(String? line) {
  if (line == null) return -1;
  final length = line.length;
  var start = 0;
  while (start < length && line.codeUnitAt(start) <= 32) {
    start += 1;
  }
  if (!line.startsWith(_tagMediaDuration, start)) return -1;
  start += _tagMediaDuration.length;
  if (start >= length || line[start] != ':') return -1;
  start += 1;
  while (start < length && line.codeUnitAt(start) <= 32) {
    start += 1;
  }
  return start < length ? start : -1;
}

int _getExtInfValueEnd(String line, int start) {
  var end = line.indexOf(',', start);
  if (end < 0) end = line.length;
  while (end > start && line.codeUnitAt(end - 1) <= 32) {
    end -= 1;
  }
  return end;
}

_Dec? _parseExtInfDuration(String line) {
  final start = _getExtInfValueStart(line);
  if (start < 0) return null;
  final end = _getExtInfValueEnd(line, start);
  return _parseDec(line.substring(start, end));
}

/// 小数位数（M3u8.java:317-323）：无小数点 → 0；非 EXTINF → -1
int _getDecimalPrecision(String line) {
  final start = _getExtInfValueStart(line);
  if (start < 0) return -1;
  final end = _getExtInfValueEnd(line, start);
  final dot = line.indexOf('.', start);
  return (dot < 0 || dot >= end) ? 0 : end - dot - 1;
}

/// 广告段数上限（按时长分档，M3u8.java:472-480）
int _getAdSegmentLimit(String content) {
  var total = 0.0;
  for (final raw in content.split('\n')) {
    final d = _parseExtInfDuration(raw);
    if (d != null) total += double.parse(_decToString(d));
  }
  final totalMinutes = total / 60;
  if (totalMinutes <= 30) return 18;
  if (totalMinutes <= 60) return 24;
  if (totalMinutes <= 90) return 30;
  return 36;
}

// ───────────────────────── 帧率判定（M3u8.java:366-413） ─────────────────────────

bool _isFrameAligned(_Dec? duration, int frameRate) {
  if (duration == null) return false;
  final features = _frameRateFeatures[frameRate];
  if (features == null) return false;
  return features.contains(_decFraction(duration));
}

/// 30/25/24 三者中「只有一个对齐」才返回该帧率（M3u8.java:397-405）
int _getExclusiveFrameRate(_Dec? duration) {
  final is30 = _isFrameAligned(duration, 30);
  final is25 = _isFrameAligned(duration, 25);
  final is24 = _isFrameAligned(duration, 24);
  if (is30 && !is25 && !is24) return 30;
  if (is25 && !is30 && !is24) return 25;
  if (is24 && !is30 && !is25) return 24;
  return 0;
}

// ───────────────────────── 分组（M3u8.java:833-873） ─────────────────────────

class _Group {
  final List<String> lines = <String>[];
  int segmentCount = 0;
  int adLikeCount = 0;
  double totalDuration = 0;
  String host = '';
  String pathPrefix = '';

  void add(String raw) {
    lines.add(raw);
    final line = raw.trim();
    final durationStart = _getExtInfValueStart(line);
    if (durationStart >= 0) {
      final durationEnd = _getExtInfValueEnd(line, durationStart);
      final v = _jsNumber(line.substring(durationStart, durationEnd));
      if (v != null) totalDuration += v;
    }
    if (line.isEmpty || line.startsWith('#')) {
      if (_isAdSignalTag(line) || _isStandaloneAdTag(line)) adLikeCount += 1;
      return;
    }
    segmentCount += 1;
    if (_isAdSegmentUri(line) || _hasAdDomain(line)) adLikeCount += 1;
    if (host.isEmpty) host = _hostOf(line);
    if (pathPrefix.isEmpty) pathPrefix = _pathPrefixOf(line);
  }

  bool hasMedia() => segmentCount > 0;

  void appendTo(List<String> sb) {
    for (final line in lines) {
      sb.add('$line\n');
    }
  }

  double score() => totalDuration > 0 ? totalDuration : segmentCount.toDouble();
}

List<_Group> _buildDiscontinuityGroups(List<String> lines) {
  final groups = <_Group>[];
  var group = _Group();
  for (final raw in lines) {
    final line = raw.trim();
    if (line.startsWith(_tagDiscontinuity) && group.hasMedia()) {
      groups.add(group);
      group = _Group();
    }
    group.add(raw);
  }
  if (group.hasMedia() || group.lines.isNotEmpty) groups.add(group);
  return groups;
}

_Group? _findMainGroup(List<_Group> groups) {
  _Group? main;
  for (final group in groups) {
    if (group.segmentCount == 0) continue;
    if (main == null || group.score() > main.score()) main = group;
  }
  return main;
}

String _hostOf(String url) {
  if (!url.startsWith('http://') && !url.startsWith('https://')) return '';
  final start = url.indexOf('://') + 3;
  final end = url.indexOf('/', start);
  return end > start ? url.substring(start, end) : url.substring(start);
}

String _pathPrefixOf(String url) {
  var clean = url;
  final query = clean.indexOf('?');
  if (query >= 0) clean = clean.substring(0, query);
  final slash = clean.lastIndexOf('/');
  return slash > 0 ? clean.substring(0, slash + 1) : '';
}

/// 非主导短组判定（M3u8.java:702-723）
bool _shouldDropGroup(_Group group, _Group main) {
  if (identical(group, main) || group.segmentCount == 0) return false;
  final shortGroup =
      group.segmentCount <= 2 ||
      (main.totalDuration > 0 &&
          group.totalDuration > 0 &&
          group.totalDuration < main.totalDuration * 0.18);
  final differentHost =
      main.host.isNotEmpty && group.host.isNotEmpty && main.host != group.host;
  final differentPath =
      main.pathPrefix.isNotEmpty &&
      group.pathPrefix.isNotEmpty &&
      main.pathPrefix != group.pathPrefix;
  final hasAdFeature =
      group.adLikeCount > 0 ||
      _hasAdDomain(group.host) ||
      _isAdSegmentUri(group.pathPrefix);
  final adLike =
      hasAdFeature ||
      differentHost ||
      (group.segmentCount <= 2 && differentPath);
  return shortGroup && adLike;
}

String _cleanDiscontinuityGroups(String content, _PurifyState st) {
  final groups = _buildDiscontinuityGroups(content.split('\n'));
  if (groups.length < 3) return content;
  final main = _findMainGroup(groups);
  if (main == null || main.segmentCount < 3) return content;
  final sb = <String>[];
  var changed = false;
  for (final group in groups) {
    if (_shouldDropGroup(group, main)) {
      st.adCount += group.segmentCount;
      changed = true;
      continue;
    }
    group.appendTo(sb);
  }
  return changed ? sb.join('') : content;
}

// ───────────────────────── 可播性 / 归一化（M3u8.java:765-831） ─────────────────────────

String _normalizeMediaPlaylist(String content) {
  final sb = <String>[];
  var seenMedia = false;
  var hasPendingDiscontinuity = false;
  var pendingDiscontinuity = '';
  for (final raw in content.replaceAll('\r\n', '\n').split('\n')) {
    final item = raw.trim();
    if (_isDiscontinuityTag(item)) {
      if (seenMedia && !hasPendingDiscontinuity) {
        pendingDiscontinuity = raw;
        hasPendingDiscontinuity = true;
      }
      continue;
    }
    if (hasPendingDiscontinuity) {
      if (item.isEmpty) continue;
      if (!item.startsWith(_tagEndList)) {
        sb.add('$pendingDiscontinuity\n');
      }
      hasPendingDiscontinuity = false;
    }
    if (item.isEmpty && sb.isEmpty) continue;
    sb.add('$raw\n');
    if (_isMediaUriLine(item)) seenMedia = true;
  }
  return sb.join('');
}

bool _isPlayableMediaPlaylist(String? content) {
  if (content == null || !content.startsWith('#EXTM3U')) return false;
  var mediaCount = 0;
  var pendingExtInf = false;
  for (final raw in content.replaceAll('\r\n', '\n').split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith(_tagMediaDuration)) {
      if (pendingExtInf) return false;
      pendingExtInf = true;
    } else if (_isMediaUriLine(line)) {
      mediaCount += 1;
      pendingExtInf = false;
    } else if (line.startsWith(_tagEndList) && pendingExtInf) {
      return false;
    }
  }
  return mediaCount > 0 && !pendingExtInf;
}

String _keepVodEndList(String original, String result) {
  if (!_hasEndList(original) || _hasEndList(result)) return result;
  return '$result${result.endsWith('\n') ? '' : '\n'}$_tagEndList\n';
}

// ───────────────────────── ④⑤ 短块清洗（M3u8.java:249-364） ─────────────────────────

({int total, int mismatched}) _getDecimalPrecisionStats(
  _Group group,
  int majorPrecision,
) {
  var total = 0;
  var mismatched = 0;
  for (final raw in group.lines) {
    final precision = _getDecimalPrecision(raw);
    if (precision < 0) continue;
    total += 1;
    if (precision != majorPrecision) mismatched += 1;
  }
  return (total: total, mismatched: mismatched);
}

String _cleanDecimalPrecisionGroups(String content, _PurifyState st) {
  final groups = _buildDiscontinuityGroups(content.split('\n'));
  if (groups.length < 2) return content;

  final precisionCounts = <int, int>{};
  var totalSegments = 0;
  for (final group in groups) {
    for (final raw in group.lines) {
      final precision = _getDecimalPrecision(raw);
      if (precision < 0) continue;
      totalSegments += 1;
      precisionCounts[precision] = (precisionCounts[precision] ?? 0) + 1;
    }
  }
  if (totalSegments < 8 || precisionCounts.length < 2) return content;

  var majorPrecision = -1;
  var majorCount = 0;
  for (final entry in precisionCounts.entries) {
    if (entry.value > majorCount) {
      majorPrecision = entry.key;
      majorCount = entry.value;
    }
  }
  if (majorPrecision < 0 || majorCount / totalSegments < 0.7) return content;

  final removeGroups = List<bool>.filled(groups.length, false);
  var removableSegments = 0;
  for (var i = 0; i < groups.length; i++) {
    final group = groups[i];
    if (i == groups.length - 1 ||
        group.segmentCount == 0 ||
        group.segmentCount > _maxFrameRateAdBlockSize) {
      continue;
    }
    final stats = _getDecimalPrecisionStats(group, majorPrecision);
    if (stats.total > 0 && stats.mismatched == stats.total) {
      removeGroups[i] = true;
      removableSegments += group.segmentCount;
    }
  }

  if (removableSegments == 0 ||
      removableSegments > _getAdSegmentLimit(content) ||
      removableSegments > totalSegments * 0.3) {
    return content;
  }

  final sb = <String>[];
  for (var i = 0; i < groups.length; i++) {
    if (removeGroups[i]) {
      st.adCount += groups[i].segmentCount;
    } else {
      groups[i].appendTo(sb);
    }
  }
  return _normalizeMediaPlaylist(sb.join(''));
}

({int matched, int mismatched}) _getFrameRateStats(
  _Group group,
  int masterFrameRate,
) {
  var matched = 0;
  var mismatched = 0;
  for (final raw in group.lines) {
    if (_getExtInfValueStart(raw) < 0) continue;
    final frameRate = _getExclusiveFrameRate(_parseExtInfDuration(raw));
    if (frameRate == masterFrameRate) {
      matched += 1;
    } else if (frameRate != 0) {
      mismatched += 1;
    }
  }
  return (matched: matched, mismatched: mismatched);
}

int _findDominantFrameRate(List<_Group> groups) {
  var count30 = 0;
  var count25 = 0;
  var count24 = 0;
  for (final group in groups) {
    for (final raw in group.lines) {
      if (_getExtInfValueStart(raw) < 0) continue;
      final frameRate = _getExclusiveFrameRate(_parseExtInfDuration(raw));
      if (frameRate == 30) {
        count30 += 1;
      } else if (frameRate == 25) {
        count25 += 1;
      } else if (frameRate == 24) {
        count24 += 1;
      }
    }
  }
  final max = math.max(count30, math.max(count25, count24));
  if (max < 2) return 0;
  if ((count30 == max ? 1 : 0) +
          (count25 == max ? 1 : 0) +
          (count24 == max ? 1 : 0) !=
      1) {
    return 0;
  }
  return count30 == max ? 30 : (count25 == max ? 25 : 24);
}

String _cleanFrameRateGroups(String content, _PurifyState st) {
  final groups = _buildDiscontinuityGroups(content.split('\n'));
  if (groups.length < 2) return content;

  final masterFrameRate = _findDominantFrameRate(groups);
  if (masterFrameRate == 0) return content;

  var removableSegments = 0;
  final removeGroups = List<bool>.filled(groups.length, false);
  for (var i = 0; i < groups.length; i++) {
    final group = groups[i];
    if (i == groups.length - 1 ||
        group.segmentCount == 0 ||
        group.segmentCount > _maxFrameRateAdBlockSize) {
      continue;
    }
    final stats = _getFrameRateStats(group, masterFrameRate);
    if (stats.mismatched > 0 && stats.mismatched >= stats.matched) {
      removeGroups[i] = true;
      removableSegments += group.segmentCount;
    }
  }

  final segmentLimit = _getAdSegmentLimit(content);
  if (removableSegments == 0 || removableSegments > segmentLimit) {
    return content;
  }

  final sb = <String>[];
  for (var i = 0; i < groups.length; i++) {
    if (removeGroups[i]) {
      st.adCount += groups[i].segmentCount;
    } else {
      groups[i].appendTo(sb);
    }
  }
  return _normalizeMediaPlaylist(sb.join(''));
}

// ───────────────────────── ②③ 规则删 / 通用广告标记（M3u8.java:513-584, 875-935） ─────────────────────────

String _scanAd(String line, String tagAd, _PurifyState st) {
  RegExp re;
  try {
    re = RegExp(tagAd);
  } catch (_) {
    return line; // 订阅里的正则语法不兼容 → 跳过该条（不中断整链）
  }
  final needRemoveAd = <String>[];
  for (final m in re.allMatches(line)) {
    final group = m.group(0);
    if (group == null) continue;
    final groupCleaned = _replaceAllLiteral(group, _tagEndList, '');
    var tCount = 0;
    for (final _ in _reMediaDuration().allMatches(group)) {
      tCount += 1;
    }
    needRemoveAd.add(groupCleaned);
    st.adCount += tCount;
  }
  var out = line;
  for (final rem in needRemoveAd) {
    out = _replaceAllLiteral(out, rem, '');
  }
  return out;
}

String _scan(String line, List<String> ads, _PurifyState st) {
  final needRemoveAd = <String>[];
  for (final m in _reXDiscontinuity().allMatches(line)) {
    final group = m.group(0);
    if (group == null) continue;
    final groupCleaned = _replaceAllLiteral(group, _tagEndList, '');
    _Dec? ft;
    _Dec? lt;
    _Dec? t;
    var tCount = 0;
    for (final dm in _reMediaDuration().allMatches(group)) {
      final d = _parseDec(dm.group(1) ?? '');
      if (d == null) continue;
      ft ??= d;
      lt = d;
      t = t == null ? d : _decAdd(t, d);
      tCount += 1;
    }
    final ftStr = ft != null ? _decToString(ft) : '0';
    final ltStr = lt != null ? _decToString(lt) : '0';
    final tStr = t != null ? _decToString(t) : '0';
    for (final ad in ads) {
      if (ad.startsWith('-')) {
        final adClean = ad.substring(1);
        if (ltStr.startsWith(adClean)) {
          needRemoveAd.add(groupCleaned);
          st.adCount += tCount;
          break;
        }
      } else if (ftStr.startsWith(ad) || tStr.startsWith(ad)) {
        needRemoveAd.add(groupCleaned);
        st.adCount += tCount;
        break;
      }
    }
  }
  var out = line;
  for (final rem in needRemoveAd) {
    out = _replaceAllLiteral(out, rem, '');
  }
  return out;
}

String _clean(String line, List<String> ads, _PurifyState st) {
  var out = line;
  var doScan = false;
  for (final ad in ads) {
    if (ad.contains(_tagDiscontinuity) || ad.contains(_tagMediaDuration)) {
      out = _scanAd(out, ad, st);
    } else if (_isDouble(ad)) {
      doScan = true;
    }
  }
  return doScan ? _scan(out, ads, st) : out;
}

void _flush(List<String> sb, List<String> pending) {
  for (final line in pending) {
    sb.add('$line\n');
  }
  pending.clear();
}

void _appendLine(List<String> sb, String line, String linesplit) {
  sb.add('$line$linesplit');
}

void _flushWith(List<String> sb, List<String> pending, String linesplit) {
  for (final line in pending) {
    _appendLine(sb, line, linesplit);
  }
  pending.clear();
}

bool _hasAdSignal(List<String> pending) {
  for (final line in pending) {
    final t = line.trim();
    if (_isAdBreakStart(t) || _isAdSignalTag(t)) return true;
  }
  return false;
}

/// ③ 通用广告标记清洗（M3u8.java:522-584）
String _cleanCommonAdMarkers(String content, _PurifyState st) {
  final sb = <String>[];
  var pending = <String>[];
  var inAdBreak = false;
  var changed = false;

  for (final raw in content.split('\n')) {
    final item = raw.trim();
    if (item.isEmpty) {
      if (pending.isEmpty) {
        sb.add('$raw\n');
      } else {
        pending.add(raw);
      }
      continue;
    }
    if (item.startsWith('#')) {
      if (item.startsWith(_tagCueIn)) {
        if (inAdBreak || _hasAdSignal(pending)) {
          inAdBreak = false;
          pending = <String>[];
          changed = true;
          continue;
        }
      }
      if (_isAdBreakStart(item)) {
        _flush(sb, pending);
        inAdBreak = true;
        pending.add(raw);
        changed = true;
        continue;
      }
      if (inAdBreak) {
        pending.add(raw);
        changed = true;
        continue;
      }
      if (_isStandaloneAdTag(item)) {
        _flush(sb, pending);
        st.adCount += 1;
        changed = true;
        continue;
      }
      if (_isSegmentTag(item) || _isAdSignalTag(item)) {
        pending.add(raw);
      } else {
        _flush(sb, pending);
        sb.add('$raw\n');
      }
      continue;
    }

    if (inAdBreak ||
        _hasAdSignal(pending) ||
        _isAdSegmentUri(item) ||
        _hasAdDomain(item)) {
      pending = <String>[];
      st.adCount += 1;
      changed = true;
      continue;
    }
    _flush(sb, pending);
    sb.add('$raw\n');
  }

  if (!inAdBreak) _flush(sb, pending);
  return changed ? sb.join('') : content;
}

// ───────────────────────── ① 少数派 URL 清洗（M3u8.java:95-231） ─────────────────────────

double _maxPercent(Map<String, int> preUrlMap) {
  var maxTimes = 0;
  var totalTimes = 0;
  for (final v in preUrlMap.values) {
    if (v > maxTimes) maxTimes = v;
    totalTimes += v;
  }
  return totalTimes == 0 ? 0 : maxTimes / totalTimes;
}

bool _shouldKeepMediaUrl(
  String absoluteUrl,
  bool domainFiltering,
  String maxTimesPreUrl,
  Map<String, int> preUrlMap,
) {
  if (!domainFiltering) return absoluteUrl.startsWith(maxTimesPreUrl);
  final ifirst = absoluteUrl.indexOf('/', 9);
  final domain = ifirst > 0 ? absoluteUrl.substring(0, ifirst) : absoluteUrl;
  final cnt = preUrlMap[domain];
  return domain == maxTimesPreUrl || (cnt != null && cnt > _timesNoAd);
}

String? _removeMinorityUrl(String tsUrlPre, String content, _PurifyState st) {
  final linesplit = content.contains('\r\n') ? '\r\n' : '\n';
  final lines = content.split(linesplit);

  var totalSegments = 0;
  for (final line in lines) {
    if (line.isNotEmpty && !line.startsWith('#')) totalSegments++;
  }

  final preUrlMap = <String, int>{};
  void bump(String key) {
    preUrlMap[key] = (preUrlMap[key] ?? 0) + 1;
  }

  for (final line in lines) {
    if (line.isEmpty || line.startsWith('#')) continue;
    final absoluteUrl = _toAbsoluteUrl(tsUrlPre, line);
    final ilast = absoluteUrl.lastIndexOf('.');
    if (ilast <= 4) continue;
    bump(absoluteUrl.substring(0, ilast - 4));
  }
  if (preUrlMap.length <= 1) return null;

  var domainFiltering = false;
  if (_maxPercent(preUrlMap) < 0.8) {
    preUrlMap.clear();
    for (final line in lines) {
      if (line.isEmpty || line.startsWith('#')) continue;
      final absoluteUrl = _toAbsoluteUrl(tsUrlPre, line);
      if (!absoluteUrl.startsWith('http://') &&
          !absoluteUrl.startsWith('https://')) {
        return null;
      }
      final ifirst = absoluteUrl.indexOf('/', 9);
      if (ifirst <= 0) continue;
      bump(absoluteUrl.substring(0, ifirst));
    }
    if (preUrlMap.length <= 1) return null;
    if (_maxPercent(preUrlMap) < 0.8) return null;
    var allDomainsExceedThreshold = true;
    for (final count in preUrlMap.values) {
      if (count <= _timesNoAd) {
        allDomainsExceedThreshold = false;
        break;
      }
    }
    if (allDomainsExceedThreshold) return null;
    domainFiltering = true;
  }

  var maxTimes = 0;
  var maxTimesPreUrl = '';
  preUrlMap.forEach((key, count) {
    if (count > maxTimes) {
      maxTimesPreUrl = key;
      maxTimes = count;
    }
  });
  if (maxTimes == 0) return null;

  final filtered = <String>[];
  var pendingSegmentTags = <String>[];
  for (var i = 0; i < lines.length; i++) {
    final item = lines[i].trim();
    if (item.isEmpty) {
      if (pendingSegmentTags.isEmpty) {
        _appendLine(filtered, lines[i], linesplit);
      } else {
        pendingSegmentTags.add(lines[i]);
      }
      continue;
    }
    if (item.startsWith('#')) {
      final output = _hasUriAttribute(item)
          ? _resolveUriLine(tsUrlPre, lines[i])
          : lines[i];
      if (_isSegmentTag(item)) {
        pendingSegmentTags.add(output);
      } else {
        _flushWith(filtered, pendingSegmentTags, linesplit);
        _appendLine(filtered, output, linesplit);
      }
      continue;
    }

    final absoluteUrl = _toAbsoluteUrl(tsUrlPre, lines[i]);
    if (_shouldKeepMediaUrl(
      absoluteUrl,
      domainFiltering,
      maxTimesPreUrl,
      preUrlMap,
    )) {
      _flushWith(filtered, pendingSegmentTags, linesplit);
      _appendLine(filtered, absoluteUrl, linesplit);
    } else {
      pendingSegmentTags = <String>[];
      st.adCount += 1;
    }
  }

  if (totalSegments > 0 && st.adCount > totalSegments * 0.3) {
    st.adCount = 0; // 该级作废（不再影响后续级）
    return null;
  }
  return _normalizeMediaPlaylist(filtered.join(''));
}

// ───────────────────────── 主链（M3u8.java:233-243, 55-93） ─────────────────────────

/// ②③④⑤ + 末级分组清洗（M3u8.java:233-243）
String _runLevels(
  String tsUrlPre,
  String content,
  List<String> rules,
  _PurifyState st,
) {
  var line = _resolveContent(tsUrlPre, content);
  if (rules.isNotEmpty) line = _clean(line, rules, st);
  line = _cleanCommonAdMarkers(line, st);
  if (_hasEndList(line) && line.contains(_tagDiscontinuity)) {
    line = _cleanDecimalPrecisionGroups(line, st);
    line = _cleanFrameRateGroups(line, st);
  }
  return _cleanDiscontinuityGroups(line, st);
}

/// 订阅 rules 里「该播放地址所属 host」的 regex 规则表
/// （对位 VideoParseRuler.getHostsRegex + M3u8.getRegex:501-511）。
///
/// 语义与上游一致：**第一个** host 命中（且该条带 regex 列表）即返回，不再往下找。
List<String> hostRegexFor(String tsUrlPre, List<dynamic>? rules) {
  if (rules == null) return const <String>[];
  for (final r in rules) {
    if (r is! Map) continue;
    final hostRaw = r['host'];
    final host = hostRaw is String ? hostRaw.trim() : '';
    if (host.isEmpty || !tsUrlPre.contains(host)) continue;
    final regexRaw = r['regex'];
    if (regexRaw is! List) continue;
    // 只在「本播放地址」下命中：返回该 host 的规则表（空数组也返回，与上游 break 语义一致）
    return regexRaw.whereType<String>().where((s) => s.isNotEmpty).toList();
  }
  return const <String>[];
}

/// m3u8 去广告主入口（对位 `M3u8.purify(tsUrlPre, content)`）。
///
/// [content] 播放列表原文；[tsUrlPre] 播放列表自身的绝对地址；[rules] 该 host 的
/// 订阅 `rules[].regex` 列表（`hostRegexFor` 的产物）。
///
/// 返回 null = 不适用（空 / 去掉 BOM 后不以 `#EXTM3U` 开头）；否则给出清洗结果与删除段数。
/// `removed == 0` 时**调用方应继续用原文**（TVBox VodController 同口径）。
PurifyResult? purifyM3u8(
  String? content,
  String tsUrlPre, {
  List<String> rules = const <String>[],
}) {
  if (content == null || content.isEmpty) return null;
  var text = content;
  if (text.startsWith('\ufeff')) text = text.substring(1);
  if (!text.startsWith('#EXTM3U')) return null;

  final total = _countSegments(text);
  final st = _PurifyState();

  String result;
  final minority = _removeMinorityUrl(tsUrlPre, text, st);
  if (minority != null && st.adCount > 0) {
    result = _runLevels(tsUrlPre, minority, rules, st);
  } else {
    result = _runLevels(tsUrlPre, text, rules, st);
  }
  var out = _keepVodEndList(text, result);

  // 三道回退保护（M3u8.java:77-87）
  if (total > 0 && st.adCount > total * 0.5) {
    st.adCount = 0;
    out = text;
  }
  if (st.adCount > 0 && !_isPlayableMediaPlaylist(out)) {
    st.adCount = 0;
    out = text;
  }

  return PurifyResult(text: out, removed: st.adCount, total: total);
}

/// 接线用入口：**仅点播清单**（含 `#EXT-X-ENDLIST`）参与清洗。
///
/// 对位口径：TVBox 只在 VOD 播放路径调用 `purify`（VodController.playM3u8）；直播清单是滚动刷新的，
/// 启发式清洗反复作用于直播会带来无谓风险（且①/③级的价值主要在点播）→ 这里显式挡掉。
PurifyResult? purifyVodM3u8(
  String? content,
  String tsUrlPre, {
  List<String> rules = const <String>[],
}) {
  if (content == null || content.isEmpty) return null;
  final text = content.startsWith('\ufeff') ? content.substring(1) : content;
  if (!text.startsWith('#EXTM3U') || !_hasEndList(text)) return null;
  return purifyM3u8(text, tsUrlPre, rules: rules);
}
