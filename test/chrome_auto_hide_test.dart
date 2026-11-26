import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/ui/pages/player/chrome_auto_hide.dart';

/// 播放器控制栏自动隐藏。
///
/// 用户反馈的原问题是：「单击唤出顶栏/底栏后，还在找按钮就自动隐藏了」。
/// 现在的约定是：鼠标停在上下栏上时不收起，离开后重新计时。
void main() {
  late int hideCount;
  late bool playing;

  PlayerChromeAutoHide build({
    Duration delay = const Duration(milliseconds: 50),
  }) {
    return PlayerChromeAutoHide(
      hideDelay: delay,
      isPlaying: () => playing,
      onHide: () => hideCount++,
    );
  }

  setUp(() {
    hideCount = 0;
    playing = true;
  });

  test('到点自动收起', () async {
    final chrome = build();
    chrome.schedule();
    expect(chrome.isPending, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 90));
    expect(hideCount, 1);
    chrome.dispose();
  });

  test('鼠标停在栏上时不收起，离开后才收起', () async {
    final chrome = build();
    chrome.schedule();
    chrome.setHovering(true);
    expect(chrome.isPending, isFalse, reason: '进入即取消倒计时');

    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(hideCount, 0, reason: '悬停期间不能收起');

    chrome.setHovering(false);
    expect(chrome.isPending, isTrue, reason: '离开后重新计时');
    await Future<void>.delayed(const Duration(milliseconds: 90));
    expect(hideCount, 1);
    chrome.dispose();
  });

  test('悬停状态下的 schedule 不会启动倒计时', () async {
    final chrome = build();
    chrome.setHovering(true);
    chrome.schedule();
    expect(chrome.isPending, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 90));
    expect(hideCount, 0);
    chrome.dispose();
  });

  test('暂停时不自动收起', () async {
    playing = false;
    final chrome = build();
    chrome.schedule();
    await Future<void>.delayed(const Duration(milliseconds: 90));
    expect(hideCount, 0, reason: '暂停时控制栏应保持可见');
    chrome.dispose();
  });

  test('手动收起后残留计时器不会再次触发', () async {
    final chrome = build();
    chrome.schedule();
    chrome.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 90));
    expect(hideCount, 0);
    chrome.dispose();
  });

  test('重复 schedule 只按最后一次计时', () async {
    final chrome = build(delay: const Duration(milliseconds: 80));
    chrome.schedule();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    chrome.schedule(); // 重置
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(hideCount, 0, reason: '第一次的计时应已被取消');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(hideCount, 1);
    chrome.dispose();
  });

  test('dispose 后不再回调', () async {
    final chrome = build();
    chrome.schedule();
    chrome.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 90));
    expect(hideCount, 0);
  });

  test('setHovering 幂等：重复同一值不重置计时', () async {
    final chrome = build(delay: const Duration(milliseconds: 60));
    chrome.schedule();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    chrome.setHovering(false); // 本来就 false，不该重置
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(hideCount, 1, reason: '未变化时不应延长显示时间');
    chrome.dispose();
  });
}
