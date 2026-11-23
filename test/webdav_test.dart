import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/core/net/proxy_runtime.dart';
import 'package:kniephos/models/dav.dart';
import 'package:kniephos/services/local_store.dart';
import 'package:kniephos/services/webdav/dav.dart';
import 'package:kniephos/services/webdav/dav_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('基础拼接', () {
    test('normalizeDavBase 去空白与尾斜杠', () {
      expect(normalizeDavBase(' https://host:5244/dav/// '), 'https://host:5244/dav');
      expect(normalizeDavBase(''), '');
    });

    test('davJoin 逐段编码中文与空格', () {
      expect(davJoin('https://host/dav/', '/电影/流浪 地球.mp4'), 'https://host/dav/%E7%94%B5%E5%BD%B1/%E6%B5%81%E6%B5%AA%20%E5%9C%B0%E7%90%83.mp4');
      expect(davJoin('https://host/dav', '/'), 'https://host/dav');
      expect(davJoin('https://host/dav', ''), 'https://host/dav');
    });

    test('davBasicAuth 无用户名给空串', () {
      expect(davBasicAuth('', 'x'), '');
      expect(davBasicAuth('alice', 'p@ss:word'), 'Basic ${base64Encode(utf8.encode('alice:p@ss:word'))}');
    });

    test('davParentPath', () {
      expect(davParentPath('/a/b'), '/a');
      expect(davParentPath('/a/b/'), '/a');
      expect(davParentPath('/a'), '/');
      expect(davParentPath('/'), '/');
      expect(davParentPath(''), '/');
    });

    test('局域网 / 私有地址不走远程代理', () {
      expect(ProxyRuntime.isPrivateHost('192.168.1.5'), isTrue);
      expect(ProxyRuntime.isPrivateHost('10.0.0.2'), isTrue);
      expect(ProxyRuntime.isPrivateHost('172.16.3.4'), isTrue);
      expect(ProxyRuntime.isPrivateHost('172.31.3.4'), isTrue);
      expect(ProxyRuntime.isPrivateHost('172.32.3.4'), isFalse);
      expect(ProxyRuntime.isPrivateHost('nas'), isTrue);
      expect(ProxyRuntime.isPrivateHost('localhost'), isTrue);
      expect(ProxyRuntime.isPrivateHost('dav.jianguoyun.com'), isFalse);
    });
  });

  group('PROPFIND 解析', () {
    const xml = '<?xml version="1.0" encoding="utf-8"?>'
        '<d:multistatus xmlns:d="DAV:">'
        '<d:response>'
        '<d:href>/dav/</d:href>'
        '<d:propstat><d:prop><d:displayname>dav</d:displayname>'
        '<d:resourcetype><d:collection/></d:resourcetype></d:prop>'
        '<d:status>HTTP/1.1 200 OK</d:status></d:propstat>'
        '</d:response>'
        '<d:response>'
        '<d:href>/dav/%E7%94%B5%E5%BD%B1/</d:href>'
        '<d:propstat><d:prop><d:displayname>电影</d:displayname>'
        '<d:resourcetype><d:collection/></d:resourcetype></d:prop>'
        '<d:status>HTTP/1.1 200 OK</d:status></d:propstat>'
        '</d:response>'
        '<d:response>'
        '<d:href>/dav/a%20b.mp4</d:href>'
        '<d:propstat><d:prop><d:displayname>a b.mp4</d:displayname>'
        '<d:getcontentlength>1048576</d:getcontentlength>'
        '<d:getlastmodified>Wed, 01 Oct 2025 10:00:00 GMT</d:getlastmodified>'
        '<d:resourcetype/></d:prop>'
        '<d:status>HTTP/1.1 200 OK</d:status></d:propstat>'
        '<d:propstat><d:prop><d:getcontentlength>0</d:getcontentlength></d:prop>'
        '<d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>'
        '</d:response>'
        '</d:multistatus>';

    test('解析目录与文件，取 200 那份 propstat', () {
      final rows = parsePropfind(xml);
      expect(rows.length, 3);
      expect(rows[0].isDir, isTrue);
      expect(rows[0].displayName, 'dav');
      expect(rows[1].isDir, isTrue);
      expect(rows[1].displayName, '电影');
      expect(rows[2].isDir, isFalse);
      expect(rows[2].size, 1048576);
      expect(rows[2].mtime, 'Wed, 01 Oct 2025 10:00:00 GMT');
      expect(rows[2].href, '/dav/a%20b.mp4');
    });

    test('容错：空串与坏 XML 返回空数组', () {
      expect(parsePropfind(''), isEmpty);
      expect(parsePropfind('<not-xml'), isEmpty);
      expect(parsePropfind('<root/>'), isEmpty);
    });

    test('hrefToPath 相对/绝对 href 都按基址解码', () {
      expect(hrefToPath('/dav/a%20b.mp4', 'https://host/dav'), '/dav/a b.mp4');
      expect(hrefToPath('https://host/dav/%E7%94%B5%E5%BD%B1/', 'https://host/dav'), '/dav/电影/');
      expect(hrefToPath('a.mp4', 'https://host/dav'), '/dav/a.mp4');
    });

    test('基址自带路径的剥离', () {
      expect(davBasePath('https://host:5244/dav/'), '/dav');
      expect(davBasePath('https://host:5244/'), '');
      expect(stripDavBase('/dav/movie/a.mp4', '/dav'), '/movie/a.mp4');
      expect(stripDavBase('/dav', '/dav'), '/');
      expect(stripDavBase('/movie/a.mp4', ''), '/movie/a.mp4');
    });
  });

  group('播放与展示辅助', () {
    test('wrapDavPlayUrl 带 url 与 dav 参数', () {
      final wrapped = wrapDavPlayUrl('http://127.0.0.1:9978/', 'https://host/dav/a b.mp4', 'srv-1');
      final uri = Uri.parse(wrapped);
      expect(uri.path, '/play');
      expect(uri.queryParameters['url'], 'https://host/dav/a b.mp4');
      expect(uri.queryParameters['dav'], 'srv-1');
    });

    test('wrapDavPlayUrl 缺中继或服务器 id 时原样返回', () {
      expect(wrapDavPlayUrl('', 'https://host/a.mp4', 'srv'), 'https://host/a.mp4');
      expect(wrapDavPlayUrl('http://127.0.0.1:9978', 'https://host/a.mp4', ''), 'https://host/a.mp4');
    });

    test('内联可播判定', () {
      expect(isDavInlinePlayable('a.MP4'), isTrue);
      expect(isDavInlinePlayable('a.m3u8'), isTrue);
      expect(isDavInlinePlayable('a.mkv'), isFalse);
      expect(looksVideo('a.MKV'), isTrue);
      expect(looksVideo('a.jpg'), isFalse);
    });

    test('大小展示', () {
      expect(davSizeLabel(0), '');
      expect(davSizeLabel(512), '512 B');
      expect(davSizeLabel(1536), '1.5 KB');
      expect(davSizeLabel(1048576), '1.0 MB');
    });

    test('DavServer JSON 往返', () {
      const server = DavServer(id: 'id1', name: 'nas', url: 'https://host/dav', username: 'u', password: 'p');
      final back = DavServer.fromJson(server.toJson());
      expect(back.id, 'id1');
      expect(back.name, 'nas');
      expect(back.url, 'https://host/dav');
      expect(back.username, 'u');
      expect(back.password, 'p');
    });
  });

  group('DavService 同步读写', () {
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      HttpOverrides.global = null;
      SharedPreferences.setMockInitialValues({});
    });

    test('同步文件：GET 404 → PUT（自动建目录）→ GET 读回', () async {
      final store = await LocalStore.create();
      final service = DavService(store);
      final files = <String, String>{};
      final dirs = <String>{'/dav'};
      final log = <String>[];
      String? auth;
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((req) async {
        log.add('${req.method} ${req.uri.path}');
        auth = req.headers.value(HttpHeaders.authorizationHeader) ?? auth;
        final path = req.uri.path;
        if (req.method == 'MKCOL') {
          // 真实服务器把带/不带尾斜杠视为同一集合，这里同样归一。
          final dir = path.replaceAll(RegExp(r'/+$'), '');
          if (dirs.contains(dir)) {
            req.response.statusCode = 405;
          } else {
            dirs.add(dir);
            req.response.statusCode = 201;
          }
          await req.response.close();
          return;
        }
        if (req.method == 'PUT') {
          final cut = path.lastIndexOf('/');
          final parent = cut <= 0 ? '' : path.substring(0, cut);
          final body = await utf8.decoder.bind(req).join();
          if (!dirs.contains(parent)) {
            req.response.statusCode = 409;
          } else {
            files[path] = body;
            req.response.statusCode = 201;
          }
          await req.response.close();
          return;
        }
        if (req.method == 'GET') {
          final body = files[path];
          if (body == null) {
            req.response.statusCode = 404;
          } else {
            req.response.write(body);
          }
          await req.response.close();
          return;
        }
        req.response.statusCode = 405;
        await req.response.close();
      });
      try {
        final saved = await service.save(
          DavServer(
            id: '',
            name: 'local',
            url: 'http://127.0.0.1:${upstream.port}/dav',
            username: 'alice',
            password: 'pw',
          ),
        );
        expect(await service.getText(saved.id, '/MisaTV/sync.json'), isNull);
        await service.putText(saved.id, '/MisaTV/sync.json', '{"ok":1}');
        expect(files['/dav/MisaTV/sync.json'], '{"ok":1}');
        expect(
          await service.getText(saved.id, '/MisaTV/sync.json'),
          '{"ok":1}',
        );
        expect(log, contains('MKCOL /dav/MisaTV/'));
        expect(auth, davBasicAuth('alice', 'pw'));
      } finally {
        await upstream.close(force: true);
      }
    });
  });

  group('DavService 浏览', () {
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      // flutter_test 默认把 HttpClient 换成「一律失败」的桩；这里要连本机测试服务器。
      HttpOverrides.global = null;
      SharedPreferences.setMockInitialValues({});
    });

    test('PROPFIND 请求头、基址路径剥离与排序', () async {
      final store = await LocalStore.create();
      final service = DavService(store);
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      String? method;
      String? depth;
      String? auth;
      String? body;
      upstream.listen((req) async {
        method = req.method;
        depth = req.headers.value('depth');
        auth = req.headers.value(HttpHeaders.authorizationHeader);
        body = await utf8.decoder.bind(req).join();
        req.response.headers.set('content-type', 'application/xml; charset=utf-8');
        req.response.write('<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">'
            '<d:response><d:href>/dav/</d:href><d:propstat><d:prop>'
            '<d:displayname>dav</d:displayname><d:resourcetype><d:collection/></d:resourcetype>'
            '</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>'
            '<d:response><d:href>/dav/%E7%94%B5%E5%BD%B1/</d:href><d:propstat><d:prop>'
            '<d:displayname>电影</d:displayname><d:resourcetype><d:collection/></d:resourcetype>'
            '</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>'
            '<d:response><d:href>/dav/a%20b.mp4</d:href><d:propstat><d:prop>'
            '<d:displayname>a b.mp4</d:displayname><d:getcontentlength>2048</d:getcontentlength>'
            '<d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>'
            '</d:multistatus>');
        await req.response.close();
      });
      try {
        final saved = await service.save(
          DavServer(
            id: '',
            name: '',
            url: 'http://127.0.0.1:${upstream.port}/dav/',
            username: 'alice',
            password: 'pw',
          ),
        );
        expect(saved.id.isNotEmpty, isTrue);
        expect(saved.name, '127.0.0.1');
        expect(saved.url.endsWith('/dav'), isTrue);
        final result = await service.browse(saved.id);
        expect(method, 'PROPFIND');
        expect(depth, '1');
        expect(auth, davBasicAuth('alice', 'pw'));
        expect(body == null ? '' : body!, contains('propfind'));
        expect(result.path, '/');
        expect(result.entries.map((e) => e.name).toList(), ['电影', 'a b.mp4']);
        expect(result.entries.first.isDir, isTrue);
        expect(result.entries.last.size, 2048);
        expect(result.entries.last.url, 'http://127.0.0.1:${upstream.port}/dav/a%20b.mp4');
        await service.remove(saved.id);
        expect(service.servers, isEmpty);
      } finally {
        await upstream.close(force: true);
      }
    });

    test('非法协议地址拒绝保存', () async {
      final store = await LocalStore.create();
      final service = DavService(store);
      await expectLater(
        service.save(const DavServer(id: '', name: 'x', url: 'ftp://host/dav')),
        throwsA(isA<DavException>()),
      );
      expect(service.byId('missing'), isNull);
      expect(service.authHeader('missing'), '');
    });
  });
}
