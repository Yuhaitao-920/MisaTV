// 纯 Dart 弹幕解析（对齐旧版 src/engine/danmaku/parseDanmakuXml.ts）：
// 聚合接口实测返回「B 站新版 JSON 弹幕」（{ count, comments:[{ p, m }] }），
// 旧接口/部分镜像仍返回 XML（<d p="…">内容</d>），两者都支持、按首字符探测。
import 'dart:convert';

import 'danmaku_models.dart';

/// XML 实体反转义。顺序重要：先其它后 amp，避免二次转义。
String unescapeXml(String s) {
  return s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
}

int _clamp(int v, int min, int max) => v < min ? min : (v > max ? max : v);

/// JS `parseFloat` 口径：取前导数字部分（允许前导空白与尾随噪声）。
double? _parseFloat(String s) {
  final m = RegExp(r'^\s*[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?')
      .firstMatch(s);
  if (m == null) return null;
  return double.tryParse(m.group(0)!.trim());
}

/// JS `parseInt(s, 10)` 口径：取前导整数部分。
int? _parseInt(String s) {
  final m = RegExp(r'^\s*([+-]?\d+)').firstMatch(s);
  if (m == null) return null;
  return int.tryParse(m.group(1)!);
}

/// B 站弹幕模式 → 弹幕类型；7/8/9（脚本/高级）不支持，丢弃。
String? _toType(int mode) {
  switch (mode) {
    case 1:
    case 2:
    case 3:
    case 6:
      return 'scroll';
    case 4:
      return 'bottom';
    case 5:
      return 'top';
    default:
      return null;
  }
}

/// 十进制颜色 int → #rrggbb。
String _toHexColor(int n) {
  var hex = (n & 0xFFFFFFFF).toRadixString(16);
  if (hex.length < 6) hex = hex.padLeft(6, '0');
  return '#${hex.substring(hex.length - 6)}';
}

final RegExp _selfClosingD = RegExp(r'<d\b([^>]*?)\/>');
final RegExp _dElement = RegExp(r'<d\b([^>]*)>([\s\S]*?)</d>');
final RegExp _pAttr = RegExp(r'''(?:^|\s)p\s*=\s*(?:"([^"]*)"|'([^']*)')''');
final RegExp _cdata = RegExp(r'<!\[CDATA\[([\s\S]*?)\]\]>');

/// 解析 B 站格式弹幕 XML。非 `<d>` 内容忽略；无有效项返回 []。
List<DanmakuItem> parseDanmakuXml(String xml) {
  final out = <DanmakuItem>[];
  // ① 自闭合 <d …/> 统一成空对（内容空 → 丢弃，避免正则吞后续弹幕）；
  // ② p 属性宽松提取：属性顺序任意、单双引号均可。
  final normalized = xml.replaceAllMapped(
    _selfClosingD,
    (m) => '<d${m.group(1)}></d>',
  );
  for (final m in _dElement.allMatches(normalized)) {
    final attrs = m.group(1)!;
    final pm = _pAttr.firstMatch(attrs);
    if (pm == null) continue;
    final p = (pm.group(1) ?? pm.group(2) ?? '').split(',');
    final time = p.isEmpty ? null : _parseFloat(p[0]);
    if (time == null || !time.isFinite) continue;
    final mode = _parseInt(p.length > 1 ? p[1] : '') ?? 0;
    final type = _toType(mode);
    if (type == null) continue;
    final sizeRaw = _parseInt(p.length > 2 ? p[2] : '') ?? 25;
    final size = _clamp(sizeRaw == 0 ? 25 : sizeRaw, 12, 40);
    final color = _toHexColor((p.length > 3 ? _parseInt(p[3]) : null) ?? 0);
    // 内容：剥 CDATA 再反转义，去 \r 与空串。
    var text = m.group(2)!.replaceAllMapped(_cdata, (c) => c.group(1)!);
    text = unescapeXml(text).replaceAll('\r', '');
    if (text.trim().isEmpty) continue;
    out.add(
      DanmakuItem(time: time, type: type, text: text, size: size, color: color),
    );
  }
  return out;
}

/// 解析 B 站新版 JSON 弹幕：`{ count, comments:[{ p: "时间,模式,颜色,id", m: "内容" }] }`。
/// 无字号字段 → 默认 25；非法/空输入返回 []。
List<DanmakuItem> parseDanmakuJson(String jsonText) {
  dynamic j;
  try {
    j = jsonDecode(jsonText);
  } catch (_) {
    return const [];
  }
  final List<dynamic> arr;
  if (j is List) {
    arr = j;
  } else if (j is Map && j['comments'] is List) {
    arr = j['comments'] as List;
  } else {
    arr = const [];
  }
  final out = <DanmakuItem>[];
  for (final c in arr) {
    if (c is! Map) continue;
    final p = c['p'];
    if (p is! String) continue;
    final attrs = p.split(',');
    final time = _parseFloat(attrs[0]);
    if (time == null || !time.isFinite) continue;
    final type = _toType(_parseInt(attrs.length > 1 ? attrs[1] : '') ?? 0);
    if (type == null) continue;
    final color = _toHexColor(
      _parseInt(attrs.length > 2 ? attrs[2] : '') ?? 16777215,
    );
    final text = (c['m'] ?? '').toString();
    if (text.trim().isEmpty) continue;
    out.add(
      DanmakuItem(time: time, type: type, text: text, size: 25, color: color),
    );
  }
  return out;
}

/// 按内容首字符探测解析弹幕响应：以 '<' 开头按 XML，否则按 JSON；空返回 []。
List<DanmakuItem> parseDanmakuResponse(String text) {
  final t = text.trim();
  if (t.isEmpty) return const [];
  return t.startsWith('<') ? parseDanmakuXml(t) : parseDanmakuJson(t);
}
