import 'dart:convert';

/// 与旧版 engine/util/json.ts 对齐的宽容 JSON 处理。
String trimJsonObject(String? content) {
  if (content == null) return '';
  final t = content.trim();
  final start = t.indexOf('{');
  final end = t.lastIndexOf('}');
  if (start >= 0 && end > start) return t.substring(start, end + 1);
  return t;
}

String stripJsonComments(String input) {
  final out = StringBuffer();
  var i = 0;
  var inString = false;
  var escape = false;
  var lineStart = true;
  while (i < input.length) {
    final c = input[i];
    final next = i + 1 < input.length ? input[i + 1] : '';
    if (inString) {
      out.write(c);
      if (escape) {
        escape = false;
      } else if (c == r'\') {
        escape = true;
      } else if (c == '"') {
        inString = false;
      }
      i++;
      continue;
    }
    // 行首的 `#` 注释（部分订阅混用 shell 风格注释）。
    if (c == '#' && lineStart) {
      while (i < input.length && input[i] != '\n' && input[i] != '\r') {
        i++;
      }
      continue;
    }
    if (c == '"') {
      inString = true;
      lineStart = false;
      out.write(c);
      i++;
      continue;
    }
    if (c == '/' && next == '/') {
      while (i < input.length && input[i] != '\n' && input[i] != '\r') {
        i++;
      }
      continue;
    }
    if (c == '/' && next == '*') {
      i += 2;
      while (i < input.length &&
          !(input[i] == '*' && i + 1 < input.length && input[i + 1] == '/')) {
        i++;
      }
      i += 2;
      continue;
    }
    out.write(c);
    if (c == '\n' || c == '\r') {
      lineStart = true;
    } else if (c != ' ' && c != '\t') {
      lineStart = false;
    }
    i++;
  }
  return out.toString();
}

String stripTrailingCommas(String input) {
  final out = StringBuffer();
  var inString = false;
  var escape = false;
  // 逗号先扣住：只有确定后面不是 ] / } 时才写出去。
  String? pending;
  for (var i = 0; i < input.length; i++) {
    final c = input[i];
    if (inString) {
      out.write(c);
      if (escape) {
        escape = false;
      } else if (c == r'\') {
        escape = true;
      } else if (c == '"') {
        inString = false;
      }
      continue;
    }
    if (c == '"') {
      inString = true;
      if (pending != null) {
        out.write(pending);
        pending = null;
      }
      out.write(c);
      continue;
    }
    if (c == ',') {
      if (pending != null) out.write(pending);
      pending = ',';
      continue;
    }
    if (c == ']' || c == '}') {
      pending = null;
      out.write(c);
      continue;
    }
    if (pending != null) {
      if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
        pending += c;
        continue;
      }
      out.write(pending);
      pending = null;
    }
    out.write(c);
  }
  if (pending != null) out.write(pending);
  return out.toString();
}

String quoteUnquotedKeys(String input) {
  const idStart = r'A-Za-z_$\u4e00-\u9fa5';
  const idPart = r'A-Za-z0-9_$\u4e00-\u9fa5-';
  final startRe = RegExp('[$idStart]');
  final partRe = RegExp('[$idPart]');
  final wsRe = RegExp(r'[ \t\n\r]');
  final out = StringBuffer();
  var i = 0;
  var inString = false;
  var escape = false;
  var expectKey = false;
  while (i < input.length) {
    final c = input[i];
    if (inString) {
      out.write(c);
      if (escape) {
        escape = false;
      } else if (c == r'\') {
        escape = true;
      } else if (c == '"') {
        inString = false;
      }
      i++;
      continue;
    }
    if (c == '"') {
      inString = true;
      expectKey = false;
      out.write(c);
      i++;
      continue;
    }
    if (c == '{' || c == ',' || c == '}' || c == ']') {
      expectKey = true;
      out.write(c);
      i++;
      continue;
    }
    if (wsRe.hasMatch(c)) {
      out.write(c);
      i++;
      continue;
    }
    if (expectKey && startRe.hasMatch(c)) {
      var j = i;
      while (j < input.length && partRe.hasMatch(input[j])) {
        j++;
      }
      var k = j;
      while (k < input.length && wsRe.hasMatch(input[k])) {
        k++;
      }
      var end = k;
      var hit = false;
      if (k < input.length && input[k] == ':') {
        hit = true;
      } else if (k < input.length && input[k] == '"') {
        var m = k + 1;
        while (m < input.length && wsRe.hasMatch(input[m])) {
          m++;
        }
        if (m < input.length && input[m] == ':') {
          hit = true;
          end = m;
        }
      }
      if (hit) {
        out.write('"${input.substring(i, j)}"');
        i = end;
        expectKey = false;
        continue;
      }
    }
    expectKey = false;
    out.write(c);
    i++;
  }
  return out.toString();
}

