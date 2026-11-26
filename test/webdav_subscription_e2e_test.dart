import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/core/net/app_http.dart';
import 'package:kniephos/services/config_parser.dart';

/// 端到端验证：WebDAV 订阅（地址内嵌账号密码）能真实取到并解析。
///
/// 仓库里**不放任何真实凭据**。要跑这条用例，自己准备一个 WebDAV / 坚果云
/// 订阅地址并通过环境变量传入（地址里的账号密码会随 `Uri.userInfo` 一起解析）：
///
/// ```bash
/// MISA_E2E_WEBDAV_URL='https://user%40example.com:app-password@dav.example.com/dav/x.json' \
///   flutter test test/webdav_subscription_e2e_test.dart
/// ```
///
/// 未设置该变量时整条用例跳过，`flutter test` 全量跑不受影响。
void main() {
  final url = const String.fromEnvironment('MISA_E2E_WEBDAV_URL');

  test('取回并解析 WebDAV 订阅', () async {
    final http = AppHttp();
    final res = await http.getText(url);
    expect(res.statusCode, 200);
    expect(res.body.length, greaterThan(100));

    final body = ConfigParser.decodePayload(res.body);
    final parsed = ConfigParser.parse(body, baseUrl: res.url);
    // ignore: avoid_print
    print(
      'sites=${parsed.config.sites.length} '
      'lives=${parsed.config.lives.length} '
      'spider=${parsed.config.spider}',
    );

    // 站点的相对路径（./lib/xxx.json）应按订阅地址解析成绝对地址。
    final resolved = parsed.config.sites
        .where((s) => s.ext.contains('://'))
        .toList();
    // ignore: avoid_print
    print('解析出绝对 ext 的站点：${resolved.length} 个');
  }, skip: url.isEmpty ? '未设置 MISA_E2E_WEBDAV_URL' : null);
}
