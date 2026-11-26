import 'dart:async';

/// 播放器控制栏（顶栏 + 底栏）的自动隐藏策略。
///
/// 从 `_PlayerPageState` 里抽出来的原因：这段逻辑有明确的几条规则，单独成类
/// 才能被单测覆盖，而不是只能靠手动点播放器验证。
///
/// 规则：
/// 1. 控制栏显示后开始 [hideDelay] 倒计时，到点自动收起（仅在播放中）。
/// 2. 鼠标停在顶栏 / 底栏上时**不收起**——用户多半正在里面找按钮，
///    这时候整条栏消失会直接打断操作。
/// 3. 鼠标离开后重新开始倒计时，与「唤出后不作任何操作」行为一致。
/// 4. 收起后移动鼠标只负责显示光标，不重新唤出控制栏。
class PlayerChromeAutoHide {
  PlayerChromeAutoHide({
    required this.hideDelay,
    required this.onHide,
    required this.isPlaying,
  });

  /// 无操作多久后收起。
  final Duration hideDelay;

  /// 真正执行收起（把 `_controls` 置 false）。
  final void Function() onHide;

  /// 是否正在播放：暂停时控制栏不该自动消失。
  final bool Function() isPlaying;

  Timer? _timer;

  /// 鼠标是否停在顶栏 / 底栏上。
  bool hovering = false;

  /// 倒计时是否在走（供测试断言）。
  bool get isPending => _timer?.isActive ?? false;

  /// 控制栏刚显示 / 有交互时调用：重置倒计时。
  void schedule() {
    _timer?.cancel();
    if (hovering) return;
    _timer = Timer(hideDelay, () {
      if (hovering || !isPlaying()) return;
      onHide();
    });
  }

  /// 鼠标进入 / 离开顶栏与底栏。返回是否有状态变化。
  void setHovering(bool value) {
    if (hovering == value) return;
    hovering = value;
    if (value) {
      // 进入：立刻取消，别让残留的计时器把栏收掉。
      _timer?.cancel();
      return;
    }
    schedule();
  }

  /// 立即停止倒计时（例如用户手动点击收起控制栏）。
  void cancel() => _timer?.cancel();

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
