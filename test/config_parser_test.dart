import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/config_parser.dart';
import 'package:pointycastle/export.dart';

/// 按潇洒 wire format 生成样本：hex(`$#key#$` + AES-CBC/PKCS7 + 13 字节 IV)。
String cbcSample(String key, String iv, String json) {
  final keyBytes = Uint8List(16)..fillRange(0, 16, 0x30);
  final keyAscii = ascii.encode(key);
  keyBytes.setRange(0, keyAscii.length, keyAscii);
  final ivAscii = ascii.encode(iv);
  final ivBytes = Uint8List(16)..fillRange(0, 16, 0x30);
  ivBytes.setRange(0, 13, ivAscii);

  final plain = utf8.encode(json);
  final pad = 16 - plain.length % 16;
  final padded = Uint8List(plain.length + pad);
  padded.setRange(0, plain.length, plain);
  padded.fillRange(plain.length, padded.length, pad);
  final cbc = CBCBlockCipher(AESEngine())
    ..init(true, ParametersWithIV(KeyParameter(keyBytes), ivBytes));
  final cipher = Uint8List(padded.length);
  for (var off = 0; off < padded.length; off += 16) {
    cbc.processBlock(padded, off, cipher, off);
  }
  final bytes = [...ascii.encode('\$#$key#\$'), ...cipher, ...ivAscii];
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

void main() {
  group('ConfigParser', () {
    test('解析基础字段与默认值', () {
      const json = '''
      {
        "sites": [
          {"key": "a", "name": " A 站 ", "type": 0, "api": "http://a/api.php"},
          {"key": "b", "type": 1, "api": "http://b/api.php", "searchable": 0, "timeout": 99},
          {"key": "c", "type": 3, "api": "http://c/a.js"},
          {"key": "d", "type": 2, "api": "http://d"},
          {"key": "e", "type": 1, "api": "http://e"},
          {"key": "f", "type": 1}
        ],
        "lives": [{"name": "L1", "api": "http://l1.txt"}],
        "parses": [{"name": "p", "url": "http://p"}],
        "flags": ["qq"],
        "hosts": ["a.com=1.2.3.4"],
        "doh": ["https://doh"]
      }
      ''';
      final parsed = ConfigParser.parse(json);
      expect(parsed.config.sites.length, 4);
      expect(parsed.report.total, 6);
      expect(parsed.report.ok, 4);
      expect(parsed.report.skipped, 2);
      expect(parsed.report.degraded, 0);
      expect(parsed.config.sites[2].isJsSpider, isTrue);

      final a = parsed.config.sites[0];
      expect(a.name, 'A 站');
      expect(a.displayName, 'A 站');
      expect(a.searchable, 1);
      expect(a.playerType, -1);
      expect(a.timeout, 15);

      final b = parsed.config.sites[1];
      expect(b.searchable, 0);
      expect(b.timeout, 60);

      expect(parsed.config.hosts['a.com'], '1.2.3.4');
      expect(parsed.config.flags, ['qq']);
      expect(parsed.config.lives.length, 1);
      expect(parsed.config.lives.first.timeout, 15);
    });

    test('多仓订阅识别', () {
      const json =
          '{"urls":[{"name":"a","url":"http://a"},{"name":"b","api":"http://b"},"http://c"]}';
      final parsed = ConfigParser.parse(json);
      expect(parsed.multiUrls.length, 3);
      expect(parsed.multiUrls[2].url, 'http://c');
    });

    test('伪装成 image/jpeg 的配置仍按正文识别', () {
      const json = '''
      {
        "spider": "http://cdn.example.com/x.jpg;md5;abc",
        "sites": [{"key": "a", "type": 3, "api": "csp_A"}]
      }
      ''';
      expect(ConfigParser.looksLikeJsonBody(json), isTrue);
      expect(
        ConfigParser.looksLikeJsonBody('\uFEFF  [{"url":"http://a"}]'),
        isTrue,
      );
      expect(
        ConfigParser.looksLikeJsonBody('<html><body>你好</body></html>'),
        isFalse,
      );
      final parsed = ConfigParser.parse(json, baseUrl: 'http://example.com/');
      expect(parsed.config.sites.length, 1);
    });

    test('相对路径：字符串起头 / 单引号 / \$\$\$ 多段都按订阅地址解析', () {
      // qist/tvbox 这类订阅的 ext 会写成 `./lib/token.json$$$./json/a.txt`，
      // 也有 `{'token': './lib/token.json'}` 这种单引号包着的 JSON 串；
      // 只认 `"./` 的话蜘蛛会拿到打不开的相对地址。
      const json = r'''
      {
        "spider":"./jar/x.jar;md5;abc",
        "sites":[
          {"key":"a","type":3,"api":"csp_PushShare","ext":"./lib/token.json$$$./json/a.txt$$$db"},
          {"key":"b","type":3,"api":"csp_Youtube","ext":"{'token': './lib/token.json', 'json': './json/y.json'}"}
        ],
        "lives":[{"name":"l","type":0,"url":"./listx.txt"}]
      }
      ''';
      final parsed = ConfigParser.parse(
        json,
        baseUrl: 'https://cdn.example.com/sub/99188.json',
      );
      expect(
        parsed.config.spider,
        'https://cdn.example.com/sub/jar/x.jar;md5;abc',
      );
      final a = parsed.config.sites.firstWhere((s) => s.key == 'a');
      expect(
        a.ext,
        'https://cdn.example.com/sub/lib/token.json'
        '\$\$\$https://cdn.example.com/sub/json/a.txt'
        '\$\$\$db',
      );
      final b = parsed.config.sites.firstWhere((s) => s.key == 'b');
      expect(
        b.ext,
        "{'token': 'https://cdn.example.com/sub/lib/token.json', "
        "'json': 'https://cdn.example.com/sub/json/y.json'}",
      );
      expect(
        parsed.config.lives.single.url,
        'https://cdn.example.com/sub/listx.txt',
      );
    });

    test('宽松 JSON：注释与尾随逗号', () {
      const json = '''
      {
        // 站点
        "sites": [
          {"key":"a","type":1,"api":"http://a",},
        ],
      }
      ''';
      final parsed = ConfigParser.parse(json);
      expect(parsed.config.sites.length, 1);
    });

    test('宽松 JSON：字符串内裸换行 / 非法转义 / # 注释 / 多余引号', () {
      const json = r'''
      {
        # type1 聚合
        "sites": [
          {"key":"a","type":1,"api":"http://a","ext":{"raw":"第一行
第二行","re":"\d+","js":"\'ok\'\\(x\\)"},"searchable": 0"},
        ],
      }
      ''';
      final parsed = ConfigParser.parse(json);
      expect(parsed.config.sites.length, 1);
      expect(parsed.config.sites.first.searchable, 0);
      expect(parsed.config.sites.first.ext, contains('第一行'));
    });

    test('宽松 JSON：错位引号不误伤字符串内容', () {
      const json =
          '{"sites":[{"key":"a","type":1,"api":"http://a",'
          'style":{"type":"rect","ratio":1.618},'
          '"ext":{"doh":"2606:4700:4700::1001"},"searchable": 0"}]}';
      final parsed = ConfigParser.parse(json);
      final site = parsed.config.sites.single;
      expect(site.searchable, 0);
      expect(site.ext, contains('2606:4700:4700::1001'));
      expect(site.style, contains('rect'));
    });

    test('live 别名：没有 sites 的直播配置也能导入', () {
      const json =
          '{"live":[{"name":"L1","url":"http://l1.m3u8"},{"name":"L2","url":"http://l2.txt"}]}';
      final parsed = ConfigParser.parse(json);
      expect(parsed.config.sites, isEmpty);
      expect(parsed.config.lives.length, 2);
      expect(parsed.config.lives.first.url, 'http://l1.m3u8');
    });

    test('py_ 前缀强制 filterable', () {
      const json =
          '{"sites":[{"key":"py_x","name":"x","type":1,"api":"http://x","filterable":0}]}';
      final parsed = ConfigParser.parse(json);
      expect(parsed.config.sites.first.filterable, 1);
    });

    test('base64 包着的订阅能解出来', () {
      const json = '{"sites":[{"key":"a","type":1,"api":"http://a"}]}';
      final encoded = base64Encode(utf8.encode(json));
      expect(ConfigParser.decodeBase64Payload(encoded), contains('"sites"'));
      final parsed = ConfigParser.parse(encoded);
      expect(parsed.config.sites.length, 1);
    });

    test('直播文本与非 base64 文本保持原样', () {
      const live = '#genre#\nCCTV1,http://a.m3u8';
      expect(ConfigParser.decodeBase64Payload(live), live);
      const plain = 'not-json-random-text';
      expect(ConfigParser.decodeBase64Payload(plain), plain);
    });

    test('潇洒 CBC 自包含格式能解出订阅', () {
      const json = '{"sites":[{"key":"a","type":1,"api":"http://a"}]}';
      final body = cbcSample('a1b2c3', '0123456789abc', json);
      final decoded = ConfigParser.decodeCbcPayload(body);
      expect(decoded, json);
      final parsed = ConfigParser.parse(body);
      expect(parsed.config.sites.length, 1);
    });

    test('CBC 格式不合规时保持原样', () {
      expect(ConfigParser.decodeCbcPayload('zzzz'), 'zzzz');
      // 纯 hex 但没有 `$#key#$` 标记
      final plainHex = List.filled(40, '24').join();
      expect(ConfigParser.decodeCbcPayload(plainHex), plainHex);
      // 密文块长不是 16 的倍数
      final bad = cbcSample('k', '0123456789abc', '{"sites":[]}');
      final truncated = bad.substring(0, bad.length - 6);
      expect(ConfigParser.decodeCbcPayload(truncated), truncated);
    });

    test('图片末尾追加的 base64 订阅能解出', () {
      const json = '{"sites":[{"key":"a","type":3,"api":"csp_A"}]}';
      final b64 = base64.encode(utf8.encode(json));
      // 前面塞一段二进制（模拟 JPEG），base64 只是尾部连续段。
      final body = '\u0000\u0001JFIF\u0000\uFFFF$b64';
      final decoded = ConfigParser.decodeEmbeddedBase64Payload(body);
      expect(decoded, json);
      final parsed = ConfigParser.parse(body);
      expect(parsed.config.sites.length, 1);
    });

    test('图片里没有订阅时保持原样', () {
      const body = '\u0000JFIF\u0000\uFFFFnot-a-subscription';
      expect(ConfigParser.decodeEmbeddedBase64Payload(body), body);
    });

    test('无效配置抛错', () {
      expect(() => ConfigParser.parse('not json'), throwsFormatException);
      expect(() => ConfigParser.parse('{"sites":1}'), throwsFormatException);
    });

    test('根部 headers：数组与单个对象两种写法都能解析', () {
      const listForm = '''
      {
        "headers": [
          {"host": "live.ottiptv.cc", "header": {"User-Agent": "okHttp/1.5", "Referer": "https://live.ottiptv.cc/"}},
          {"host": "mgtv.ottiptv.cc", "header": {"User-Agent": "okHttp/1.5"}}
        ],
        "lives": [{"name": "L1", "url": "http://l1.m3u"}]
      }
      ''';
      final listParsed = ConfigParser.parse(listForm);
      expect(listParsed.config.headers.length, 2);
      expect(listParsed.config.headers.first.host, 'live.ottiptv.cc');
      expect(
        listParsed.config.headers.first.header['Referer'],
        'https://live.ottiptv.cc/',
      );

      const objectForm = '''
      {
        "headers": {"host": "mgtv.ottiptv.cc", "header": {"user-agent": "okHttp/1.5"}},
        "lives": [{"name": "L1", "url": "http://l1.m3u"}]
      }
      ''';
      final objectParsed = ConfigParser.parse(objectForm);
      expect(objectParsed.config.headers.length, 1);
      expect(
        objectParsed.config.headers.single.header['user-agent'],
        'okHttp/1.5',
      );
    });

    test('分组标题不算坏源，空直播线路被忽略', () {
      const json = '''
      {
        "sites": [
          {"key": "1", "name": "--- 1 ---"},
          {"key": "a", "type": 1, "api": "http://a"}
        ],
        "lives": [
          {"name": "空线路"},
          {"name": "L1", "url": "http://l1.m3u"}
        ]
      }
      ''';
      final parsed = ConfigParser.parse(json);
      expect(parsed.config.sites.length, 1);
      expect(parsed.config.lives.length, 1);
      final separator = parsed.report.items.first;
      expect(separator.status, 'SKIP');
      expect(separator.reason, 'SEPARATOR');
    });
  });
}
