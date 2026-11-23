import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/core/utils/text_utils.dart';
import 'package:kniephos/models/site_config.dart';

void main() {
  group('TVBus core 解析', () {
    test('LiveBean 保留 core 的引擎与选项', () {
      final bean = LiveBean.fromJson(const {
        'name': 'p2p',
        'url': 'http://example.com/live.json',
        'type': '0',
        'core': {
          'so': 'https://example.com/tvbus.so',
          'auth': 'http://example.com/auth',
          'name': 'user',
          'pass': 'pass',
          'broker': 'https://example.com/broker',
          'domain': 'example.com',
          'resp': 'http://example.com/resp',
          'option': [
            {
              'key': 'dns',
              'values': ['1.1.1.1', ''],
            },
          ],
        },
      });
      expect(bean.core, isNotNull);
      expect(bean.core!.hasEngine, isTrue);
      expect(bean.core!.so, 'https://example.com/tvbus.so');
      expect(bean.core!.options.single.key, 'dns');
      expect(bean.core!.options.single.values, ['1.1.1.1', '']);

      final round = LiveBean.fromJson(bean.toJson());
      expect(round.core, isNotNull);
      expect(round.core!.so, bean.core!.so);
      expect(round.core!.options.single.values, ['1.1.1.1', '']);
    });

    test('core 写成 JSON 字符串也能解析', () {
      final bean = LiveBean.fromJson(const {
        'name': 'p2p',
        'url': 'http://example.com/live.json',
        'type': '0',
        'core': '{"so":"https://example.com/tvbus.so","auth":"http://a"}',
      });
      expect(bean.core!.so, 'https://example.com/tvbus.so');
      expect(bean.core!.auth, 'http://a');
    });
  });

  test('tvbus:// 被认作直播地址', () {
    expect(isLiveUrl('tvbus://abc'), isTrue);
    expect(isLiveUrl('tvbus://abc\$备用'), isTrue);
    expect(isLiveUrl('http://example.com/live.m3u8'), isTrue);
    expect(isLiveUrl('ftp://example.com/a'), isFalse);
  });
}
