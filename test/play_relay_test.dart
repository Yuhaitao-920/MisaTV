import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/models/vod.dart';
import 'package:kniephos/state/app_state.dart';

void main() {
  group('播放地址中继判定', () {
    test('网盘直链即使没有 header 也要走中继注入 Cookie', () {
      const play = PlayResult(url: 'https://pan.quark.cn/x.mp4');
      expect(AppState.needsRelayForPlay(play, 'quark'), isTrue);
      expect(AppState.needsRelayForPlay(play, ''), isFalse);
      // 蜘蛛自己的本机取流代理不需要再套一层中继。
      expect(
        AppState.needsRelayForPlay(
          const PlayResult(url: 'http://127.0.0.1:1234/proxy'),
          'quark',
        ),
        isFalse,
      );
    });

    test('header / m3u8 / 去广告仍然走中继', () {
      expect(
        AppState.needsRelayForPlay(
          const PlayResult(
            url: 'https://a.test/x.mp4',
            headers: {'Referer': 'x'},
          ),
          '',
        ),
        isTrue,
      );
      expect(
        AppState.needsRelayForPlay(
          const PlayResult(url: 'https://a.test/x.m3u8'),
          '',
        ),
        isTrue,
      );
      expect(
        AppState.needsRelayForPlay(
          const PlayResult(url: 'https://a.test/x.mp4'),
          '',
          purify: true,
        ),
        isTrue,
      );
      expect(
        AppState.needsRelayForPlay(const PlayResult(url: ''), ''),
        isFalse,
      );
    });

    test('本机取流地址带 header / 去广告也不套中继', () {
      // 加固壳的 /chunk 会发两个 Content-Length，套中继会被 dart:io 解析器拒绝。
      expect(
        AppState.needsRelayForPlay(
          const PlayResult(
            url: 'http://127.0.0.1:19979/chunk?id=abc&thread=32&chunk=64',
            headers: {'User-Agent': 'okhttp/3.12.13'},
          ),
          'quark',
          purify: true,
        ),
        isFalse,
      );
      expect(
        AppState.needsRelayForPlay(
          const PlayResult(
            url: 'http://localhost:1234/proxy/0?do=pan',
            headers: {'Referer': 'https://x.test/'},
          ),
          '',
          purify: true,
        ),
        isFalse,
      );
    });
  });
}
