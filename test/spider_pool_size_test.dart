import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/models/user_data.dart';

/// JAR 源并发相关的设置语义。
///
/// 背景：`JarSpiderService` 每个源原本写死最多 3 只常驻 JVM，池满后会把新请求
/// 塞进正在工作的 JVM 管道里串行排队——前面的请求一超时，整只进程被杀，排队
/// 的其它源一起失败，表现为「订阅里 JAR 源一多就丢结果、越搜越慢」。
///
/// 现在池大小可由用户调整（1–8），这里守着取值的夹紧与持久化。
void main() {
  group('spiderPoolSize 取值', () {
    test('默认 3，与引入设置前的行为一致', () {
      expect(const PlayerSettings().spiderPoolSize, 3);
    });

    test('copyWith 会把越界值夹到 1–8', () {
      final base = const PlayerSettings();
      expect(base.copyWith(spiderPoolSize: 0).spiderPoolSize, 1);
      expect(base.copyWith(spiderPoolSize: -5).spiderPoolSize, 1);
      expect(base.copyWith(spiderPoolSize: 9).spiderPoolSize, 8);
      expect(base.copyWith(spiderPoolSize: 999).spiderPoolSize, 8);
    });

    test('合法值原样保留', () {
      final base = const PlayerSettings();
      for (final v in [1, 2, 3, 4, 5, 6, 7, 8]) {
        expect(base.copyWith(spiderPoolSize: v).spiderPoolSize, v);
      }
    });

    test('不传时保持原值', () {
      final custom = const PlayerSettings().copyWith(spiderPoolSize: 6);
      expect(custom.copyWith(keepSpiderHosts: true).spiderPoolSize, 6);
    });
  });

  group('spiderPoolSize 持久化', () {
    test('JSON 往返保留', () {
      final settings = const PlayerSettings().copyWith(spiderPoolSize: 7);
      final restored = PlayerSettings.fromJson(settings.toJson());
      expect(restored.spiderPoolSize, 7);
    });

    test('旧档案缺字段时回落到 3', () {
      final json = const PlayerSettings().toJson()..remove('spiderPoolSize');
      expect(PlayerSettings.fromJson(json).spiderPoolSize, 3);
    });

    test('坏值（0 / 负数 / 超大）读取时也被夹紧', () {
      final json = const PlayerSettings().toJson();
      expect(
        PlayerSettings.fromJson({...json, 'spiderPoolSize': 0}).spiderPoolSize,
        1,
      );
      expect(
        PlayerSettings.fromJson({...json, 'spiderPoolSize': 99}).spiderPoolSize,
        8,
      );
    });
  });
}
