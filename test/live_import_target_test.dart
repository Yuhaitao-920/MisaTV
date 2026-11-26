import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/models/site_config.dart';
import 'package:kniephos/state/app_state.dart';

/// 本地 TXT / M3U 直播源的导入语义。
///
/// 以前导入本地直播文件只会变成一条独立线路（`localLives`），多份文件就散成
/// 一堆线路；现在要和点播 PY 源一样，可以并入已有直播订阅或新建订阅。
/// 这里守两件事：线路能正确并入订阅 JSON，以及刷新订阅时不会被远端内容冲掉。
void main() {
  ConfigProfile profileOf(
    String rawJson, {
    List<String> addedLiveKeys = const [],
  }) {
    return ConfigProfile(
      id: 'p1',
      name: '直播订阅A',
      url: 'https://example.com/live.json',
      rawJson: rawJson,
      importedAt: DateTime(2026),
      addedLiveKeys: addedLiveKeys,
    );
  }

  group('订阅刷新保留本地并入的直播线路', () {
    test('远端没有的本地线路会被补回', () {
      final existing = profileOf(
        jsonEncode({
          'lives': [
            {'name': '远端台', 'url': 'https://example.com/a.txt'},
            {'name': '本地台', 'url': 'file:///local/b.txt'},
          ],
        }),
        addedLiveKeys: const ['本地台|file:///local/b.txt'],
      );
      final incoming = jsonEncode({
        'lives': [
          {'name': '远端台', 'url': 'https://example.com/a.txt'},
        ],
      });
      final merged = jsonDecode(
        AppState.mergeAddedLives(incoming, existing, existing.addedLiveKeys),
      ) as Map<String, dynamic>;
      final lives = merged['lives'] as List;
      expect(lives.length, 2);
      expect(
        lives.any(
          (e) =>
              (e as Map)['name'] == '本地台' && e['url'] == 'file:///local/b.txt',
        ),
        isTrue,
      );
    });

    test('远端也有同名同地址时以本地版本为准', () {
      final existing = profileOf(
        jsonEncode({
          'lives': [
            {'name': '本地台', 'url': 'file:///local/b.txt', 'timeout': 15},
          ],
        }),
        addedLiveKeys: const ['本地台|file:///local/b.txt'],
      );
      final incoming = jsonEncode({
        'lives': [
          {'name': '本地台', 'url': 'file:///local/b.txt', 'timeout': 99},
        ],
      });
      final merged = jsonDecode(
        AppState.mergeAddedLives(incoming, existing, existing.addedLiveKeys),
      ) as Map<String, dynamic>;
      final lives = merged['lives'] as List;
      expect(lives.length, 1);
      expect((lives.single as Map)['timeout'], 15);
    });

    test('兼容只写 live 字段的订阅', () {
      final existing = profileOf(
        jsonEncode({
          'live': [
            {'name': '本地台', 'url': 'file:///local/b.txt'},
          ],
        }),
        addedLiveKeys: const ['本地台|file:///local/b.txt'],
      );
      final incoming = jsonEncode({'live': <dynamic>[]});
      final merged = jsonDecode(
        AppState.mergeAddedLives(incoming, existing, existing.addedLiveKeys),
      ) as Map<String, dynamic>;
      final lives = merged['live'] as List;
      expect(lives.length, 1);
      expect((lives.single as Map)['name'], '本地台');
    });

    test('没有标记为本地新增的线路不会被补回', () {
      final existing = profileOf(
        jsonEncode({
          'lives': [
            {'name': '远端旧台', 'url': 'https://example.com/old.txt'},
          ],
        }),
      );
      final incoming = jsonEncode({'lives': <dynamic>[]});
      final merged = AppState.mergeAddedLives(incoming, existing, const []);
      // 空标记时原样返回，不参与改写。
      expect(merged, incoming);
    });

    test('坏 JSON 一律原样返回，不抛错', () {
      final existing = profileOf('不是 JSON', addedLiveKeys: const ['a|b']);
      expect(
        AppState.mergeAddedLives('也不是 JSON', existing, existing.addedLiveKeys),
        '也不是 JSON',
      );
    });

    test('没有新增记录时不改写原文（刷新不产生无意义变更）', () {
      final existing = profileOf(
        jsonEncode({
          'lives': [
            {'name': '台', 'url': 'https://example.com/a.txt'},
          ],
        }),
        addedLiveKeys: const ['台|https://example.com/a.txt'],
      );
      final incoming = jsonEncode({
        'lives': [
          {'name': '台', 'url': 'https://example.com/a.txt'},
        ],
      });
      // 内容一致时不应改写（保持远端原文，避免每次都记一条快照）。
      final merged = AppState.mergeAddedLives(
        incoming,
        existing,
        existing.addedLiveKeys,
      );
      expect(merged, incoming);
    });
  });

  group('ConfigProfile 的 addedLiveKeys 持久化', () {
    test('JSON 往返保留', () {
      final profile = profileOf(
        jsonEncode({'lives': <dynamic>[]}),
        addedLiveKeys: const ['台A|file:///a.txt', '台B|file:///b.txt'],
      );
      final restored = ConfigProfile.fromJson(
        jsonDecode(jsonEncode(profile.toJson())) as Map<String, dynamic>,
      );
      expect(restored.addedLiveKeys, profile.addedLiveKeys);
    });

    test('缺字段的旧档案回落为空列表', () {
      final restored = ConfigProfile.fromJson({
        'id': 'p1',
        'name': '旧档案',
        'url': '',
        'rawJson': '{}',
        'importedAt': DateTime(2026).toIso8601String(),
      });
      expect(restored.addedLiveKeys, isEmpty);
    });
  });
}
