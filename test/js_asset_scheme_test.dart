import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/js_spider/js_asset_key.dart';

/// `assets://` 脚本解析。
///
/// 修的是这个真 bug（2026-11-17 12:35:35 日志）：
///
/// ```
/// [E][source] home key=hipy_js_好趣网 type=3 8ms
///   api=assets://bhdc/宝盒/lib/drpy2.min.js
///   error=Invalid argument(s): Unsupported scheme 'assets' in URI
/// ```
///
/// 这类源来自 CatVod 离线包，`assets://` 指向**应用内置**脚本。以前这个地址
/// 被直接丢给 `HttpClient.getUrl`，Dart 不认这个 scheme，于是整个源 8 毫秒
/// 就失败，用户只看到「首页加载失败」。
void main() {
  group('assets:// 脚本路径', () {
    test('普通 http(s) 不被当成内置资产', () {
      expect(bundleAssetKeyOf('https://a.com/x.js'), isNull);
      expect(bundleAssetKeyOf('http://a.com/x.js'), isNull);
      expect(bundleAssetKeyOf('file:///tmp/x.js'), isNull);
    });

    test('assets:// 换算出打包资产键', () {
      expect(
        bundleAssetKeyOf('assets://bhdc/宝盒/lib/drpy2.min.js'),
        'assets/bhdc/宝盒/lib/drpy2.min.js',
      );
    });

    test('clan://localhost/ 是同一个东西的另一种写法', () {
      expect(
        bundleAssetKeyOf('clan://localhost/bhdc/lib/x.js'),
        'assets/bhdc/lib/x.js',
      );
    });

    test('去掉 query 与 ;md5; 校验尾缀', () {
      expect(bundleAssetKeyOf('assets://a/b.js?name=x'), 'assets/a/b.js');
      expect(bundleAssetKeyOf('assets://a/b.js;md5;abc'), 'assets/a/b.js');
    });

    test('前后多余斜杠不影响结果', () {
      expect(bundleAssetKeyOf('assets:///a/b.js'), 'assets/a/b.js');
    });

    test('空串 / 只有前缀 → null', () {
      expect(bundleAssetKeyOf(''), isNull);
      expect(bundleAssetKeyOf('assets://'), isNull);
      expect(bundleAssetKeyOf('clan://localhost/'), isNull);
    });
  });
}
