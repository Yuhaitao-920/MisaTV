/// 纯 Dart 字幕解析：SRT / WebVTT / ASS(SSA) → 统一 cue 列表。
///
/// 逐函数移植自旧版 `src/engine/subtitle/parseSubtitle.ts`，
/// 并保留 `SubtitleText.decode` 的编码探测顺序（BOM、严格 UTF-8、GBK）。
library;

import 'dart:convert';

// 用 charset 的常量映射 GBK 解码器，而不是 gbk_codec：后者的 `gbk_bytes` 是顶层
// final，首次使用时才用 24000+ 条条目现场构造映射表，初始化一旦失败会直接打掉
// 整个 isolate（表现为整批用例 did not complete），在并发/低内存环境偶发。
import 'package:charset/charset.dart' show gbk;

/// 单条字幕。
class SubtitleCue {
  const SubtitleCue({
    required this.start,
    required this.end,
    required this.text,
  });

  /// 秒。
  final double start;

  /// 秒。
  final double end;
  final String text;
}

double _hmsToSec(String v) {
  final t = v.trim();
  final m = RegExp(r'(\d+):(\d{1,2}):(\d{1,2})[,.](\d{1,3})').firstMatch(t);
  if (m != null) {
    final h = int.parse(m.group(1)!);
    final mm = int.parse(m.group(2)!);
    final ss = int.parse(m.group(3)!);
    final ms = int.parse(m.group(4)!.padRight(3, '0').substring(0, 3));
    return h * 3600 + mm * 60 + ss + ms / 1000;
  }
  final m2 = RegExp(r'(\d{1,2}):(\d{1,2})[,.](\d{1,3})').firstMatch(t);
  if (m2 != null) {
    final ms = int.parse(m2.group(3)!.padRight(3, '0').substring(0, 3));
    return int.parse(m2.group(1)!) * 60 + int.parse(m2.group(2)!) + ms / 1000;
  }
  return double.nan;
}

/// SRT：序号 \n 起-->止 \n 文本 \n (空行)。
List<SubtitleCue> parseSrt(String text) {
  final out = <SubtitleCue>[];
  final blocks = text.split(RegExp(r'\r?\n\s*\r?\n'));
  for (final b in blocks) {
    final lines = b.split(RegExp(r'\r?\n')).map((l) => l.trim()).toList();
    if (lines.isEmpty) continue;
    final timeIdx = lines.indexWhere((l) => l.contains('-->'));
    if (timeIdx < 0) continue;
    final parts = lines[timeIdx].split('-->');
    final s = _hmsToSec(parts.first);
    final e = _hmsToSec(parts.length > 1 ? parts[1] : '');
    if (!s.isFinite || !e.isFinite || s >= e) continue;
    final body = lines.skip(timeIdx + 1).join('\n').trim();
    if (body.isEmpty) continue;
    out.add(SubtitleCue(start: s, end: e, text: body));
  }
  return out;
}

