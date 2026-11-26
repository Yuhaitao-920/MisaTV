import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/models/xunlei_account.dart';
import 'package:kniephos/services/torrent/xunlei_cloud.dart';

void main() {
  group('迅雷云盘签名', () {
    test('设备签名固定格式与长度', () {
      final sign = xunleiDeviceSign('0123456789abcdef0123456789abcdef');
      expect(sign, startsWith('div101.0123456789abcdef0123456789abcdef'));
      expect(sign.length, 'div101.'.length + 32 + 32);
      expect(RegExp(r'^div101\.[0-9a-f]{64}$').hasMatch(sign), isTrue);
      expect(
        xunleiDeviceSign('0123456789abcdef0123456789abcdef'),
        sign,
        reason: '同一设备号必须得到同一签名',
      );
    });

    test('验证码签名可复现且随毫秒时间戳变化', () {
      const device = '0123456789abcdef0123456789abcdef';
      final first = xunleiCaptchaSign(deviceId: device, nowMs: 1700000000000);
      final second = xunleiCaptchaSign(deviceId: device, nowMs: 1700000000000);
      expect(first.timestamp, '1700000000000');
      expect(first.sign, second.sign);
      expect(first.sign, startsWith('1.'));
      expect(
        RegExp(r'^1\.[0-9a-f]{32}$').hasMatch(first.sign),
        isTrue,
        reason: '最后一轮是 md5，签名主体应为 32 位十六进制',
      );
      final other = xunleiCaptchaSign(deviceId: device, nowMs: 1700000000001);
      expect(other.sign, isNot(first.sign));
    });

    test('登录验证码 meta 按账号形态归类', () {
      expect(xunleiLoginMeta('13800138000'), {'phone_number': '13800138000'});
      expect(xunleiLoginMeta('a@b.com'), {'email': 'a@b.com'});
      expect(xunleiLoginMeta('someuser'), {'username': 'someuser'});
    });

    test('接口动作只保留方法与路径', () {
      expect(
        xunleiAction('POST', 'https://api-pan.xunlei.com/drive/v1/files?x=1'),
        'POST:/drive/v1/files',
      );
      expect(
        xunleiAction('GET', 'https://xluser-ssl.xunlei.com/v1/user/me'),
        'GET:/v1/user/me',
      );
    });
  });

  group('迅雷登录响应解析', () {
    test('密码登录成功：sessionID / 昵称 / 用户号', () {
      final step = parseXunleiLoginResponse({
        'error': 'success',
        'errorCode': '0',
        'sessionID': 'sess-1',
        'nickName': '迅雷用户',
        'userID': 'u-1',
      });
      expect(step.needSms, isFalse);
      expect(step.sessionId, 'sess-1');
      expect(step.nickName, '迅雷用户');
      expect(step.userId, 'u-1');
      expect(step.success, isFalse, reason: '还没换 token，不算完成登录');
    });

    test('review_panel / 1007 / verifyType 都进入短信验证', () {
      final review = parseXunleiLoginResponse({
        'error': 'review_panel',
        'errorCode': '1007',
        'reviewurl':
            'https://i.xunlei.com/xlcaptcha/android.html?creditkey=ck&token=tk',
        'errorDesc': '需要短信验证',
      });
      expect(review.needSms, isTrue);
      expect(review.creditKey, 'ck');
      expect(review.smsToken, 'tk');
      expect(review.reviewUrl, contains('xlcaptcha'));
      expect(review.message, '需要短信验证');

      expect(parseXunleiLoginResponse({'errorCode': '1007'}).needSms, isTrue);
      expect(parseXunleiLoginResponse({'verifyType': 'MEA'}).needSms, isTrue);
    });

    test('普通错误保留可读提示', () {
      final step = parseXunleiLoginResponse({
        'error': 'invalid_account',
        'errorDesc': '账号或密码错误',
      });
      expect(step.needSms, isFalse);
      expect(step.sessionId, '');
      expect(step.message, '账号或密码错误');
    });
  });

  group('迅雷验证链接', () {
    test('query 解析保留 base64 里的加号', () {
      final map = parseXunleiReviewUrl(
        'https://i.xunlei.com/xlcaptcha/android.html?creditkey=abc%2Bdef&token=t%2Bk',
      );
      expect(map['creditkey'], 'abc+def');
      expect(map['token'], 't+k');
    });

    test('补齐 deviceid 时使用 div101 设备签名', () {
      const device = '0123456789abcdef0123456789abcdef';
      final url = xunleiReviewUrlWithDevice(
        'https://i.xunlei.com/xlcaptcha/android.html?creditkey=ck',
        device,
      );
      expect(url, contains('deviceid='));
      expect(
        Uri.decodeQueryComponent(url.split('deviceid=').last),
        startsWith('div101.'),
      );
      expect(
        xunleiReviewUrlWithDevice(url, device),
        url,
        reason: '已有 deviceid 不重复追加',
      );
    });
  });

  group('迅雷登录请求体', () {
    test('字段与设备签名对齐官方抓包', () {
      const device = '0123456789abcdef0123456789abcdef';
      const peer = 'fedcba9876543210fedcba9876543210';
      final body = xunleiLoginBody(
        deviceId: device,
        peerId: peer,
        clientVersion: xunleiLoginClientVersion,
        sdkVersion: xunleiLoginSdkVersion,
      );
      expect(body['appid'], '40');
      expect(body['appName'], 'ANDROID-com.xunlei.downloadprovider');
      expect(body['clientVersion'], '25.0.5.25');
      expect(body['sdkVersion'], '513006');
      expect(body['peerID'], peer);
      expect(body['devicesign'], xunleiDeviceSign(device));
      expect(body['creditkey'], '');
      expect(int.tryParse(body['sequenceNo'] as String), isNotNull);
    });

    test('短信登录把 creditkey 写进请求体', () {
      final body = xunleiLoginBody(
        deviceId: '0123456789abcdef0123456789abcdef',
        peerId: 'fedcba9876543210fedcba9876543210',
        clientVersion: xunleiSmsClientVersion,
        sdkVersion: xunleiSmsSdkVersion,
        creditKey: 'ck',
      );
      expect(body['creditkey'], 'ck');
      expect(body['sdkVersion'], '231500');
    });
  });

  group('迅雷 JWT', () {
    test('从 access_token 的 payload 取 sub', () {
      final payload = base64Url
          .encode(utf8.encode('{"sub":"123456","exp":1700000000}'))
          .replaceAll('=', '');
      expect(xunleiJwtSub('head.$payload.sign'), '123456');
      expect(xunleiJwtSub('not-a-jwt'), '');
    });
  });

  group('迅雷账号持久化', () {
    test('JSON 往返保留令牌与开关', () {
      const account = XunleiAccount(
        accessToken: 'at',
        refreshToken: 'rt',
        tokenType: 'Bearer',
        expiresAt: 123,
        userId: 'u1',
        nickName: '迅雷会员',
        deviceId: '0123456789abcdef0123456789abcdef',
        peerId: 'fedcba9876543210fedcba9876543210',
        enabled: false,
      );
      final back = XunleiAccount.fromJsonString(account.toJsonString());
      expect(back.accessToken, 'at');
      expect(back.refreshToken, 'rt');
      expect(back.expiresAt, 123);
      expect(back.nickName, '迅雷会员');
      expect(back.deviceId, account.deviceId);
      expect(back.peerId, account.peerId);
      expect(back.enabled, isFalse);
      expect(back.loggedIn, isTrue);
    });

    test('空串 / 坏 JSON 回落未登录，默认开启', () {
      final empty = XunleiAccount.fromJsonString('');
      expect(empty.loggedIn, isFalse);
      expect(empty.enabled, isTrue);
      expect(XunleiAccount.fromJsonString('not json').loggedIn, isFalse);
    });

    test('展示名优先昵称，其次用户号', () {
      expect(const XunleiAccount(nickName: '小明').displayName, '小明');
      expect(
        const XunleiAccount(userId: '1234567890').displayName,
        '迅雷用户 123456…',
      );
      expect(const XunleiAccount().displayName, '迅雷账号');
    });
  });
}
