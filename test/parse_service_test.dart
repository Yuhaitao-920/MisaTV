import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/core/net/app_http.dart';
import 'package:kniephos/models/site_config.dart';
import 'package:kniephos/services/parse/parse_service.dart';

void main() {
  test('buildParseUrl：占位、直接拼接、?url=', () {
    expect(
      ParseService.buildParseUrl('https://p.test/jx/{url}', 'https://a.test/x'),
      'https://p.test/jx/${Uri.encodeQueryComponent('https://a.test/x')}',
    );
    expect(
      ParseService.buildParseUrl('https://p.test/jx/?', 'https://a.test/x'),
      'https://p.test/jx/?https://a.test/x',
    );
    expect(
      ParseService.buildParseUrl('https://p.test/jx', 'https://a.test/x'),
      'https://p.test/jx?url=${Uri.encodeQueryComponent('https://a.test/x')}',
    );
    expect(
      ParseService.buildParseUrl('https://p.test/jx?a=1', 'https://a.test/x'),
      'https://p.test/jx?a=1&url=${Uri.encodeQueryComponent('https://a.test/x')}',
    );
  });

  test('extractParseResult：JSON / 嵌套 data / JSONP / header', () {
    final json = ParseService.extractParseResult(
      jsonEncode({
        'code': 200,
        'data': {
          'url': 'https://cdn.test/a.m3u8',
          'header': {'Referer': 'https://a.test/'},
        },
      }),
    );
    expect(json?.url, 'https://cdn.test/a.m3u8');
    expect(json?.headers['Referer'], 'https://a.test/');

    final jsonp = ParseService.extractParseResult(
      'cb({"url":"https://cdn.test/b.m3u8"});',
    );
    expect(jsonp?.url, 'https://cdn.test/b.m3u8');

    final bare = ParseService.extractParseResult('https://cdn.test/c.mp4');
    expect(bare?.url, 'https://cdn.test/c.mp4');
  });

  test('extractParseResult：只找到页面地址时不返回', () {
    final hit = ParseService.extractParseResult(
      jsonEncode({'page': 'https://a.test/detail/1.html'}),
    );
    expect(hit, isNull);
  });

  test('isMediaUrl 与 relay 地址还原', () {
    expect(ParseService.isMediaUrl('https://a.test/x.m3u8?token=1'), isTrue);
    expect(ParseService.isMediaUrl('https://a.test/x.html'), isFalse);
    expect(
      ParseService.unwrapRelayUrl(
        'http://127.0.0.1:9978/play?url=https%3A%2F%2Fa.test%2Fx.m3u8',
      ),
      'https://a.test/x.m3u8',
    );
  });

  test('resolve：JSON 接口命中；失败后网页嗅探兜底', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      if (req.uri.path == '/jx') {
        final target = req.uri.queryParameters['url'] ?? '';
        req.response.write(
          jsonEncode({'url': 'https://cdn.test/from-json.m3u8'}),
        );
        await req.response.close();
        expect(target, isNotEmpty);
        return;
      }
      if (req.uri.path == '/page') {
        req.response.write('<html>page</html>');
        await req.response.close();
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    });

    final http = AppHttp();
    final service = ParseService(http);
    final parses = [
      ParseBean(name: 'jx', url: 'http://127.0.0.1:${server.port}/jx', type: 1),
      ParseBean(
        name: 'page',
        url: 'http://127.0.0.1:${server.port}/page',
        type: 0,
      ),
    ];
    final hit = await service.resolve(parses, 'https://a.test/play/1');
    expect(hit?.url, 'https://cdn.test/from-json.m3u8');
    expect(hit?.via, contains('json:jx'));

    final failed = [
      ParseBean(
        name: 'page',
        url: 'http://127.0.0.1:${server.port}/page',
        type: 0,
      ),
    ];
    final sniffed = await service.resolve(
      failed,
      'https://a.test/play/1',
      sniff: (url) async => const SniffHit(url: 'https://cdn.test/sniff.m3u8'),
    );
    expect(sniffed?.url, 'https://cdn.test/sniff.m3u8');
    expect(sniffed?.via, contains('sniff'));

    http.close();
    await server.close(force: true);
  });
}
