import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/models/sync_settings.dart';
import 'package:kniephos/services/lan/flow_payload.dart';

/// 设备流转的载荷与设置语义。
void main() {
  group('FlowPayload 序列化', () {
    FlowPayload sample() => const FlowPayload(
      vodName: '龙狱天棺',
      episodeName: '第1集',
      episodeIndex: 0,
      url: 'https://cdn.example.com/a.m3u8',
      fromDevice: '书房电脑',
      flag: '独家1',
      positionMs: 125000,
      headers: {'Referer': 'https://example.com/'},
      pic: 'https://example.com/p.jpg',
      sourceName: '某源',
      sourceKey: 'cat_x',
      vodId: '12345',
      sentAtMs: 1700000000000,
    );

    test('JSON 往返保留全部字段', () {
      final back = FlowPayload.fromJson(sample().toJson());
      final a = sample();
      expect(back.vodName, a.vodName);
      expect(back.episodeName, a.episodeName);
      expect(back.episodeIndex, a.episodeIndex);
      expect(back.url, a.url);
      expect(back.fromDevice, a.fromDevice);
      expect(back.flag, a.flag);
      expect(back.positionMs, a.positionMs);
      expect(back.headers, a.headers);
      expect(back.pic, a.pic);
      expect(back.sourceKey, a.sourceKey);
      expect(back.vodId, a.vodId);
      expect(back.sentAtMs, a.sentAtMs);
    });

    test('缺字段时回落默认值，不抛异常', () {
      final back = FlowPayload.fromJson(const {});
      expect(back.vodName, '');
      expect(back.url, '');
      expect(back.episodeIndex, 0);
      expect(back.headers, isEmpty);
      expect(back.sentAtMs, 0);
    });

    test('headers 不是 Map 时忽略，不崩溃', () {
      final back = FlowPayload.fromJson(const {
        'vodName': 'x',
        'url': 'u',
        'headers': 'not-a-map',
      });
      expect(back.headers, isEmpty);
    });

    test('合成的播放结果带上流转标记与请求头', () {
      final play = sample().toPlayResult();
      expect(play.url, 'https://cdn.example.com/a.m3u8');
      expect(play.headers['Referer'], 'https://example.com/');
      expect(play.flag, '独家1');
    });

    test('flag 为空时用「流转」作为线路名', () {
      final play = const FlowPayload(
        vodName: 'x',
        episodeName: '',
        episodeIndex: 0,
        url: 'u',
        fromDevice: 'd',
      ).toPlayResult();
      expect(play.flag, '流转');
    });
  });

  group('SyncSettings 的流转字段', () {
    test('deviceId 首次生成后保持稳定', () {
      final empty = const SyncSettings();
      final once = empty.ensureDeviceId();
      expect(once.deviceId, isNotEmpty);
      expect(once.deviceId.startsWith('dev-'), isTrue);
      // 已有 id 时不再改动
      expect(once.ensureDeviceId().deviceId, once.deviceId);
    });

    test('不同设备生成的 id 不同', () {
      final a = const SyncSettings().ensureDeviceId().deviceId;
      final b = const SyncSettings().ensureDeviceId().deviceId;
      expect(a, isNot(b));
    });

    test('JSON 往返保留 deviceId', () {
      final settings = const SyncSettings().ensureDeviceId();
      final back = SyncSettings.fromJson(settings.toJson());
      expect(back.deviceId, settings.deviceId);
    });

    test('旧档案缺字段时 deviceId 为空', () {
      final back = SyncSettings.fromJson(const {});
      expect(back.deviceId, '');
    });

    // 流转是**一次性**操作（像投屏），不持久化开关：
    // 设置里不该出现任何「是否开启流转」的字段。
    test('SyncSettings 里没有流转开关', () {
      final json = const SyncSettings().toJson();
      expect(json.containsKey('flowEnabled'), isFalse);
    });
  });
}
