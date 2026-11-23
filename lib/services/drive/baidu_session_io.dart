import 'dart:convert';
import 'dart:io';

import 'quark_session_io.dart'
    show QuarkSessionResult, mergeSetCookies, sanitizeCookie;

const _baiduUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/126.0.6478.61 Safari/537.36';
const _baiduReferer = 'https://pan.baidu.com/';
const _baiduTokenUrl =
    'https://pan.baidu.com/api/gettemplatevariable'
    '?fields=%5B%22bdstoken%22%2C%22uk%22%5D&channel=chunlei&web=1&app_id=250528'
    '&clienttype=0';
const _baiduShareUa =
    'netdisk;12.24.6;WinBox;android-android;12;JSbridge4.4.0;jointBridge;1.1.0';
const _baiduUserInfoUrl =
    'https://mbd.baidu.com/userx/v1/info/get'
    '?appname=baiduboxapp&fields=%5B%22bg_image%22,%22member%22,%22uid%22,'
    '%22avatar%22,%22avatar_member%22%5D&lang=zh-cn';
const _baiduPanUinfoUrl = '${_baiduReferer}rest/2.0/xpan/nas?method=uinfo';
final _digitsRe = RegExp(r'^\d+$');
Future<String> _fetchBaiduPanUk(HttpClient client, String headerVal) async {
  try {
    final req = await client.getUrl(Uri.parse(_baiduPanUinfoUrl));
    req.headers
      ..set(HttpHeaders.userAgentHeader, _baiduUa)
        ..set(HttpHeaders.refererHeader, _baiduReferer)
          ..set(HttpHeaders.acceptHeader, 'application/json, text/plain, */*')
            ..set(HttpHeaders.cookieHeader, headerVal);
            final resp = await req.close().timeout(const Duration(seconds: 12));
            if (resp.statusCode < 200 || resp.statusCode >= 300) return '';
            final body = await resp.transform(utf8.decoder).join();
            final decoded = jsonDecode(body);
            if (decoded is! Map<String, dynamic>) return '';
            if ((decoded['errno'] as num?)?.toInt() != 0) return '';
            final uk = '${decoded['uk'] ?? ''}'.trim();
            return _digitsRe.hasMatch(uk) ? uk : '';
   } catch (_) {
     return '';
    }
}
Future<String> _fetchBaiduUid(HttpClient client, String headerVal) async {
  try {
    final req = await client.getUrl(Uri.parse(_baiduUserInfoUrl));
    req.headers
      ..set(HttpHeaders.userAgentHeader, _baiduShareUa)
      ..set(HttpHeaders.refererHeader, _baiduReferer)
      ..set(HttpHeaders.acceptHeader, 'application/json, text/plain, */*')
      ..set(HttpHeaders.cookieHeader, headerVal);
    final resp = await req.close().timeout(const Duration(seconds: 12));
    if (resp.statusCode < 200 || resp.statusCode >= 300) return '';
    final body = await resp.transform(utf8.decoder).join();
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) return '';
    if ((decoded['errno'] as num?)?.toInt() != 0) return '';
    final data = decoded['data'];
    final fields = data is Map ? data['fields'] : null;
    final uid = fields is Map ? '${fields['uid'] ?? ''}'.trim() : '';
    return _digitsRe.hasMatch(uid) ? uid : '';
  } catch (_) {
    return '';
  }
}

/// 探测百度登录态并吸收响应里的新 Cookie（不写盘，调用方决定是否保存）。
///
/// 只有 BDUSS 没有 pan 域 STOKEN 的「半个会话」会在 playerContent 里报
/// `JsonObject.get(...) is null` / errno -6；`/api/gettemplatevariable`
/// 返回 errno -6 即未登录。
Future<QuarkSessionResult> refreshBaiduSession(String cookie) async {
  final original = cookie.trim();
  if (original.isEmpty) {
    return const QuarkSessionResult(cookie: '', changed: false, valid: null);
  }
  final base = sanitizeCookie(original);
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
  try {
    final request = await client.getUrl(Uri.parse(_baiduTokenUrl));
    request.headers
      ..set(HttpHeaders.userAgentHeader, _baiduUa)
      ..set(HttpHeaders.refererHeader, _baiduReferer)
      ..set(HttpHeaders.acceptHeader, 'application/json, text/plain, */*')
      ..set(HttpHeaders.cookieHeader, base);
    final response = await request.close().timeout(const Duration(seconds: 15));
    final body = await response.transform(utf8.decoder).join();
    final setCookies = <String>[];
    response.headers.forEach((name, values) {
      if (name.toLowerCase() == 'set-cookie') setCookies.addAll(values);
    });

    Map<String, dynamic>? json;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) json = decoded;
    } catch (_) {
      // 非 JSON（网关错误页）→ 状态未知
    }
    final errno = (json?['errno'] as num?)?.toInt();
    final valid = response.statusCode == 200 && errno == 0;
    // -6 = 未登录 / 会话失效；其它负值是接口临时错误，不能误判成游客态。
    final guest = errno == -6;
    final merged = mergeSetCookies(base, setCookies);
    final resMap = json?['result'];
    var uk = resMap is Map ? '${resMap['uk'] ?? ''}'.trim() : '';
    if (valid && !_digitsRe.hasMatch(uk)) {
      uk = await _fetchBaiduPanUk(client, merged);
      if (!_digitsRe.hasMatch(uk)) {
        uk = await _fetchBaiduUid(client, merged);
       }
      }
        return QuarkSessionResult(
      cookie: merged,
      changed: merged != original,
      valid: valid ? true : (guest ? false : null),
      userId: uk,
    );
  } catch (_) {
    return QuarkSessionResult(cookie: original, changed: false, valid: null);
  } finally {
    client.close(force: true);
  }
}
