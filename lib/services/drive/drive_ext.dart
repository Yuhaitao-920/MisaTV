import 'dart:convert';

import '../relay/local_relay.dart';

/// 把已登录网盘 Cookie 并入蜘蛛 ext（对齐 TVBox 生态：provider 名即 ext 键名）。
/// ext 为空或非 JSON 对象时原样返回（避免改变源作者预期的格式）。
///
/// 同时把 ext 里的 `Cloud-drive` 相对路径归一为本地 `/file` 地址：fty 系 jar
/// 只认 `http…` 或 `./…` 两种形态，裸相对路径不会 fetch（cookie 被置空）。
String enrichSpiderExt(String ext, Map<String, String> tokens) {
  final trimmed = ext.trim();
  if (trimmed.isEmpty) return ext;
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is! Map) return ext;
    var changed = false;
    for (final entry in tokens.entries) {
      final value = entry.value.trim();
      if (value.isEmpty) continue;
      decoded[entry.key] = value;
      changed = true;
    }
    if (_normalizeCloudDrive(decoded)) changed = true;
    if (_ensureBiliCookieUrl(decoded, tokens)) changed = true;
    return changed ? jsonEncode(decoded) : ext;
  } catch (_) {
    return ext;
  }
}

/// 哔哩系蜘蛛（`csp_Bili` / `csp_BiliYS`）的 ext 用 `cookie` 指向一个**文本文件**
/// （订阅里通常写死 `http://127.0.0.1:9978/file/TVBox/bili_cookie.txt`）。
///
/// 这里做两件事：
///   1. 把写死的 9978 换成中继的真实端口（端口被占用时会换临时端口）；
///   2. 源没写 `cookie` 但本机配了哔哩 Cookie 时，补上这个地址，
///      让蜘蛛能读到登录态而不是空串。
bool _ensureBiliCookieUrl(Map decoded, Map<String, String> tokens) {
  final relay = LocalRelay.instance;
  if (!relay.running) return false;
  final fileUrl = '${relay.baseUrl}/file/TVBox/bili_cookie.txt';
  final raw = '${decoded['cookie'] ?? ''}'.trim();
  if (raw.isEmpty) {
    if ((tokens['bili'] ?? '').trim().isEmpty) return false;
    decoded['cookie'] = fileUrl;
    return true;
  }
  final rewritten = _relayFileUrl(raw, relay.baseUrl);
  if (rewritten == null || rewritten == raw) return false;
  decoded['cookie'] = rewritten;
  return true;
}

/// 把 `http://127.0.0.1:<任意端口>/file/...` 对齐到当前中继端口。
String? _relayFileUrl(String raw, String baseUrl) {
  final match = RegExp(
    r'^https?://(?:127\.0\.0\.1|localhost):\d+(/file/.*)$',
    caseSensitive: false,
  ).firstMatch(raw);
  final tail = match?.group(1);
  if (tail == null) return null;
  return '$baseUrl$tail';
}

/// `Cloud-drive: "tvfan/Cloud-drive.txt"` → `http://127.0.0.1:<relay>/file/tvfan/Cloud-drive.txt`。
bool _normalizeCloudDrive(Map decoded) {
  final raw = '${decoded['Cloud-drive'] ?? ''}'.trim();
  if (raw.isEmpty ||
      RegExp(r'^https?://', caseSensitive: false).hasMatch(raw)) {
    return false;
  }
  if (!LocalRelay.instance.running) return false;
  final rel = raw.replaceFirst(RegExp(r'^\.{0,2}/+'), '');
  if (rel.isEmpty) return false;
  decoded['Cloud-drive'] = '${LocalRelay.instance.baseUrl}/file/$rel';
  return true;
}
