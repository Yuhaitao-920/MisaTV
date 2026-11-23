import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/player/drive_slow_switch.dart';

void main() {
  group('DriveSlowSwitchPolicy', () {
    test('样本足够、持续缓冲且低速时切换', () {
      expect(
        DriveSlowSwitchPolicy.shouldSwitch(
          samples: 4,
          stallSamples: 3,
          lowSpeedSamples: 3,
          isDriveCdn: true,
          isJarSpider: true,
          alreadyRetried: false,
        ),
        isTrue,
      );
    });

    test('只是偶发缓冲不切换', () {
      expect(
        DriveSlowSwitchPolicy.shouldSwitch(
          samples: 4,
          stallSamples: 2,
          lowSpeedSamples: 4,
          isDriveCdn: true,
          isJarSpider: true,
          alreadyRetried: false,
        ),
        isFalse,
      );
    });

    test('速度正常不切换', () {
      expect(
        DriveSlowSwitchPolicy.shouldSwitch(
          samples: 8,
          stallSamples: 0,
          lowSpeedSamples: 0,
          isDriveCdn: true,
          isJarSpider: true,
          alreadyRetried: false,
        ),
        isFalse,
      );
    });

    test('非网盘直链 / 非 JAR / 已重试都不切换', () {
      const base = (
        samples: 8,
        stallSamples: 8,
        lowSpeedSamples: 8,
        alreadyRetried: false,
      );
      expect(
        DriveSlowSwitchPolicy.shouldSwitch(
          samples: base.samples,
          stallSamples: base.stallSamples,
          lowSpeedSamples: base.lowSpeedSamples,
          isDriveCdn: false,
          isJarSpider: true,
          alreadyRetried: base.alreadyRetried,
        ),
        isFalse,
      );
      expect(
        DriveSlowSwitchPolicy.shouldSwitch(
          samples: base.samples,
          stallSamples: base.stallSamples,
          lowSpeedSamples: base.lowSpeedSamples,
          isDriveCdn: true,
          isJarSpider: false,
          alreadyRetried: base.alreadyRetried,
        ),
        isFalse,
      );
      expect(
        DriveSlowSwitchPolicy.shouldSwitch(
          samples: base.samples,
          stallSamples: base.stallSamples,
          lowSpeedSamples: base.lowSpeedSamples,
          isDriveCdn: true,
          isJarSpider: true,
          alreadyRetried: true,
        ),
        isFalse,
      );
    });
  });
}
