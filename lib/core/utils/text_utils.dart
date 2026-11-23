const defaultGroupName = '直播';
const legacyDefaultGroupName = 'Ungrouped';
const defaultChannelName = 'Unnamed';

final _tvgLogo = RegExp(r'tvg-logo="(.*?)"');
final _tvgUrl = RegExp(r'tvg-url="(.*?)"');
final _tvgId = RegExp(r'tvg-id="(.*?)"');
final _tvgName = RegExp(r'tvg-name="(.*?)"');
final _tvgChno = RegExp(r'tvg-chno="(.*?)"');
final _ua = RegExp(r'http-user-agent="(.*?)"');
final _catchup = RegExp(r'catchup="(.*?)"');
final _catchupSource = RegExp(r'catchup-source="(.*?)"');
final _catchupReplace = RegExp(r'catchup-replace="(.*?)"');
final _groupTitle = RegExp(r'group-title="(.*?)"');
final _epName = RegExp(r'\s*,\s*(.+?)\s*$');

String firstGroup(String text, RegExp re) {
  final m = re.firstMatch(text);
  return m != null && m.groupCount >= 1 ? (m.group(1) ?? '') : '';
}

String normalizeGroupName(String? name) {
  if (name == null) return defaultGroupName;
  final t = name.trim();
  if (t.isEmpty || t.toLowerCase() == legacyDefaultGroupName.toLowerCase()) {
    return defaultGroupName;
  }
  return t;
}

bool isLiveUrl(String url) {
  return url.isNotEmpty &&
      (url.startsWith('http') ||
          url.startsWith('rtp') ||
          url.startsWith('rtsp') ||
          url.startsWith('rtmp') ||
          url.startsWith('tvbus://'));
}

/// 取 #EXTINF 最后一个逗号后的频道名，兼容引号内逗号。
String extractM3uName(String line) {
  var inQuote = false;
  for (var i = 0; i < line.length; i++) {
    if (line[i] == '"') inQuote = !inQuote;
  }
  if (!inQuote) {
    final m = _epName.firstMatch(line);
    return (m?.group(1) ?? '').trim();
  }
  // 引号未闭合时按最后一个引号之后查找
  final idx = line.lastIndexOf('",');
  if (idx >= 0) {
    final tail = line.substring(idx + 2).trim();
    return tail;
  }
  final m = _epName.firstMatch(line);
  return (m?.group(1) ?? '').trim();
}

Map<String, String> m3uMeta(String line) {
  final out = <String, String>{};
  void put(String k, String v) {
    if (v.isNotEmpty) out[k] = v;
  }

  put('logo', firstGroup(line, _tvgLogo));
  // 复刻上游怪癖：tvg-url 会子串命中 x-tvg-url
  put('epg', firstGroup(line, _tvgUrl));
  put('tvg-id', firstGroup(line, _tvgId));
  put('tvg-name', firstGroup(line, _tvgName));
  put('tvg-chno', firstGroup(line, _tvgChno));
  put('ua', firstGroup(line, _ua));
  final catchup = firstGroup(line, _catchup);
  final source = firstGroup(line, _catchupSource);
  final replace = firstGroup(line, _catchupReplace);
  if (catchup.isNotEmpty || source.isNotEmpty || replace.isNotEmpty) {
    out['catchup'] = '$catchup\u0001$source\u0001$replace';
  }
  return out;
}

String m3uGroup(String line) => firstGroup(line, _groupTitle);

bool isSettingLine(String line) {
  return line.startsWith('ua') ||
      line.startsWith('parse') ||
      line.startsWith('click') ||
      line.startsWith('player') ||
      line.startsWith('header') ||
      line.startsWith('format') ||
      line.startsWith('origin') ||
      line.startsWith('referer') ||
      line.startsWith('#EXTHTTP:') ||
      line.startsWith('#EXTVLCOPT:') ||
      line.startsWith('#KODIPROP:');
}

String _value(String line, String key) {
  final idx = line.indexOf('$key=');
  if (idx < 0) return '';
  return line.substring(idx + key.length + 1).trim().replaceAll('"', '');
}

Map<String, String> m3uSettings(String line) {
  final out = <String, String>{};
  void put(String k, String v) {
    if (v.isNotEmpty) out[k] = v;
  }

  if (line.startsWith('ua')) put('ua', _value(line, 'ua'));
  if (line.startsWith('parse')) put('parse', _value(line, 'parse'));
  if (line.startsWith('click')) put('click', _value(line, 'click'));
  if (line.startsWith('header')) put('header', _value(line, 'header'));
  if (line.startsWith('format')) put('format', _value(line, 'format'));
  if (line.startsWith('origin')) put('origin', _value(line, 'origin'));
  if (line.startsWith('referer')) put('referer', _value(line, 'referer'));
  if (line.startsWith('#EXTHTTP:')) put('header', line.split('#EXTHTTP:').last.trim());
  if (line.startsWith('#EXTVLCOPT:')) {
    if (line.contains('http-user-agent')) put('ua', _value(line, 'http-user-agent'));
    if (line.contains('http-origin')) put('origin', _value(line, 'http-origin'));
    if (line.contains('http-referrer')) put('referer', _value(line, 'http-referrer'));
  }
  if (line.startsWith('#KODIPROP:') && line.contains('manifest_type=')) {
    put('format', _value(line, 'manifest_type'));
  }
  return out;
}

String splitUrlHeadersClean(String raw) {
  final s = raw.trim();
  if (!s.contains('@')) return s;
  final m = RegExp(r'@([A-Za-z0-9-]+)=').firstMatch(s);
  if (m == null || m.start == 0) return s;
  final url = s.substring(0, m.start);
  if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(url)) return s;
  return url;
}

Map<String, String> splitUrlHeaders(String raw) {
  final s = raw.trim();
  final out = <String, String>{};
  if (!s.contains('@')) return out;
  final m = RegExp(r'@([A-Za-z0-9-]+)=').firstMatch(s);
  if (m == null || m.start == 0) return out;
  final url = s.substring(0, m.start);
  if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(url)) return out;
  final rest = s.substring(m.start + 1);
  for (final kv in RegExp(r'([A-Za-z0-9-]+)=([^@]*)').allMatches(rest)) {
    final key = kv.group(1)!.toLowerCase();
    final value = kv.group(2)!.trim();
    if (value.isEmpty) continue;
    if (key == 'referer' || key == 'referrer') {
      out.putIfAbsent('Referer', () => value);
    } else if (key == 'user-agent' || key == 'ua') {
      out.putIfAbsent('User-Agent', () => value);
    } else if (key == 'cookie') {
      out.putIfAbsent('Cookie', () => value);
    }
  }
  return out;
}
