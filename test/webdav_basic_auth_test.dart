import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/core/net/app_http.dart';

/// WebDAV / 坚果云订阅常把账号密码写在地址里：
/// `https://user:pass@dav.jianguoyun.com/dav/x.json`。
///
/// Dart 的 `HttpClient` 不会把 `Uri.userInfo` 自动转成请求头，不补这一步
/// 服务端直接回 401，用户看到的是「订阅导入失败：站点返回 HTTP 401」。
void main() {
  group('URL 内嵌账号密码 → Basic Auth', () {
    test('用户名里的 %40 要解码回 @', () {
      // 用户名是邮箱时，`@` 在 URL 里必须写成 %40，否则会被当成 userinfo 分隔符。
      final uri = Uri.parse(
        'https://someone%40example.com:app-password@dav.jianguoyun.com/dav/x.json',
      );
      final headers = AppHttp.authHeadersOf(uri);
      final auth = headers['authorization'];
      expect(auth, isNotNull);
      expect(auth, startsWith('Basic '));
      final decoded = utf8.decode(base64Decode(auth!.substring(6)));
      expect(
        decoded,
        'someone@example.com:app-password',
        reason: '%40 必须还原成 @，否则 Basic 串是错的',
      );
    });

    test('普通明文账号密码', () {
      final headers = AppHttp.authHeadersOf(
        Uri.parse('https://alice:secret@dav.example.com/x.json'),
      );
      final decoded = utf8.decode(
        base64Decode(headers['authorization']!.substring(6)),
      );
      expect(decoded, 'alice:secret');
    });

    test('密码里含冒号时只在第一个冒号处切开', () {
      final headers = AppHttp.authHeadersOf(
        Uri.parse('https://user:a%3Ab@dav.example.com/x.json'),
      );
      final decoded = utf8.decode(
        base64Decode(headers['authorization']!.substring(6)),
      );
      expect(decoded, 'user:a:b');
    });

    test('没有账号密码时不加头', () {
      expect(
        AppHttp.authHeadersOf(Uri.parse('https://dav.example.com/x.json')),
        isEmpty,
      );
    });

    test('只有用户名没有密码时不加头（避免发出半截凭据）', () {
      expect(
        AppHttp.authHeadersOf(Uri.parse('https://user@dav.example.com/x.json')),
        isEmpty,
      );
    });
  });
}
