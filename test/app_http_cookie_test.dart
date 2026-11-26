import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kniephos/core/net/app_http.dart';

void main() {
  group('Set-Cookie 解析', () {
    test('单个 Cookie 忽略属性', () {
      expect(parseSetCookieHeader('a=1; Path=/; HttpOnly'), 'a=1');
      expect(
        parseSetCookieHeader('cf_clearance=xyz; Secure; SameSite=None'),
        'cf_clearance=xyz',
      );
    });

    test('多个 Cookie 与 Expires 里的逗号不误切', () {
      expect(
        parseSetCookieHeader(
          'a=1; Path=/, b=2; Expires=Wed, 21 Oct 2026 07:28:00 GMT',
        ),
        'a=1; b=2',
      );
    });

    test('空值与异常片段', () {
      expect(parseSetCookieHeader(''), '');
      expect(parseSetCookieHeader('nosemicolon'), '');
    });
  });

  group('会话 Cookie 捕获', () {
    test('403 响应也会收下 Set-Cookie', () async {
      final client = MockClient((request) async {
        return http.Response(
          'blocked',
          403,
          headers: {'set-cookie': 'sid=abc; Path=/'},
        );
      });
      final api = AppHttp(client: client);
      await expectLater(
        api.getText('https://example.com/a'),
        throwsA(isA<AppHttpException>()),
      );
      expect(api.cookiesFor('https://example.com/b'), 'sid=abc');
      expect(api.cookiesFor('https://other.com/a'), '');
      api.close();
    });

    test('同名 Cookie 后值覆盖前值', () async {
      var round = 0;
      final client = MockClient((request) async {
        round++;
        return http.Response(
          '{}',
          200,
          headers: {
            'set-cookie': round == 1 ? 'sid=old; Path=/' : 'sid=new; Path=/',
          },
        );
      });
      final api = AppHttp(client: client);
      await api.getText('https://example.com/a');
      await api.getText('https://example.com/b');
      expect(api.cookiesFor('https://example.com/c'), 'sid=new');
      api.close();
    });
  });
}
