import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/drive/drive_cookie_input.dart';

void main() {
  group('normalizeDriveCookieInput', () {
    test('原始 Cookie 串与 Cookie: 前缀', () {
      expect(
        normalizeDriveCookieInput('__puus=abc; __pus=def'),
        '__puus=abc; __pus=def',
      );
      expect(
        normalizeDriveCookieInput('Cookie: __puus=abc; __pus=def'),
        '__puus=abc; __pus=def',
      );
    });

    test('从 cURL 里只取 Cookie 一段', () {
      final raw =
          "curl 'https://pan.quark.cn/' \\\n"
          " -H 'cookie: __puus=abc; __pus=def' \\\n"
          " -H 'user-agent: Mozilla/5.0'";
      expect(normalizeDriveCookieInput(raw), '__puus=abc; __pus=def');
    });

    test('每行一个 a=b', () {
      expect(
        normalizeDriveCookieInput('__puus=abc\n__pus=def\n'),
        '__puus=abc; __pus=def',
      );
    });

    test('Set-Cookie 属性被丢弃', () {
      expect(
        normalizeDriveCookieInput(
          'BDUSS=abc; Path=/; Domain=.baidu.com; '
          'Expires=Wed, 21 Oct 2015 07:28:00 GMT; Secure; HttpOnly',
        ),
        'BDUSS=abc',
      );
    });

    test('同名后值覆盖前值，值里的等号保留', () {
      expect(normalizeDriveCookieInput('a=1; a=2'), 'a=2');
      expect(normalizeDriveCookieInput('token=abc==; x=y'), 'token=abc==; x=y');
    });

    test('非法片段被忽略', () {
      expect(normalizeDriveCookieInput('=no; bad name=1; ok=1'), 'ok=1');
    });
  });

  group('登录态字段校验', () {
    test('夸克 / UC / 百度各认自己的字段', () {
      expect(driveCookieHasAuth('quark', '__pus=x'), isTrue);
      expect(driveCookieHasAuth('quark', '__puus=x'), isTrue);
      expect(driveCookieHasAuth('uc', 'PUVID=x'), isTrue);
      expect(driveCookieHasAuth('baidu', 'BDUSS=x'), isTrue);
    });

    test('缺少登录态字段时给出提示', () {
      expect(driveCookieHasAuth('quark', 'foo=bar'), isFalse);
      expect(driveCookieMissingHint('baidu'), contains('BDUSS'));
    });

    test('哔哩只认 SESSDATA', () {
      expect(driveCookieHasAuth('bili', 'SESSDATA=abc'), isTrue);
      expect(driveCookieHasAuth('bili', 'buvid3=abc'), isFalse);
      expect(driveCookieMissingHint('bili'), contains('SESSDATA'));
    });

    test('115 需要 UID / CID / SEID 三件套齐全', () {
      expect(driveCookieHasAuth('115', 'UID=1'), isTrue);
      // 只有 UID 是半个会话，服务端仍判未登录。
      expect(driveCookieIsComplete('115', 'UID=1'), isFalse);
      expect(driveCookieIsComplete('115', 'UID=1; CID=2'), isFalse);
      expect(driveCookieIsComplete('115', 'UID=1; CID=2; SEID=3'), isTrue);
      expect(
        driveCookieMissingHint('115'),
        allOf(contains('UID'), contains('CID'), contains('SEID')),
      );
    });

    test('没有额外要求的 provider 只校验登录态字段', () {
      expect(driveCookieIsComplete('quark', '__puus=x'), isTrue);
      expect(driveCookieIsComplete('bili', 'SESSDATA=x'), isTrue);
    });
  });
}