/// WebVTT：头部 WEBVTT（可选 NOTE/STYLE/REGION 等区块），其余同 SRT cue。
List<SubtitleCue> parseVtt(String text) {
  final out = <SubtitleCue>[];
  final content = text.replaceFirst(RegExp(r'^\uFEFF?WEBVTT[^\n]*(?:\n|$)'), '');
  final blocks = content.split(RegExp(r'\r?\n\s*\r?\n'));
  for (final b in blocks) {
    final lines = b
        .split(RegExp(r'\r?\n'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.isEmpty) continue;
    // 按「块首行」识别区块头（NOTE/STYLE/REGION）→ 整块跳过。
    final head = lines.first.toUpperCase();
    if (head == 'NOTE' ||
        head == 'STYLE' ||
        head == 'REGION' ||
        head.startsWith('NOTE ')) {
      continue;
    }
    final timeIdx = lines.indexWhere((l) => l.contains('-->'));
    if (timeIdx < 0) continue;
    final timeLine = lines[timeIdx].split('-->');
    final s = _hmsToSec((timeLine.first).replaceFirst(RegExp(r'^\d+\s+'), ''));
    final ePart = timeLine.length > 1 ? timeLine[1].trim() : '';
    final e = _hmsToSec(ePart.split(RegExp(r'\s+')).first);
    if (!s.isFinite || !e.isFinite || s >= e) continue;
    final body = lines.skip(timeIdx + 1).join('\n').trim();
    if (body.isEmpty) continue;
    out.add(SubtitleCue(start: s, end: e, text: body));
  }
  return out;
}

/// ASS/SSA：Dialogue 行 Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text…
List<SubtitleCue> parseAss(String text) {
  final out = <SubtitleCue>[];
  final re = RegExp(
    r'^Dialogue:\s*([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),(.*)$',
  );
  for (final line in text.split(RegExp(r'\r?\n'))) {
    final m = re.firstMatch(line);
    if (m == null) continue;
    final start = _hmsToSec(m.group(2) ?? '');
    final end = _hmsToSec(m.group(3) ?? '');
    if (!start.isFinite || !end.isFinite || start >= end) continue;
    final raw = (m.group(10) ?? '')
        .replaceAll(RegExp(r'\\N', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'\\n', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'\{[^}]*\}'), '')
        .trim();
    if (raw.isEmpty) continue;
    out.add(SubtitleCue(start: start, end: end, text: raw));
  }
  return out;
}

List<SubtitleCue> _parseBySniff(String text) {
  final head = text.length > 3000 ? text.substring(0, 3000) : text;
  if (RegExp(r'\[Script Info\]|(^|\r?\n)\s*Dialogue:', caseSensitive: false)
      .hasMatch(head)) {
    final c = parseAss(text);
    if (c.isNotEmpty) return c;
  }
  if (RegExp(r'WEBVTT', caseSensitive: false)
      .hasMatch(text.length > 200 ? text.substring(0, 200) : text)) {
    final c = parseVtt(text);
    if (c.isNotEmpty) return c;
  }
  return parseSrt(text);
}

/// 按扩展名分派解析；扩展名不信任，0 cue 时按内容再嗅探一次。
List<SubtitleCue> parseSubtitleFile(String fileName, String text) {
  final dot = fileName.lastIndexOf('.');
  final ext = dot >= 0 ? fileName.substring(dot + 1).toLowerCase() : '';
  if (ext == 'srt' || ext == 'vtt' || ext == 'ass' || ext == 'ssa') {
    final byExt = ext == 'srt'
        ? parseSrt(text)
        : ext == 'vtt'
        ? parseVtt(text)
        : parseAss(text);
    if (byExt.isNotEmpty) return byExt;
  }
  return _parseBySniff(text);
}

/// 字幕总体时间偏移（±秒）。完全移出 0 点之前的区间丢弃，部分穿零钳 0。
List<SubtitleCue> shiftCues(List<SubtitleCue> cues, double offsetSec) {
  if (offsetSec == 0) return cues;
  final out = <SubtitleCue>[];
  for (final c in cues) {
    final start = c.start + offsetSec;
    final end = c.end + offsetSec;
    if (end <= 0) continue;
    final s = start < 0 ? 0.0 : start;
    out.add(SubtitleCue(
      start: s,
      end: end < s ? s : end,
      text: c.text,
    ));
  }
  return out;
}

String _srtTime(double sec) {
  final s = sec.isFinite && sec > 0 ? sec : 0.0;
  final ms = ((s % 1) * 1000).round();
  final total = s.floor();
  final hh = total ~/ 3600;
  final mm = (total % 3600) ~/ 60;
  final ss = total % 60;
  String p(int n, [int w = 2]) => n.toString().padLeft(w, '0');
  return '${p(hh)}:${p(mm)}:${p(ss)},${p(ms > 999 ? 999 : ms, 3)}';
}

/// cue 列表 → SRT 文本（供 mpv `sub-add` 等需要 SRT 文件的场景）。
String cuesToSrt(List<SubtitleCue> cues) {
  final out = <String>[];
  for (var i = 0; i < cues.length; i++) {
    final c = cues[i];
    out.add('${i + 1}');
    out.add('${_srtTime(c.start)} --> ${_srtTime(c.end)}');
    out.add(c.text);
    out.add('');
  }
  return out.join('\r\n');
}

/// 字幕文本解码：BOM 优先；严格 UTF-8 成功即 UTF-8，否则 GBK 兜底。
class SubtitleText {
  const SubtitleText._();

  static String decode(List<int> bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xef &&
        bytes[1] == 0xbb &&
        bytes[2] == 0xbf) {
      return utf8.decode(bytes.sublist(3), allowMalformed: true);
    }
    if (bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe) {
      return _utf16le(bytes.sublist(2));
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      // 严格 UTF-8 失败 → 尝试旧字幕常用的 GBK 编码。
    }
    try {
      return gbk.decode(bytes);
    } catch (_) {
      return utf8.decode(bytes, allowMalformed: true);
    }
  }

  static String _utf16le(List<int> bytes) {
    final units = <int>[];
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      units.add(bytes[i] | (bytes[i + 1] << 8));
    }
    return String.fromCharCodes(units);
  }
}

/// 文本是否像字幕（有 cue 时间轴或 ASS/VTT 结构）。
bool looksLikeSubtitle(String text) {
  final head = text.length > 2000 ? text.substring(0, 2000) : text;
  return RegExp(r'-->').hasMatch(head) ||
      RegExp(r'Dialogue:', caseSensitive: false).hasMatch(head) ||
      RegExp(r'\[Script Info\]', caseSensitive: false).hasMatch(head) ||
      RegExp(r'WEBVTT', caseSensitive: false).hasMatch(head);
}
