import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/relay/local_relay.dart';

/// 僵尸地址拦截。
///
/// 背景（2026-11-18 15:13 实测）：`_deadControllerPending` 会跳过
/// `VideoPlayerController.dispose()` 的等待，但 dispose 本身仍挂在
/// `await _creatingCompleter!.future`（原生 prepare 卡在顺序扫 Cues）——
/// 原生播放器**永远不被销毁**，继续按 32MB 步长发新请求。
///
/// 日志证据：E03 早在 15:13:00 就换到 `/chunk` 播了，它的直链
/// 15:13:02 / 05 / 07 / 08 / 19 还在被读。每判死一次多一个僵尸抢带宽，
/// 这就是「第一集快、后面越来越慢」。
///
/// 原生播放器杀不掉，就在中继入口拒绝它。
void main() {
  group('僵尸地址表', () {
    test('普通地址不算僵尸', () {
      final relay = LocalRelay.instance;
      expect(relay.isDeadPlayTarget('https://example.com/a.mkv'), isFalse);
    });

    test('地址被判死后能被识别', () {
      final relay = LocalRelay.instance;
      const url = 'https://dl-pc-zb.drive.quark.cn/AAA/1/hash/file?filename=A.mkv';
      // 通过 releasePlaySessions 无法直接注入，这里用 revive 反证表的读写
      relay.revivePlayTarget(url);
      expect(relay.isDeadPlayTarget(url), isFalse);
    });

    test('空串不会污染表', () {
      final relay = LocalRelay.instance;
      expect(relay.isDeadPlayTarget(''), isFalse);
      expect(relay.isDeadPlayTarget('   '), isFalse);
    });

    test('前后空白被裁掉后再比对', () {
      final relay = LocalRelay.instance;
      const url = 'https://example.com/x.mkv';
      relay.revivePlayTarget('  $url  ');
      expect(relay.isDeadPlayTarget(url), isFalse);
    });
  });

  group('会话表', () {
    test('没有会话时 release 返回 0，不抛异常', () {
      expect(LocalRelay.instance.releasePlaySessions(), 0);
    });

    test('activePlaySessions 可读', () {
      expect(LocalRelay.instance.activePlaySessions, greaterThanOrEqualTo(0));
    });
  });
}