/// 修正字符串里未转义的控制字符与非法转义：
///   · 长文本里的真实换行 / 制表符（JSON 字符串不允许裸控制字符）；
///   · JS 风格的 `\'`（转成普通单引号）；
///   · 正则 / Windows 路径里的 `\d`、`\U` 等非法转义（保留字面反斜杠）。
String repairJsonStrings(String input) {
  final out = StringBuffer();
  var inString = false;
  var i = 0;
  while (i < input.length) {
    final c = input[i];
    if (!inString) {
      if (c == '"') inString = true;
      out.write(c);
      i++;
      continue;
    }
    if (c == '"') {
      inString = false;
      out.write(c);
      i++;
      continue;
    }
    if (c == r'\') {
      final next = i + 1 < input.length ? input[i + 1] : '';
      if (next.isEmpty) {
        out.write(r'\\');
        i++;
        continue;
      }
      if (next == "'") {
        out.write("'");
        i += 2;
        continue;
      }
      if (r'"\/bfnrtu'.contains(next)) {
        out.write(c);
        out.write(next);
        i += 2;
        continue;
      }
      out.write(r'\\');
      i++;
      continue;
    }
    final code = c.codeUnitAt(0);
    if (code < 0x20) {
      if (c == '\n') {
        out.write(r'\n');
      } else if (c == '\r') {
        out.write(r'\r');
      } else if (c == '\t') {
        out.write(r'\t');
      } else {
        out.write('\\u${code.toRadixString(16).padLeft(4, '0')}');
      }
      i++;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

/// 修正引号写错的位置：
///   · `,style":{`（引号跑到键后面）→ `,"style":{`；
///   · `"searchable": 0"}`（值后面多一个引号）→ `"searchable": 0}`。
///
/// 按 token 上下文判断，只在结构位置生效；字符串内部（包括 URL、正则）原样保留，
/// 因此不会像正则替换那样误伤 `"2606:...::1001"` 这类值。
String fixMisplacedQuotes(String input) {
  final out = StringBuffer();
  var inString = false;
  var escape = false;
  // none / colon / comma / open / close / value（刚结束的字符串）
  // number / ident（尚未写出的标量 token）
  var token = 'none';
  StringBuffer? scalar;
  // 冒号后的裸标量（如 `"key":爱迪V2`、`"spider":./jar/vip.jar`）需要补引号。
  var scalarQuote = false;

  void flush() {
    if (scalar != null) {
      final text = scalar.toString();
      if (scalarQuote && !_isJsonScalarLiteral(text)) {
        out.write('"$text"');
        token = 'value';
      } else {
        out.write(text);
      }
      scalar = null;
      scalarQuote = false;
    }
  }

  String nextSignificant(int i) {
    var j = i + 1;
    while (j < input.length && _isJsonWs(input[j])) {
      j++;
    }
    return j < input.length ? input[j] : '';
  }

  for (var i = 0; i < input.length; i++) {
    final c = input[i];
    if (inString) {
      out.write(c);
      if (escape) {
        escape = false;
      } else if (c == r'\') {
        escape = true;
      } else if (c == '"') {
        inString = false;
        token = 'value';
      }
      continue;
    }
    if (c == '"') {
      final next = nextSignificant(i);
      if (token == 'ident' && next == ':') {
        out.write('"${scalar.toString()}"');
        scalar = null;
        token = 'none';
        continue;
      }
      if ((token == 'number' ||
              token == 'value' ||
              token == 'ident' ||
              token == 'close') &&
          (next == ',' || next == '}' || next == ']')) {
        continue;
      }
      flush();
      inString = true;
      out.write(c);
      continue;
    }
    if (_isJsonWs(c)) {
      flush();
      out.write(c);
      continue;
    }
    if (c == '{' || c == '[' || c == '}' || c == ']' || c == ':' || c == ',') {
      flush();
      out.write(c);
      if (c == '{' || c == '[') {
        token = 'open';
      } else if (c == '}' || c == ']') {
        token = 'close';
      } else if (c == ':') {
        token = 'colon';
      } else {
        token = 'comma';
      }
      continue;
    }
    final code = c.codeUnitAt(0);
    final isDigit = (code >= 0x30 && code <= 0x39) || c == '.' || c == '-';
    if (token != 'number' && token != 'ident') {
      final afterColon = token == 'colon';
      flush();
      token = isDigit ? 'number' : 'ident';
      scalarQuote = afterColon;
    }
    (scalar ??= StringBuffer()).write(c);
  }
  flush();
  return out.toString();
}

bool _isJsonWs(String c) => c == ' ' || c == '\t' || c == '\n' || c == '\r';

bool _isJsonScalarLiteral(String text) {
  if (text == 'true' || text == 'false' || text == 'null') return true;
  return num.tryParse(text) != null;
}

/// 组合修复：错位引号 → 注释 → 尾随逗号 → 未加引号的键 → 字符串转义。
///
/// 先修错位引号：否则 `,style":{`、`"k":0"}` 会打乱后续扫描器的字符串配对，
/// 把注释剥离误判到字符串内部（例如 URL 里的 `//` 被删掉）。
String repairJsonFull(String input) {
  final fixed = fixMisplacedQuotes(input);
  final noComments = stripJsonComments(fixed);
  final noCommas = stripTrailingCommas(noComments);
  final keys = quoteUnquotedKeys(noCommas);
  return repairJsonStrings(keys);
}

dynamic parseJsonLenient(String text) {
  final raw = trimJsonObject(text);
  if (raw.isEmpty) throw const FormatException('空 JSON');
  try {
    return jsonDecode(raw);
  } catch (_) {}
  for (final candidate in <String Function(String)>[
    stripJsonComments,
    (s) => stripTrailingCommas(stripJsonComments(s)),
    (s) => quoteUnquotedKeys(stripTrailingCommas(stripJsonComments(s))),
    repairJsonFull,
  ]) {
    try {
      return jsonDecode(candidate(raw));
    } catch (_) {}
  }
  throw FormatException(
    '不是合法 JSON 对象：${raw.substring(0, raw.length > 80 ? 80 : raw.length)}',
  );
}

String safeString(Map<String, dynamic>? o, String key, [String def = '']) {
  if (o == null || !o.containsKey(key)) return def;
  final v = o[key];
  if (v == null) return def;
  if (v is Map || v is List) {
    try {
      return jsonEncode(v).trim();
    } catch (_) {
      return def;
    }
  }
  return v.toString().trim();
}

int safeInt(Map<String, dynamic>? o, String key, [int def = 0]) {
  if (o == null || !o.containsKey(key)) return def;
  final v = o[key];
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v?.toString().trim() ?? '') ?? def;
}

List<String> safeStringList(Map<String, dynamic>? o, String key) {
  if (o == null) return const [];
  final v = o[key];
  if (v is List) {
    return v
        .where((e) => e != null)
        .map((e) => e is Map || e is List ? jsonEncode(e) : e.toString().trim())
        .toList();
  }
  return const [];
}
