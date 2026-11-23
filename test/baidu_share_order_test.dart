import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/drive/baidu_native.dart';

/// 百度分享的 `shareId` / `uk` 段序在两种壳之间是**相反**的，光看位数分不清。
///
/// 实测（2026-11-14 ~ 11-17 日志）：
///   · 11-14 18:12 成功直链 `fid=3576627086-250528-2373516524948`
///     → `fid` 首段是文件所有者的 uk，存在 10 位 uk；
///   · 11-14 16:47 成功直链 `fid=1100411320977-250528-…` → 13 位 uk；
///   · 11-17 errno=-7 的描述符 `{"a":"582004336478962"(15位),"c":"1100435471011"(13位)}`。
/// 所以取链时两种顺序都要试：第一次 -7 换过来再打一次。
void main() {
  group('百度 shareId/uk 段序', () {
    test('两种顺序都会给出，原序优先', () {
      final orders = baiduShareIdOrders('582004336478962', '1100435471011');
      expect(orders.length, 2);
      expect(orders[0].shareId, '582004336478962');
      expect(orders[0].uk, '1100435471011');
      expect(orders[1].shareId, '1100435471011');
      expect(orders[1].uk, '582004336478962');
    });

    test('两段相同时不重复请求', () {
      final orders = baiduShareIdOrders('123456', '123456');
      expect(orders.length, 1);
    });
  });

  group('errno 文案', () {
    test('-7 指向段序而不是「分享已删」', () {
      final text = baiduErrnoText(-7);
      expect(text, contains('段序'));
      expect(text, isNot(contains('分享不存在')));
    });

    test('其它常见 errno 保持原义', () {
      expect(baiduErrnoText(-9), contains('提取码'));
      expect(baiduErrnoText(-6), contains('登录态'));
      expect(baiduErrnoText(-20), contains('验证码'));
      expect(baiduErrnoText(116), contains('分享不存在'));
    });
  });

  group('嵌套信封的取链路径', () {
    test('解析出 shareId/uk 后两种顺序都能拿到', () {
      final inner = <String, String>{
        'a': '271762599896626',
        'b': '01 4K.mkv',
        'c': '3576627086',
        'd': '10420030909',
        'e': 'vlOn10c2a5NjfkUUh4NvdA',
        'f': 'wogg',
      };
      final raw = base64Encode(
        utf8.encode(jsonEncode(<String, String>{
          'a': 'baidu',
          'b': jsonEncode(inner),
        })),
      );
      final file = extractBaiduSharedFile(raw);
      expect(file, isNotNull);
      final orders = baiduShareIdOrders(file!.shareId, file.uk);
      expect(
        orders.map((o) => '${o.shareId}/${o.uk}').toSet(),
        <String>{
          '271762599896626/3576627086',
          '3576627086/271762599896626',
        },
      );
    });
  });
}
