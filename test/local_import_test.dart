import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/local_import_service.dart';
import 'package:path/path.dart' as p;

void main() {
  group('本地包路径改写', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('kniephos-pkg-');
      File(p.join(root.path, 'spider.jar'))
          .writeAsBytesSync([0x50, 0x4b, 1, 2]);
      File(p.join(root.path, 'logo.png')).writeAsBytesSync([1, 2, 3]);
      File(p.join(root.path, 'ext', 'list.json')).createSync(recursive: true);
      File(p.join(root.path, 'ext', 'list.json')).writeAsStringSync('[]');
      File(p.join(root.path, 'js', 'x.js')).createSync(recursive: true);
      File(p.join(root.path, 'js', 'x.js')).writeAsStringSync('x');
    });

    tearDown(() {
      root.deleteSync(recursive: true);
    });

    test('相对路径 / clan / assets / ext 都改写成 file://', () {
      final text = jsonEncode({
        'spider': 'spider.jar;md5;abc',
        'logo': 'logo.png',
        'sites': [
          {
            'key': 'a',
            'name': 'A',
            'type': 3,
            'api': 'csp_A',
            'jar': './spider.jar',
            'ext': './ext/list.json',
          },
          {
            'key': 'b',
            'name': 'B',
            'type': 3,
            'api': 'clan://localhost/my_pkg/spider.jar',
          },
          {'key': 'c', 'name': 'C', 'type': 3, 'api': 'assets://js/x.js'},
          {
            'key': 'd',
            'name': 'D',
            'type': 3,
            'api': 'https://a.test/x.js',
            'ext': {'a': 1},
          },
        ],
      });
      final rewritten = LocalImportService.rewriteLocalPaths(text, root.path);
      final map = jsonDecode(rewritten) as Map<String, dynamic>;

      expect(map['spider'], startsWith('file://'));
      expect(map['spider'], endsWith('spider.jar;md5;abc'));
      expect(map['logo'], startsWith('file://'));
      expect(map['logo'], endsWith('logo.png'));

      final sites = (map['sites'] as List).cast<Map<String, dynamic>>();
      expect(sites[0]['jar'], startsWith('file://'));
      expect(sites[0]['jar'], endsWith('spider.jar'));
      expect(sites[0]['ext'], startsWith('file://'));
      expect(sites[0]['ext'], endsWith('list.json'));
      expect(sites[1]['api'], startsWith('file://'));
      expect(sites[1]['api'], endsWith('spider.jar'));
      expect(sites[2]['api'], startsWith('file://'));
      expect(sites[2]['api'], endsWith('x.js'));
      expect(sites[3]['api'], 'https://a.test/x.js');
      expect(sites[3]['ext'], isA<Map>());
    });

    test('包内不存在的引用保持原样', () {
      final text = jsonEncode({
        'spider': 'missing.jar',
        'sites': [
          {'key': 'a', 'name': 'A', 'type': 3, 'api': './missing.py'},
        ],
      });
      final map = jsonDecode(
        LocalImportService.rewriteLocalPaths(text, root.path),
      ) as Map;
      expect(map['spider'], 'missing.jar');
      expect((map['sites'] as List).first['api'], './missing.py');
    });

    test(r'ext 的 $线路名 后缀保留，前面的路径照常改写', () {
      // 真实离线包（open-js 的 wanpan.js）写法：ext 是「配置地址$线路名」，
      // 脚本自己按 `$` 切开取 order。若不把 `$` 当分隔符，整串会被当成
      // 文件路径 `env.json$闪电` 去找 → 找不到 → 原样退回相对路径 → 404。
      Directory(p.join(root.path, 'config')).createSync(recursive: true);
      File(p.join(root.path, 'config', 'env.json')).writeAsStringSync('{}');
      final text = jsonEncode({
        'sites': [
          {
            'key': 'a',
            'name': '闪电',
            'type': 3,
            'api': './open/wanpan.js',
            'ext': r'./config/env.json$闪电',
          },
          {
            'key': 'b',
            'name': '至臻',
            'type': 3,
            'api': './open/wanpan.js',
            'ext': r'./config/env.json$至臻',
          },
          {
            'key': 'c',
            'name': '无后缀',
            'type': 3,
            'api': './open/wanpan.js',
            'ext': './config/env.json',
          },
        ],
      });
      final map = jsonDecode(
        LocalImportService.rewriteLocalPaths(text, root.path),
      ) as Map<String, dynamic>;
      final sites = (map['sites'] as List).cast<Map<String, dynamic>>();

      for (final site in sites) {
        expect(
          site['ext'],
          startsWith('file://'),
          reason: '${site['name']} 的 ext 必须改写成本地地址',
        );
      }
      expect(sites[0]['ext'], endsWith(r'$闪电'));
      expect(sites[1]['ext'], endsWith(r'$至臻'));
      expect(sites[2]['ext'], endsWith('env.json'));
      expect(sites[2]['ext'], isNot(contains(r'$')));
    });

    test(r'$ 出现在结尾时不当作分隔符', () {
      Directory(p.join(root.path, 'config')).createSync(recursive: true);
      File(p.join(root.path, 'config', 'env.json')).writeAsStringSync('{}');
      final text = jsonEncode({
        'sites': [
          {
            'key': 'a',
            'name': 'A',
            'type': 3,
            'api': './open/x.js',
            'ext': './config/env.json\$',
          },
        ],
      });
      final map = jsonDecode(
        LocalImportService.rewriteLocalPaths(text, root.path),
      ) as Map<String, dynamic>;
      final ext = (map['sites'] as List).first['ext'] as String;
      expect(ext, startsWith('file://'));
      expect(ext, endsWith(r'$'));
    });
  });

  group('本地包订阅 JSON 查找', () {
    test('优先 config.json，并支持子目录', () {
      final root = Directory.systemTemp.createTempSync('kniephos-find-');
      try {
        File(p.join(root.path, 'manifest.json'))
            .writeAsStringSync('{"name":"x"}');
        final sub = Directory(p.join(root.path, 'local'))
          ..createSync(recursive: true);
        File(p.join(sub.path, 'config.json')).writeAsStringSync('{"sites":[]}');
        final found = LocalImportService.findSubscriptionJson(root);
        expect(found, isNotNull);
        expect(p.basename(found!.path), 'config.json');
      } finally {
        root.deleteSync(recursive: true);
      }
    });

    test('没有 sites / urls / lives 的 JSON 不误选', () {
      final root = Directory.systemTemp.createTempSync('kniephos-find-');
      try {
        File(p.join(root.path, 'version.json'))
            .writeAsStringSync('{"version":1}');
        expect(LocalImportService.findSubscriptionJson(root), isNull);
      } finally {
        root.deleteSync(recursive: true);
      }
    });
  });
}
