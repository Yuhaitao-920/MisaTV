import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/models/site_config.dart';

/// 订阅里的 `ext` 可能是字符串，也可能是 JSON 对象 / 数组。
///
/// 历史实现用 `json['ext']?.toString()`：对 Map 得到的是 Dart 的
/// `Map.toString()`（`{site: http://x, token: }`），**不是合法 JSON**。
/// 加固壳（`csp_MoggCAT` 的 `Mogg.init` → `JsonParser.parseString`）解析失败后
/// 得到空 JsonObject，`getAsJsonPrimitive("site")` 返回 null → `.getAsString()`
/// NPE，表现为「配置能导入、所有站点 homeContent 全失败」。
void main() {
  group('SourceBean.ext 序列化', () {
    test('字符串 ext 原样保留（既有源行为不变）', () {
      final site = SourceBean.fromJson(<String, dynamic>{
        'key': '玩偶',
        'type': 3,
        'api': 'csp_WoGGGuard',
        'ext': './lib/wogg.json',
      });
      expect(site.ext, './lib/wogg.json');
    });

    test('对象 ext 输出合法 JSON（壳里 JsonParser 能解析）', () {
      final site = SourceBean.fromJson(<String, dynamic>{
        'key': 'P123',
        'type': 3,
        'api': 'csp_MoggCAT',
        'ext': <String, dynamic>{
          'tyitoken': '',
          'dutoken': '',
          'p123token': '',
          'token': '',
          'cookie': '',
          'uccookie': '',
          'site': 'http://666.666291.xyz/',
        },
      });
      // 必须能被 JSON 解析，且键值完整
      final decoded = jsonDecode(site.ext) as Map<String, dynamic>;
      expect(decoded['site'], 'http://666.666291.xyz/');
      expect(decoded.containsKey('cookie'), isTrue);
      expect(decoded.containsKey('uccookie'), isTrue);
      // 不能是 Dart 的 Map.toString()
      expect(site.ext.contains('site:'), isFalse);
      expect(site.ext.startsWith('{'), isTrue);
    });

    test('数组 ext 输出合法 JSON', () {
      final site = SourceBean.fromJson(<String, dynamic>{
        'key': 'x',
        'type': 3,
        'api': 'csp_Y',
        'ext': <dynamic>['a', 'b'],
      });
      expect(jsonDecode(site.ext), <String>['a', 'b']);
    });

    test('缺 ext / null / 纯数字', () {
      expect(
        SourceBean.fromJson(<String, dynamic>{'key': 'k', 'type': 3}).ext,
        '',
      );
      expect(
        SourceBean.fromJson(<String, dynamic>{
          'key': 'k',
          'type': 3,
          'ext': null,
        }).ext,
        '',
      );
      expect(
        SourceBean.fromJson(<String, dynamic>{'key': 'k', 'type': 3, 'ext': 0})
            .ext,
        '0',
      );
    });

    test('空对象 ext 输出 {}，不是 {site: }', () {
      final site = SourceBean.fromJson(<String, dynamic>{
        'key': 'k',
        'type': 3,
        'api': 'csp_Z',
        'ext': <String, dynamic>{},
      });
      expect(site.ext, '{}');
    });
  });

  group('ConfigProfile 相对路径基准', () {
    test('保存实际订阅地址，序列化后用实际地址解析', () {
      final profile = ConfigProfile(
        id: 'p',
        name: 'n',
        url: 'https://clun.top/box.json',
        baseUrl: 'https://mirror.example.com/sub/box.json',
        rawJson: '{}',
        importedAt: DateTime(2026),
      );
      final restored = ConfigProfile.fromJson(profile.toJson());
      expect(restored.baseUrl, 'https://mirror.example.com/sub/box.json');
      expect(
        restored.resolveBaseUrl,
        'https://mirror.example.com/sub/box.json',
      );
    });

    test('旧档案没有 baseUrl 时回落到 url', () {
      final legacy = ConfigProfile.fromJson(<String, dynamic>{
        'id': 'p',
        'url': 'https://clun.top/box.json',
        'rawJson': '{}',
      });
      expect(legacy.baseUrl, isEmpty);
      expect(legacy.resolveBaseUrl, 'https://clun.top/box.json');
    });
  });
}
