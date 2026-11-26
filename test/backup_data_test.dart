import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/backup_data.dart';
import 'package:kniephos/services/config_parser.dart';

void main() {
  test('原生备份可以原样解析', () {
    final text = jsonEncode({
      'kind': 'kniephos-backup',
      'version': 1,
      'profiles': [
        {
          'id': 'p1',
          'name': '测试',
          'url': 'https://example.com/a.json',
          'rawJson': '{"sites":[{"key":"a","type":1,"api":"https://a"}]}',
        },
      ],
      'activeProfileId': 'p1',
    });
    final parsed = BackupData.parse(text);
    expect(parsed['kind'], 'kniephos-backup');
    expect((parsed['profiles'] as List).length, 1);
  });

  test('旧版 Win-Box 备份的 userConfig 能转成当前档案', () {
    final text = jsonEncode({
      'app': 'win-box',
      'kind': 'win-box-backup',
      'version': 1,
      'settings': {
        'userConfig': {
          'version': 2,
          'apiUrl': 'https://example.com/sub.json',
          'global': {
            'spider': 'https://example.com/spider.jar',
            'flags': ['qq'],
          },
          'sources': [
            {'key': 'a', 'name': 'A', 'type': 1, 'api': 'https://a'},
            {'key': 'b', 'name': 'B', 'type': 3, 'api': 'csp_B'},
          ],
          'lives': [
            {'name': '直播', 'api': 'https://live.txt', 'type': 0},
          ],
          'parses': [],
          'ui': {'activeSourceKey': 'b'},
        },
        'driveTokens': {'quark': 'cookie=1'},
      },
    });
    final parsed = BackupData.parse(text);
    final profiles = parsed['profiles'] as List;
    expect(profiles.length, 1);
    final raw = jsonDecode((profiles.first as Map)['rawJson'] as String) as Map;
    expect((raw['sites'] as List).length, 2);
    expect(raw['spider'], 'https://example.com/spider.jar');
    expect(parsed['activeSiteKey'], 'b');
    final drives = parsed['driveAccounts'] as List;
    expect(drives.length, 1);
    expect((drives.first as Map)['provider'], 'quark');
  });

  test('直接选 user-config.json 也能导入', () {
    final inner = jsonEncode({
      'version': 2,
      'sources': [
        {'key': 'a', 'name': 'A', 'type': 0, 'api': 'https://a'},
      ],
      'lives': [],
    });
    final text = jsonEncode({'user-config': inner});
    final parsed = BackupData.parse(text);
    final profiles = parsed['profiles'] as List;
    expect(profiles.length, 1);
  });

  test('备份版本高于当前会拒绝', () {
    final text = jsonEncode({
      'kind': 'kniephos-backup',
      'version': 99,
      'profiles': [],
    });
    expect(() => BackupData.parse(text), throwsFormatException);
  });

  test('合并导出按 key 去重，并回填不同档案的 jar', () {
    final one = ConfigParser.parse(
      jsonEncode({
        'spider': 'https://a/spider.jar',
        'sites': [
          {'key': 'same', 'name': 'S1', 'type': 1, 'api': 'https://a'},
          {'key': 'only1', 'name': 'O1', 'type': 1, 'api': 'https://a'},
        ],
        'lives': [
          {'name': 'L', 'api': 'https://l.txt', 'type': 0},
        ],
        'flags': ['qq'],
      }),
    ).config;
    final two = ConfigParser.parse(
      jsonEncode({
        'spider': 'https://b/spider.jar',
        'sites': [
          {'key': 'same', 'name': 'S2', 'type': 1, 'api': 'https://b'},
          {'key': 'only2', 'name': 'O2', 'type': 1, 'api': 'https://b'},
        ],
        'lives': [
          {'name': 'L', 'api': 'https://l.txt', 'type': 0},
        ],
        'flags': ['iqiyi'],
      }),
    ).config;
    final merged = ConfigParser.mergeForExport([one, two]);
    expect(merged.sites.map((e) => e.key), ['same', 'only1', 'only2']);
    expect(merged.sites.first.jar, isEmpty);
    expect(merged.sites[2].jar, 'https://b/spider.jar');
    expect(merged.lives.length, 1);
    expect(merged.flags, containsAll(['qq', 'iqiyi']));
  });
}
