import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/state/app_state.dart';

/// CatVod 猫源的 `xxx.js.md5` 导入适配。
///
/// 这类地址在订阅列表里很常见（如「牛二猫源」「潇洒猫源」），但它本身只是
/// 一个 32 位十六进制的 md5 摘要文件，真正的蜘蛛脚本在同目录的 `xxx.js`。
/// 直接按普通订阅导入会拿到一坨 hex，报「不是 TVBox 订阅配置」。
///
/// 实测数据（2026-11）：
///   https://9280.kstore.vip/cat/index.js.md5 → 32 字节 hex
///   https://9280.kstore.vip/cat/index.js     → 6.6 MB 脚本
///   两者 md5 完全一致。
void main() {
  group('识别 .js.md5 猫源地址', () {
    test('标准写法的地址会去掉末尾 .md5', () {
      expect(
        AppState.catJsMd5TargetForTest(
          'https://9280.kstore.vip/cat/index.js.md5',
        ),
        'https://9280.kstore.vip/cat/index.js',
      );
    });

    test('保留查询串', () {
      expect(
        AppState.catJsMd5TargetForTest(
          'https://xiaosage.361123.xyz/index.js.md5?v=2',
        ),
        'https://xiaosage.361123.xyz/index.js?v=2',
      );
    });

    test('保留原始大小写', () {
      expect(
        AppState.catJsMd5TargetForTest('https://a.com/Path/Spider.JS.MD5'),
        'https://a.com/Path/Spider.JS',
      );
    });

    test('http 也支持', () {
      expect(
        AppState.catJsMd5TargetForTest('http://wexfnw/wexfnwdex.js.md5'),
        'http://wexfnw/wexfnwdex.js',
      );
    });

    test('普通订阅地址不误判', () {
      for (final url in [
        'https://gitee.com/cycod/tvbox/raw/master/api.json',
        'http://www.y456y.com',
        'https://8815.kstore.vip/tvbox/wmz',
        'https://15318.kstore.space/easytv.jpg',
        'https://gh-proxy.com/https://raw.githubusercontent.com/x/y/main/z.json',
      ]) {
        expect(
          AppState.catJsMd5TargetForTest(url),
          isNull,
          reason: '$url 不该被当成猫源摘要',
        );
      }
    });

    test('只是 .md5 但不是 .js.md5 时不处理', () {
      expect(
        AppState.catJsMd5TargetForTest('https://a.com/config.json.md5'),
        isNull,
      );
      expect(AppState.catJsMd5TargetForTest('https://a.com/x.md5'), isNull);
    });

    test('非 http(s) 协议不处理', () {
      expect(AppState.catJsMd5TargetForTest('file:///a/b.js.md5'), isNull);
      expect(
        AppState.catJsMd5TargetForTest('clan://localhost/a.js.md5'),
        isNull,
      );
    });

    test('空串与非法地址返回 null', () {
      expect(AppState.catJsMd5TargetForTest(''), isNull);
      expect(AppState.catJsMd5TargetForTest('   '), isNull);
      expect(AppState.catJsMd5TargetForTest('not a url'), isNull);
    });
  });
}
