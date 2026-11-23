import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/jar_spider/jar_spider.dart';

void main() {
  group('driveShareKey（网盘负缓存 key）', () {
    test('短描述符原样保留，provider 作前缀', () {
      expect(driveShareKey('baidu', ' baidu@abc '), 'baidu|baidu@abc');
    });

    test('超长描述符截断到 96 字符，同一集稳定命中', () {
      final desc = 'baidu@${'A' * 500}';
      final key = driveShareKey('baidu', desc);
      expect(key.length, 'baidu|'.length + 96);
      expect(driveShareKey('baidu', desc), key);
    });

    test('不同 provider 不会互相串', () {
      const id = 'share-params-here';
      expect(driveShareKey('baidu', id), isNot(driveShareKey('uc', id)));
    });
  });
}
