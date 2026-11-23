import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/relay/play_speed_meter.dart';

/// 播放下行速率的计量窗口。
///
/// 实测背景（2026-11-17）：详情悬浮层的实时网速读的是 fvp 的
/// `MediaInfo.bitRate`，那是**容器标称码率**，不是实时流量 ——
/// 奥德赛 82.2G 那条 Remux 的 bitRate 读出来是 0，于是右下角的速度
/// 一直不显示。改成在中继 `/play` 里数转发字节。
void main() {
  group('PlaySpeedMeter', () {
    test('没有流量时不显示', () {
      PlaySpeedMeter.instance.reset();
      expect(PlaySpeedMeter.instance.text, '');
      expect(PlaySpeedMeter.instance.bytesPerSecond, 0);
    });

    test('累计字节按时间窗换算成速率', () async {
      final meter = PlaySpeedMeter.instance;
      meter.reset();
      // 先让窗口过去，避免 < _minWindowMs 时直接返回旧值
      await Future<void>.delayed(const Duration(milliseconds: 350));
      meter.add(2 * 1024 * 1024); // 2MB
      final rate = meter.bytesPerSecond;
      expect(rate, greaterThan(0), reason: '有流量就该有速率');
      expect(meter.text, isNotEmpty);
      expect(meter.text, matches(RegExp(r'(MB/s|KB/s|B/s)$')));
    });

    test('reset 清掉上一集的量', () async {
      final meter = PlaySpeedMeter.instance;
      meter.reset();
      await Future<void>.delayed(const Duration(milliseconds: 350));
      meter.add(8 * 1024 * 1024);
      expect(meter.bytesPerSecond, greaterThan(0));
      meter.reset();
      expect(meter.bytesPerSecond, 0);
      expect(meter.flowing, isFalse);
    });

    test('文案单位随量级切换', () async {
      final meter = PlaySpeedMeter.instance;
      // 小流量 → KB/s
      meter.reset();
      await Future<void>.delayed(const Duration(milliseconds: 350));
      meter.add(300 * 1024);
      expect(meter.text, isNotEmpty);
      // 大流量 → MB/s
      meter.reset();
      await Future<void>.delayed(const Duration(milliseconds: 350));
      meter.add(30 * 1024 * 1024);
      expect(meter.text, contains('MB/s'));
    });
  });
}
